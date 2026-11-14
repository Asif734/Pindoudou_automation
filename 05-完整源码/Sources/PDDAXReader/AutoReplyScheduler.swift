import Foundation

struct AutoReplyDiscovery: Equatable, Sendable {
    let uid: String
    let hasUnreadEvidence: Bool
    var hasUncapturedCustomerMessages = false
}

enum AutoReplyDeliveryResult: Equatable, Sendable {
    case sent(serviceMessageID: String)
    case failedBeforeSend(String)
    case discardedBeforeSend(String)
    case uncertain(String)
}

enum AutoReplyTransferResult: Equatable, Sendable {
    case transferred(agentLabel: String)
    case failed(String)
}

@MainActor
protocol AutoReplyAutomationDriver: AnyObject {
    var supportsTextDeliveryTracking: Bool { get }
    func reconcileTextDelivery(uid: String, text: String, deliveryID: UUID,
        expectedCustomerMessageIDs: Set<String>, lease: UIOperationLease) async throws -> AutoReplyDeliveryResult
    func acknowledgeDiscoveryCapture(_ capture: AutoReplyCapture) throws
    func reconcileVisibleIdentity(in tree: PDDAXSemanticTree) throws
    func visibleConversationsSnapshot() -> [PDDConversationLocator]?
    func send(uid: String, text: String, outgoingImages: [DatasetReplyImage], deliveryID: UUID,
              expectedCustomerCursor: AutoReplyCursor, expectedCustomerMessageIDs: Set<String>,
              lease: UIOperationLease) async throws -> AutoReplyDeliveryResult
    func discover() async throws -> [AutoReplyDiscovery]
    func capture(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture
    func preflight(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture?
    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor
    ) async throws -> AutoReplyDeliveryResult
    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor,
        expectedCustomerMessageIDs: Set<String>
    ) async throws -> AutoReplyDeliveryResult
    func transferToAnyHuman(
        uid: String, lease: UIOperationLease
    ) async throws -> AutoReplyTransferResult
    func discover(lease: UIOperationLease) async throws -> [AutoReplyDiscovery]
    func capture(
        uid: String, after cursor: AutoReplyCursor, lease: UIOperationLease
    ) async throws -> AutoReplyCapture
    func capture(
        uid: String, after cursor: AutoReplyCursor, includeImages: Bool,
        lease: UIOperationLease
    ) async throws -> AutoReplyCapture
    func capture(
        uid: String, after cursor: AutoReplyCursor, includeImages: Bool,
        onlyVideoMessageID: String?, lease: UIOperationLease
    ) async throws -> AutoReplyCapture
    func preflight(
        uid: String, after cursor: AutoReplyCursor, lease: UIOperationLease
    ) async throws -> AutoReplyCapture?
    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor,
        lease: UIOperationLease
    ) async throws -> AutoReplyDeliveryResult
    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor,
        expectedCustomerMessageIDs: Set<String>,
        lease: UIOperationLease
    ) async throws -> AutoReplyDeliveryResult
    func revokeCurrentUIOperation(operationID: UUID) async
    func restoreConversationLocators(_ locators: [String: PDDConversationLocator])
    func restoreConversationCaptureState(
        baselinedUIDs: Set<String>,
        knownServiceMessageIDsByUID: [String: Set<String>]
    )
    func conversationLocatorsSnapshot() -> [String: PDDConversationLocator]?
    func takeConversationDiagnostics() -> [PDDConversationDiagnostic]
    func restoreProvisionalReceipts(_ receipts: [String: [PDDProvisionalReceipt]])
    func provisionalReceiptsSnapshot() -> [String: [PDDProvisionalReceipt]]?
    func restoreMessageSourceSelectorStates(_ states: [String: PDDMessageSourceSelectorState])
    func messageSourceSelectorStatesSnapshot() -> [String: PDDMessageSourceSelectorState]?
}

extension AutoReplyAutomationDriver {
    var supportsTextDeliveryTracking: Bool { false }
    func reconcileTextDelivery(uid: String, text: String, deliveryID: UUID,
        expectedCustomerMessageIDs: Set<String>, lease: UIOperationLease) async throws -> AutoReplyDeliveryResult {
        .uncertain("驱动未提供发送凭据核对")
    }
    func acknowledgeDiscoveryCapture(_ capture: AutoReplyCapture) throws {}
    func reconcileVisibleIdentity(in tree: PDDAXSemanticTree) throws {}
    func visibleConversationsSnapshot() -> [PDDConversationLocator]? { nil }
    func send(uid: String, text: String, outgoingImages: [DatasetReplyImage], deliveryID: UUID,
              expectedCustomerCursor: AutoReplyCursor, expectedCustomerMessageIDs: Set<String>,
              lease: UIOperationLease) async throws -> AutoReplyDeliveryResult {
        guard outgoingImages.isEmpty else { return .failedBeforeSend("驱动不支持发送图片") }
        return try await send(uid: uid, text: text, expectedCustomerCursor: expectedCustomerCursor,
            expectedCustomerMessageIDs: expectedCustomerMessageIDs, lease: lease)
    }
    func transferToAnyHuman(
        uid: String, lease: UIOperationLease
    ) async throws -> AutoReplyTransferResult {
        try lease.validate()
        return .failed("当前驱动未配置转人工执行器")
    }

    func discover(lease: UIOperationLease) async throws -> [AutoReplyDiscovery] {
        try lease.validate()
        let value = try await discover()
        try lease.validate()
        return value
    }

    func capture(
        uid: String, after cursor: AutoReplyCursor, lease: UIOperationLease
    ) async throws -> AutoReplyCapture {
        try lease.validate()
        let value = try await capture(uid: uid, after: cursor)
        try lease.validate()
        return value
    }

    func capture(
        uid: String, after cursor: AutoReplyCursor, includeImages: Bool,
        lease: UIOperationLease
    ) async throws -> AutoReplyCapture {
        try await capture(uid: uid, after: cursor, lease: lease)
    }

    func capture(
        uid: String, after cursor: AutoReplyCursor, includeImages: Bool,
        onlyVideoMessageID: String?, lease: UIOperationLease
    ) async throws -> AutoReplyCapture {
        try await capture(
            uid: uid, after: cursor, includeImages: includeImages, lease: lease
        )
    }

    func preflight(
        uid: String, after cursor: AutoReplyCursor, lease: UIOperationLease
    ) async throws -> AutoReplyCapture? {
        try lease.validate()
        let value = try await preflight(uid: uid, after: cursor)
        try lease.validate()
        return value
    }

    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor,
        expectedCustomerMessageIDs: Set<String>
    ) async throws -> AutoReplyDeliveryResult {
        try await send(
            uid: uid, text: text, expectedCustomerCursor: expectedCustomerCursor
        )
    }

    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor,
        lease: UIOperationLease
    ) async throws -> AutoReplyDeliveryResult {
        try lease.validate()
        let value = try await send(
            uid: uid, text: text, expectedCustomerCursor: expectedCustomerCursor
        )
        try lease.validate()
        return value
    }

    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor,
        expectedCustomerMessageIDs: Set<String>,
        lease: UIOperationLease
    ) async throws -> AutoReplyDeliveryResult {
        try lease.validate()
        let value = try await send(
            uid: uid,
            text: text,
            expectedCustomerCursor: expectedCustomerCursor,
            expectedCustomerMessageIDs: expectedCustomerMessageIDs
        )
        try lease.validate()
        return value
    }

    func revokeCurrentUIOperation(operationID: UUID) async {}
    func restoreConversationLocators(_ locators: [String: PDDConversationLocator]) {}
    func restoreConversationCaptureState(
        baselinedUIDs: Set<String>,
        knownServiceMessageIDsByUID: [String: Set<String>]
    ) {}
    func conversationLocatorsSnapshot() -> [String: PDDConversationLocator]? { nil }
    func takeConversationDiagnostics() -> [PDDConversationDiagnostic] { [] }
    func restoreProvisionalReceipts(_ receipts: [String: [PDDProvisionalReceipt]]) {}
    func provisionalReceiptsSnapshot() -> [String: [PDDProvisionalReceipt]]? { nil }
    func restoreMessageSourceSelectorStates(_ states: [String: PDDMessageSourceSelectorState]) {}
    func messageSourceSelectorStatesSnapshot() -> [String: PDDMessageSourceSelectorState]? { nil }
}

protocol AutoReplyGenerating: Sendable {
    func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult
}

@MainActor
final class AutoReplyScheduler: ObservableObject {
    var onStateChange: (@MainActor () -> Void)?
    @Published private(set) var jobs: [AutoReplyJob]
    @Published private(set) var isRunning = false
    @Published private(set) var currentUIOwner: String? {
        didSet { onStateChange?() }
    }
    @Published private(set) var deliveryEnabled = true
    @Published private(set) var latestCapture: AutoReplyCapture?
    @Published private(set) var lastAXWakeAt: Date?
    @Published private(set) var latestResourceSnapshot: RuntimeResourceSnapshot?
    @Published private(set) var lastRuntimeIssue: String?
    @Published private(set) var latestVideoStatus: PDDVideoProgressStatus?
    @Published private(set) var realDeliveryPausedForPersistence = false

    var liveGenerationCount: Int { liveGenerationJobIDs.count }
    let codexExecutablePath: String?
    var latestKnowledgeDiagnostic: KnowledgeRetrievalDiagnostic? {
        jobs.sorted { $0.sequence > $1.sequence }
            .compactMap { $0.generationDiagnostic?.knowledge }
            .first
    }

    private let driver: any AutoReplyAutomationDriver
    private let generator: any AutoReplyGenerating
    private let store: AutoReplyStore
    private let transactionalStore: AutoReplyTransactionalStore
    private let concurrencyPolicy: AdaptiveConcurrencyPolicy
    private let retryPolicy = AutoReplyRetryPolicy()
    private let configuredMaximumConcurrentGenerations: Int?
    private let availableMemoryBytes: @Sendable () -> UInt64
    private let now: @Sendable () -> Date
    private let resourceMonitor: any RuntimeResourceMonitoring
    private let uiOperationTimeoutOverride: Duration?
    private let generationTimeout: Duration
    private var backgroundLifecycleHandler: @Sendable (Int, Bool) async -> Void
    private var backgroundLifecycleRevision = 0
    private let uiLeaseRegistry = UIOperationLeaseRegistry()
    private var state: AutoReplyPersistentState
    private var checkpointToken: AutoReplyCheckpointToken?
    private var liveGenerationJobIDs: Set<UUID> = []
    private var generationAttempts: [UUID: UUID] = [:]
    private var generationTasks: [UUID: Task<Void, Never>] = [:]
    private var workTurnsSinceDiscovery = 0
    private var nextWorkLane = 0
    private var lastTurnWasTail = false
    private var consecutiveSendTurns = 0
    private var lastDiscoveryAt = Date.distantPast
    private var pendingFastDiscoveryAttempts = 0
    private var ordinaryCaptureAuthorizations = Set<String>()
    private var ordinaryCaptureFailureCounts: [String: Int] = [:]
    private var pumping = false
    private var identityRecoveryBlockedUIDs = Set<String>()
    private var identityRecoveryRetryAt: [String: Date] = [:]
    private var activeUIOperationID: UUID?


    init(
        driver: any AutoReplyAutomationDriver,
        generator: any AutoReplyGenerating,
        store: AutoReplyStore,
        configuredMaximumConcurrentGenerations: Int? = nil,
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        availableMemoryBytes: @escaping @Sendable () -> UInt64 = {
            ProcessInfo.processInfo.physicalMemory
        },
        resourceMonitor: (any RuntimeResourceMonitoring)? = nil,
        codexExecutablePath: String? = nil,
        uiOperationTimeout: Duration? = nil,
        generationTimeout: Duration = .seconds(210),
        backgroundStopHandler: @escaping @Sendable () async -> Void = {},
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.driver = driver
        self.generator = generator
        self.store = store
        self.transactionalStore = AutoReplyTransactionalStore(rootDirectory: store.rootDirectory)
        self.configuredMaximumConcurrentGenerations = configuredMaximumConcurrentGenerations
        self.availableMemoryBytes = availableMemoryBytes
        self.now = now
        self.resourceMonitor = resourceMonitor ?? RuntimeResourceMonitor(
            availableMemoryBytes: availableMemoryBytes,
            now: now
        )
        self.codexExecutablePath = codexExecutablePath
        self.uiOperationTimeoutOverride = uiOperationTimeout
        self.generationTimeout = generationTimeout
        self.backgroundLifecycleHandler = { _, enabled in
            if !enabled { await backgroundStopHandler() }
        }
        concurrencyPolicy = AdaptiveConcurrencyPolicy(physicalMemoryBytes: physicalMemoryBytes)
        state = try store.loadRecoveringInterruptedWork(now: now())
        var activeReceiptIDs: [String: Set<String>] = [:]
        for job in state.jobs where [.queued, .generating, .ready, .sending].contains(job.state) {
            activeReceiptIDs[job.uid, default: []].formUnion(job.capture.batch?.customerMessageIDs ?? [])
        }
        for pending in state.pendingVideoBatches {
            activeReceiptIDs[pending.uid, default: []].formUnion(pending.expectedMessageIDs)
        }
        _ = try CustomerMessageReceipts(root: store.rootDirectory)
            .reconcileLegacyVideoSkips(excluding: activeReceiptIDs, at: now())
        ordinaryCaptureAuthorizations = Set(state.pendingCaptureRequests.filter { $0.kind == .ordinary }.map(\.uid))
        driver.restoreConversationLocators(state.conversationLocatorsByUID)
        driver.restoreConversationCaptureState(
            baselinedUIDs: state.axFirstBaselinedUIDs,
            knownServiceMessageIDsByUID: state.knownServiceMessageIDsByUID
        )
        driver.restoreProvisionalReceipts(state.provisionalReceiptsByUID)
        driver.restoreMessageSourceSelectorStates(state.messageSourceSelectorStatesByUID)
        var migratedBlockingState = PDDConversationIdentityRecovery.retireSupersededHandoffs(
            in: &state, root: store.rootDirectory, at: now())
        for index in state.jobs.indices {
            guard state.jobs[index].state == .completed,
                  state.jobs[index].deliveryOutcome == .uncertain,
                  state.jobs[index].lastError == "写入前 UID 不匹配",
                  let batch = state.jobs[index].capture.batch,
                  state.answeredCursors[state.jobs[index].uid] == batch.endCursor
            else { continue }
            state.jobs[index].state = .ready
            state.jobs[index].deliveryOutcome = .notSent
            state.jobs[index].lastError = "旧版误把写入前 UID 不匹配标为发送不确定；已恢复重试"
            state.jobs[index].nextAttemptAt = nil
            state.jobs[index].durableAttemptOperationID = nil
            state.jobs[index].sendWasInvoked = false
            state.answeredCursors[state.jobs[index].uid] = batch.startCursor
            migratedBlockingState = true
        }
        if let latestJob = state.jobs.max(by: { $0.sequence < $1.sequence }),
           latestJob.state == .quarantined,
           latestJob.lastError == "发送前检测到未确认的人工客服消息",
           let batch = latestJob.capture.batch,
           (state.answeredCursors[latestJob.uid]?.count ?? 0) > batch.endCursor.count {
            state.answeredCursors[latestJob.uid] = batch.endCursor
        }
        for index in state.jobs.indices
        where [.uncertain, .quarantined].contains(state.jobs[index].state) {
            state.jobs[index].state = .failed
            state.jobs[index].deliveryOutcome = .notSent
            state.jobs[index].lastError = "旧阻塞状态已解除；已跳过当前批次并继续"
            state.jobs[index].nextAttemptAt = nil
            _ = state.advanceSourceAndPromoteSupplement(at: index)
            migratedBlockingState = true
        }
        if let latestJob = state.jobs.max(by: { $0.sequence < $1.sequence }),
           latestJob.state == .failed,
           latestJob.lastError?.hasPrefix("输入区存在未知草稿") == true,
           let batch = latestJob.capture.batch,
           state.answeredCursors[latestJob.uid] == batch.endCursor {
            state.answeredCursors[latestJob.uid] = batch.startCursor
            migratedBlockingState = true
        }
        if let latestJob = state.jobs.max(by: { $0.sequence < $1.sequence }),
           latestJob.state == .failed,
           latestJob.lastError == "客户消息前缀已变化",
           let batch = latestJob.capture.batch,
           (state.answeredCursors[latestJob.uid]?.count ?? 0) >= batch.endCursor.count {
            state.answeredCursors[latestJob.uid] = batch.startCursor
            migratedBlockingState = true
        }
        // Recover the latest known-unsent lookup failure from older builds.
        // Sent/uncertain deliveries and superseded jobs are never replayed.
        for index in state.jobs.indices {
            let job = state.jobs[index]
            guard job.state == .failed, job.deliveryOutcome == .notSent,
                  !job.sendWasInvoked, job.outgoingImages.isEmpty, job.replyAction == .reply,
                  job.lastError?.contains("目标消息") == true,
                  let batch = job.capture.batch,
                  !state.jobs.contains(where: { $0.uid == job.uid && $0.sequence > job.sequence })
            else { continue }
            state.nextSequence = max(state.nextSequence, state.jobs.map(\.sequence).max() ?? 0) + 1
            let recovered = AutoReplyJob(id: UUID(), uid: job.uid, sequence: state.nextSequence,
                state: job.reply == nil ? .queued : .ready, capture: job.capture, reply: job.reply,
                generationDiagnostic: job.generationDiagnostic, deliveryOutcome: .notSent,
                confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil,
                lastError: "旧版目标消息定位失败；已恢复未发送回复，等待重试",
                customerRevision: job.customerRevision + 1,
                imageAttachments: job.imageAttachments, videoAttachments: job.videoAttachments,
                imageCaptureAttempted: job.imageCaptureAttempted)
            state.jobs.append(recovered)
            if state.answeredCursors[job.uid] == batch.endCursor {
                state.answeredCursors[job.uid] = batch.startCursor
            }
            state.events.append(.init(id: UUID(), timestamp: now(), uid: job.uid,
                kind: "unsent-lookup-recovered", detail: "source=\(job.id) retry=\(recovered.id) sequence=\(recovered.sequence)"))
            AutomationStepLog.record(root: store.rootDirectory, uid: job.uid,
                step: "unsent-lookup-recovered", detail: "source=\(job.id) retry=\(recovered.id) sequence=\(recovered.sequence)")
            migratedBlockingState = true
        }
        if migratedBlockingState { try store.save(state) }
        checkpointToken = try transactionalStore.loadCheckpoint().token
        jobs = state.jobs
        if releaseTerminalVideoWaits() {
            syncJobs()
            try persist()
        }
        // Recover the narrow crash window between persisting an omission and
        // archiving it. An archive problem stays local to that historical job.
        for job in state.jobs where job.omittedAt != nil && job.reply != nil {
            let record = store.rootDirectory.appendingPathComponent("archive/records/\(job.id.uuidString).json")
            if !FileManager.default.fileExists(atPath: record.path) {
                do { try transactionalStore.archiveTerminal(job) }
                catch {
                    AutomationStepLog.record(root: store.rootDirectory, uid: job.uid,
                        step: "omitted-reply-archive-failed", detail: error.localizedDescription)
                }
            }
        }
    }

    func setBackgroundLifecycleHandler(
        _ handler: @escaping @Sendable (Int, Bool) async -> Void
    ) {
        backgroundLifecycleHandler = handler
    }

    func start() {
        guard !isRunning else { return }
        AutomationStepLog.record(root: store.rootDirectory, uid: nil, step: "automation-started")
        isRunning = true
        backgroundLifecycleRevision += 1
        let revision = backgroundLifecycleRevision
        Task { await backgroundLifecycleHandler(revision, true) }
    }

    func stop() {
        AutomationStepLog.record(root: store.rootDirectory, uid: nil, step: "automation-stopped")
        isRunning = false
        backgroundLifecycleRevision += 1
        let revision = backgroundLifecycleRevision
        let operationID = activeUIOperationID
        uiLeaseRegistry.revokeAll()
        for index in state.jobs.indices where generationAttempts[state.jobs[index].id] != nil {
            if state.jobs[index].state == .generating {
                state.jobs[index].state = .queued
                state.jobs[index].nextAttemptAt = nil
            }
        }
        generationAttempts.removeAll()
        liveGenerationJobIDs.removeAll()
        generationTasks.values.forEach { $0.cancel() }
        generationTasks.removeAll()
        syncJobs()
        try? persist()
        if let operationID {
            Task { [driver] in
                await driver.revokeCurrentUIOperation(operationID: operationID)
            }
        }
        Task { await backgroundLifecycleHandler(revision, false) }
    }

    func setDeliveryEnabled(_ enabled: Bool) { deliveryEnabled = enabled }

    func reconcileVisibleIdentity(in tree: PDDAXSemanticTree) throws {
        guard !isRunning, !pumping else { return }
        guard try transactionalStore.loadCheckpoint().token == checkpointToken else {
            throw AutoReplyTransactionalStoreError.checkpointChanged
        }
        try driver.reconcileVisibleIdentity(in: tree)
        identityRecoveryRetryAt.removeAll()
        try reconcileConversationIdentities()
        syncJobs(); try persist()
    }

    func requestAXRefresh() {
        lastAXWakeAt = now()
        if pendingFastDiscoveryAttempts == 0 {
            pendingFastDiscoveryAttempts = 3
            appendEvent(uid: nil, kind: "ax-notification", detail: "收到拼多多 AX 变化通知")
            lastDiscoveryAt = .distantPast
        }
    }

    func answeredCursor(_ uid: String) -> AutoReplyCursor {
        state.answeredCursors[uid] ?? .empty
    }

    var pendingVideoBatchesSnapshot: [PDDPendingVideoBatch] { state.pendingVideoBatches }

    func requestVideoRecovery(uid: String, messageID: String) {
        guard !state.jobs.contains(where: { job in
            job.uid == uid && job.omittedAt != nil
                && (job.capture.batch?.events.contains { $0.messageID == messageID } ?? false)
        }) else { return }
        let pendingCapture = state.pendingVideoBatches.first(where: {
            $0.uid == uid && $0.expectedMessageIDs.contains(messageID)
        })?.capture
        let archivedCapture = state.jobs.reversed().first(where: {
            $0.uid == uid && ($0.capture.batch?.events.contains {
                $0.messageID == messageID
            } ?? false)
        })?.capture
        guard let start = (pendingCapture ?? archivedCapture)?.batch?.startCursor else { return }
        let duplicate = state.pendingCaptureRequests.contains {
            $0.uid == uid && $0.kind == .videoRecovery
                && $0.baseCursor == start && $0.videoMessageID == messageID
        }
        guard !duplicate else { return }
        state.pendingCaptureRequests.append(AutoReplyCaptureRequest(
            uid: uid, kind: .videoRecovery, baseCursor: start,
            videoMessageID: messageID
        ))
        try? persist()
    }

    func receiveVideoTransferEvent(_ event: PDDVideoTransferEvent) async {
        if let closed = try? await CustomerTransferPolicyStore.shared.closedMessageIDs(root: store.rootDirectory, uid: event.uid),
           closed.contains(event.messageID) {
            appendEvent(uid: event.uid, kind: "video-closed-message-ignored", detail: event.messageID)
            try? persist()
            return
        }
        latestVideoStatus = PDDVideoProgressStatus(event: event)
        if [.waitingForAddress, .downloading, .downloaded, .preparingEvidence, .readyForGeneration].contains(event.phase) {
            registerVideoHold(uid: event.uid, messageIDs: [event.messageID])
        }
        onStateChange?()
        appendEvent(
            uid: event.uid,
            kind: "video-\(event.phase.rawValue)",
            detail: [event.messageID, event.diagnostic].compactMap { $0 }.joined(separator: " · ")
        )
        let matchingIndices = state.pendingVideoBatches.indices.filter {
            let pending = state.pendingVideoBatches[$0]
            return pending.uid == event.uid && pending.expectedMessageIDs.contains(event.messageID)
        }
        guard !matchingIndices.isEmpty else {
            if event.phase == .readyForGeneration, event.recovered == true,
               let attachment = event.attachment {
                admitRecoveredVideo(uid: event.uid, attachment: attachment)
                syncJobs()
                try? persist()
                return
            }
            if event.phase == .readyForGeneration || event.phase == .duplicate
                || event.phase == .failed || event.phase == .fallbackRequired
                || event.phase == .waitingForRetry {
                state.deferredVideoTransferEvents.removeAll {
                    $0.uid == event.uid && $0.messageID == event.messageID
                }
                state.deferredVideoTransferEvents.append(event)
            }
            try? persist()
            return
        }

        // One video can appear in multiple durable captures after a cursor changes.
        // Resolve every reference before promoting/removing any pending batch.
        for index in matchingIndices {
            switch event.phase {
            case .readyForGeneration:
                guard let attachment = event.attachment,
                      state.pendingVideoBatches[index]
                        .completedAttachmentsByMessageID[event.messageID] == nil,
                      !state.pendingVideoBatches[index].failedMessageIDs.contains(event.messageID),
                      !state.pendingVideoBatches[index].duplicateMessageIDs.contains(event.messageID)
                else {
                    continue
                }
                state.pendingVideoBatches[index]
                    .completedAttachmentsByMessageID[event.messageID] = attachment
            case .failed, .fallbackRequired, .waitingForRetry:
                guard state.pendingVideoBatches[index]
                    .completedAttachmentsByMessageID[event.messageID] == nil,
                      !state.pendingVideoBatches[index].duplicateMessageIDs.contains(event.messageID)
                else {
                    continue
                }
                state.pendingVideoBatches[index].failedMessageIDs.insert(event.messageID)
            case .duplicate:
                guard state.pendingVideoBatches[index]
                    .completedAttachmentsByMessageID[event.messageID] == nil,
                      !state.pendingVideoBatches[index].failedMessageIDs.contains(event.messageID)
                else {
                    continue
                }
                state.pendingVideoBatches[index].duplicateMessageIDs.insert(event.messageID)
                do {
                    try CustomerMessageReceipts(root: store.rootDirectory).closeUnsubmitted(uid: event.uid,
                        messageIDs: [event.messageID], reason: "legacy-video-content-duplicate", at: now())
                } catch {
                    appendEvent(uid: event.uid, kind: "message-receipt-closure-failed", detail: error.localizedDescription)
                }
            default:
                try? persist()
                return
            }

        }
        let completedBatchIDs = matchingIndices.compactMap { index -> UUID? in
            let pending = state.pendingVideoBatches[index]
            let terminal = Set(pending.completedAttachmentsByMessageID.keys)
                .union(pending.failedMessageIDs).union(pending.duplicateMessageIDs)
            return Set(pending.expectedMessageIDs).isSubset(of: terminal) ? pending.id : nil
        }
        for id in completedBatchIDs {
            if let index = state.pendingVideoBatches.firstIndex(where: { $0.id == id }) {
                promotePendingVideoBatch(at: index)
            }
        }
        syncJobs()
        do {
            try persist()
        } catch {
            recordPersistenceFailure(error, sendCritical: false)
        }
    }

    func tick() async {
        guard isRunning, !pumping else { return }
        pumping = true
        defer {
            pumping = false
            latestResourceSnapshot = resourceMonitor.snapshot(
                activeCLI: liveGenerationJobIDs.count,
                queueDepth: state.jobs.filter { [.queued, .generating, .ready, .sending].contains($0.state) }.count,
                lastLatencyMilliseconds: state.jobs.compactMap { $0.generationDiagnostic?.codexDurationMilliseconds }.last
            )
        }

        do {
            try reconcileConversationIdentities()
            if releaseTerminalVideoWaits() {
                syncJobs()
                try persist()
            }
            await drainDeferredVideoTransferEvents()
            refreshVideoHoldingNotices()
            _ = launchQueuedGenerations()

            if try await sendDueVideoHoldingNotice() { return }

            if state.consecutiveDeliveryCount >= 3 || workTurnsSinceDiscovery >= 3
                || (workTurnsSinceDiscovery > 0 && now().timeIntervalSince(lastDiscoveryAt) >= 5) {
                workTurnsSinceDiscovery = 0
                state.consecutiveDeliveryCount = 0
                consecutiveSendTurns = 0
                try await performDiscovery()
                try persist()
                return
            }

            // Ready answers precede routine tail/reconciliation/capture work.
            // After two send attempts, yield one maintenance turn when available.
            if consecutiveSendTurns < 2, let index = nextReadyJobIndex() {
                try await deliverPriorityReply(at: index)
                return
            }

            if consecutiveSendTurns >= 2 {
                if let index = nextPendingTransferTaskIndex() {
                    consecutiveSendTurns = 0
                    workTurnsSinceDiscovery += 1
                    try await executeTransferTask(at: index)
                    return
                }
                if let index = state.pendingCaptureRequests.firstIndex(where: {
                    $0.kind == .ordinary && ordinaryCaptureAuthorizations.contains($0.uid)
                        && !hasActiveJob(uid: $0.uid)
                        && !PDDConversationIdentityStore.isSharedVisitorUID($0.uid)
                        && ($0.nextAttemptAt.map { $0 <= now() } ?? true)
                }) {
                    let request = state.pendingCaptureRequests.remove(at: index)
                    ordinaryCaptureAuthorizations.remove(request.uid)
                    consecutiveSendTurns = 0
                    workTurnsSinceDiscovery += 1
                    try await capture(request: request)
                    return
                }
            }

            if !lastTurnWasTail, let index = state.pendingCaptureRequests.firstIndex(where: {
                $0.kind == .tail && !PDDConversationIdentityStore.isSharedVisitorUID($0.uid)
                    && ($0.nextAttemptAt.map { $0 <= now() } ?? true)
            }) {
                lastTurnWasTail = true
                consecutiveSendTurns = 0
                workTurnsSinceDiscovery += 1
                let request = state.pendingCaptureRequests.remove(at: index)
                try await capture(request: request)
                return
            }
            lastTurnWasTail = false
            // Rotate sends, transfers and captures. Failed attempts consume a
            // turn too, so a backlog of broken jobs cannot starve discovery.
            for offset in 0..<3 {
                let lane = (nextWorkLane + offset) % 3
                if lane == 0, let readyIndex = nextReadyJobIndex() {
                    try await deliverPriorityReply(at: readyIndex)
                    return
                }
                if lane == 0, let index = nextDeliveryReconciliationIndex() {
                    nextWorkLane = 1
                    consecutiveSendTurns = 0
                    workTurnsSinceDiscovery += 1
                    try await reconcileDelivery(at: index)
                    return
                }
                if lane == 1, let transferIndex = nextPendingTransferTaskIndex() {
                    nextWorkLane = 2
                    consecutiveSendTurns = 0
                    workTurnsSinceDiscovery += 1
                    try await executeTransferTask(at: transferIndex)
                    return
                }
                if lane == 2, let request = nextSupplementCaptureRequest() ?? nextCaptureRequest() {
                    nextWorkLane = 0
                    consecutiveSendTurns = 0
                    workTurnsSinceDiscovery += 1
                    try await capture(request: request)
                    return
                }
            }

            let discoveryInterval = pendingFastDiscoveryAttempts > 0 ? 0.2 : 1.0
            if now().timeIntervalSince(lastDiscoveryAt) >= discoveryInterval {
                try await performDiscovery()
            }
            lastRuntimeIssue = nil
        } catch {
            lastRuntimeIssue = error.localizedDescription
            appendEvent(uid: nil, kind: "scheduler-error", detail: error.localizedDescription)
            if !isRunning, realDeliveryPausedForPersistence { return }
            do {
                try persist()
            } catch {
                recordPersistenceFailure(error, sendCritical: false)
            }
        }
    }

    private func reconcileConversationIdentities() throws {
        let registry = PDDConversationIdentityStore(root: store.rootDirectory)
        let receipts = CustomerMessageReceipts(root: store.rootDirectory)
        try recoverVerifiedAliasWork(registry: registry, receipts: receipts)
        let originals = state.jobs.filter { [.queued, .ready].contains($0.state) && !$0.sendWasInvoked }
        var reassignments: [(String, Set<String>, String)] = []
        for source in originals {
            guard !identityRecoveryBlockedUIDs.contains(source.uid) else { continue }
            guard let batch = source.capture.batch else { continue }
            do {
                guard let canonical = try registry.owner(messageIDs: batch.customerMessageIDs, boundary: batch.incomingHandoffKey),
                      canonical != source.uid,
                      let index = state.jobs.firstIndex(where: { $0.id == source.id }) else { continue }
                // Every target must independently belong to this canonical chat.
                guard try batch.customerMessageIDs.allSatisfy({ try registry.owner(messageIDs: [$0]) == canonical }) else { continue }
                let canonicalReceipts = try receipts.receipts(uid: canonical)
                let alreadyAnswered = !batch.customerMessageIDs.isEmpty
                    && batch.customerMessageIDs.allSatisfy { canonicalReceipts[$0]?.replySentAt != nil }
                let alreadyOwned = state.jobs.contains { job in
                    guard job.uid == canonical, [.queued, .generating, .ready, .sending].contains(job.state), let other = job.capture.batch else { return false }
                    if let boundary = batch.incomingHandoffKey { return other.incomingHandoffKey == boundary }
                    return !batch.customerMessageIDs.isEmpty && batch.customerMessageIDs.isSubset(of: other.customerMessageIDs)
                }
                // Images already submitted must not be replayed by identity recovery.
                guard source.outgoingImages.isEmpty || source.stageAttempt == 0 else { continue }
                if !alreadyAnswered && !alreadyOwned {
                    guard let capture = try PDDConversationIdentityRecovery.capture(source.capture, canonicalUID: canonical, root: store.rootDirectory) else { continue }
                    try receipts.capture(capture, at: now())
                    state.nextSequence += 1
                    state.jobs.append(AutoReplyJob(id: UUID(), uid: canonical, sequence: state.nextSequence,
                        state: .queued, capture: capture, reply: nil, deliveryOutcome: nil, confirmedServiceMessageID: nil,
                        retries: 0, nextAttemptAt: nil, lastError: nil,
                        imageAttachments: capture.imageAttachments, videoAttachments: capture.videoAttachments))
                }
                state.jobs[index].state = .failed
                state.jobs[index].deliveryOutcome = .notSent
                state.jobs[index].nextAttemptAt = nil
                state.jobs[index].lastError = "会话身份已核对到 \(canonical)；原任务保留为未发送，后续由同一客户的规范记录处理"
                state.jobs[index].durableAttemptOperationID = nil
                state.jobs[index].supplementCapturePending = false
                state.pendingCaptureRequests.removeAll { $0.uid == source.uid && ($0.sourceJobID == source.id || $0.baseCursor == batch.endCursor) }
                for holdIndex in state.videoHoldingNotices.indices where state.videoHoldingNotices[holdIndex].uid == source.uid
                    && !state.videoHoldingNotices[holdIndex].messageIDs.isDisjoint(with: batch.customerMessageIDs) {
                    state.videoHoldingNotices[holdIndex].uid = canonical
                }
                reassignments.append((source.uid, batch.customerMessageIDs, canonical))
                appendEvent(uid: source.uid, kind: "identity-work-reassigned",
                    detail: "source_job=\(source.id) canonical=\(canonical) answered=\(alreadyAnswered) owned=\(alreadyOwned); no history-folder merge")
            } catch {
                appendEvent(uid: source.uid, kind: "identity-recovery-deferred", detail: error.localizedDescription)
            }
        }
        if !reassignments.isEmpty {
            syncJobs(); try persist(sendCritical: true)
            for (uid, ids, canonical) in reassignments {
                try receipts.closeSuperseded(uid: uid, messageIDs: ids, canonicalUID: canonical, at: now())
            }
        }
        // A receipt copied into a legacy visitor bucket must not trigger endless capture.
        for (uid, ids) in try receipts.awaitingSubmission() {
            for id in ids {
                guard let canonical = try registry.owner(messageIDs: [id]), canonical != uid else { continue }
                let answered = try receipts.receipts(uid: canonical)[id]?.replySentAt != nil
                if answered {
                    try receipts.closeSuperseded(uid: uid, messageIDs: [id], canonicalUID: canonical, at: now())
                }
            }
        }
    }

    private func recoverVerifiedAliasWork(registry: PDDConversationIdentityStore, receipts: CustomerMessageReceipts) throws {
        identityRecoveryBlockedUIDs = []
        let aliases = try registry.aliases()
        for canonical in Set(aliases.values) {
            let aliasUIDs = Set(aliases.filter { $0.value == canonical }.map(\.key))
            let uids = aliasUIDs.union([canonical])
            var active = state.jobs.filter { uids.contains($0.uid) && [.queued, .generating, .ready].contains($0.state) && !$0.sendWasInvoked }
            guard active.contains(where: { aliasUIDs.contains($0.uid) }) else { continue }
            identityRecoveryBlockedUIDs.formUnion(uids)
            if identityRecoveryRetryAt[canonical].map({ $0 > now() }) == true { continue }
            do {
                let covered = Set(try receipts.receipts(uid: canonical).filter { $0.value.replySentAt != nil }.map(\.key))
                let answeredAliases = active.filter { source in
                    let ids = (source.capture.batch?.customerMessageIDs ?? []).union(source.pendingSupplement?.batch?.customerMessageIDs ?? [])
                    return aliasUIDs.contains(source.uid) && source.state != .generating && !ids.isEmpty && ids.isSubset(of: covered)
                }
                if !answeredAliases.isEmpty {
                    let ids = Set(answeredAliases.map(\.id))
                    for index in state.jobs.indices where ids.contains(state.jobs[index].id) {
                        state.jobs[index].state = .failed
                        state.jobs[index].deliveryOutcome = .notSent
                        state.jobs[index].nextAttemptAt = nil
                        state.jobs[index].supplementCapturePending = false
                        state.jobs[index].lastError = "规范会话已确认回复相同消息；别名回复未发送，已结束重复重试"
                    }
                    state.pendingCaptureRequests.removeAll { request in
                        answeredAliases.contains { $0.uid == request.uid && ($0.id == request.sourceJobID || $0.capture.batch?.endCursor == request.baseCursor) }
                    }
                    appendEvent(uid: canonical, kind: "identity-alias-already-answered",
                        detail: "source_jobs=\(answeredAliases.map { String($0.sequence) }.joined(separator: ",")); existing reply receipts preserved; aliases not sent")
                    syncJobs(); try persist(sendCritical: true)
                    for source in answeredAliases {
                        try receipts.closeSuperseded(uid: source.uid, messageIDs: source.capture.batch?.customerMessageIDs ?? [], canonicalUID: canonical, at: now())
                    }
                    active.removeAll { ids.contains($0.id) }
                    if !active.contains(where: { aliasUIDs.contains($0.uid) }) {
                        identityRecoveryBlockedUIDs.subtract(uids)
                        continue
                    }
                }
                guard !active.contains(where: { $0.state == .generating || (!$0.outgoingImages.isEmpty && $0.stageAttempt > 0) }),
                      let capture = try PDDConversationIdentityRecovery.currentThreadCapture(canonicalUID: canonical,
                        after: answeredCursor(canonical), jobs: active, root: store.rootDirectory, covered: covered) else {
                    identityRecoveryRetryAt[canonical] = now().addingTimeInterval(15)
                    appendEvent(uid: canonical, kind: "identity-recovery-waiting",
                        detail: "需完整会话依据或等待在途工作结束；15秒后复查；其他客户继续")
                    continue
                }
                try receipts.capture(capture, at: now())
                let jobIDs = Set(active.map(\.id))
                for index in state.jobs.indices where jobIDs.contains(state.jobs[index].id) {
                    state.jobs[index].state = .failed
                    state.jobs[index].deliveryOutcome = .notSent
                    state.jobs[index].nextAttemptAt = nil
                    state.jobs[index].durableAttemptOperationID = nil
                    state.jobs[index].supplementCapturePending = false
                    state.jobs[index].lastError = "已通过同一会话的消息依据恢复到 \(canonical)；原回复未发送，使用最新上下文重新生成"
                }
                state.pendingCaptureRequests.removeAll { request in
                    guard request.kind != .videoRecovery, uids.contains(request.uid) else { return false }
                    return request.sourceJobID.map { jobIDs.contains($0) } == true
                        || active.contains { $0.uid == request.uid && $0.capture.batch?.endCursor == request.baseCursor }
                }
                for index in state.transferTasks.indices where jobIDs.contains(state.transferTasks[index].sourceJobID) && state.transferTasks[index].state == .pending {
                    state.transferTasks[index].state = .failed
                }
                for index in state.videoHoldingNotices.indices where aliasUIDs.contains(state.videoHoldingNotices[index].uid) {
                    state.videoHoldingNotices[index].uid = canonical
                }
                state.nextSequence += 1
                state.jobs.append(.init(id: UUID(), uid: canonical, sequence: state.nextSequence, state: .queued,
                    capture: capture, reply: nil, deliveryOutcome: nil, confirmedServiceMessageID: nil,
                    retries: 0, nextAttemptAt: nil, lastError: nil, imageAttachments: capture.imageAttachments,
                    videoAttachments: capture.videoAttachments))
                latestCapture = capture
                appendEvent(uid: canonical, kind: "identity-split-work-recovered",
                    detail: "source_jobs=\(active.map { String($0.sequence) }.joined(separator: ",")) new_job=\(state.nextSequence) message_ids=\((capture.batch?.customerMessageIDs ?? []).sorted().joined(separator: ",")); old replies not sent")
                syncJobs(); try persist(sendCritical: true)
                for source in active where aliasUIDs.contains(source.uid) {
                    try receipts.closeSuperseded(uid: source.uid, messageIDs: source.capture.batch?.customerMessageIDs ?? [], canonicalUID: canonical, at: now())
                }
                identityRecoveryBlockedUIDs.subtract(uids)
                identityRecoveryRetryAt[canonical] = nil
            } catch {
                identityRecoveryRetryAt[canonical] = now().addingTimeInterval(15)
                appendEvent(uid: canonical, kind: "identity-recovery-deferred", detail: error.localizedDescription)
            }
        }
    }

    private func performDiscovery() async throws {
        lastDiscoveryAt = now()
        let discoveries = try await performUI(stage: "discover", uid: "discovery") {
            driver, lease in
            try await driver.discover(lease: lease)
        }
        try reconcileConversationIdentities()
        if pendingFastDiscoveryAttempts > 0 { pendingFastDiscoveryAttempts -= 1 }
        try await updateCustomerVisibility(driver.visibleConversationsSnapshot())
        var changed = false
        for discovery in discoveries
        where discovery.hasUnreadEvidence || discovery.hasUncapturedCustomerMessages {
            if scheduleSupplementCaptureIfActive(uid: discovery.uid) {
                changed = true
            } else {
                ordinaryCaptureAuthorizations.insert(discovery.uid)
                let before = state.pendingCaptureRequests.count
                enqueueCapture(discovery.uid, kind: .ordinary)
                changed = changed || state.pendingCaptureRequests.count != before
            }
        }
        // Recover captured-but-unsubmitted messages even after PDD clears its red dot.
        for (uid, pendingIDs) in try CustomerMessageReceipts(root: store.rootDirectory).awaitingSubmission() {
            var known = Set<String>()
            for job in state.jobs where job.uid == uid {
                known.formUnion(job.capture.batch?.events.map(\.messageID) ?? [])
                known.formUnion(job.pendingSupplement?.batch?.events.map(\.messageID) ?? [])
            }
            for pending in state.pendingVideoBatches where pending.uid == uid {
                known.formUnion(pending.capture.batch?.events.map(\.messageID) ?? [])
            }
            let closed = try await CustomerTransferPolicyStore.shared.closedMessageIDs(root: store.rootDirectory, uid: uid)
            let missing = pendingIDs.subtracting(known).subtracting(closed)
            if !missing.isEmpty {
                enqueueCapture(uid, kind: .tail)
                appendEvent(uid: uid, kind: "capture-submission-gap-recovered",
                    detail: "message_ids=\(missing.sorted().joined(separator: ","))")
                changed = true
            }
        }
        if changed {
            syncJobs()
            try persist()
        }
    }

    private func nextDeliveryReconciliationIndex() -> Int? {
        guard driver.supportsTextDeliveryTracking, let visible = driver.visibleConversationsSnapshot() else { return nil }
        return state.jobs.indices.first {
            let job = state.jobs[$0]
            return job.state == .completed && job.deliveryOutcome == .uncertain && job.outgoingImages.isEmpty
                && (job.nextAttemptAt.map { $0 <= now() } ?? false)
                && customerIsVisible(job.uid, in: visible) == true
        }
    }

    private func reconcileDelivery(at index: Int) async throws {
        let job = state.jobs[index]
        guard let reply = job.reply, let batch = job.capture.batch else { return }
        state.jobs[index].nextAttemptAt = now().addingTimeInterval(60)
        try persist(sendCritical: true)
        do {
            let result = try await performUI(stage: "delivery-reconcile", uid: job.uid) { driver, lease in
                try await driver.reconcileTextDelivery(uid: job.uid, text: reply, deliveryID: job.id,
                    expectedCustomerMessageIDs: Set(batch.events.map(\.messageID)), lease: lease)
            }
            if case .sent(let id) = result {
                state.jobs[index].deliveryOutcome = .sent
                state.jobs[index].confirmedServiceMessageID = id
                state.jobs[index].nextAttemptAt = nil
                state.jobs[index].lastError = nil
                try CustomerMessageReceipts(root: store.rootDirectory).replied(job.capture, at: now())
                state.confirmedAutoReplyMessageIDsByUID[job.uid, default: []].insert(id)
                if let boundary = batch.incomingHandoffKey {
                    try await CustomerTransferPolicyStore.shared.acknowledgeIncomingReply(root: store.rootDirectory,
                        uid: job.uid, boundaryKey: boundary)
                }
                markProvisionalReceiptsAnswered(in: batch, uid: job.uid)
                try transactionalStore.archiveTerminal(state.jobs[index])
                appendEvent(uid: job.uid, kind: "reply-delivery-reconciled", detail: "job=\(job.id) message=\(id)")
            }
        } catch {
            appendEvent(uid: job.uid, kind: "reply-delivery-reconciliation-deferred", detail: error.localizedDescription)
        }
        syncJobs()
        try persist(sendCritical: true)
    }

    private func deliverPriorityReply(at index: Int) async throws {
        nextWorkLane = 1
        consecutiveSendTurns += 1
        workTurnsSinceDiscovery += 1
        appendEvent(uid: state.jobs[index].uid, kind: "ready-reply-priority-selected", detail: "job=\(state.jobs[index].id)")
        try await deliverJob(at: index)
        if state.jobs.indices.contains(index), state.jobs[index].state == .completed,
           state.jobs[index].deliveryOutcome != nil {
            state.consecutiveDeliveryCount += 1
            try persist()
        }
    }

    private func nextReadyJobIndex() -> Int? {
        guard deliveryEnabled, !realDeliveryPausedForPersistence else { return nil }
        return state.jobs.indices
            .filter { state.jobs[$0].state == .ready }
            .filter { !identityRecoveryBlockedUIDs.contains(state.jobs[$0].uid) }
            .filter { !PDDConversationIdentityStore.isSharedVisitorUID(state.jobs[$0].uid) }
            .filter { state.jobs[$0].customerMissingSince.map { now().timeIntervalSince($0) < 600 } ?? true }
            .filter { state.jobs[$0].nextAttemptAt.map { $0 <= now() } ?? true }
            .filter { state.jobs[$0].deliveryNotBefore.map { $0 <= now() } ?? true }
            .filter { isHeadOfLine($0) }
            .min { state.jobs[$0].sequence < state.jobs[$1].sequence }
    }

    private func customerIsVisible(_ uid: String, in visible: [PDDConversationLocator]) -> Bool? {
        let known = state.conversationLocatorsByUID[uid]
        guard uid.hasPrefix("PDD-") || known != nil else { return nil }
        if visible.contains(where: { locator in
            PDDConversationKey.make(locator: locator) == uid
                || PDDConversationKey.make(locator: .init(nickname: locator.nickname)) == uid
                || (known?.normalizedIdentifier != nil && known?.normalizedIdentifier == locator.normalizedIdentifier)
                || (known != nil && known?.normalizedNickname == locator.normalizedNickname)
        }) { return true }
        if let known, visible.contains(where: { known.couldBeSameDisplayedCustomer(as: $0) }) {
            return nil
        }
        return false
    }

    private func resetCustomerAbsence(_ uid: String) {
        let indexes = state.jobs.indices.filter {
            state.jobs[$0].uid == uid && [.queued, .generating, .ready].contains(state.jobs[$0].state)
                && state.jobs[$0].customerMissingSince != nil
        }
        guard !indexes.isEmpty else { return }
        for index in indexes { state.jobs[index].customerMissingSince = nil }
        appendEvent(uid: uid, kind: "reply-customer-visible", detail: "Customer visible again; absence timer reset")
    }

    private func updateCustomerVisibility(_ visible: [PDDConversationLocator]?) async throws {
        let activeStates: Set<AutoReplyJobState> = [.queued, .generating, .ready]
        let uids = Set(state.jobs.filter { activeStates.contains($0.state) }.map(\.uid))
        var changed = false
        for uid in uids.sorted() {
            let indexes = state.jobs.indices.filter { state.jobs[$0].uid == uid && activeStates.contains(state.jobs[$0].state) }
            guard let visible, let present = customerIsVisible(uid, in: visible) else {
                if indexes.contains(where: { state.jobs[$0].customerMissingSince != nil }) {
                    for index in indexes { state.jobs[index].customerMissingSince = nil }
                    appendEvent(uid: uid, kind: "reply-customer-presence-uncertain",
                        detail: "Absence timer cleared: unreadable list or ambiguous masked customer name; not proof of absence")
                    changed = true
                }
                continue
            }
            if present {
                if indexes.contains(where: { state.jobs[$0].customerMissingSince != nil }) {
                    resetCustomerAbsence(uid)
                    changed = true
                }
                continue
            }
            let since = indexes.compactMap { state.jobs[$0].customerMissingSince }.min() ?? now()
            if !indexes.contains(where: { state.jobs[$0].customerMissingSince != nil }) {
                let labels = visible.map(\.normalizedNickname).joined(separator: ",")
                appendEvent(uid: uid, kind: "reply-customer-absent", detail: "Customer absent from conversation list; omit after 600s; visible_count=\(visible.count) visible_labels=\(labels)")
            }
            for index in indexes where state.jobs[index].customerMissingSince == nil {
                state.jobs[index].customerMissingSince = since
                changed = true
            }
            if now().timeIntervalSince(since) >= 600 {
                try await omitAbsentCustomerWork(uid: uid, at: now())
                changed = true
            }
        }
        if changed { syncJobs(); try persist() }
    }

    private func omitAbsentCustomerWork(uid: String, at date: Date) async throws {
        let jobIDs = Set(state.jobs.filter {
            $0.uid == uid && [.queued, .generating, .ready].contains($0.state)
        }.map(\.id))
        var closed = Set(state.jobs.filter { jobIDs.contains($0.id) }.flatMap {
            ($0.capture.batch?.events.map(\.messageID) ?? [])
                + ($0.pendingSupplement?.batch?.events.map(\.messageID) ?? [])
        })
        closed.formUnion(state.pendingVideoBatches.filter { $0.uid == uid }.flatMap {
            $0.capture.batch?.events.map(\.messageID) ?? []
        })
        for receipt in state.provisionalReceiptsByUID[uid] ?? [] where closed.contains(receipt.provisionalMessageID) {
            if let actual = receipt.absorbedAXMessageID { closed.insert(actual) }
        }
        try await CustomerTransferPolicyStore.shared.omitMessages(root: store.rootDirectory, uid: uid, messageIDs: closed)
        for index in state.jobs.indices where jobIDs.contains(state.jobs[index].id) {
            let id = state.jobs[index].id
            generationAttempts[id] = nil
            liveGenerationJobIDs.remove(id)
            generationTasks.removeValue(forKey: id)?.cancel()
            state.jobs[index].state = .completed
            state.jobs[index].deliveryOutcome = .notSent
            state.jobs[index].omittedAt = date
            state.jobs[index].lastError = "客户在会话列表中连续不可见超过10分钟，已省略旧回复"
            state.jobs[index].nextAttemptAt = nil
            state.jobs[index].durableAttemptOperationID = nil
            state.jobs[index].sendWasInvoked = false
            state.jobs[index].pendingSupplement = nil
            state.jobs[index].supplementCapturePending = false
            appendEvent(uid: uid, kind: "reply-omitted-customer-absent", detail: "job=\(id) absent_seconds=\(Int(date.timeIntervalSince(state.jobs[index].customerMissingSince ?? date))) sent=false")
        }
        for index in state.transferTasks.indices where state.transferTasks[index].uid == uid && state.transferTasks[index].state == .pending {
            state.transferTasks[index].state = .failed
        }
        state.pendingCaptureRequests.removeAll { $0.uid == uid }
        ordinaryCaptureAuthorizations.remove(uid)
        ordinaryCaptureFailureCounts[uid] = nil
        state.pendingVideoBatches.removeAll { $0.uid == uid }
        state.deferredVideoTransferEvents.removeAll { $0.uid == uid }
        if latestVideoStatus?.uid == uid { latestVideoStatus = nil }
        do {
            try CodexSessionRegistry(rootDirectory: store.rootDirectory).invalidate(uid: uid)
        } catch {
            appendEvent(uid: uid, kind: "omitted-reply-session-reset-failed", detail: error.localizedDescription)
        }
        syncJobs()
        try persist()
        for job in state.jobs where jobIDs.contains(job.id) && job.reply != nil {
            try transactionalStore.archiveTerminal(job)
        }
    }

    private func nextPendingTransferTaskIndex() -> Int? {
        guard deliveryEnabled, !realDeliveryPausedForPersistence else { return nil }
        return state.transferTasks.indices
            .filter { state.transferTasks[$0].state == .pending }
            .filter { state.transferTasks[$0].nextAttemptAt.map { $0 <= now() } ?? true }
            .filter { !PDDConversationIdentityStore.isSharedVisitorUID(state.transferTasks[$0].uid) }
            .filter { taskIndex in
                state.jobs.first(where: {
                    $0.id == state.transferTasks[taskIndex].sourceJobID
                })?.state == .completed
            }
            .min {
                state.transferTasks[$0].createdAt < state.transferTasks[$1].createdAt
            }
    }

    private func executeTransferTask(at index: Int) async throws {
        guard state.transferTasks.indices.contains(index) else { return }
        let task = state.transferTasks[index]
        appendEvent(uid: task.uid, kind: "transfer-started", detail: "target=after-sales task=\(task.id)")
        let result: AutoReplyTransferResult
        do {
            result = try await performUI(stage: "transfer", uid: task.uid) { driver, lease in
                try await driver.transferToAnyHuman(uid: task.uid, lease: lease)
            }
        } catch let error as PDDTransferPrecommitError {
            state.transferTasks[index].nextAttemptAt = now().addingTimeInterval(15)
            appendEvent(uid: task.uid, kind: "transfer-precommit-retry-deferred",
                detail: "No transfer control invoked; retry_in=15s; other customers continue; \(error.localizedDescription)")
            try persist()
            return
        } catch {
            state.transferTasks[index].state = .failed
            appendEvent(
                uid: task.uid, kind: "transfer-failed",
                detail: "转人工任务失败，已隔离且继续处理其他客户：\(error.localizedDescription)"
            )
            try persist()
            return
        }
        switch result {
        case .transferred(let agentLabel):
            state.transferTasks[index].state = .completed
            // Close all work already observed for this customer. Returning to this
            // profile cannot revive an old pending generation or handoff request.
            let closedIDs = Set(state.jobs.filter { $0.uid == task.uid }
                .flatMap { $0.capture.fullHistory.filter { $0.sender == .customer }.map(\.id) })
            for jobIndex in state.jobs.indices where state.jobs[jobIndex].uid == task.uid {
                let jobID = state.jobs[jobIndex].id
                generationAttempts[jobID] = nil
                liveGenerationJobIDs.remove(jobID)
                generationTasks.removeValue(forKey: jobID)?.cancel()
                if [.discovered, .capturing, .queued, .generating, .ready].contains(state.jobs[jobIndex].state) {
                    state.jobs[jobIndex].state = .quarantined
                    state.jobs[jobIndex].lastError = "Closed after successful human handoff"
                }
                state.jobs[jobIndex].pendingSupplement = nil
                state.jobs[jobIndex].supplementCapturePending = false
            }
            state.pendingCaptureRequests.removeAll { $0.uid == task.uid }
            state.pendingVideoBatches.removeAll { $0.uid == task.uid }
            state.deferredVideoTransferEvents.removeAll { $0.uid == task.uid }
            syncJobs()
            try persist()
            try await CustomerTransferPolicyStore.shared.completeHandoff(
                root: store.rootDirectory, uid: task.uid, messageIDs: closedIDs)
            try CodexSessionRegistry(rootDirectory: store.rootDirectory).invalidate(uid: task.uid)
            appendEvent(
                uid: task.uid, kind: "transfer-completed",
                detail: "已无原因直接转移给：\(agentLabel)"
            )
        case .failed(let reason):
            state.transferTasks[index].state = .failed
            appendEvent(
                uid: task.uid, kind: "transfer-failed",
                detail: "转人工任务失败，已隔离且继续处理其他客户：\(reason)"
            )
        }
        try persist()
    }

    private func deliverJob(at index: Int) async throws {
        guard let reply = state.jobs[index].reply,
              !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let batch = state.jobs[index].capture.batch else {
            state.jobs[index].state = .failed
            state.jobs[index].deliveryOutcome = .notSent
            state.jobs[index].lastError = "任务缺少回复或客户批次；已隔离，其他会话继续"
            appendEvent(uid: state.jobs[index].uid, kind: "invalid-ready-job-isolated",
                detail: "job=\(state.jobs[index].id)")
            syncJobs()
            try persist()
            return
        }
        let uid = state.jobs[index].uid
        state.jobs[index].state = .sending
        state.jobs[index].durableAttemptOperationID = UUID()
        state.jobs[index].sendWasInvoked = false
        syncJobs()
        try persist(sendCritical: true)
        guard state.jobs.indices.contains(index), state.jobs[index].state == .sending else {
            return
        }
        do {
            if driver.supportsTextDeliveryTracking, state.jobs[index].outgoingImages.isEmpty {
                let attempts = PDDTextDeliveryAttemptStore(root: store.rootDirectory)
                if try attempts.load(state.jobs[index].id)?.mayHaveSent != true {
                    try attempts.save(.init(uid: uid, replySHA256: PDDTextDeliveryAttempt.hash(reply),
                        stage: .prepared, updatedAt: now()), id: state.jobs[index].id)
                }
            }
        } catch {
            state.jobs[index].state = .ready
            state.jobs[index].deliveryOutcome = .notSent
            state.jobs[index].sendWasInvoked = false
            state.jobs[index].durableAttemptOperationID = nil
            state.jobs[index].nextAttemptAt = now().addingTimeInterval(15)
            state.jobs[index].lastError = "发送凭据尚未保存；未执行发送，将重试"
            syncJobs()
            try persist(sendCritical: true)
            return
        }
        state.jobs[index].sendWasInvoked = true
        // Persist the follow-up scan before the send, so a crash cannot erase it.
        enqueueCapture(uid, kind: .tail, baseCursor: batch.endCursor)
        do {
            try persist(sendCritical: true)
        } catch {
            state.jobs[index].state = .ready
            state.jobs[index].durableAttemptOperationID = nil
            state.jobs[index].sendWasInvoked = false
            syncJobs()
            throw error
        }
        guard state.jobs.indices.contains(index),
              state.jobs[index].state == .sending,
              state.jobs[index].sendWasInvoked else {
            return
        }
        currentUIOwner = "send:\(state.jobs[index].uid)"
        defer { currentUIOwner = nil }
        let result: AutoReplyDeliveryResult
        let outgoingImages = state.jobs[index].outgoingImages
        let deliveryID = state.jobs[index].id
        do {
            result = try await performUI(stage: outgoingImages.isEmpty ? "send" : "send-images", uid: uid) { driver, lease in
                try await driver.send(
                    uid: uid,
                    text: reply,
                    outgoingImages: outgoingImages,
                    deliveryID: deliveryID,
                    expectedCustomerCursor: batch.endCursor,
                    expectedCustomerMessageIDs: Set(batch.events.map(\.messageID)),
                    lease: lease
                )
            }
        } catch {
            if outgoingImages.isEmpty, driver.supportsTextDeliveryTracking,
               let attempt = try? PDDTextDeliveryAttemptStore(root: store.rootDirectory).load(deliveryID),
               attempt.uid == uid, attempt.replySHA256 == PDDTextDeliveryAttempt.hash(reply), !attempt.mayHaveSent {
                state.jobs[index].state = .ready
                state.jobs[index].deliveryOutcome = .notSent
                state.jobs[index].sendWasInvoked = false
                state.jobs[index].durableAttemptOperationID = nil
                state.jobs[index].nextAttemptAt = now().addingTimeInterval(5)
                state.jobs[index].lastError = "发送前中断；未发送回复已保留"
                appendEvent(uid: uid, kind: "reply-pre-send-interruption-retained", detail: "job=\(deliveryID)")
            } else {
                try finalizeUncertainSend(at: index, batch: batch, reason: "发送执行失败：\(error.localizedDescription)")
            }
            syncJobs()
            try persist(sendCritical: true)
            return
        }

        switch result {
        case .sent(let serviceMessageID):
            state.jobs[index].state = .completed
            state.jobs[index].deliveryOutcome = .sent
            state.jobs[index].confirmedServiceMessageID = serviceMessageID
            try CustomerMessageReceipts(root: store.rootDirectory).replied(state.jobs[index].capture, at: now())
            state.confirmedAutoReplyMessageIDsByUID[state.jobs[index].uid, default: []].insert(serviceMessageID)
            if let key = batch.incomingHandoffKey {
                try await CustomerTransferPolicyStore.shared.acknowledgeIncomingReply(
                    root: store.rootDirectory, uid: uid, boundaryKey: key
                )
            }
            appendEvent(uid: uid, kind: "reply-delivery-confirmed", detail: "service_message=\(serviceMessageID)")
            markProvisionalReceiptsAnswered(in: batch, uid: state.jobs[index].uid)
            enqueueTransferTaskIfNeeded(at: index)
            _ = state.advanceSourceAndPromoteSupplement(at: index)
            try transactionalStore.archiveTerminal(state.jobs[index])
        case .failedBeforeSend(let reason):
            if outgoingImages.isEmpty { removeUnnecessaryPreSendTail(uid: uid, cursor: batch.endCursor, deliveryID: deliveryID) }
            if state.jobs[index].replyAction == .replyThenTransfer {
                state.jobs[index].state = .completed
                state.jobs[index].deliveryOutcome = .notSent
                state.jobs[index].lastError = "客套回复尝试一次后未发送：\(reason)；转人工任务不受影响"
                state.jobs[index].nextAttemptAt = nil
                state.jobs[index].durableAttemptOperationID = nil
                state.jobs[index].sendWasInvoked = false
                _ = state.advanceSourceAndPromoteSupplement(at: index)
                try transactionalStore.archiveTerminal(state.jobs[index])
            } else if reason == "客户消息游标已变化" {
                state.jobs[index].deliveryOutcome = .notSent
                state.jobs[index].lastError = reason
                state.jobs[index].state = .failed
                enqueueCapture(state.jobs[index].uid, kind: .ordinary)
            } else {
                state.jobs[index].durableAttemptOperationID = nil
                state.jobs[index].sendWasInvoked = false
                handleTaskUIFailure(
                    at: index,
                    reason: "\(reason)；发送动作尚未执行，将继续重试"
                )
            }
        case .discardedBeforeSend(let reason):
            if batch.incomingHandoffKey == nil {
                state.jobs[index].durableAttemptOperationID = nil
                state.jobs[index].sendWasInvoked = false
                handleTaskUIFailure(at: index, reason: "\(reason)；未发送回复已保留，将重试")
                break
            }
            state.jobs[index].state = .failed
            state.jobs[index].deliveryOutcome = .notSent
            state.jobs[index].lastError = "\(reason)；已丢弃当前批次并继续"
            state.jobs[index].nextAttemptAt = nil
            state.jobs[index].durableAttemptOperationID = nil
            state.jobs[index].sendWasInvoked = false
            // A superseded handoff is safe to cancel, but no-send is never a
            // delivery receipt for customer messages.
            _ = state.advanceSourceAndPromoteSupplement(at: index, advanceCursor: false)
            try transactionalStore.archiveTerminal(state.jobs[index])
        case .uncertain(let reason):
            try finalizeUncertainSend(at: index, batch: batch, reason: reason)
        }
        syncJobs()
        try persist(sendCritical: true)
    }

    private func removeUnnecessaryPreSendTail(uid: String, cursor: AutoReplyCursor, deliveryID: UUID) {
        do {
            if let attempt = try PDDTextDeliveryAttemptStore(root: store.rootDirectory).load(deliveryID) {
                guard attempt.uid == uid, !attempt.mayHaveSent else { return }
            }
            let receipts = try CustomerMessageReceipts(root: store.rootDirectory).receipts(uid: uid)
            guard !receipts.values.contains(where: { $0.requiresSubmission && $0.submittedAt == nil && $0.replySentAt == nil && $0.closedAt == nil }) else { return }
            let count = state.pendingCaptureRequests.count
            state.pendingCaptureRequests.removeAll { $0.uid == uid && $0.kind == .tail && $0.baseCursor == cursor }
            if count != state.pendingCaptureRequests.count {
                appendEvent(uid: uid, kind: "pre-send-tail-scan-released", detail: "No send executed and no uncaptured submission gap; delivery retry retained")
            }
        } catch { appendEvent(uid: uid, kind: "pre-send-tail-check-deferred", detail: error.localizedDescription) }
    }

    private func registerVideoHold(uid: String, messageIDs: Set<String>) {
        guard !messageIDs.isEmpty else { return }
        let known = Set(state.videoHoldingNotices.filter { $0.uid == uid }.flatMap { $0.messageIDs })
        let sent = (try? CustomerMessageReceipts(root: store.rootDirectory).receipts(uid: uid)) ?? [:]
        let fresh = messageIDs.subtracting(known).filter { sent[$0]?.replySentAt == nil && sent[$0]?.closedAt == nil }
        guard !fresh.isEmpty else { return }
        refreshVideoHoldingNotices()
        if let index = state.videoHoldingNotices.firstIndex(where: { $0.uid == uid && $0.finishedAt == nil }) {
            state.videoHoldingNotices[index].messageIDs.formUnion(fresh)
        } else {
            state.videoHoldingNotices.append(.init(uid: uid, messageIDs: Set(fresh), capturedAt: now()))
        }
        appendEvent(uid: uid, kind: "video-hold-timer-started", detail: "delay_seconds=10 message_ids=\(fresh.sorted().joined(separator: ","))")
    }

    private func refreshVideoHoldingNotices() {
        for index in state.videoHoldingNotices.indices where state.videoHoldingNotices[index].finishedAt == nil {
            let notice = state.videoHoldingNotices[index]
            let terminal = Set(state.jobs.filter {
                $0.uid == notice.uid && [.completed, .failed, .quarantined].contains($0.state)
            }.flatMap { $0.capture.batch?.customerMessageIDs ?? [] })
            if notice.messageIDs.isSubset(of: terminal) {
                state.videoHoldingNotices[index].finishedAt = now()
                appendEvent(uid: notice.uid, kind: "video-hold-finished", detail: "final work terminal; notice=\(notice.id)")
            }
        }
    }

    private func sendDueVideoHoldingNotice() async throws -> Bool {
        guard deliveryEnabled, !realDeliveryPausedForPersistence else { return false }
        guard let index = state.videoHoldingNotices.firstIndex(where: { notice in
            notice.finishedAt == nil && notice.attemptedAt == nil && now().timeIntervalSince(notice.capturedAt) >= 10
                && videoHoldCapture(for: notice) != nil
                && !state.jobs.contains { $0.uid == notice.uid && [.ready, .sending].contains($0.state) }
        }) else { return false }
        let notice = state.videoHoldingNotices[index]
        guard let capture = videoHoldCapture(for: notice) else { return false }
        // Save the attempt before any UI action. Uncertain sends are never replayed.
        state.videoHoldingNotices[index].attemptedAt = now()
        appendEvent(uid: notice.uid, kind: "video-hold-send-started", detail: "notice=\(notice.id) message=\(notice.text)")
        try persist(sendCritical: true)
        currentUIOwner = "video-hold:\(notice.uid)"
        defer { currentUIOwner = nil }
        do {
            let result = try await performUI(stage: "send", uid: notice.uid) { driver, lease in
                try await driver.send(uid: notice.uid, text: notice.text, outgoingImages: [], deliveryID: notice.id,
                    expectedCustomerCursor: capture.customerCursor, expectedCustomerMessageIDs: notice.messageIDs, lease: lease)
            }
            switch result {
            case .sent(let id):
                state.videoHoldingNotices[index].outcome = "sent"
                state.videoHoldingNotices[index].confirmedServiceMessageID = id
                state.confirmedAutoReplyMessageIDsByUID[notice.uid, default: []].insert(id)
            case .failedBeforeSend, .discardedBeforeSend: state.videoHoldingNotices[index].outcome = "not-sent"
            case .uncertain: state.videoHoldingNotices[index].outcome = "uncertain"
            }
            appendEvent(uid: notice.uid, kind: "video-hold-send-result", detail: "notice=\(notice.id) \(result); final reply still required")
        } catch {
            state.videoHoldingNotices[index].outcome = "uncertain"
            appendEvent(uid: notice.uid, kind: "video-hold-send-failed", detail: "\(error.localizedDescription); no courtesy retry; final work continues")
        }
        // Do not advance answered cursors or set any original message's reply receipt.
        try persist(sendCritical: true)
        return true
    }

    private func videoHoldCapture(for notice: PDDVideoHoldingNotice) -> AutoReplyCapture? {
        let captures = state.pendingVideoBatches.filter { $0.uid == notice.uid }.map(\.capture)
            + state.jobs.filter { $0.uid == notice.uid && [.queued, .generating, .ready].contains($0.state) }.map(\.capture)
        return captures.filter { notice.messageIDs.isSubset(of: Set($0.fullHistory.map(\.id))) }
            .max { $0.customerCursor.count < $1.customerCursor.count }
    }

    private func coalesceQueuedVideoReplies() {
        let videoIDs = state.jobs.filter { $0.state == .queued && !$0.capture.videoAttachments.isEmpty }.map(\.id)
        for videoID in videoIDs {
            guard let video = state.jobs.first(where: { $0.id == videoID && $0.state == .queued }) else { continue }
            let ids = Set(video.capture.videoAttachments.map(\.messageID))
            let candidates = state.jobs.filter { job in
                guard job.uid == video.uid, job.state == .queued, job.capture.batch?.incomingHandoffKey == nil,
                      job.retries == 0, job.pendingSupplement == nil, !job.supplementCapturePending,
                      job.customerMissingSince == nil else { return false }
                if job.id == video.id { return true }
                guard job.capture.batch?.events.allSatisfy({ $0.kind == .text }) == true else { return false }
                let historyIDs = job.capture.fullHistory.map(\.id)
                guard let videoPosition = historyIDs.lastIndex(where: { ids.contains($0) }) else { return false }
                return job.capture.batch?.events.allSatisfy { event in
                    historyIDs.firstIndex(of: event.messageID).map { $0 > videoPosition } ?? false
                } == true
            }.sorted { $0.sequence < $1.sequence }
            guard candidates.count > 1, let first = candidates.first,
                  let joined = PDDVideoReplyBatch.joining(candidates.map(\.capture)),
                  let index = state.jobs.firstIndex(where: { $0.id == first.id }) else { continue }
            state.jobs[index] = AutoReplyJob(id: first.id, uid: first.uid, sequence: first.sequence, state: .queued,
                capture: joined, reply: nil, deliveryOutcome: nil, confirmedServiceMessageID: nil, retries: 0,
                nextAttemptAt: nil, lastError: nil, imageAttachments: joined.imageAttachments, videoAttachments: joined.videoAttachments)
            let removed = Set(candidates.dropFirst().map(\.id))
            state.jobs.removeAll { removed.contains($0.id) }
            appendEvent(uid: first.uid, kind: "video-text-batch-joined", detail: "queued_batches=\(candidates.count) message_ids=\((joined.batch?.customerMessageIDs ?? []).sorted().joined(separator: ","))")
        }
    }

    @discardableResult
    private func launchQueuedGenerations() -> Bool {
        let promoted = promoteCapturedFollowups()
        // Disabled by request: a ready answer must keep its own delivery turn.
        // New questions generate independently; never replace an existing reply.
        // let replaced = coalesceKnownUnsentTextDrafts()
        if promoted {
            syncJobs()
            do { try persist(sendCritical: true) }
            catch { recordPersistenceFailure(error, sendCritical: true); return false }
            archiveSupersededDrafts()
        }
        coalesceQueuedVideoReplies()
        let queued = state.jobs.indices.filter { index in
            state.jobs[index].state == .queued
                && !identityRecoveryBlockedUIDs.contains(state.jobs[index].uid)
                && !PDDConversationIdentityStore.isSharedVisitorUID(state.jobs[index].uid)
                && !generationWaitsForVideo(state.jobs[index])
                && (state.jobs[index].customerMissingSince.map { now().timeIntervalSince($0) < 600 } ?? true)
                && (state.jobs[index].nextAttemptAt.map { $0 <= now() } ?? true)
                && isHeadOfGeneration(index)
        }
        guard !queued.isEmpty else { return false }
        let dynamic = concurrencyPolicy.limit(
            queueDepth: queued.count + liveGenerationJobIDs.count,
            availableMemoryBytes: availableMemoryBytes(),
            activeCleanup: liveGenerationJobIDs.count,
            now: now()
        )
        let capacity = configuredMaximumConcurrentGenerations.map { min($0, dynamic) }
            ?? dynamic
        let slots = max(0, capacity - liveGenerationJobIDs.count)
        guard slots > 0 else { return false }

        for index in queued.prefix(slots) {
            let id = state.jobs[index].id
            var capture = state.jobs[index].capture
            capture.pendingReplyDrafts = unconfirmedDrafts(before: index)
            state.jobs[index].capture = capture
            state.jobs[index].state = .generating
            appendEvent(uid: capture.uid, kind: "generation-dispatched", detail: "job=\(id)")
            liveGenerationJobIDs.insert(id)
            let attempt = UUID()
            generationAttempts[id] = attempt
            let deadline = capture.batch?.incomingHandoffKey != nil
                ? min(generationTimeout, .seconds(75)) : generationTimeout
            generationTasks[id] = Task { [weak self, generator] in
                do {
                    let result = try await withOperationDeadline(deadline, stage: "generation") {
                        try await generator.generate(capture)
                    }
                    self?.generationFinished(jobID: id, attemptID: attempt, result: .success(result))
                } catch {
                    self?.generationFinished(jobID: id, attemptID: attempt, result: .failure(error))
                }
            }
        }
        syncJobs()
        do {
            try persist()
        } catch {
            recordPersistenceFailure(error, sendCritical: false)
        }
        return true
    }

    private func generationWaitsForVideo(_ job: AutoReplyJob) -> Bool {
        let prepared = Set(job.videoAttachments.map(\.messageID))
            .union(job.capture.videoAttachments.map(\.messageID))
        let targets = Set(job.capture.batch?.events.filter { $0.kind == .video }.map(\.messageID) ?? [])
            .union(job.capture.pendingVideoMessageIDs).subtracting(prepared)
        return state.pendingVideoBatches.contains {
            $0.uid == job.uid && !targets.isDisjoint(with: $0.expectedMessageIDs)
        }
    }

    /// A background retry may outlive the original video reply. Its UI capture
    /// must not reopen that answered turn or absorb a later customer message.
    @discardableResult
    private func releaseTerminalVideoWaits() -> Bool {
        guard !state.pendingVideoBatches.isEmpty else { return false }
        var terminalByUID: [String: Set<String>] = [:]
        for uid in Set(state.pendingVideoBatches.map(\.uid)) {
            var ids = Set(state.jobs.filter {
                $0.uid == uid && $0.state == .completed
                    && ($0.deliveryOutcome == .sent || $0.deliveryOutcome == .uncertain)
            }.flatMap { $0.capture.batch?.customerMessageIDs ?? [] })
            do {
                let receipts = try CustomerMessageReceipts(root: store.rootDirectory).receipts(uid: uid)
                ids.formUnion(receipts.values.filter { $0.replySentAt != nil }.map(\.messageID))
            } catch {
                appendEvent(uid: uid, kind: "video-terminal-receipts-unavailable", detail: error.localizedDescription)
            }
            terminalByUID[uid] = ids
        }
        var changed = false
        for pending in state.pendingVideoBatches {
            let terminal = terminalByUID[pending.uid] ?? []
            let released = Set(pending.expectedMessageIDs).intersection(terminal)
            guard !released.isEmpty,
                  let index = state.pendingVideoBatches.firstIndex(where: { $0.id == pending.id }) else { continue }
            state.pendingVideoBatches.remove(at: index)
            if let capture = captureByRemovingMessages(pending.capture, messageIDs: terminal) {
                let expected = pending.expectedMessageIDs.filter { !terminal.contains($0) }
                let retained = PDDPendingVideoBatch(id: pending.id, uid: pending.uid,
                    capture: capture, expectedMessageIDs: expected,
                    completedAttachmentsByMessageID: pending.completedAttachmentsByMessageID.filter { !terminal.contains($0.key) },
                    failedMessageIDs: pending.failedMessageIDs.subtracting(terminal),
                    duplicateMessageIDs: pending.duplicateMessageIDs.subtracting(terminal), createdAt: pending.createdAt)
                state.pendingVideoBatches.append(retained)
                let resolved = Set(retained.completedAttachmentsByMessageID.keys)
                    .union(retained.failedMessageIDs).union(retained.duplicateMessageIDs)
                if Set(expected).isSubset(of: resolved) {
                    promotePendingVideoBatch(at: state.pendingVideoBatches.count - 1)
                }
            }
            appendEvent(uid: pending.uid, kind: "video-terminal-wait-released",
                detail: "message_ids=\(released.sorted().joined(separator: ",")); background retry remains independent; later unsent messages preserved")
            changed = true
        }
        return changed
    }

    private func generationFinished(jobID: UUID, attemptID: UUID, result: Result<CodexReplyResult, Error>) {
        guard generationAttempts[jobID] == attemptID else { return }
        generationAttempts[jobID] = nil
        generationTasks[jobID] = nil
        liveGenerationJobIDs.remove(jobID)
        guard let index = state.jobs.firstIndex(where: { $0.id == jobID }),
              state.jobs[index].state == .generating else { return }
        switch result {
        case .success(let generated):
            state.jobs[index].reply = generated.reply
            state.jobs[index].outgoingImages = generated.outgoingImages
            state.jobs[index].replyAction = generated.action
            state.jobs[index].transferReason = generated.transferReason
            state.jobs[index].generationDiagnostic = generated.diagnostic
            if state.jobs[index].capture.batch?.incomingHandoffKey != nil {
                state.jobs[index].replyAction = .reply
                state.jobs[index].transferReason = .none
            }
            state.jobs[index].state = .ready
            appendEvent(uid: state.jobs[index].uid, kind: "generation-ready",
                detail: "job=\(jobID) action=\(state.jobs[index].replyAction.rawValue)")
            enqueueTransferTaskIfNeeded(at: index)
            concurrencyPolicy.recordSuccess(now: now())
        case .failure(let error):
            state.jobs[index].retries += 1
            state.jobs[index].lastError = retryPolicy.boundedDescription(error)
            appendEvent(uid: state.jobs[index].uid, kind: "generation-failed",
                detail: "job=\(jobID) \(retryPolicy.boundedDescription(error))")
            if state.jobs[index].capture.batch?.incomingHandoffKey != nil, !(error is CancellationError) {
                state.jobs[index].reply = PDDAXIncomingTransfer.fallbackReply(history: state.jobs[index].capture.fullHistory)
                state.jobs[index].replyAction = .reply
                state.jobs[index].transferReason = .none
                state.jobs[index].state = .ready
                state.jobs[index].nextAttemptAt = nil
                appendEvent(uid: state.jobs[index].uid, kind: "incoming-handoff-fallback-ready",
                    detail: "Generation unavailable; acknowledge receipt without creating a transfer loop")
                break
            }
            if retryPolicy.isBackpressure(error) {
                concurrencyPolicy.recordBackpressure(now: now())
            }
            let disposition = CodexFailureClassifier.classify(error)
            switch disposition {
            case .transferImmediately(let reason):
                prepareCodexFailureTransfer(at: index, reason: reason, error: error)
            case .retryOnceThenTransfer(let reason) where state.jobs[index].retries >= 2:
                prepareCodexFailureTransfer(at: index, reason: reason, error: error)
            case .retryOnceThenTransfer:
                state.jobs[index].state = .queued
                state.jobs[index].nextAttemptAt = now().addingTimeInterval(1)
            case .ordinaryRetry, .cancelled:
                switch retryPolicy.decision(
                    attempt: state.jobs[index].retries,
                    error: error,
                    now: now()
                ) {
                case .retry(let date), .rebuildSessionAndRetry(let date):
                    state.jobs[index].state = .queued
                    state.jobs[index].nextAttemptAt = date
                case .failRevision:
                    state.jobs[index].state = .quarantined
                    state.jobs[index].deliveryOutcome = .notSent
                    state.jobs[index].nextAttemptAt = nil
                    if state.jobs[index].pendingSupplement != nil
                        || state.jobs[index].supplementCapturePending {
                        _ = state.advanceSourceAndPromoteSupplement(at: index)
                    } else {
                        enqueueCapture(state.jobs[index].uid, kind: .ordinary)
                    }
                }
            }
        }
        syncJobs()
        do {
            // A generated reply is never eligible for delivery until the exact
            // ready/failed transition has a durable checkpoint.
            try persist(sendCritical: state.jobs[index].state == .ready)
        } catch {
            recordPersistenceFailure(
                error,
                sendCritical: state.jobs[index].state == .ready
            )
        }
    }

    private func prepareCodexFailureTransfer(
        at index: Int,
        reason: String,
        error: Error
    ) {
        state.jobs[index].reply = CustomerFacingFallback.handoff(history: state.jobs[index].capture.fullHistory)
        state.jobs[index].replyAction = .replyThenTransfer
        state.jobs[index].transferReason = .troubleshootingExhausted
        state.jobs[index].state = .ready
        state.jobs[index].nextAttemptAt = nil
        state.jobs[index].lastError = "\(reason)：\(retryPolicy.boundedDescription(error))"
        enqueueTransferTaskIfNeeded(at: index)
        appendEvent(
            uid: state.jobs[index].uid,
            kind: "codex-failure-transfer",
            detail: "\(reason)；已生成客套回复并建立独立转人工任务"
        )
    }

    private func nextCaptureRequest() -> AutoReplyCaptureRequest? {
        var deferred: [AutoReplyCaptureRequest] = []
        while !state.pendingCaptureRequests.isEmpty {
            let request = state.pendingCaptureRequests.removeFirst()
            if request.nextAttemptAt.map({ $0 > now() }) == true {
                deferred.append(request)
                continue
            }
            if PDDConversationIdentityStore.isSharedVisitorUID(request.uid) {
                var waiting = request
                waiting.nextAttemptAt = now().addingTimeInterval(30)
                deferred.append(waiting)
                appendEvent(uid: request.uid, kind: "identity-capture-waiting",
                    detail: "旧共享访客记录需先用平台消息核对身份；保留请求，30秒后复查，不占用聊天窗口")
                continue
            }
            if request.kind == .ordinary {
                guard ordinaryCaptureAuthorizations.contains(request.uid) else { continue }
            }
            if request.kind == .supplement || request.kind == .videoRecovery
                || !hasActiveJob(uid: request.uid) {
                if request.kind == .ordinary { ordinaryCaptureAuthorizations.remove(request.uid) }
                state.pendingCaptureRequests.append(contentsOf: deferred)
                return request
            }
            deferred.append(request)
        }
        state.pendingCaptureRequests.append(contentsOf: deferred)
        return nil
    }

    private func nextSupplementCaptureRequest() -> AutoReplyCaptureRequest? {
        guard let index = state.pendingCaptureRequests.firstIndex(where: {
            guard $0.kind == .supplement && ($0.tailAttempt ?? 0) == 0 else { return false }
            guard !PDDConversationIdentityStore.isSharedVisitorUID($0.uid) else { return false }
            guard $0.nextAttemptAt.map({ $0 <= now() }) ?? true else { return false }
            guard let source = supplementSourceIndex(for: $0) else { return false }
            return isHeadOfLine(source)
        })
        else { return nil }
        return state.pendingCaptureRequests.remove(at: index)
    }

    private func capture(request: AutoReplyCaptureRequest) async throws {
        let uid = request.uid
        currentUIOwner = "capture:\(uid)"
        defer { currentUIOwner = nil }
        let startingCursor = request.kind == .ordinary || request.kind == .tail
            ? answeredCursor(uid)
            : request.baseCursor
        let sourceIndex = request.kind == .supplement
            ? supplementSourceIndex(for: request)
            : nil
        let includeImages = sourceIndex.map { !state.jobs[$0].imageCaptureAttempted } ?? true
        if includeImages, let sourceIndex {
            state.jobs[sourceIndex].imageCaptureAttempted = true
            syncJobs()
            try persist()
        }
        let rawCapture: AutoReplyCapture
        do {
            rawCapture = try await performUI(stage: "capture", uid: uid) { driver, lease in
                try await driver.capture(
                    uid: uid, after: startingCursor, includeImages: includeImages,
                    onlyVideoMessageID: request.kind == .videoRecovery
                        ? request.videoMessageID : nil,
                    lease: lease
                )
            }
        } catch {
            if request.kind == .supplement {
                let attempt = request.tailAttempt ?? 0
                if attempt < 2 {
                    state.pendingCaptureRequests.append(AutoReplyCaptureRequest(
                        uid: request.uid,
                        kind: .supplement,
                        baseCursor: request.baseCursor,
                        tailAttempt: attempt + 1,
                        sourceJobID: request.sourceJobID
                    ))
                } else {
                    var retry = request
                    retry.nextAttemptAt = now().addingTimeInterval(15)
                    state.pendingCaptureRequests.append(retry)
                    appendEvent(uid: uid, kind: "capture-retry-deferred",
                        detail: "supplement retry_in=15s; other conversations continue")
                }
            } else {
                let failureCount = ordinaryCaptureFailureCounts[uid, default: 0] + 1
                ordinaryCaptureFailureCounts[uid] = failureCount
                if failureCount == 1 {
                    ordinaryCaptureAuthorizations.insert(uid)
                    state.pendingCaptureRequests.append(request)
                    appendEvent(
                        uid: uid, kind: "capture-requeued",
                        detail: "首次定位或采集失败；已移到队尾"
                    )
                } else {
                    if request.kind == .ordinary { ordinaryCaptureAuthorizations.insert(uid) }
                    var retry = request
                    retry.nextAttemptAt = now().addingTimeInterval(15)
                    state.pendingCaptureRequests.append(retry)
                    appendEvent(
                        uid: uid, kind: "capture-retry-deferred",
                        detail: "连续采集失败；请求已保留，15 秒后重试，其他会话继续"
                    )
                }
            }
            throw error
        }
        if request.kind == .ordinary {
            ordinaryCaptureFailureCounts[uid] = nil
        }
        try CustomerMessageReceipts(root: store.rootDirectory).capture(rawCapture, at: now())
        do { try driver.acknowledgeDiscoveryCapture(rawCapture) }
        catch {
            appendEvent(uid: uid, kind: "discovery-capture-ack-deferred", detail: error.localizedDescription)
        }
        registerVideoHold(uid: uid, messageIDs: Set(rawCapture.batch?.events.filter { $0.kind == .video }.map(\.messageID) ?? []))
        appendEvent(uid: uid, kind: "customer-messages-captured",
            detail: "message_ids=\((rawCapture.batch?.customerMessageIDs ?? []).sorted().joined(separator: ","))")
        try reconcileVisibleReplies(in: rawCapture, uid: uid)
        let normalizedCapture = normalizeObservation(rawCapture, uid: uid)
        let capture: AutoReplyCapture
        if request.kind == .ordinary || request.kind == .tail {
            let closed = try await CustomerTransferPolicyStore.shared.closedMessageIDs(
                root: store.rootDirectory, uid: uid)
            let aliasCovered = confirmedAliasMessageIDs(in: normalizedCapture)
            let receiptClosed = try CustomerMessageReceipts(root: store.rootDirectory).closedMessageIDs(uid: uid)
            let covered = coveredMessageIDs(uid: uid).union(closed).union(aliasCovered).union(receiptClosed)
            if !aliasCovered.isEmpty {
                appendEvent(uid: uid, kind: "masked-name-delivery-reconciled",
                    detail: "Previously sent reply verified after its exact target message in this chat; covered_message_ids=\(aliasCovered.sorted().joined(separator: ","))")
            }
            guard let filtered = captureByRemovingMessages(
                normalizedCapture, messageIDs: covered
            ) else {
                latestCapture = normalizedCapture
                let inFlight = Set(state.jobs.filter {
                    $0.uid == uid && [.queued, .generating, .ready, .sending].contains($0.state)
                }.flatMap { $0.capture.batch?.events.map(\.messageID) ?? [] })
                let observed = Set(normalizedCapture.batch?.events.map(\.messageID) ?? [])
                if normalizedCapture.customerCursor.count > startingCursor.count,
                   inFlight.isDisjoint(with: observed) {
                    state.answeredCursors[uid] = normalizedCapture.customerCursor
                }
                syncJobs()
                try persist()
                return
            }
            capture = filtered
        } else {
            capture = normalizedCapture
        }
        latestCapture = capture
        if request.kind != .videoRecovery, let batch = capture.batch, batch.incomingHandoffKey == nil,
           !batch.events.isEmpty, batch.events.allSatisfy({ $0.kind == .text }),
           let pendingIndex = state.pendingVideoBatches.firstIndex(where: { $0.uid == uid }),
           batch.customerMessageIDs.isDisjoint(with: Set(state.pendingVideoBatches[pendingIndex].expectedMessageIDs)),
           let joined = PDDVideoReplyBatch.joining([state.pendingVideoBatches[pendingIndex].capture, capture]) {
            state.pendingVideoBatches[pendingIndex].capture = joined
            appendEvent(uid: uid, kind: "video-text-batch-joined", detail: "message_ids=\(batch.customerMessageIDs.sorted().joined(separator: ","))")
            syncJobs(); try persist(); return
        }
        if request.kind == .tail, let batch = capture.batch,
           let index = activeJobIndex(uid: uid) {
            let count = state.jobs[index].pendingSupplement?.customerCursor.count ?? -1
            if capture.customerCursor.count > count {
                state.jobs[index].pendingSupplement = capture
            }
            appendEvent(uid: uid, kind: "post-send-capture-attached",
                detail: "message_ids=\(batch.customerMessageIDs.sorted().joined(separator: ","))")
            syncJobs()
            try persist()
            return
        }
        if request.kind == .supplement {
            let sourceIndex = supplementSourceIndex(for: request)
            guard let index = sourceIndex else {
                enqueueCapture(uid, kind: .ordinary)
                syncJobs()
                try persist()
                return
            }
            if capture.batch != nil {
                if try reconcileInflightSupplementWithPromotedRevision(capture, from: index) {
                    state.jobs[index].supplementCapturePending = false
                    syncJobs()
                    try persist()
                    return
                }
                let currentCount = state.jobs[index].pendingSupplement?.customerCursor.count ?? -1
                if capture.customerCursor.count > currentCount {
                    state.jobs[index].pendingSupplement = capture
                }
                state.jobs[index].supplementCapturePending = false
                if [.completed, .failed, .uncertain, .quarantined].contains(state.jobs[index].state) {
                    _ = state.advanceSourceAndPromoteSupplement(at: index)
                }
            } else if state.jobs[index].pendingSupplement != nil {
                state.jobs[index].supplementCapturePending = false
            } else if [.completed, .failed, .uncertain, .quarantined].contains(state.jobs[index].state) {
                let attempt = request.tailAttempt ?? 0
                if attempt < 2 {
                    state.pendingCaptureRequests.append(AutoReplyCaptureRequest(
                        uid: request.uid,
                        kind: .supplement,
                        baseCursor: request.baseCursor,
                        tailAttempt: attempt + 1,
                        sourceJobID: request.sourceJobID
                    ))
                } else {
                    state.jobs[index].supplementCapturePending = false
                    enqueueCapture(uid, kind: .ordinary)
                }
            } else {
                state.jobs[index].supplementCapturePending = false
            }
            syncJobs()
            try persist()
            return
        }
        if request.kind != .videoRecovery && answeredCursor(uid) != startingCursor {
            enqueueCapture(uid, kind: .ordinary)
            syncJobs()
            try persist()
            return
        }
        guard capture.batch != nil else {
            if request.kind == .videoRecovery {
                requeueVideoRecoveryIfNeeded(request)
                syncJobs()
                try persist()
                return
            }
            if capture.customerCursor.count > startingCursor.count {
                state.answeredCursors[uid] = capture.customerCursor
            }
            syncJobs()
            try persist()
            return
        }
        if !capture.pendingVideoMessageIDs.isEmpty {
            if let endCursor = capture.batch?.endCursor {
                state.answeredCursors[uid] = endCursor
            }
            let alreadyPending = state.pendingVideoBatches.contains {
                $0.uid == uid && $0.capture.batch?.endCursor == capture.batch?.endCursor
            }
            if !alreadyPending {
                state.pendingVideoBatches.append(PDDPendingVideoBatch(
                    uid: uid,
                    capture: capture,
                    expectedMessageIDs: capture.pendingVideoMessageIDs
                ))
            }
            if request.kind == .videoRecovery,
               let target = request.videoMessageID,
               !capture.pendingVideoMessageIDs.contains(target) {
                requeueVideoRecoveryIfNeeded(request)
            }
            syncJobs()
            try persist()
            let deferred = state.deferredVideoTransferEvents.filter {
                $0.uid == uid && capture.pendingVideoMessageIDs.contains($0.messageID)
            }
            state.deferredVideoTransferEvents.removeAll {
                $0.uid == uid && capture.pendingVideoMessageIDs.contains($0.messageID)
            }
            for event in deferred { await receiveVideoTransferEvent(event) }
            return
        }
        if request.kind == .videoRecovery {
            requeueVideoRecoveryIfNeeded(request)
            syncJobs()
            try persist()
            return
        }
        state.nextSequence += 1
        state.jobs.append(AutoReplyJob(
            id: UUID(),
            uid: uid,
            sequence: state.nextSequence,
            state: .queued,
            capture: capture,
            reply: nil,
            deliveryOutcome: nil,
            confirmedServiceMessageID: nil,
            retries: 0,
            nextAttemptAt: nil,
            lastError: nil,
            imageAttachments: capture.imageAttachments,
            videoAttachments: capture.videoAttachments
        ))
        syncJobs()
        try persist()
    }

    private func requeueVideoRecoveryIfNeeded(_ request: AutoReplyCaptureRequest) {
        let attempt = request.tailAttempt ?? 0
        guard attempt < 1 else {
            appendEvent(
                uid: request.uid,
                kind: "video-recovery-dropped",
                detail: "连续两次未找到目标视频；已删除本次恢复请求并继续扫描"
            )
            if let messageID = request.videoMessageID,
               let index = state.pendingVideoBatches.firstIndex(where: {
                   $0.uid == request.uid && $0.expectedMessageIDs.contains(messageID)
               }) {
                state.pendingVideoBatches[index].failedMessageIDs.insert(messageID)
                let pending = state.pendingVideoBatches[index]
                let terminal = Set(pending.completedAttachmentsByMessageID.keys)
                    .union(pending.failedMessageIDs)
                    .union(pending.duplicateMessageIDs)
                if Set(pending.expectedMessageIDs).isSubset(of: terminal) {
                    promotePendingVideoBatch(at: index)
                }
            }
            return
        }
        state.pendingCaptureRequests.append(AutoReplyCaptureRequest(
            uid: request.uid,
            kind: .videoRecovery,
            baseCursor: request.baseCursor,
            tailAttempt: attempt + 1,
            sourceJobID: request.sourceJobID,
            videoMessageID: request.videoMessageID
        ))
    }

    private func normalizeObservation(_ rawCapture: AutoReplyCapture, uid: String) -> AutoReplyCapture {
        let observedServiceIDs = Set(
            rawCapture.fullHistory.lazy.filter { $0.sender == .service }.map(\.id)
        )
        state.axFirstBaselinedUIDs.insert(uid)
        state.knownServiceMessageIDsByUID[uid, default: []].formUnion(observedServiceIDs)
        return AutoReplyCapture(
            uid: rawCapture.uid,
            fullHistory: rawCapture.fullHistory,
            batch: rawCapture.batch,
            customerCursor: rawCapture.customerCursor,
            unexpectedServiceMessageIDs: [],
            knowledgeEvidence: rawCapture.knowledgeEvidence,
            ocrDiagnostic: rawCapture.ocrDiagnostic,
            imageAttachments: rawCapture.imageAttachments,
            videoAttachments: rawCapture.videoAttachments,
            pendingVideoMessageIDs: rawCapture.pendingVideoMessageIDs
        )
    }

    private func reconcileVisibleReplies(in capture: AutoReplyCapture, uid: String) throws {
        var usedServiceIDs = state.confirmedAutoReplyMessageIDsByUID[uid] ?? []
        let candidateIndices = state.jobs.indices
            .filter { state.jobs[$0].uid == uid && state.jobs[$0].state != .completed }
            .filter { state.jobs[$0].reply != nil && state.jobs[$0].capture.batch != nil }
            .sorted { state.jobs[$0].sequence < state.jobs[$1].sequence }

        for jobIndex in candidateIndices {
            guard let reply = state.jobs[jobIndex].reply,
                  let batch = state.jobs[jobIndex].capture.batch,
                  let targetMessageID = batch.events.last?.messageID,
                  let targetIndex = capture.fullHistory.lastIndex(where: { $0.id == targetMessageID }),
                  targetIndex < capture.fullHistory.index(before: capture.fullHistory.endIndex),
                  let service = capture.fullHistory[capture.fullHistory.index(after: targetIndex)...]
                    .first(where: {
                        $0.sender == .service
                            && !usedServiceIDs.contains($0.id)
                            && $0.content == reply
                    })
            else { continue }

            state.jobs[jobIndex].state = .completed
            state.jobs[jobIndex].deliveryOutcome = .sent
            state.jobs[jobIndex].confirmedServiceMessageID = service.id
            state.jobs[jobIndex].lastError = nil
            state.jobs[jobIndex].nextAttemptAt = nil
            if let batch = state.jobs[jobIndex].capture.batch {
                markProvisionalReceiptsAnswered(in: batch, uid: uid)
            }
            enqueueTransferTaskIfNeeded(at: jobIndex)
            _ = state.advanceSourceAndPromoteSupplement(at: jobIndex)
            state.confirmedAutoReplyMessageIDsByUID[uid, default: []].insert(service.id)
            usedServiceIDs.insert(service.id)
            appendEvent(uid: uid, kind: "delivery-reconciled", detail: service.id)
            try transactionalStore.archiveTerminal(state.jobs[jobIndex])
        }
    }

    private func enqueueCapture(
        _ uid: String,
        kind: AutoReplyCaptureRequestKind,
        baseCursor: AutoReplyCursor? = nil,
        tailAttempt: Int? = nil,
        sourceJobID: UUID? = nil
    ) {
        if kind == .ordinary, !ordinaryCaptureAuthorizations.contains(uid) { return }
        let cursor = baseCursor ?? answeredCursor(uid)
        let duplicate = state.pendingCaptureRequests.contains {
            $0.uid == uid && $0.kind == kind && $0.baseCursor == cursor
                && $0.sourceJobID == sourceJobID
        }
        guard !duplicate else { return }
        if kind == .ordinary && hasActiveJob(uid: uid) { return }
        state.pendingCaptureRequests.append(AutoReplyCaptureRequest(
            uid: uid,
            kind: kind,
            baseCursor: cursor,
            tailAttempt: tailAttempt,
            sourceJobID: sourceJobID
        ))
    }

    private func admitRecoveredVideo(uid: String, attachment: AutoReplyVideoAttachment) {
        guard !state.jobs.contains(where: {
            $0.uid == uid && $0.videoAttachments.contains { existing in
                existing.messageID == attachment.messageID
            }
        }) else { return }
        let messageID = "video-analysis:\(attachment.messageID)"
        let message = PDDChatMessage(
            id: messageID, sender: .customer, content: "[视频]",
            displayTime: nil, kind: .video, capturedAt: now()
        )
        guard let timeline = try? AutoReplyTimeline.make(messages: [message]),
              let batch = try? timeline.freeze(after: .empty) else { return }
        let capture = AutoReplyCapture(
            uid: uid, fullHistory: [message], batch: batch,
            customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [],
            ocrDiagnostic: "后台重试已成功下载客户视频",
            videoAttachments: [attachment]
        )
        state.nextSequence += 1
        state.jobs.append(AutoReplyJob(
            id: UUID(), uid: uid, sequence: state.nextSequence, state: .queued,
            capture: capture, reply: nil, deliveryOutcome: nil,
            confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil,
            lastError: nil, videoAttachments: [attachment]
        ))
    }

    @discardableResult
    private func scheduleSupplementCaptureIfActive(uid: String) -> Bool {
        guard let index = activeJobIndex(uid: uid) else { return false }
        guard !state.jobs[index].supplementCapturePending else { return false }
        let baseCursor = state.jobs[index].capture.batch?.endCursor
            ?? state.jobs[index].capture.customerCursor
        state.jobs[index].supplementCapturePending = true
        let before = state.pendingCaptureRequests.count
        enqueueCapture(
            uid, kind: .supplement, baseCursor: baseCursor,
            sourceJobID: state.jobs[index].id
        )
        return state.pendingCaptureRequests.count != before
    }

    private func failAndContinue(at index: Int, reason: String) {
        guard state.jobs[index].capture.batch != nil else { return }
        let uid = state.jobs[index].uid
        state.jobs[index].state = .failed
        state.jobs[index].deliveryOutcome = .notSent
        state.jobs[index].lastError = "\(reason)；已跳过当前批次并继续"
        state.jobs[index].nextAttemptAt = nil
        if !state.advanceSourceAndPromoteSupplement(at: index) {
            enqueueCapture(uid, kind: .ordinary)
        }
    }

    private func handleTaskUIFailure(at index: Int, reason: String) {
        state.jobs[index].stageAttempt += 1
        state.jobs[index].deliveryOutcome = .notSent
        state.jobs[index].lastError = reason
        switch TaskFailurePolicy.uiDecision(
            previousFailures: state.jobs[index].stageAttempt - 1
        ) {
        case .requeueAtTail:
            state.jobs[index].state = .ready
            state.jobs[index].nextAttemptAt = now().addingTimeInterval(
                TaskFailurePolicy.firstRetryDelay
            )
        case .parkRevision:
            // Keep a known-unsent reply retryable without holding the UI or
            // blocking other customers. A temporary AX failure must not consume it.
            state.jobs[index].state = .ready
            state.jobs[index].nextAttemptAt = now().addingTimeInterval(15)
            appendEvent(uid: state.jobs[index].uid, kind: "reply-not-sent-retry-scheduled",
                detail: "attempt=\(state.jobs[index].stageAttempt) retry_in=15s \(reason)")
        }
    }

    private func finalizeUncertainSend(
        at index: Int,
        batch: FrozenCustomerBatch,
        reason: String
    ) throws {
        let uid = state.jobs[index].uid
        state.jobs[index].state = .completed
        state.jobs[index].deliveryOutcome = .uncertain
        state.jobs[index].lastError = reason
        let tracked = state.jobs[index].outgoingImages.isEmpty
            && (try? PDDTextDeliveryAttemptStore(root: store.rootDirectory).load(state.jobs[index].id)) != nil
        state.jobs[index].nextAttemptAt = tracked ? now().addingTimeInterval(15) : nil
        _ = state.advanceSourceAndPromoteSupplement(at: index)
        if !tracked { try transactionalStore.archiveTerminal(state.jobs[index]) }
        appendEvent(uid: uid, kind: "reply-delivery-reconciliation-pending", detail: "job=\(state.jobs[index].id); no confirmed delivery receipt")
    }

    private func performUI<Value: Sendable>(
        stage: String,
        uid: String,
        operation: @escaping @MainActor @Sendable (
            any AutoReplyAutomationDriver, UIOperationLease
        ) async throws -> Value
    ) async throws -> Value {
        do {
            let current = try transactionalStore.loadCheckpoint()
            guard current.token == checkpointToken else {
                throw AutoReplyTransactionalStoreError.checkpointChanged
            }
        } catch {
            realDeliveryPausedForPersistence = true
            lastRuntimeIssue = "持久化状态异常，自动客服已停止：\(error.localizedDescription)"
            stop()
            throw error
        }
        let lease = uiLeaseRegistry.acquire(uid: uid)
        AutomationStepLog.record(root: store.rootDirectory, uid: uid, step: "\(stage)-operation-started",
            detail: "operation=\(lease.operationID)")
        activeUIOperationID = lease.operationID
        currentUIOwner = "\(stage):\(uid)"
        defer {
            uiLeaseRegistry.release(lease)
            if activeUIOperationID == lease.operationID {
                activeUIOperationID = nil
                currentUIOwner = nil
            }
        }
        do {
            let deadline = uiOperationTimeoutOverride ?? timeout(for: stage)
            let result = try await withOperationDeadline(
                deadline,
                stage: stage,
                shouldDeferTimeout: { lease.isDeadlineSuspended },
                maximumDuration: deadline
            ) {
                try lease.validate()
                let value = try await operation(self.driver, lease)
                try lease.validate()
                return value
            }
            AutomationStepLog.record(root: store.rootDirectory, uid: uid, step: "\(stage)-operation-completed",
                detail: "operation=\(lease.operationID)")
            return result
        } catch {
            AutomationStepLog.record(root: store.rootDirectory, uid: uid, step: "\(stage)-operation-failed",
                detail: "operation=\(lease.operationID) \(error.localizedDescription)")
            uiLeaseRegistry.revoke(operationID: lease.operationID)
            // Cleanup may itself be stuck. Revocation is synchronous above;
            // never await an unbounded driver cleanup while holding the pump.
            Task { [driver] in
                _ = try? await withOperationDeadline(.seconds(1), stage: "ui-cleanup") {
                    await driver.revokeCurrentUIOperation(operationID: lease.operationID)
                    return true
                }
            }
            throw error
        }
    }

    private func timeout(for stage: String) -> Duration {
        .seconds(PDDUIStageTimeouts.approved.outerSeconds(forOperationNamed: stage))
    }

    private func hasActiveJob(uid: String) -> Bool {
        activeJobIndex(uid: uid) != nil
    }

    private func promotePendingVideoBatch(at index: Int) {
        guard state.pendingVideoBatches.indices.contains(index) else { return }
        let pending = state.pendingVideoBatches.remove(at: index)
        let attachments = pending.expectedMessageIDs.compactMap {
            pending.completedAttachmentsByMessageID[$0]
        }
        guard let uncoveredCapture = captureByRemovingMessages(
            pending.capture, messageIDs: coveredMessageIDs(uid: pending.uid)
        ) else {
            if let end = pending.capture.batch?.endCursor,
               end.count > (state.answeredCursors[pending.uid]?.count ?? 0) {
                state.answeredCursors[pending.uid] = end
            }
            appendEvent(
                uid: pending.uid, kind: "video-batch-already-covered",
                detail: pending.expectedMessageIDs.sorted().joined(separator: ",")
            )
            return
        }
        let retainedCapture = captureByRemovingMessages(
            uncoveredCapture, messageIDs: pending.duplicateMessageIDs
        )
        guard let retainedCapture else {
            if let end = pending.capture.batch?.endCursor,
               end.count > (state.answeredCursors[pending.uid]?.count ?? 0) {
                state.answeredCursors[pending.uid] = end
            }
            appendEvent(
                uid: pending.uid, kind: "video-content-duplicate",
                detail: pending.duplicateMessageIDs.sorted().joined(separator: ",")
            )
            return
        }
        let failed = pending.failedMessageIDs
        let diagnostic: String
        if failed.isEmpty {
            diagnostic = retainedCapture.ocrDiagnostic ?? ""
        } else {
            let suffix = "视频内容暂未读取成功，请简短询问客户希望查看什么"
            let existing = retainedCapture.ocrDiagnostic ?? ""
            diagnostic = existing.isEmpty ? suffix : "\(existing)；\(suffix)"
        }
        let capture = AutoReplyCapture(
            uid: retainedCapture.uid,
            fullHistory: retainedCapture.fullHistory,
            batch: retainedCapture.batch,
            customerCursor: retainedCapture.customerCursor,
            unexpectedServiceMessageIDs: retainedCapture.unexpectedServiceMessageIDs,
            knowledgeEvidence: retainedCapture.knowledgeEvidence,
            ocrDiagnostic: diagnostic.isEmpty ? nil : diagnostic,
            imageAttachments: retainedCapture.imageAttachments,
            videoAttachments: attachments,
            pendingVideoMessageIDs: []
        )
        let isPureFailedVideo = !failed.isEmpty
            && attachments.isEmpty
            && (capture.batch?.events.allSatisfy {
                pending.expectedMessageIDs.contains($0.messageID)
            } == true)
        state.nextSequence += 1
        state.jobs.append(AutoReplyJob(
            id: UUID(),
            uid: pending.uid,
            sequence: state.nextSequence,
            state: isPureFailedVideo ? .ready : .queued,
            capture: capture,
            reply: isPureFailedVideo
                ? "视频已收到，您希望我重点帮您查看哪个问题？也可以描述一下具体表现。"
                : nil,
            deliveryOutcome: nil,
            confirmedServiceMessageID: nil,
            retries: 0,
            nextAttemptAt: nil,
            lastError: nil,
            imageAttachments: capture.imageAttachments,
            videoAttachments: attachments
        ))
    }

    private func confirmedAliasMessageIDs(in capture: AutoReplyCapture) -> Set<String> {
        let customerIDs = Set(capture.fullHistory.filter { $0.sender == .customer }.map(\.id))
        return Set(state.jobs.filter { job in
            guard job.uid != capture.uid, job.state == .completed, job.deliveryOutcome == .sent,
                  let target = job.capture.batch?.events.last?.messageID,
                  let index = capture.fullHistory.lastIndex(where: { $0.id == target && $0.sender == .customer })
            else { return false }
            // Text sender receipts may use a synthetic ax-send ID. In that
            // case, also require the exact delivered reply after the exact
            // target customer message; a sent flag alone is insufficient.
            return capture.fullHistory.dropFirst(index + 1).contains { message in
                message.sender == .service && (message.id == job.confirmedServiceMessageID
                    || (job.reply?.isEmpty == false && message.content == job.reply))
            }
        }.flatMap { $0.capture.batch?.customerMessageIDs ?? [] }).intersection(customerIDs)
    }

    private func coveredMessageIDs(uid: String) -> Set<String> {
        let jobIDs = state.jobs.lazy
            .filter { job in
                guard job.uid == uid else { return false }
                if [.queued, .generating, .ready, .sending].contains(job.state) {
                    return true
                }
                return job.state == .completed && job.deliveryOutcome != .notSent
            }
            .flatMap { $0.capture.batch?.events.map(\.messageID) ?? [] }
        let pendingIDs = state.pendingVideoBatches.lazy
            .filter { $0.uid == uid }
            .flatMap { $0.capture.batch?.events.map(\.messageID) ?? [] }
        return Set(jobIDs).union(pendingIDs)
    }

    private func captureByRemovingMessages(
        _ capture: AutoReplyCapture,
        messageIDs: Set<String>
    ) -> AutoReplyCapture? {
        guard !messageIDs.isEmpty, let batch = capture.batch else { return capture }
        let retained = batch.events.filter { !messageIDs.contains($0.messageID) }
        guard retained.count != batch.events.count else { return capture }
        guard !retained.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let jsonl = retained.compactMap { event -> String? in
            guard let data = try? encoder.encode(event) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
        let retainedIDs = Set(retained.map(\.messageID))
        return AutoReplyCapture(
            uid: capture.uid,
            fullHistory: capture.fullHistory,
            batch: FrozenCustomerBatch(
                startCursor: batch.startCursor,
                endCursor: batch.endCursor,
                events: retained,
                targetCustomerJSONL: jsonl
            ),
            customerCursor: capture.customerCursor,
            unexpectedServiceMessageIDs: capture.unexpectedServiceMessageIDs,
            knowledgeEvidence: capture.knowledgeEvidence,
            ocrDiagnostic: capture.ocrDiagnostic,
            imageAttachments: capture.imageAttachments.filter {
                retainedIDs.contains($0.messageID)
            },
            videoAttachments: capture.videoAttachments.filter {
                retainedIDs.contains($0.messageID)
            },
            pendingVideoMessageIDs: capture.pendingVideoMessageIDs.filter {
                retainedIDs.contains($0)
            }
        )
    }

    private func supplementSourceIndex(for request: AutoReplyCaptureRequest) -> Int? {
        if let sourceJobID = request.sourceJobID {
            return state.jobs.firstIndex(where: { $0.id == sourceJobID })
        }
        let matches = state.jobs.indices.filter { index in
            let job = state.jobs[index]
            return job.uid == request.uid
                && job.capture.batch?.endCursor == request.baseCursor
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func reconcileInflightSupplementWithPromotedRevision(
        _ capture: AutoReplyCapture,
        from sourceIndex: Int
    ) throws -> Bool {
        guard state.jobs.indices.contains(sourceIndex), let incoming = capture.batch else {
            return false
        }
        let source = state.jobs[sourceIndex]
        let incomingIDs = incoming.events.map(\.messageID)
        let candidateIndices = state.jobs.indices.filter { index in
            let candidate = state.jobs[index]
            return candidate.id != source.id
                && candidate.uid == source.uid
                && candidate.sequence > source.sequence
                && candidate.customerRevision >= source.customerRevision + 1
                && candidate.capture.batch != nil
        }
        if candidateIndices.contains(where: { index in
            guard let promoted = state.jobs[index].capture.batch else { return false }
            return promoted.endCursor == incoming.endCursor
                || promoted.events.map(\.messageID) == incomingIDs
        }) { return true }

        let timeline = try AutoReplyTimeline.make(messages: capture.fullHistory)
        for index in candidateIndices.sorted(by: {
            state.jobs[$0].sequence > state.jobs[$1].sequence
        }) {
            let promotedCursor = state.jobs[index].capture.customerCursor
            guard promotedCursor.count < capture.customerCursor.count,
                  timeline.validatesPrefix(promotedCursor),
                  let deltaBatch = try timeline.freeze(after: promotedCursor) else { continue }
            let deltaIDs = Set(deltaBatch.events.map(\.messageID))
            let deltaCapture = AutoReplyCapture(
                uid: capture.uid,
                fullHistory: capture.fullHistory,
                batch: deltaBatch,
                customerCursor: capture.customerCursor,
                unexpectedServiceMessageIDs: [],
                knowledgeEvidence: capture.knowledgeEvidence,
                ocrDiagnostic: capture.ocrDiagnostic,
                imageAttachments: capture.imageAttachments.filter {
                    deltaIDs.contains($0.messageID)
                },
                videoAttachments: capture.videoAttachments.filter {
                    deltaIDs.contains($0.messageID)
                },
                pendingVideoMessageIDs: capture.pendingVideoMessageIDs.filter {
                    deltaIDs.contains($0)
                }
            )
            if state.jobs[index].state == .queued, deltaCapture.pendingVideoMessageIDs.isEmpty,
               let joined = PDDVideoReplyBatch.joining([state.jobs[index].capture, deltaCapture]) {
                updateQueuedCapture(at: index, capture: joined)
            } else {
                let currentCount = state.jobs[index].pendingSupplement?.customerCursor.count ?? -1
                if deltaCapture.customerCursor.count > currentCount {
                    state.jobs[index].pendingSupplement = deltaCapture
                }
            }
            state.jobs[index].supplementCapturePending = false
            if [.completed, .failed, .uncertain, .quarantined].contains(state.jobs[index].state) {
                _ = state.advanceSourceAndPromoteSupplement(at: index)
            }
            return true
        }
        return false
    }

    private func drainDeferredVideoTransferEvents() async {
        let deferred = state.deferredVideoTransferEvents.filter { event in
            state.pendingVideoBatches.contains {
                $0.uid == event.uid && $0.expectedMessageIDs.contains(event.messageID)
            }
        }
        guard !deferred.isEmpty else { return }
        let keys = Set(deferred.map { "\($0.uid)\u{0}\($0.messageID)" })
        state.deferredVideoTransferEvents.removeAll {
            keys.contains("\($0.uid)\u{0}\($0.messageID)")
        }
        for event in deferred {
            await receiveVideoTransferEvent(event)
        }
    }

    private func promoteCapturedFollowups() -> Bool {
        var changed = false
        for id in state.jobs.map(\.id) {
            guard let index = state.jobs.firstIndex(where: { $0.id == id }),
                  [.queued, .generating, .ready, .sending].contains(state.jobs[index].state),
                  let pending = state.jobs[index].pendingSupplement, pending.batch != nil else { continue }
            if state.jobs[index].state == .queued, pending.pendingVideoMessageIDs.isEmpty,
               let joined = PDDVideoReplyBatch.joining([state.jobs[index].capture, pending]) {
                updateQueuedCapture(at: index, capture: joined)
                state.jobs[index].pendingSupplement = nil
            } else {
                do {
                    if try reconcileInflightSupplementWithPromotedRevision(pending, from: index) {
                        state.jobs[index].pendingSupplement = nil
                    } else {
                        _ = state.advanceSourceAndPromoteSupplement(at: index, advanceCursor: false, retainCaptureRequests: true)
                    }
                } catch {
                    appendEvent(uid: state.jobs[index].uid, kind: "followup-generation-promotion-deferred", detail: error.localizedDescription)
                    continue
                }
            }
            changed = true
            appendEvent(uid: state.jobs[index].uid, kind: "followup-generation-admitted", detail: "source=\(id); delivery completion not required; answered cursor unchanged")
        }
        return changed
    }

    private func updateQueuedCapture(at index: Int, capture: AutoReplyCapture) {
        guard state.jobs[index].state == .queued else { return }
        state.jobs[index].capture = capture
        state.jobs[index].revision = (try? AutoReplyRevision.derived(from: capture, legacyOrdinal: state.jobs[index].customerRevision)) ?? state.jobs[index].revision
        state.jobs[index].imageAttachments = capture.imageAttachments
        state.jobs[index].videoAttachments = capture.videoAttachments
    }

    private func coalesceKnownUnsentTextDrafts() -> Bool {
        var changed = false
        for id in state.jobs.filter({ $0.state == .queued }).sorted(by: { $0.sequence < $1.sequence }).map(\.id) {
            guard let next = state.jobs.firstIndex(where: { $0.id == id }),
                  state.jobs[next].capture.batch?.incomingHandoffKey == nil else { continue }
            let older = state.jobs.indices.filter {
                state.jobs[$0].uid == state.jobs[next].uid && state.jobs[$0].sequence < state.jobs[next].sequence
                    && state.jobs[$0].state == .ready
            }
            for previous in older {
                let source = state.jobs[previous]
                guard source.replyAction == .reply, source.reply?.isEmpty == false, source.capture.batch?.incomingHandoffKey == nil,
                      source.capture.batch?.events.isEmpty == false,
                      source.capture.batch?.events.allSatisfy({ $0.kind == .text }) == true,
                      source.imageAttachments.isEmpty, source.videoAttachments.isEmpty,
                      source.outgoingImages.isEmpty, !source.sendWasInvoked, source.confirmedServiceMessageID == nil,
                      source.deliveryOutcome != .sent, source.deliveryOutcome != .uncertain,
                      !state.transferTasks.contains(where: { $0.sourceJobID == source.id }),
                      let joined = PDDVideoReplyBatch.joining([source.capture, state.jobs[next].capture]) else { continue }
                do {
                    let attempt = try PDDTextDeliveryAttemptStore(root: store.rootDirectory).load(source.id)
                    if let attempt {
                        guard attempt.uid == source.uid,
                              attempt.replySHA256 == PDDTextDeliveryAttempt.hash(source.reply ?? ""),
                              !attempt.mayHaveSent else { continue }
                    }
                } catch {
                    appendEvent(uid: source.uid, kind: "draft-replacement-deferred", detail: "delivery checkpoint unreadable; \(error.localizedDescription)")
                    continue
                }
                changed = true
                updateQueuedCapture(at: next, capture: joined)
                let cooldowns = [state.jobs[next].deliveryNotBefore, source.deliveryNotBefore, source.nextAttemptAt].compactMap { $0 }
                state.jobs[next].deliveryNotBefore = cooldowns.max()
                state.jobs[next].stageAttempt = max(state.jobs[next].stageAttempt, source.stageAttempt)
                state.jobs[previous].state = .completed
                state.jobs[previous].supersededByJobID = id
                state.jobs[previous].deliveryOutcome = .notSent
                state.jobs[previous].nextAttemptAt = nil
                state.jobs[previous].pendingSupplement = nil
                state.jobs[previous].supplementCapturePending = false
                state.jobs[previous].lastError = "未发送草稿已并入较新的完整答复；未推进已回复游标"
                appendEvent(uid: source.uid, kind: "unsent-draft-superseded", detail: "source=\(source.id) replacement=\(id); message coverage retained; sent=false")
            }
        }
        return changed
    }

    private func archiveSupersededDrafts() {
        for job in state.jobs where job.supersededByJobID != nil && job.reply != nil {
            let path = store.rootDirectory.appendingPathComponent("archive/records/\(job.id.uuidString).json")
            guard !FileManager.default.fileExists(atPath: path.path) else { continue }
            do { try transactionalStore.archiveTerminal(job) }
            catch { appendEvent(uid: job.uid, kind: "superseded-draft-archive-deferred", detail: error.localizedDescription) }
        }
    }

    private func unconfirmedDrafts(before index: Int) -> [PendingReplyDraft]? {
        let job = state.jobs[index]
        let earlier = state.jobs.filter { $0.uid == job.uid && $0.sequence < job.sequence }
        let immediatePredecessor = earlier.max { $0.sequence < $1.sequence }?.id
        let prior = earlier.filter {
            $0.reply?.isEmpty == false && ([.ready, .sending].contains($0.state)
                || ($0.id == immediatePredecessor && $0.deliveryOutcome == .uncertain)
                || $0.supersededByJobID == job.id)
        }.sorted { $0.sequence < $1.sequence }
        let head = prior.first { [.ready, .sending].contains($0.state) }
        let selected = head.map { [$0] } ?? []
        let rest = prior.filter { $0.id != head?.id }.suffix(head == nil ? 4 : 3)
        let drafts = (selected + rest).map { PendingReplyDraft(jobID: $0.id,
            messageIDs: Array($0.capture.batch?.customerMessageIDs ?? []).sorted(), text: $0.reply ?? "") }
        return drafts.isEmpty ? nil : drafts
    }

    private func isHeadOfGeneration(_ index: Int) -> Bool {
        let job = state.jobs[index]
        guard !liveGenerationJobIDs.contains(where: { id in state.jobs.contains { $0.id == id && $0.uid == job.uid } }) else { return false }
        return !state.jobs.indices.contains { other in
            guard other != index, state.jobs[other].uid == job.uid else { return false }
            let prior = state.jobs[other]
            if prior.state == .generating { return true }
            return prior.sequence < job.sequence && [.discovered, .capturing, .queued].contains(prior.state)
        }
    }

    private func activeJobIndex(uid: String) -> Int? {
        state.jobs.indices.filter {
            let job = state.jobs[$0]
            return job.uid == uid
                && [.queued, .generating, .ready, .sending].contains(job.state)
        }.min { state.jobs[$0].sequence < state.jobs[$1].sequence }
    }

    private func isHeadOfLine(_ index: Int) -> Bool {
        guard state.jobs.indices.contains(index) else { return false }
        let candidate = state.jobs[index]
        return !state.jobs.indices.contains { otherIndex in
            guard otherIndex != index else { return false }
            let other = state.jobs[otherIndex]
            return other.uid == candidate.uid
                && other.sequence < candidate.sequence
                && [.discovered, .capturing, .queued, .generating, .ready, .sending]
                    .contains(other.state)
        }
    }

    private func syncJobs() { jobs = state.jobs }

    private func persist(sendCritical: Bool = false) throws {
        state.repairOverlappingExecutions(at: now())
        if let locators = driver.conversationLocatorsSnapshot() {
            state.conversationLocatorsByUID = locators
        }
        if var receipts = driver.provisionalReceiptsSnapshot() {
            for (uid, existing) in state.provisionalReceiptsByUID {
                for prior in existing where prior.answered {
                    if let index = receipts[uid]?.firstIndex(where: {
                        $0.provisionalMessageID == prior.provisionalMessageID
                    }) {
                        receipts[uid]?[index].answered = true
                    }
                }
            }
            state.provisionalReceiptsByUID = receipts
        }
        if let selectorStates = driver.messageSourceSelectorStatesSnapshot() {
            state.messageSourceSelectorStatesByUID = selectorStates
        }
        for diagnostic in driver.takeConversationDiagnostics() {
            appendEvent(
                uid: diagnostic.uid,
                kind: diagnostic.kind,
                detail: diagnostic.detail
            )
        }
        let desired = state
        do {
            checkpointToken = try transactionalStore.commit(expected: checkpointToken) { current in
                current = desired
            }
            realDeliveryPausedForPersistence = false
        } catch {
            recordPersistenceFailure(error, sendCritical: sendCritical)
            throw error
        }
    }

    private func markProvisionalReceiptsAnswered(
        in batch: FrozenCustomerBatch,
        uid: String
    ) {
        let ids = Set(batch.events.map(\.messageID).filter {
            $0.hasPrefix("ocr-provisional-")
        })
        guard !ids.isEmpty, var receipts = state.provisionalReceiptsByUID[uid] else { return }
        for index in receipts.indices {
            if ids.contains(receipts[index].provisionalMessageID) {
                receipts[index].answered = true
            }
        }
        state.provisionalReceiptsByUID[uid] = receipts
    }

    private func enqueueTransferTaskIfNeeded(at index: Int) {
        guard state.jobs.indices.contains(index),
              state.jobs[index].replyAction == .replyThenTransfer,
              state.jobs[index].transferReason != .none,
              !state.transferTasks.contains(where: { $0.sourceJobID == state.jobs[index].id })
        else { return }
        let job = state.jobs[index]
        state.transferTasks.append(AutoReplyTransferTask(
            id: UUID(), sourceJobID: job.id, uid: job.uid, revision: job.revision,
            reason: job.transferReason, state: .pending, createdAt: now()
        ))
        appendEvent(
            uid: job.uid, kind: "transfer-task-created",
            detail: "独立转人工任务已入队；不依赖客套回复发送结果"
        )
    }

    private func recordPersistenceFailure(_ error: Error, sendCritical: Bool) {
        let checkpointConflict = (error as? AutoReplyTransactionalStoreError) == .checkpointChanged
        if sendCritical || checkpointConflict {
            realDeliveryPausedForPersistence = true
        }
        lastRuntimeIssue = "持久化失败：\(error.localizedDescription)"
    }

    private func appendEvent(uid: String?, kind: String, detail: String) {
        AutomationStepLog.record(root: store.rootDirectory, uid: uid, step: kind, detail: detail)
        state.events.append(AutoReplyEvent(
            id: UUID(), timestamp: now(), uid: uid, kind: kind, detail: detail
        ))
    }
}
