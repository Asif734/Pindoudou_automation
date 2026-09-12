import Foundation

final class ArmedPDDVideoTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private let onStart: @Sendable () -> Void
    private let operation: @Sendable () async -> Void

    init(
        onStart: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async -> Void
    ) {
        self.onStart = onStart
        self.operation = operation
    }

    func start() {
        _ = startTask()
    }

    func startAndWaitUntilDownloadFinishes() async {
        await startTask().value
    }

    private func startTask() -> Task<Void, Never> {
        lock.lock()
        if let task {
            lock.unlock()
            return task
        }
        let onStart = self.onStart
        let operation = self.operation
        let task = Task.detached(priority: .utility) {
            onStart()
            await operation()
        }
        self.task = task
        lock.unlock()
        return task
    }
}

private actor PDDVideoDownloadCompletion {
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if completed { return }
        await withCheckedContinuation { continuation in
            if completed { continuation.resume() }
            else { waiters.append(continuation) }
        }
    }

    func finish() {
        guard !completed else { return }
        completed = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
protocol PDDVideoTransferArming: AnyObject {
    func arm(
        uid: String,
        messageID: String,
        candidate: PDDCustomerVideoCandidate
    ) async throws -> ArmedPDDVideoTransfer?
    func reportFailure(uid: String, messageID: String, error: Error) async
}

extension PDDVideoTransferArming {
    func reportFailure(uid: String, messageID: String, error: Error) async {}
}

@MainActor
protocol PDDVideoPreviewOpening: AnyObject {
    func open(_ candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws
    func waitUntilOpen() async throws -> Bool
    func close() async
}

extension PDDVideoPreviewOpening {
    func waitUntilOpen() async throws -> Bool { true }
}

@MainActor
struct PDDVideoForegroundCoordinator {
    let armer: any PDDVideoTransferArming
    let opener: any PDDVideoPreviewOpening

    func begin(
        uid: String,
        candidates: [PDDCustomerVideoCandidate],
        lease: UIOperationLease
    ) async throws -> [String] {
        var pending: [String] = []
        for candidate in candidates {
            pending.append(candidate.messageID)
            do {
                try await beginOne(uid: uid, candidate: candidate, lease: lease)
            } catch {
                await armer.reportFailure(uid: uid, messageID: candidate.messageID, error: error)
            }
        }
        return pending
    }

    private func beginOne(
        uid: String,
        candidate: PDDCustomerVideoCandidate,
        lease: UIOperationLease
    ) async throws {
        try lease.validate()
        guard let armed = try await armer.arm(
            uid: uid, messageID: candidate.messageID, candidate: candidate
        ) else { return }
        var confirmed = false
        var lastOpenError: Error?
        for _ in 0..<3 {
            do {
                try lease.validate()
                try await opener.open(candidate, lease: lease)
                if try await opener.waitUntilOpen() {
                    confirmed = true
                    break
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastOpenError = error
            }
        }
        guard confirmed else {
            throw lastOpenError ?? PDDCustomerVideoError.clickFailed
        }
        await armed.startAndWaitUntilDownloadFinishes()
        do {
            try lease.validate()
        } catch {
            await opener.close()
            throw error
        }
        await opener.close()
    }
}

@MainActor
final class PDDVideoTransferArmer: PDDVideoTransferArming {
    typealias EventHandler = @Sendable (PDDVideoTransferEvent) async -> Void

    private let cefRoot: URL
    private let destinationRoot: URL
    private let watcher: PDDVideoCacheWatcher
    private let downloader: PDDUnlimitedVideoDownloadClient
    private let alternateDownloader: PDDAlternateVideoDownloadClient
    private let registry: PDDVideoTransferRegistry
    private let analysisInbox: PDDVideoAnalysisInbox
    private let stateStore: PDDDurableVideoTransferStore
    private let speechTranscriber: any PDDVideoSpeechTranscribing
    private let eventHandler: EventHandler

    init(
        cefRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.pinduoduo.merchantMac/PMDataRelease/Caches/cef"),
        destinationRoot: URL,
        watcher: PDDVideoCacheWatcher = PDDVideoCacheWatcher(),
        downloader: PDDUnlimitedVideoDownloadClient = PDDUnlimitedVideoDownloadClient(),
        alternateDownloader: PDDAlternateVideoDownloadClient = PDDAlternateVideoDownloadClient(),
        registry: PDDVideoTransferRegistry,
        analysisInbox: PDDVideoAnalysisInbox,
        stateStore: PDDDurableVideoTransferStore? = nil,
        speechTranscriber: any PDDVideoSpeechTranscribing = PDDAppleVideoSpeechTranscriber(),
        eventHandler: @escaping EventHandler
    ) {
        self.cefRoot = cefRoot
        self.destinationRoot = destinationRoot
        self.watcher = watcher
        self.downloader = downloader
        self.alternateDownloader = alternateDownloader
        self.registry = registry
        self.analysisInbox = analysisInbox
        self.stateStore = stateStore ?? PDDDurableVideoTransferStore(
            url: destinationRoot.appendingPathComponent("transfer-state.json")
        )
        self.speechTranscriber = speechTranscriber
        self.eventHandler = eventHandler
    }

    func arm(
        uid: String,
        messageID: String,
        candidate: PDDCustomerVideoCandidate
    ) async throws -> ArmedPDDVideoTransfer? {
        let key = PDDVideoTransferKey(uid: uid, messageID: messageID)
        guard !(await registry.contains(key)) else { return nil }
        let record = try await stateStore.begin(key: key, uid: uid, messageID: messageID)
        let isRecovery = record.retryIndex > 0
        switch record.phase {
        case .downloaded, .preparingEvidence, .readyForGeneration,
             .completed, .terminalFailure, .admitted:
            return nil
        case .waitingForRetry where (record.nextAttemptAt ?? .distantPast) > Date():
            return nil
        default:
            break
        }
        try await stateStore.transition(key: key, to: .opening)
        let directories = try PDDVideoCacheLocator.findCacheDataDirectories(inCEFRoot: cefRoot)
        let baselines = try PDDVideoCacheBaseline.capture(directories: directories)
        let transferDirectory = destinationRoot
            .appendingPathComponent("transfers", isDirectory: true)
            .appendingPathComponent(key.customerHash, isDirectory: true)
            .appendingPathComponent(key.messageHash, isDirectory: true)
        let partialURL = transferDirectory.appendingPathComponent("video.partial.mp4")
        let stableURL = transferDirectory.appendingPathComponent("video.mp4")
        let evidenceRoot = destinationRoot
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent(key.customerHash, isDirectory: true)
        let watcher = self.watcher
        let downloader = self.downloader
        let alternateDownloader = self.alternateDownloader
        let eventHandler = self.eventHandler
        let registry = self.registry
        let analysisInbox = self.analysisInbox
        let stateStore = self.stateStore
        let speechTranscriber = self.speechTranscriber
        let downloadCompletion = PDDVideoDownloadCompletion()
        let transferOperation: @Sendable () async -> Void = {
            await eventHandler(.init(
                uid: uid, messageID: messageID, phase: .waitingForAddress
            ))
            do {
                let sourceURL = try await withOperationDeadline(
                    .seconds(30), stage: "video-address"
                ) {
                    let preloadedWindow = PDDAXSnapshotOrder.messageOrdinal(from: messageID)
                        .map { ordinal -> ClosedRange<Date> in
                            let messageDate = Date(
                                timeIntervalSince1970: TimeInterval(ordinal) / 1_000
                            )
                            return messageDate...messageDate.addingTimeInterval(20)
                        }
                    return try await watcher.wait(
                        in: baselines, preloadedWindow: preloadedWindow
                    ) { url in
                        await registry.claimSource(url, for: key)
                    }
                }
                try Task.checkCancellation()
                try await stateStore.transition(key: key, to: .addressCaptured)
                try await stateStore.recordAttempt(key: key)
                await eventHandler(.init(uid: uid, messageID: messageID, phase: .downloading))
                try await stateStore.transition(key: key, to: .downloading)
                do {
                    _ = try await downloader.download(from: sourceURL, to: partialURL)
                } catch {
                    _ = try await alternateDownloader.download(
                        from: sourceURL, to: partialURL
                    )
                }
                try await stateStore.transition(key: key, to: .validating)
                let summary = try await PDDVideoFileInspector.inspect(partialURL)
                try FileManager.default.createDirectory(
                    at: transferDirectory, withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: stableURL.path) {
                    try? FileManager.default.removeItem(at: partialURL)
                } else {
                    try FileManager.default.moveItem(at: partialURL, to: stableURL)
                }
                let receipt = PDDDownloadedCustomerVideo(
                    uid: uid, messageID: messageID, key: key,
                    fileURL: stableURL, summary: summary
                )
                try await stateStore.transition(
                    key: key, to: .downloaded, fileName: stableURL.lastPathComponent
                )
                await eventHandler(.init(uid: uid, messageID: messageID, phase: .downloaded))
                await downloadCompletion.finish()
                guard try await analysisInbox.claim(receipt) else {
                    try? await stateStore.transition(key: key, to: .completed)
                    await eventHandler(.init(
                        uid: uid, messageID: messageID, phase: .duplicate,
                        diagnostic: "同一客户的相同视频内容已处理"
                    ))
                    return
                }
                await eventHandler(.init(
                    uid: uid, messageID: messageID, phase: .preparingEvidence
                ))
                try await stateStore.transition(key: key, to: .preparingEvidence)
                let preparer = PDDCustomerVideoEvidencePreparer(
                    rootURL: evidenceRoot,
                    transcriber: speechTranscriber
                )
                let attachment = try await withOperationDeadline(
                    .seconds(90), stage: "video-evidence"
                ) {
                    try await preparer.prepare(download: receipt)
                }
                await eventHandler(.init(
                    uid: uid, messageID: messageID, phase: .readyForGeneration,
                    attachment: attachment, recovered: isRecovery
                ))
                try await stateStore.transition(key: key, to: .readyForGeneration)
            } catch is CancellationError {
                await downloadCompletion.finish()
                return
            } catch {
                await Self.handleFailure(
                    uid: uid, messageID: messageID, key: key, error: error,
                    stateStore: stateStore, eventHandler: eventHandler
                )
                await downloadCompletion.finish()
            }
        }
        return ArmedPDDVideoTransfer(
            onStart: {
                Task {
                    let started = await registry.start(key: key, operation: transferOperation)
                    if !started { await downloadCompletion.finish() }
                }
            },
            operation: { await downloadCompletion.wait() }
        )
    }

    func reportFailure(uid: String, messageID: String, error: Error) async {
        let key = PDDVideoTransferKey(uid: uid, messageID: messageID)
        _ = try? await stateStore.begin(key: key, uid: uid, messageID: messageID)
        await Self.handleFailure(
            uid: uid, messageID: messageID, key: key, error: error,
            stateStore: stateStore, eventHandler: eventHandler
        )
    }

    private static func handleFailure(
        uid: String, messageID: String, key: PDDVideoTransferKey, error: Error,
        stateStore: PDDDurableVideoTransferStore, eventHandler: EventHandler
    ) async {
        let category: PDDVideoTransferFailureCategory = error is PDDCustomerVideoError
            ? .invalidVideo : .responseTimeout
        let record = try? await stateStore.record(key)
        if let delay = PDDVideoRetryPolicy.delay(afterFailure: record?.retryIndex ?? 0) {
            try? await stateStore.scheduleRetry(
                key: key, category: category,
                nextAttemptAt: Date().addingTimeInterval(delay)
            )
            await eventHandler(.init(
                uid: uid, messageID: messageID, phase: .waitingForRetry,
                diagnostic: "视频下载将在后台重试"
            ))
        } else {
            try? await stateStore.transition(
                key: key, to: .terminalFailure, failure: .retryBudgetExhausted
            )
            await eventHandler(.init(
                uid: uid, messageID: messageID, phase: .failed,
                diagnostic: "视频下载重试已用完"
            ))
        }
        if (try? await stateStore.markFallbackEmitted(key: key)) == true {
            await eventHandler(.init(
                uid: uid, messageID: messageID, phase: .fallbackRequired,
                diagnostic: "亲，视频暂时无法加载，麻烦您先简单描述一下需要我们查看的问题。"
            ))
        }
    }
}
