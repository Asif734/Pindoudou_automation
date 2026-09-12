import Foundation

struct AutoReplyDiscovery: Equatable, Sendable {
    let uid: String
    let hasUnreadEvidence: Bool
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
    private var backgroundLifecycleHandler: @Sendable (Int, Bool) async -> Void
    private var backgroundLifecycleRevision = 0
    private let uiLeaseRegistry = UIOperationLeaseRegistry()
    private var state: AutoReplyPersistentState
    private var checkpointToken: AutoReplyCheckpointToken?
    private var liveGenerationJobIDs: Set<UUID> = []
    private var lastDiscoveryAt = Date.distantPast
    private var pendingFastDiscoveryAttempts = 0
    private var ordinaryCaptureAuthorizations = Set<String>()
    private var ordinaryCaptureFailureCounts: [String: Int] = [:]
    private var pumping = false
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
        self.backgroundLifecycleHandler = { _, enabled in
            if !enabled { await backgroundStopHandler() }
        }
        concurrencyPolicy = AdaptiveConcurrencyPolicy(physicalMemoryBytes: physicalMemoryBytes)
        state = try store.loadRecoveringInterruptedWork(now: now())
        driver.restoreConversationLocators(state.conversationLocatorsByUID)
        driver.restoreConversationCaptureState(
            baselinedUIDs: state.axFirstBaselinedUIDs,
            knownServiceMessageIDsByUID: state.knownServiceMessageIDsByUID
        )
        driver.restoreProvisionalReceipts(state.provisionalReceiptsByUID)
        driver.restoreMessageSourceSelectorStates(state.messageSourceSelectorStatesByUID)
        var migratedBlockingState = false
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
        if migratedBlockingState { try store.save(state) }
        checkpointToken = try transactionalStore.loadCheckpoint().token
        jobs = state.jobs
    }

    func setBackgroundLifecycleHandler(
        _ handler: @escaping @Sendable (Int, Bool) async -> Void
    ) {
        backgroundLifecycleHandler = handler
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        backgroundLifecycleRevision += 1
        let revision = backgroundLifecycleRevision
        Task { await backgroundLifecycleHandler(revision, true) }
    }

    func stop() {
        isRunning = false
        backgroundLifecycleRevision += 1
        let revision = backgroundLifecycleRevision
        let operationID = activeUIOperationID
        uiLeaseRegistry.revokeAll()
        if let operationID {
            Task { [driver] in
                await driver.revokeCurrentUIOperation(operationID: operationID)
            }
        }
        Task { await backgroundLifecycleHandler(revision, false) }
    }

    func setDeliveryEnabled(_ enabled: Bool) { deliveryEnabled = enabled }

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
        latestVideoStatus = PDDVideoProgressStatus(event: event)
        onStateChange?()
        appendEvent(
            uid: event.uid,
            kind: "video-\(event.phase.rawValue)",
            detail: event.messageID
        )
        guard let index = state.pendingVideoBatches.firstIndex(where: {
            $0.uid == event.uid && $0.expectedMessageIDs.contains(event.messageID)
        }) else {
            if event.phase == .readyForGeneration, event.recovered == true,
               let attachment = event.attachment {
                admitRecoveredVideo(uid: event.uid, attachment: attachment)
                syncJobs()
                try? persist()
                return
            }
            if event.phase == .readyForGeneration || event.phase == .duplicate
                || event.phase == .failed || event.phase == .fallbackRequired {
                state.deferredVideoTransferEvents.removeAll {
                    $0.uid == event.uid && $0.messageID == event.messageID
                }
                state.deferredVideoTransferEvents.append(event)
            }
            try? persist()
            return
        }

        switch event.phase {
        case .readyForGeneration:
            guard let attachment = event.attachment,
                  state.pendingVideoBatches[index]
                    .completedAttachmentsByMessageID[event.messageID] == nil,
                  !state.pendingVideoBatches[index].failedMessageIDs.contains(event.messageID),
                  !state.pendingVideoBatches[index].duplicateMessageIDs.contains(event.messageID)
            else {
                try? persist()
                return
            }
            state.pendingVideoBatches[index]
                .completedAttachmentsByMessageID[event.messageID] = attachment
        case .failed, .fallbackRequired:
            guard state.pendingVideoBatches[index]
                .completedAttachmentsByMessageID[event.messageID] == nil,
                  !state.pendingVideoBatches[index].duplicateMessageIDs.contains(event.messageID)
            else {
                try? persist()
                return
            }
            state.pendingVideoBatches[index].failedMessageIDs.insert(event.messageID)
        case .duplicate:
            guard state.pendingVideoBatches[index]
                .completedAttachmentsByMessageID[event.messageID] == nil,
                  !state.pendingVideoBatches[index].failedMessageIDs.contains(event.messageID)
            else {
                try? persist()
                return
            }
            state.pendingVideoBatches[index].duplicateMessageIDs.insert(event.messageID)
        default:
            try? persist()
            return
        }

        let pending = state.pendingVideoBatches[index]
        let terminal = Set(pending.completedAttachmentsByMessageID.keys)
            .union(pending.failedMessageIDs)
            .union(pending.duplicateMessageIDs)
        if Set(pending.expectedMessageIDs).isSubset(of: terminal) {
            promotePendingVideoBatch(at: index)
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
            await drainDeferredVideoTransferEvents()
            _ = launchQueuedGenerations()

            if state.consecutiveDeliveryCount >= 3 {
                try await performDiscovery()
                state.consecutiveDeliveryCount = 0
                try persist()
                return
            }

            if let readyIndex = nextReadyJobIndex() {
                try await deliverJob(at: readyIndex)
                if state.jobs.indices.contains(readyIndex),
                   state.jobs[readyIndex].state == .completed,
                   state.jobs[readyIndex].deliveryOutcome != nil {
                    state.consecutiveDeliveryCount += 1
                    try persist()
                }
                return
            }

            if let transferIndex = nextPendingTransferTaskIndex() {
                try await executeTransferTask(at: transferIndex)
                return
            }

            if let request = nextSupplementCaptureRequest() {
                try await capture(request: request)
                return
            }

            if let request = nextCaptureRequest() {
                try await capture(request: request)
                return
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

    private func performDiscovery() async throws {
        lastDiscoveryAt = now()
        let discoveries = try await performUI(stage: "discover", uid: "discovery") {
            driver, lease in
            try await driver.discover(lease: lease)
        }
        if pendingFastDiscoveryAttempts > 0 { pendingFastDiscoveryAttempts -= 1 }
        let unreadUIDs = Set(discoveries.filter(\.hasUnreadEvidence).map(\.uid))
        ordinaryCaptureFailureCounts = ordinaryCaptureFailureCounts.filter {
            unreadUIDs.contains($0.key)
        }
        var changed = false
        for discovery in discoveries
        where discovery.hasUnreadEvidence {
            if scheduleSupplementCaptureIfActive(uid: discovery.uid) {
                changed = true
            } else {
                ordinaryCaptureAuthorizations.insert(discovery.uid)
                let before = state.pendingCaptureRequests.count
                enqueueCapture(discovery.uid, kind: .ordinary)
                changed = changed || state.pendingCaptureRequests.count != before
            }
        }
        if changed {
            syncJobs()
            try persist()
        }
    }

    private func nextReadyJobIndex() -> Int? {
        guard deliveryEnabled, !realDeliveryPausedForPersistence else { return nil }
        return state.jobs.indices
            .filter { state.jobs[$0].state == .ready }
            .filter { state.jobs[$0].nextAttemptAt.map { $0 <= now() } ?? true }
            .filter { isHeadOfLine($0) }
            .min { state.jobs[$0].sequence < state.jobs[$1].sequence }
    }

    private func nextPendingTransferTaskIndex() -> Int? {
        guard deliveryEnabled, !realDeliveryPausedForPersistence else { return nil }
        return state.transferTasks.indices
            .filter { state.transferTasks[$0].state == .pending }
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
        let result: AutoReplyTransferResult
        do {
            result = try await performUI(stage: "transfer", uid: task.uid) { driver, lease in
                try await driver.transferToAnyHuman(uid: task.uid, lease: lease)
            }
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
              let batch = state.jobs[index].capture.batch else { return }
        let uid = state.jobs[index].uid
        state.jobs[index].state = .sending
        state.jobs[index].durableAttemptOperationID = UUID()
        state.jobs[index].sendWasInvoked = false
        syncJobs()
        try persist(sendCritical: true)
        guard state.jobs.indices.contains(index), state.jobs[index].state == .sending else {
            return
        }
        state.jobs[index].sendWasInvoked = true
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
        do {
            result = try await performUI(stage: "send", uid: uid) { driver, lease in
                try await driver.send(
                    uid: uid,
                    text: reply,
                    expectedCustomerCursor: batch.endCursor,
                    expectedCustomerMessageIDs: Set(batch.events.map(\.messageID)),
                    lease: lease
                )
            }
        } catch {
            try finalizeUncertainSend(
                at: index,
                batch: batch,
                reason: "发送执行失败：\(error.localizedDescription)"
            )
            syncJobs()
            try persist(sendCritical: true)
            return
        }

        switch result {
        case .sent(let serviceMessageID):
            state.jobs[index].state = .completed
            state.jobs[index].deliveryOutcome = .sent
            state.jobs[index].confirmedServiceMessageID = serviceMessageID
            state.confirmedAutoReplyMessageIDsByUID[state.jobs[index].uid, default: []].insert(serviceMessageID)
            markProvisionalReceiptsAnswered(in: batch, uid: state.jobs[index].uid)
            enqueueTransferTaskIfNeeded(at: index)
            _ = state.advanceSourceAndPromoteSupplement(at: index)
            try transactionalStore.archiveTerminal(state.jobs[index])
        case .failedBeforeSend(let reason):
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
            state.jobs[index].state = .failed
            state.jobs[index].deliveryOutcome = .notSent
            state.jobs[index].lastError = "\(reason)；已丢弃当前批次并继续"
            state.jobs[index].nextAttemptAt = nil
            state.jobs[index].durableAttemptOperationID = nil
            state.jobs[index].sendWasInvoked = false
            state.answeredCursors[uid] = batch.endCursor
            _ = state.advanceSourceAndPromoteSupplement(at: index)
            try transactionalStore.archiveTerminal(state.jobs[index])
        case .uncertain(let reason):
            try finalizeUncertainSend(at: index, batch: batch, reason: reason)
        }
        syncJobs()
        try persist(sendCritical: true)
    }

    @discardableResult
    private func launchQueuedGenerations() -> Bool {
        let queued = state.jobs.indices.filter {
            state.jobs[$0].state == .queued
                && (state.jobs[$0].nextAttemptAt.map { $0 <= now() } ?? true)
                && isHeadOfLine($0)
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
            let capture = state.jobs[index].capture
            state.jobs[index].state = .generating
            liveGenerationJobIDs.insert(id)
            Task { [weak self, generator] in
                do {
                    let result = try await generator.generate(capture)
                    self?.generationFinished(jobID: id, result: .success(result))
                } catch {
                    self?.generationFinished(jobID: id, result: .failure(error))
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

    private func generationFinished(jobID: UUID, result: Result<CodexReplyResult, Error>) {
        liveGenerationJobIDs.remove(jobID)
        guard let index = state.jobs.firstIndex(where: { $0.id == jobID }),
              state.jobs[index].state == .generating else { return }
        switch result {
        case .success(let generated):
            state.jobs[index].reply = generated.reply
            state.jobs[index].replyAction = generated.action
            state.jobs[index].transferReason = generated.transferReason
            state.jobs[index].generationDiagnostic = generated.diagnostic
            state.jobs[index].state = .ready
            enqueueTransferTaskIfNeeded(at: index)
            concurrencyPolicy.recordSuccess(now: now())
        case .failure(let error):
            state.jobs[index].retries += 1
            state.jobs[index].lastError = retryPolicy.boundedDescription(error)
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
        state.jobs[index].reply = "亲亲，这边系统暂时繁忙，我帮您转接人工客服处理～"
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
            if request.kind == .ordinary {
                guard ordinaryCaptureAuthorizations.remove(request.uid) != nil else { continue }
            }
            if request.kind == .supplement || request.kind == .videoRecovery
                || !hasActiveJob(uid: request.uid) { return request }
            deferred.append(request)
        }
        state.pendingCaptureRequests.append(contentsOf: deferred)
        return nil
    }

    private func nextSupplementCaptureRequest() -> AutoReplyCaptureRequest? {
        guard let index = state.pendingCaptureRequests.firstIndex(where: {
            guard $0.kind == .supplement && ($0.tailAttempt ?? 0) == 0 else { return false }
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
        let startingCursor = request.kind == .ordinary
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
                    if let index = supplementSourceIndex(for: request) {
                        state.jobs[index].supplementCapturePending = false
                    }
                    enqueueCapture(uid, kind: .ordinary)
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
                    ordinaryCaptureAuthorizations.remove(uid)
                    appendEvent(
                        uid: uid, kind: "capture-dropped",
                        detail: "连续两次定位或采集失败；已删除本次请求并继续其他会话"
                    )
                }
            }
            throw error
        }
        if request.kind == .ordinary {
            ordinaryCaptureFailureCounts[uid] = nil
        }
        try reconcileVisibleReplies(in: rawCapture, uid: uid)
        let normalizedCapture = normalizeObservation(rawCapture, uid: uid)
        let capture: AutoReplyCapture
        if request.kind == .ordinary {
            let covered = coveredMessageIDs(uid: uid)
            guard let filtered = captureByRemovingMessages(
                normalizedCapture, messageIDs: covered
            ) else {
                latestCapture = normalizedCapture
                if normalizedCapture.customerCursor.count > startingCursor.count {
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
        if request.kind == .supplement {
            let sourceIndex = supplementSourceIndex(for: request)
            guard let index = sourceIndex else {
                enqueueCapture(uid, kind: .ordinary)
                syncJobs()
                try persist()
                return
            }
            if capture.batch != nil {
                if [.completed, .failed, .uncertain, .quarantined].contains(state.jobs[index].state),
                   try reconcileInflightSupplementWithPromotedRevision(capture, from: index) {
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
                && $0.tailAttempt == tailAttempt && $0.sourceJobID == sourceJobID
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
                existing.sha256 == attachment.sha256
            }
        }) else { return }
        let messageID = "video-analysis:\(attachment.sha256)"
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
        guard !state.jobs[index].supplementCapturePending,
              state.jobs[index].pendingSupplement == nil else { return false }
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
            state.jobs[index].state = .quarantined
            state.jobs[index].nextAttemptAt = nil
            if state.jobs[index].pendingSupplement != nil
                || state.jobs[index].supplementCapturePending {
                _ = state.advanceSourceAndPromoteSupplement(at: index)
            }
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
        state.jobs[index].nextAttemptAt = nil
        markProvisionalReceiptsAnswered(in: batch, uid: uid)
        _ = state.advanceSourceAndPromoteSupplement(at: index)
        try transactionalStore.archiveTerminal(state.jobs[index])
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
            return try await withOperationDeadline(
                deadline,
                stage: stage,
                shouldDeferTimeout: { lease.isDeadlineSuspended }
            ) {
                try lease.validate()
                let value = try await operation(self.driver, lease)
                try lease.validate()
                return value
            }
        } catch {
            uiLeaseRegistry.revoke(operationID: lease.operationID)
            await driver.revokeCurrentUIOperation(operationID: lease.operationID)
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
                ? "亲，视频暂时无法加载，麻烦您先简单描述一下需要我们查看的问题。"
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
            let currentCount = state.jobs[index].pendingSupplement?.customerCursor.count ?? -1
            if deltaCapture.customerCursor.count > currentCount {
                state.jobs[index].pendingSupplement = deltaCapture
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
        state.events.append(AutoReplyEvent(
            id: UUID(), timestamp: now(), uid: uid, kind: kind, detail: detail
        ))
    }
}
