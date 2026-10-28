import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

enum PDDPermissionSettingsPage: Equatable {
    case accessibility
    case screenRecording

    fileprivate var url: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}

enum AutoReplyScope: Equatable {
    case testUID(String)
    case allUsersLocked
    case allUsers
}

enum AutoReplyRuntimeCreationError: LocalizedError {
    case codexUnavailable
    case knowledgeResourcesUnavailable
    case senseVoiceResourcesUnavailable
    case codexPrewarmFailed

    var errorDescription: String? {
        switch self {
        case .codexUnavailable: return BilingualText.lines("未找到可执行的本机 Codex CLI", "No executable local Codex CLI was found")
        case .knowledgeResourcesUnavailable: return BilingualText.lines("主要知识目录或检索运行资源不可用", "Primary knowledge folder or retrieval runtime is unavailable")
        case .senseVoiceResourcesUnavailable: return BilingualText.lines("未找到完整的 SenseVoiceSmall INT8 资源", "Complete SenseVoiceSmall INT8 resources were not found")
        case .codexPrewarmFailed: return BilingualText.lines("Codex CLI 启动检查未通过", "Codex CLI startup check failed")
        }
    }
}

@MainActor
protocol AutoReplyRunning: AnyObject {
    var onStateChange: (@MainActor () -> Void)? { get set }
    var jobs: [AutoReplyJob] { get }
    var currentUIOwner: String? { get }
    var latestCapture: AutoReplyCapture? { get }
    var liveGenerationCount: Int { get }
    var lastAXWakeAt: Date? { get }
    var codexExecutablePath: String? { get }
    var latestKnowledgeDiagnostic: KnowledgeRetrievalDiagnostic? { get }
    var latestResourceSnapshot: RuntimeResourceSnapshot? { get }
    var lastRuntimeIssue: String? { get }
    var latestVideoStatus: PDDVideoProgressStatus? { get }
    func setDeliveryEnabled(_ enabled: Bool)
    func requestAXRefresh()
    func start()
    func stop()
    func tick() async
}

extension AutoReplyScheduler: AutoReplyRunning {}

extension AutoReplyRunning {
    var latestVideoStatus: PDDVideoProgressStatus? { nil }
}

@MainActor
final class AutoReplyViewModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published var isDryRun = false
    @Published private(set) var scope: AutoReplyScope = .allUsers
    @Published private(set) var status = BilingualText.lines("准备自动启动 · 截图红点 · OCR 正文 · AX 操作 · 10 秒兜底", "Preparing automatic startup · screenshot red dots · OCR text · AX actions · 10-second fallback")
    @Published private(set) var jobs: [AutoReplyJob] = []
    @Published private(set) var currentUIOwner: String?
    @Published private(set) var latestCapture: AutoReplyCapture?
    @Published private(set) var liveGenerationCount = 0
    @Published private(set) var lastAXWakeAt: Date?
    @Published private(set) var codexExecutablePath: String?
    @Published private(set) var latestKnowledgeDiagnostic: KnowledgeRetrievalDiagnostic?
    @Published private(set) var latestResourceSnapshot: RuntimeResourceSnapshot?
    @Published private(set) var lastRuntimeIssue: String?
    @Published private(set) var latestVideoStatus: PDDVideoProgressStatus?
    @Published private(set) var compatibilityReport: PDDCompatibilityReport?

    var canStart: Bool { compatibilityReport?.overallStatus != .fail }

    private let runtime: any AutoReplyRunning
    private let identity: PDDRuntimeIdentity
    private let sessionLock: any AutoReplyLocking
    private let permissionCheck: @Sendable () -> Bool
    private let screenRecordingPermissionCheck: @Sendable () -> Bool
    private let permissionSettingsOpener: (PDDPermissionSettingsPage) -> Bool
    private let permissionPrompt: @Sendable () -> Bool
    private let axNotificationListener: any AXNotificationListening
    private let runIntentStore: any AutoReplyRunIntentStoring
    private let diskHealthChecker: (any AutoReplyDiskHealthChecking)?
    private let compatibilityCheck: @MainActor () async -> PDDCompatibilityReport
    private let startupPrewarm: (@Sendable () async throws -> Void)?
    private var loopTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var startupPrepared = false
    private var desiredRunning = false

    init(
        runtime: any AutoReplyRunning,
        identity: PDDRuntimeIdentity = .currentAutoReply(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ),
        sessionLock: any AutoReplyLocking = AutoReplySessionLock(),
        permissionCheck: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        screenRecordingPermissionCheck: @escaping @Sendable () -> Bool = {
            CGPreflightScreenCaptureAccess()
        },
        permissionSettingsOpener: @escaping (PDDPermissionSettingsPage) -> Bool = {
            NSWorkspace.shared.open($0.url)
        },
        axNotificationListener: (any AXNotificationListening)? = nil,
        runIntentStore: any AutoReplyRunIntentStoring = VolatileAutoReplyRunIntentStore(),
        diskHealthChecker: (any AutoReplyDiskHealthChecking)? = nil,
        startupPrewarm: (@Sendable () async throws -> Void)? = nil,
        compatibilityCheck: @escaping @MainActor () async -> PDDCompatibilityReport = {
            await PDDCompatibilityChecker.check()
        },
        permissionPrompt: @escaping @Sendable () -> Bool = {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
    ) {
        self.runtime = runtime
        self.identity = identity
        self.sessionLock = sessionLock
        self.permissionCheck = permissionCheck
        self.screenRecordingPermissionCheck = screenRecordingPermissionCheck
        self.permissionSettingsOpener = permissionSettingsOpener
        self.permissionPrompt = permissionPrompt
        self.runIntentStore = runIntentStore
        self.diskHealthChecker = diskHealthChecker
        self.startupPrewarm = startupPrewarm
        self.compatibilityCheck = compatibilityCheck
        self.axNotificationListener = axNotificationListener ?? AXNotificationWakeup()
        self.runtime.onStateChange = { [weak self] in self?.refreshSnapshot() }
        self.axNotificationListener.callback = { [weak runtime] in
            runtime?.requestAXRefresh()
        }
        refreshSnapshot()
    }

    convenience init() {
        let mode = PDDAppMode(bundleIdentifier: Bundle.main.bundleIdentifier)
        let identity = PDDRuntimeIdentity.forMode(mode)
        do {
            let assembly = try Self.makeLiveRuntime(identity: identity)
            self.init(
                runtime: assembly.runtime,
                identity: identity,
                sessionLock: AutoReplySessionLock(lockURLs: identity.sessionLockURLs),
                runIntentStore: AutoReplyRunIntentStore(rootDirectory: identity.dataRoot),
                diskHealthChecker: AutoReplyDiskHealthChecker(rootDirectory: identity.dataRoot),
                startupPrewarm: { try await assembly.prewarmer.prepare() }
            )
        } catch {
            let unavailable = UnavailableAutoReplyRuntime()
            self.init(runtime: unavailable, identity: identity)
            status = BilingualText.lines("初始化失败：\(error.localizedDescription)", "Initialization failed: \(error.localizedDescription)")
        }
    }

    func checkUnreadOnly() async {
        guard !isRunning else { return }
        status = BilingualText.lines("正在只读检查会话红点，不生成或发送回复…", "Checking unread markers only; no reply will be generated or sent…")
        do {
            let backend = LivePDDAXBackend()
            let detector = PDDLiveUnreadEvidenceDetector(requireConversationRows: true)
            let tree = try backend.readSemanticTree()
            let unread = try await detector.unreadRows(in: tree)
            if unread.isEmpty {
                status = BilingualText.lines("会话列表已读取，未匹配到客户未读红点。未发送消息。", "Conversation list read successfully; no customer unread marker matched. No message sent.")
            } else {
                let names = unread.map(\.visibleLabel).joined(separator: ", ")
                status = BilingualText.lines("检测到 \(unread.count) 个未读会话：\(names)。仅检查，未打开客户或发送消息。", "Detected \(unread.count) unread conversation(s): \(names). Check only; no customer opened or message sent.")
            }
        } catch {
            status = BilingualText.lines("未读检查失败：\(error.localizedDescription)", "Unread check failed: \(error.localizedDescription)")
        }
    }

    func viewAppeared() {
        if CommandLine.arguments.contains("--start-stopped") {
            status = BilingualText.lines("已停止 · 请手动开始", "Stopped · press Start when ready")
            return
        }
        let persistedIntent = (try? runIntentStore.load()) ?? false
        if identity.startsAutomatically || persistedIntent {
            start()
        } else {
            status = BilingualText.lines("已停止 · 候选版需手动开始", "Stopped · this candidate build must be started manually")
        }
    }

    func viewDisappeared() {
        // SwiftUI may transiently remove the main view while AppKit presents the
        // independent progress panel. Autonomous reply must continue until the
        // user explicitly presses Stop or the process exits.
    }

    func start() {
        guard !isRunning else { return }
        guard canStart else {
            status = BilingualText.lines("兼容性检查未通过；请修复失败项后重新检查", "Compatibility check failed; fix the failed items and check again")
            return
        }
        desiredRunning = true
        do {
            try runIntentStore.save(desiredRunning: true)
        } catch {
            status = BilingualText.lines("等待运行环境恢复：\(error.localizedDescription)", "Waiting for the runtime environment to recover: \(error.localizedDescription)")
            scheduleEnvironmentRecovery()
            return
        }
        beginStartupPreparation()
    }

    private func beginStartupPreparation() {
        guard desiredRunning, !isRunning, prewarmTask == nil else { return }
        guard !startupPrepared, let startupPrewarm else {
            attemptRuntimeStart()
            return
        }
        status = BilingualText.lines("正在预热 OCR、知识库、SenseVoice 和 Codex…", "Prewarming OCR, knowledge base, SenseVoice, and Codex…")
        prewarmTask = Task { [weak self] in
            do {
                try await startupPrewarm()
                guard let self, !Task.isCancelled, self.desiredRunning else { return }
                self.startupPrepared = true
                self.prewarmTask = nil
                self.attemptRuntimeStart()
            } catch {
                guard let self, !Task.isCancelled, self.desiredRunning else { return }
                self.prewarmTask = nil
                self.status = BilingualText.lines("启动预热失败，等待自动重试：\(error.localizedDescription)", "Startup prewarm failed; waiting to retry automatically: \(error.localizedDescription)")
                self.scheduleEnvironmentRecovery()
            }
        }
    }

    private func attemptRuntimeStart() {
        guard desiredRunning, !isRunning else { return }
        do {
            try diskHealthChecker?.check()
        } catch {
            status = BilingualText.lines("等待运行环境恢复：\(error.localizedDescription)", "Waiting for the runtime environment to recover: \(error.localizedDescription)")
            scheduleEnvironmentRecovery()
            return
        }
        guard permissionCheck() || permissionPrompt() else {
            status = BilingualText.lines("需要辅助功能权限；请在系统设置中允许本应用", "Accessibility permission is required; allow this app in System Settings")
            scheduleEnvironmentRecovery()
            return
        }
        guard screenRecordingPermissionCheck() else {
            status = BilingualText.lines("需要录屏权限；等待系统设置授权后自动继续", "Screen Recording permission is required; operation will continue after authorization")
            scheduleEnvironmentRecovery()
            return
        }
        do {
            guard try sessionLock.acquire() else {
                status = BilingualText.lines("另一个自动回复实例正在运行", "Another automatic-reply instance is running")
                scheduleEnvironmentRecovery()
                return
            }
        } catch {
            status = BilingualText.lines("运行锁失败：\(error.localizedDescription)", "Runtime lock failed: \(error.localizedDescription)")
            scheduleEnvironmentRecovery()
            return
        }

        runtime.setDeliveryEnabled(!isDryRun)
        runtime.start()
        axNotificationListener.start()
        isRunning = true
        recoveryTask?.cancel()
        recoveryTask = nil
        status = isDryRun
            ? BilingualText.lines("运行中 · 干运行（不会发送）", "Running · dry run (nothing will be sent)")
            : BilingualText.lines("运行中 · 允许 AX 发送", "Running · AX sending enabled")
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                await self.runtime.tick()
                self.refreshSnapshot()
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func scheduleEnvironmentRecovery() {
        guard desiredRunning, recoveryTask == nil else { return }
        recoveryTask = Task { [weak self] in
            var delay: UInt64 = 1
            while let self, !Task.isCancelled, self.desiredRunning, !self.isRunning {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.beginStartupPreparation()
                delay = min(30, delay * 2)
            }
            self?.recoveryTask = nil
        }
    }

    func stop() {
        desiredRunning = false
        recoveryTask?.cancel()
        recoveryTask = nil
        prewarmTask?.cancel()
        prewarmTask = nil
        do {
            try runIntentStore.save(desiredRunning: false)
        } catch {
            status = BilingualText.lines("停止意图保存失败：\(error.localizedDescription)", "Could not save the stop intent: \(error.localizedDescription)")
        }
        guard isRunning else { return }
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        runtime.stop()
        axNotificationListener.stop()
        sessionLock.release()
        refreshSnapshot()
        status = BilingualText.lines("已停止", "Stopped")
    }

    func setDryRun(_ enabled: Bool) {
        guard !isRunning else { return }
        isDryRun = enabled
    }

    func openRecordsDirectory() {
        let directory = identity.dataRoot
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    func openRequiredPermissionSettings() {
        if !permissionCheck() {
            _ = permissionSettingsOpener(.accessibility)
            status = BilingualText.lines("已打开辅助功能权限设置", "Accessibility permission settings opened")
        } else if !screenRecordingPermissionCheck() {
            _ = permissionSettingsOpener(.screenRecording)
            status = BilingualText.lines("已打开录屏与系统录音权限设置", "Screen and system-audio recording settings opened")
        } else {
            status = BilingualText.lines("所需权限已开启", "Required permissions are enabled")
        }
    }

    func runCompatibilityCheck() async {
        status = BilingualText.lines("正在检查兼容性…", "Checking compatibility…")
        let report = await compatibilityCheck()
        compatibilityReport = report
        status = report.summary
    }

    func exportCompatibilityReport(to destination: URL) throws {
        guard let compatibilityReport else {
            throw CocoaError(.fileNoSuchFile)
        }
        try compatibilityReport.redactedJSON().write(to: destination, options: .atomic)
    }

    func saveCompatibilityReport() {
        guard compatibilityReport != nil else {
            status = BilingualText.lines("请先运行兼容性检查", "Run the compatibility check first")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "拼多多兼容性检查-\(Int(Date().timeIntervalSince1970)).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportCompatibilityReport(to: url)
            status = BilingualText.lines("兼容性报告已导出", "Compatibility report exported")
        } catch {
            status = BilingualText.lines("兼容性报告导出失败：\(error.localizedDescription)", "Compatibility report export failed: \(error.localizedDescription)")
        }
    }

    private func refreshSnapshot() {
        jobs = runtime.jobs
        currentUIOwner = runtime.currentUIOwner
        latestCapture = runtime.latestCapture
        liveGenerationCount = runtime.liveGenerationCount
        lastAXWakeAt = runtime.lastAXWakeAt
        codexExecutablePath = runtime.codexExecutablePath
        latestKnowledgeDiagnostic = runtime.latestKnowledgeDiagnostic
        latestResourceSnapshot = runtime.latestResourceSnapshot
        lastRuntimeIssue = runtime.lastRuntimeIssue
        latestVideoStatus = runtime.latestVideoStatus
    }

    private struct LiveRuntimeAssembly: Sendable {
        let runtime: AutoReplyScheduler
        let prewarmer: PDDStartupPrewarmer
    }

    private static func makeLiveRuntime(identity: PDDRuntimeIdentity) throws -> LiveRuntimeAssembly {
        let root = identity.dataRoot
        let leaseGate = PDDUIOperationLeaseGate()
        let videoRelay = PDDVideoTransferRelay()
        let videoRegistry = PDDVideoTransferRegistry()
        let videoRoot = root.appendingPathComponent("videos", isDirectory: true)
        let videoAnalysisInbox = PDDVideoAnalysisInbox(
            stateURL: videoRoot.appendingPathComponent("content-hashes.json"),
            legacySchedulerRoot: root
        )
        let videoStateStore = PDDDurableVideoTransferStore(
            url: videoRoot.appendingPathComponent("transfer-state.json")
        )
        let backend = LeaseValidatedPDDAXBackend(
            base: LivePDDAXBackend(), gate: leaseGate
        )
        let localKnowledge = DirectLocalKnowledge()
        try localKnowledge.validate()
        let senseVoice = PDDSenseVoiceResourceLocator.resolve().flatMap { resources in
            PythonRuntimeResolver.resolve(resourceRootURL: Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")).map { python in
                PDDSenseVoiceFactory.make(resources: resources, pythonURL: python.executableURL,
                    knowledgeSitePackagesURL: python.executableURL.deletingLastPathComponent())
            }
        }
        let speechTranscriber: any PDDVideoSpeechTranscribing
        if let senseVoice {
            speechTranscriber = PDDAppleThenFallbackVideoSpeechTranscriber(
                primary: PDDAppleVideoSpeechTranscriber(), fallback: senseVoice
            )
        } else {
            // Native speech can return no transcript; video frames remain usable.
            speechTranscriber = PDDAppleVideoSpeechTranscriber()
        }
        let videoArmer = PDDVideoTransferArmer(
            destinationRoot: videoRoot,
            registry: videoRegistry,
            analysisInbox: videoAnalysisInbox,
            stateStore: videoStateStore,
            speechTranscriber: speechTranscriber,
            eventHandler: { event in
                await videoRelay.send(event)
                if event.phase == .readyForGeneration {
                    try? await videoStateStore.transition(key: event.key, to: .admitted)
                }
            }
        )
        let ocrEngine = PDDPaddleOCREngine()
        let conversation = PDDAXConversationDriver(
            backend: backend,
            chatStore: PerUserChatStore(rootDirectory: root),
            allowedUIDs: nil,
            ocrSupplement: PDDLiveOCRSupplement(engine: ocrEngine),
            imageResolver: PDDAXImagePreviewResolver(
                clicker: CGEventPDDImageDoubleClicker(),
                reader: LivePDDImagePreviewReader()
            ),
            imageDownloader: PDDCustomerImageDownloader(),
            imageRootDirectory: root.appendingPathComponent("images", isDirectory: true),
            videoArmer: videoArmer,
            videoPreviewOpener: PDDAXVideoPreviewOpener(backend: backend)
        )
        let sender = PDDAXReplySender(backend: backend, opener: conversation)
        let transferer = PDDAXConversationTransferer(
            backend: backend, opener: conversation, clicker: CGEventPDDTransferClicker()
        )
        let driver = PDDLiveAutoReplyDriver(
            conversationDriver: conversation, sender: sender,
            transferer: transferer, leaseGate: leaseGate
        )
        guard let codexURL = CodexInstallation.resolve() else {
            throw AutoReplyRuntimeCreationError.codexUnavailable
        }
        let codexEnvironment = try CodexHomeManager(dataRoot: root).prepare()
        let codexRunner = CodexProcessRunner(environment: codexEnvironment.values)
        let evidencePreparer = localKnowledge
        let scheduler = try AutoReplyScheduler(
            driver: driver,
            generator: AutoReplyCodexGenerator(
                executableURL: codexURL,
                runner: codexRunner,
                sessionRegistry: CodexSessionRegistry(rootDirectory: root),
                evidencePreparer: evidencePreparer,
                loginStatusProvider: CodexLoginCache(
                    checker: LiveCodexLoginChecker(runner: codexRunner)
                )
            ),
            store: AutoReplyStore(rootDirectory: root),
            codexExecutablePath: codexURL.path
        )
        let sink = AutoReplyVideoSchedulerSink(scheduler: scheduler)
        Task {
            await videoRelay.install { event in
                await sink.receive(event)
            }
        }
        scheduler.setBackgroundLifecycleHandler { revision, enabled in
            guard await videoRegistry.setDesired(revision: revision, enabled: enabled),
                  enabled else { return }
            let batches = await MainActor.run { sink.pendingBatches() }
            for batch in batches {
                let completed = Set(batch.completedAttachmentsByMessageID.keys)
                    .union(batch.failedMessageIDs)
                    .union(batch.duplicateMessageIDs)
                for messageID in batch.expectedMessageIDs where !completed.contains(messageID) {
                    let key = PDDVideoTransferKey(uid: batch.uid, messageID: messageID)
                    switch PDDBackgroundVideoRecovery.action(
                        root: videoRoot, uid: batch.uid, messageID: messageID
                    ) {
                    case .reopen(let uid, let messageID):
                        await MainActor.run { sink.requestRecovery(uid: uid, messageID: messageID) }
                    case .prepareEvidence(let uid, let messageID, let stableURL):
                        _ = await videoRegistry.start(key: key) {
                            await PDDBackgroundVideoRecovery.resumeStableVideo(
                                root: videoRoot, uid: uid, messageID: messageID,
                                stableURL: stableURL,
                                analysisInbox: videoAnalysisInbox,
                                speechTranscriber: speechTranscriber,
                                eventHandler: { event in await videoRelay.send(event) }
                            )
                        }
                    }
                }
            }
            while await videoRegistry.isEnabled(for: revision) {
                if let due = try? await videoStateStore.claimDueRecords() {
                    for record in due {
                        let stableURL = PDDBackgroundVideoRecovery.stableVideoURL(
                            root: videoRoot, key: record.key
                        )
                        if FileManager.default.fileExists(atPath: stableURL.path) {
                            _ = await videoRegistry.start(key: record.key) {
                                await PDDBackgroundVideoRecovery.resumeStableVideo(
                                    root: videoRoot, uid: record.uid,
                                    messageID: record.messageID, stableURL: stableURL,
                                    analysisInbox: videoAnalysisInbox,
                                    speechTranscriber: speechTranscriber, recovered: true,
                                    failureHandler: { _ in
                                        try? FileManager.default.removeItem(at: stableURL)
                                        let latest = try? await videoStateStore.record(record.key)
                                        if let delay = PDDVideoRetryPolicy.delay(
                                            afterFailure: latest?.retryIndex ?? 0
                                        ) {
                                            try? await videoStateStore.scheduleRetry(
                                                key: record.key, category: .invalidVideo,
                                                nextAttemptAt: Date().addingTimeInterval(delay)
                                            )
                                        } else {
                                            try? await videoStateStore.transition(
                                                key: record.key, to: .terminalFailure,
                                                failure: .retryBudgetExhausted
                                            )
                                        }
                                    },
                                    eventHandler: { event in
                                        await videoRelay.send(event)
                                        if event.phase == .readyForGeneration {
                                            try? await videoStateStore.transition(
                                                key: event.key, to: .admitted
                                            )
                                        }
                                    }
                                )
                            }
                        } else {
                            await MainActor.run {
                                sink.requestRecovery(uid: record.uid, messageID: record.messageID)
                            }
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let prewarmer = PDDStartupPrewarmer(
            warmOCR: { try await ocrEngine.prewarm() },
            warmKnowledge: { try localKnowledge.validate() },
            warmSenseVoice: { if let senseVoice { try await senseVoice.prepare() } },
            checkCodex: {
                guard await CodexCompatibilityProbe().check(executableURL: codexURL) == .ready else {
                    throw AutoReplyRuntimeCreationError.codexPrewarmFailed
                }
            }
        )
        return LiveRuntimeAssembly(runtime: scheduler, prewarmer: prewarmer)
    }
}

@MainActor
private final class AutoReplyVideoSchedulerSink {
    weak var scheduler: AutoReplyScheduler?
    init(scheduler: AutoReplyScheduler) { self.scheduler = scheduler }
    func receive(_ event: PDDVideoTransferEvent) async {
        await scheduler?.receiveVideoTransferEvent(event)
    }
    func pendingBatches() -> [PDDPendingVideoBatch] {
        scheduler?.pendingVideoBatchesSnapshot ?? []
    }
    func requestRecovery(uid: String, messageID: String) {
        scheduler?.requestVideoRecovery(uid: uid, messageID: messageID)
    }
}

@MainActor
private final class UnavailableAutoReplyRuntime: AutoReplyRunning {
    var onStateChange: (@MainActor () -> Void)?
    var jobs: [AutoReplyJob] { [] }
    var currentUIOwner: String? { nil }
    var latestCapture: AutoReplyCapture? { nil }
    var liveGenerationCount: Int { 0 }
    var lastAXWakeAt: Date? { nil }
    var codexExecutablePath: String? { nil }
    var latestKnowledgeDiagnostic: KnowledgeRetrievalDiagnostic? { nil }
    var latestResourceSnapshot: RuntimeResourceSnapshot? { nil }
    var lastRuntimeIssue: String? { nil }
    var latestVideoStatus: PDDVideoProgressStatus? { nil }
    func setDeliveryEnabled(_ enabled: Bool) {}
    func start() {}
    func stop() {}
    func tick() async {}
    func requestAXRefresh() {}
}
