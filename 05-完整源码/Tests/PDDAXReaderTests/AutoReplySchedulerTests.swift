import XCTest
@testable import PDDAXReader

@MainActor
final class AutoReplySchedulerTests: XCTestCase {
    func testConfirmed429CreatesCourtesyReplyAndTransferWithoutGenerationRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-codex-429-transfer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "PDD-NAME-codex-429"
        let driver = ControlledAutoReplyDriver(capturesByUID: [uid: [["你好"]]])
        driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        let generator = AlwaysFailingCodexGenerator(
            error: AutoReplyCodexGeneratorError.commandFailed(1, "HTTP 429 rate limit")
        )
        let store = AutoReplyStore(rootDirectory: root)
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: generator, store: store,
            configuredMaximumConcurrentGenerations: 1,
            availableMemoryBytes: { 64 << 30 }, uiOperationTimeout: .seconds(3)
        )
        scheduler.start()

        for _ in 0..<60 {
            await scheduler.tick()
            if try store.load().transferTasks.first?.state == .completed { break }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }

        let callCount = await generator.calls()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(driver.sentTexts, ["亲亲，这边系统暂时繁忙，我帮您转接人工客服处理～"])
        XCTAssertEqual(driver.transferredUIDs, [uid])
        XCTAssertEqual(try store.load().transferTasks.first?.state, .completed)
    }

    func testConfirmed404RetriesOneFreshTurnThenCreatesTransfer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-codex-404-transfer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "PDD-NAME-codex-404"
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 100))
        let driver = ControlledAutoReplyDriver(capturesByUID: [uid: [["你好"]]])
        driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        let generator = AlwaysFailingCodexGenerator(
            error: AutoReplyCodexGeneratorError.commandFailed(1, "HTTP 404 model not found")
        )
        let store = AutoReplyStore(rootDirectory: root)
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: generator, store: store,
            configuredMaximumConcurrentGenerations: 1,
            availableMemoryBytes: { 64 << 30 }, uiOperationTimeout: .seconds(3),
            now: { clock.value }
        )
        scheduler.start()

        for _ in 0..<80 {
            clock.value = clock.value.addingTimeInterval(2)
            await scheduler.tick()
            if try store.load().transferTasks.first?.state == .completed { break }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }

        let callCount = await generator.calls()
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(driver.sentTexts.count, 1)
        XCTAssertEqual(driver.transferredUIDs, [uid])
        XCTAssertEqual(try store.load().transferTasks.first?.state, .completed)
    }

    func testLegacyTransferPlaceholderIsNeverExecutedAfterUpgrade() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-legacy-transfer-placeholder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "PDD-NAME-legacy-transfer"
        let jobID = UUID()
        var state = AutoReplyPersistentState.empty
        let completedJob = AutoReplyJob(
            id: jobID, uid: uid, sequence: 1, state: .completed,
            capture: try makeFrozenCapture(uid: uid, ids: ["old"], after: .empty),
            reply: "旧回复", deliveryOutcome: .sent,
            confirmedServiceMessageID: "service-old", retries: 0,
            nextAttemptAt: nil, lastError: nil
        )
        state.jobs = [completedJob]
        state.transferTasks = [AutoReplyTransferTask(
            id: UUID(), sourceJobID: jobID, uid: uid, revision: completedJob.revision,
            reason: .customerExplicitlyRequestedHuman,
            state: .placeholderPending, createdAt: Date(timeIntervalSince1970: 1)
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let driver = ControlledAutoReplyDriver(capturesByUID: [:])
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: TransferReplyGenerator(), store: store
        )
        scheduler.start()

        await scheduler.tick()

        XCTAssertTrue(driver.transferredUIDs.isEmpty)
        XCTAssertEqual(try store.load().transferTasks.first?.state, .placeholderPending)
    }

    func testReplyThenTransferPersistsTransferTaskBeforeTextDeliveryRuns() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-transfer-before-delivery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "PDD-NAME-transfer-before-delivery"
        let driver = ControlledAutoReplyDriver(capturesByUID: [uid: [["我要人工客服"]]])
        driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        let store = AutoReplyStore(rootDirectory: root)
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: TransferReplyGenerator(), store: store,
            configuredMaximumConcurrentGenerations: 1,
            availableMemoryBytes: { 64 << 30 }, uiOperationTimeout: .seconds(3)
        )
        scheduler.setDeliveryEnabled(false)
        scheduler.start()

        for _ in 0..<40 {
            await scheduler.tick()
            if scheduler.jobs.contains(where: { $0.state == .ready }) { break }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }

        XCTAssertEqual(driver.sendCallCount, 0)
        XCTAssertTrue(scheduler.jobs.contains { $0.state == .ready })
        let state = try store.load()
        XCTAssertEqual(state.transferTasks.count, 1)
        let task = try XCTUnwrap(state.transferTasks.first)
        XCTAssertEqual(task.uid, uid)
        XCTAssertEqual(task.sourceJobID, scheduler.jobs[0].id)
        XCTAssertEqual(task.state, .pending)
    }

    func testReplyThenTransferAttemptsCourtesyTextOnlyOnceWhenSendFailsBeforeInvocation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-transfer-send-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "PDD-NAME-transfer-send-failure"
        let driver = ControlledAutoReplyDriver(capturesByUID: [uid: [["我要人工客服"]]])
        driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        driver.deliveryResults = [.failedBeforeSend("输入框定位失败")]
        let store = AutoReplyStore(rootDirectory: root)
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: TransferReplyGenerator(), store: store,
            configuredMaximumConcurrentGenerations: 1,
            availableMemoryBytes: { 64 << 30 }, uiOperationTimeout: .seconds(3)
        )
        scheduler.start()

        for _ in 0..<40 {
            await scheduler.tick()
            if scheduler.jobs.contains(where: { $0.state == .completed }) { break }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }

        XCTAssertEqual(driver.sendCallCount, 1)
        XCTAssertEqual(scheduler.jobs.first?.state, .completed)
        XCTAssertEqual(scheduler.jobs.first?.deliveryOutcome, .notSent)
        XCTAssertEqual(try store.load().transferTasks.count, 1)
    }

    func testReplyThenTransferKeepsTransferTaskWhenTextDeliveryIsUncertain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-transfer-uncertain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "PDD-NAME-transfer-uncertain"
        let driver = ControlledAutoReplyDriver(capturesByUID: [uid: [["我要人工客服"]]])
        driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        driver.deliveryResults = [.uncertain("气泡核对失败")]
        let store = AutoReplyStore(rootDirectory: root)
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: TransferReplyGenerator(), store: store,
            configuredMaximumConcurrentGenerations: 1,
            availableMemoryBytes: { 64 << 30 }, uiOperationTimeout: .seconds(3)
        )
        scheduler.start()

        for _ in 0..<40 {
            await scheduler.tick()
            if scheduler.jobs.contains(where: { $0.state == .completed }) { break }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }

        XCTAssertEqual(driver.sendCallCount, 1)
        XCTAssertEqual(scheduler.jobs.first?.deliveryOutcome, .uncertain)
        XCTAssertEqual(try store.load().transferTasks.count, 1)
    }

    func testReplyThenTransferSendsTextThenExecutesTransferOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-transfer-placeholder-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "PDD-NAME-transfer"
        let driver = ControlledAutoReplyDriver(capturesByUID: [uid: [["我要人工客服"]]])
        driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        let store = AutoReplyStore(rootDirectory: root)
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: TransferReplyGenerator(), store: store,
            configuredMaximumConcurrentGenerations: 1,
            availableMemoryBytes: { 64 << 30 }, uiOperationTimeout: .seconds(3)
        )
        scheduler.start()

        for _ in 0..<40 {
            await scheduler.tick()
            if scheduler.jobs.contains(where: { $0.state == .completed }) { break }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        await scheduler.tick()
        await scheduler.tick()

        XCTAssertEqual(driver.sentTexts, ["好的，我帮您转人工处理～"])
        XCTAssertEqual(driver.transferredUIDs, [uid])
        XCTAssertTrue(scheduler.jobs.allSatisfy { $0.state == .completed })
        let stateURL = root.appendingPathComponent("state.json")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        let tasks = try XCTUnwrap(object["transferTasks"] as? [[String: Any]])
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0]["uid"] as? String, uid)
        XCTAssertEqual(tasks[0]["reason"] as? String, "customer_explicitly_requested_human")
        XCTAssertEqual(tasks[0]["state"] as? String, "completed")
        XCTAssertNotNil(tasks[0]["sourceJobID"] as? String)
    }

    func testFailedTransferIsIsolatedAndDoesNotStopOtherCustomers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-transfer-isolated-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transferUID = "PDD-NAME-transfer-fails"
        let otherUID = "PDD-NAME-other"
        let driver = ControlledAutoReplyDriver(capturesByUID: [
            transferUID: [["我要人工客服"]], otherUID: [["你好"]]
        ])
        driver.discoveries = [
            .init(uid: transferUID, hasUnreadEvidence: true),
            .init(uid: otherUID, hasUnreadEvidence: true)
        ]
        driver.transferResults = [.failed("没有可用客服")]
        let store = AutoReplyStore(rootDirectory: root)
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: TransferAwareReplyGenerator(), store: store,
            configuredMaximumConcurrentGenerations: 2,
            availableMemoryBytes: { 64 << 30 }, uiOperationTimeout: .seconds(3)
        )
        scheduler.start()

        for _ in 0..<80 {
            await scheduler.tick()
            let state = try store.load()
            if state.transferTasks.first?.state == .failed,
               scheduler.jobs.filter({ $0.state == .completed }).count == 2 { break }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }

        let state = try store.load()
        XCTAssertEqual(state.transferTasks.first?.state, .failed)
        XCTAssertEqual(driver.transferredUIDs, [transferUID])
        XCTAssertTrue(scheduler.isRunning)
        XCTAssertEqual(Set(driver.sentTexts), ["好的，我帮您转人工处理～", "回复:你好"])
    }

    func testReplyNeverCreatesTransferPlaceholder() async throws {
        let uid = "PDD-NAME-reply-only"
        let fixture = try SchedulerFixture(capturesByUID: [uid: [["退款多久到账"]]])
        fixture.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]

        await fixture.runUntilCompletedJobs(1)

        XCTAssertEqual(fixture.driver.sentTexts, ["回复:退款多久到账"])
        let state = try AutoReplyStore(rootDirectory: fixture.root).load()
        XCTAssertTrue(state.transferTasks.isEmpty)
    }

    func testReadyReplyRunsBeforePendingSupplementCapture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-ready-before-supplement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let supplementUID = "PDD-supplement"
        var source = AutoReplyJob(
            id: UUID(), uid: supplementUID, sequence: 1, state: .ready,
            capture: try makeFrozenCapture(uid: supplementUID, ids: ["A"], after: .empty),
            reply: "回复:A", deliveryOutcome: nil, confirmedServiceMessageID: nil,
            retries: 0, nextAttemptAt: nil, lastError: nil,
            supplementCapturePending: true
        )
        source.supplementCapturePending = true
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 1
        state.jobs = [source]
        state.pendingCaptureRequests = [.init(
            uid: supplementUID, kind: .supplement,
            baseCursor: source.capture.customerCursor, sourceJobID: source.id
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let driver = ControlledAutoReplyDriver(capturesByUID: [supplementUID: [["C"]]])
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: ControlledReplyGenerator(delayNanoseconds: 1_000_000_000),
            store: store
        )
        scheduler.start()

        await scheduler.tick()

        XCTAssertEqual(driver.sentTexts, ["回复:A"])
        XCTAssertEqual(driver.captureCallCount, 0)
    }

    func testDeliveryUsesSenderValidationWithoutSchedulerPreflight() async throws {
        let uid = "PDD-ready"
        let f = try SchedulerFixture(capturesByUID: [uid: [["A"]]])
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]

        await f.runUntilCompletedJobs(1)

        XCTAssertEqual(f.driver.preflightCallCount, 0)
        XCTAssertEqual(f.driver.sendCallCount, 1)
    }

    func testPersistentUnreadRedDotCanCreateFreshAttemptAfterTwoCaptureFailures() async throws {
        let uid = "PDD-reappearing"
        let f = try SchedulerFixture(capturesByUID: [uid: [["A"]]])
        f.driver.captureErrorsByUID[uid] = CocoaError(.fileReadUnknown)
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        await f.runTicks(3)
        XCTAssertEqual(f.driver.captureCallCountByUID[uid], 2)

        f.driver.captureErrorsByUID[uid] = nil
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        f.scheduler.requestAXRefresh()
        await f.runTicks(4)

        XCTAssertEqual(f.driver.captureCallCountByUID[uid], 3)
        XCTAssertTrue(f.scheduler.jobs.contains { $0.uid == uid })
    }

    func testSupplementRetryDoesNotAttemptImageCaptureTwice() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-image-attempt-once-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "PDD-image"
        let source = AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .queued,
            capture: try makeFrozenCapture(uid: uid, ids: ["A"], after: .empty),
            reply: nil, deliveryOutcome: nil, confirmedServiceMessageID: nil,
            retries: 0, nextAttemptAt: nil, lastError: nil,
            supplementCapturePending: true
        )
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 1
        state.jobs = [source]
        state.pendingCaptureRequests = [.init(
            uid: uid, kind: .supplement, baseCursor: source.capture.customerCursor,
            sourceJobID: source.id
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let driver = ControlledAutoReplyDriver(capturesByUID: [uid: [["B"]]])
        driver.captureErrorsByUID[uid] = CocoaError(.fileReadUnknown)
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: ControlledReplyGenerator(delayNanoseconds: 1_000_000_000),
            store: store
        )
        scheduler.start()

        await scheduler.tick()
        driver.captureErrorsByUID[uid] = nil
        await scheduler.tick()

        XCTAssertEqual(driver.captureIncludeImages, [true, false])
        XCTAssertTrue(try store.load().jobs[0].imageCaptureAttempted)
    }

    func testCompletedVideoQueuesBehindExistingJobForSameUID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-video-head-of-line-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "PDD-one"
        let existing = AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .queued,
            capture: try makeFrozenCapture(uid: uid, ids: ["text-1"], after: .empty),
            reply: nil, deliveryOutcome: nil, confirmedServiceMessageID: nil,
            retries: 0, nextAttemptAt: nil, lastError: nil
        )
        let videoCapture = try makeVideoCapture(uid: uid, messageID: "video-1")
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 1
        state.jobs = [existing]
        state.pendingVideoBatches = [PDDPendingVideoBatch(
            uid: uid, capture: videoCapture, expectedMessageIDs: ["video-1"]
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let generator = ControlledReplyGenerator(delayNanoseconds: 1_000_000_000)
        let scheduler = try AutoReplyScheduler(
            driver: ControlledAutoReplyDriver(capturesByUID: [:]),
            generator: generator, store: store,
            configuredMaximumConcurrentGenerations: 4,
            availableMemoryBytes: { 64 << 30 }
        )
        scheduler.start()

        await scheduler.receiveVideoTransferEvent(.init(
            uid: uid, messageID: "video-1", phase: .readyForGeneration,
            attachment: videoAttachment(messageID: "video-1")
        ))
        await scheduler.tick()
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(scheduler.jobs.count, 2)
        XCTAssertEqual(generator.targetIDs, [["text-1"]])
        XCTAssertEqual(scheduler.jobs[1].state, .queued)
    }

    func testPendingVideoEvidenceDoesNotBlockNewMessageCaptureForSameUID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-video-does-not-block-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "PDD-one"
        let videoCapture = try makeVideoCapture(uid: uid, messageID: "video-1")
        var state = AutoReplyPersistentState.empty
        state.answeredCursors[uid] = videoCapture.customerCursor
        state.pendingVideoBatches = [PDDPendingVideoBatch(
            uid: uid, capture: videoCapture, expectedMessageIDs: ["video-1"]
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let driver = ControlledAutoReplyDriver(capturesByUID: [uid: [["text-2"]]])
        driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        let scheduler = try AutoReplyScheduler(
            driver: driver,
            generator: ControlledReplyGenerator(delayNanoseconds: 1_000_000_000),
            store: store
        )
        scheduler.start()

        await scheduler.tick()
        await scheduler.tick()

        XCTAssertEqual(driver.captureCallCountByUID[uid], 1)
        XCTAssertEqual(scheduler.jobs.count, 1)
        XCTAssertEqual(scheduler.jobs.first?.capture.batch?.events.map(\.messageID), ["text-2"])
        XCTAssertEqual(scheduler.pendingVideoBatchesSnapshot.count, 1)
    }

    func testOrdinaryCaptureDropsMessagesAlreadyOwnedByPendingVideoBatch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-pending-video-message-dedup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "PDD-one"
        let videoCapture = try makeVideoCapture(uid: uid, messageID: "video-1")
        var state = AutoReplyPersistentState.empty
        state.answeredCursors[uid] = videoCapture.customerCursor
        state.pendingVideoBatches = [PDDPendingVideoBatch(
            uid: uid, capture: videoCapture, expectedMessageIDs: ["video-1"]
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let driver = ControlledAutoReplyDriver(capturesByUID: [uid: [["video-1", "text-2"]]])
        driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        let scheduler = try AutoReplyScheduler(
            driver: driver,
            generator: ControlledReplyGenerator(delayNanoseconds: 1_000_000_000),
            store: store
        )
        scheduler.start()

        await scheduler.tick()
        await scheduler.tick()

        XCTAssertEqual(scheduler.jobs.count, 1)
        XCTAssertEqual(scheduler.jobs.first?.capture.batch?.events.map(\.messageID), ["text-2"])
        XCTAssertEqual(scheduler.pendingVideoBatchesSnapshot.count, 1)
        XCTAssertEqual(scheduler.pendingVideoBatchesSnapshot.first?.expectedMessageIDs, ["video-1"])
    }

    func testCompletedJobPreventsStalePendingVideoBatchFromBeingPromotedAgain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-stale-pending-video-dedup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "PDD-one"
        let messageID = "video-1"
        let capture = try makeVideoCapture(uid: uid, messageID: messageID)
        let completed = AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .completed,
            capture: capture, reply: "done", deliveryOutcome: .sent,
            confirmedServiceMessageID: "service-1", retries: 0,
            nextAttemptAt: nil, lastError: nil
        )
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 1
        state.jobs = [completed]
        state.pendingVideoBatches = [PDDPendingVideoBatch(
            uid: uid, capture: capture, expectedMessageIDs: [messageID]
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let scheduler = try AutoReplyScheduler(
            driver: ControlledAutoReplyDriver(capturesByUID: [:]),
            generator: ControlledReplyGenerator(delayNanoseconds: 0),
            store: store
        )

        await scheduler.receiveVideoTransferEvent(.init(
            uid: uid, messageID: messageID, phase: .readyForGeneration,
            attachment: videoAttachment(messageID: messageID)
        ))

        XCTAssertEqual(scheduler.jobs.count, 1)
        XCTAssertTrue(scheduler.pendingVideoBatchesSnapshot.isEmpty)
    }

    func testSupplementVideoWaitsForPreparedEvidenceBeforeEnteringQueue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-video-supplement-evidence-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "PDD-one"
        let messageID = "video-1"
        var pendingVideo = try makeVideoCapture(uid: uid, messageID: messageID)
        pendingVideo.pendingVideoMessageIDs = [messageID]
        var source = AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .completed,
            capture: try makeFrozenCapture(uid: uid, ids: ["text-1"], after: .empty),
            reply: "first", deliveryOutcome: .sent, confirmedServiceMessageID: "service-1",
            retries: 0, nextAttemptAt: nil, lastError: nil
        )
        source.pendingSupplement = pendingVideo
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 1
        state.jobs = [source]

        XCTAssertTrue(state.advanceSourceAndPromoteSupplement(at: 0))
        XCTAssertEqual(state.jobs.count, 1, "视频证据未完成前不得创建 queued 任务")
        XCTAssertEqual(state.pendingVideoBatches.map(\.expectedMessageIDs), [[messageID]])

        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let scheduler = try AutoReplyScheduler(
            driver: ControlledAutoReplyDriver(capturesByUID: [:]),
            generator: ControlledReplyGenerator(delayNanoseconds: 1_000_000_000),
            store: store
        )
        await scheduler.receiveVideoTransferEvent(.init(
            uid: uid, messageID: messageID, phase: .readyForGeneration,
            attachment: videoAttachment(messageID: messageID)
        ))

        XCTAssertEqual(scheduler.jobs.count, 2)
        XCTAssertEqual(scheduler.jobs[1].state, .queued)
        XCTAssertEqual(scheduler.jobs[1].videoAttachments.map(\.messageID), [messageID])
        XCTAssertTrue(scheduler.jobs[1].capture.pendingVideoMessageIDs.isEmpty)
    }

    func testPreparedVideoEventArrivingBeforeSupplementPromotionIsNotLost() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-video-supplement-ready-first-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "PDD-one"
        let messageID = "video-1"
        var pendingVideo = try makeVideoCapture(uid: uid, messageID: messageID)
        pendingVideo.pendingVideoMessageIDs = [messageID]
        var source = AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .ready,
            capture: try makeFrozenCapture(uid: uid, ids: ["text-1"], after: .empty),
            reply: "first", deliveryOutcome: nil, confirmedServiceMessageID: nil,
            retries: 0, nextAttemptAt: nil, lastError: nil
        )
        source.pendingSupplement = pendingVideo
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 1
        state.jobs = [source]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let scheduler = try AutoReplyScheduler(
            driver: ControlledAutoReplyDriver(capturesByUID: [:]),
            generator: ControlledReplyGenerator(delayNanoseconds: 1_000_000_000),
            store: store
        )

        await scheduler.receiveVideoTransferEvent(.init(
            uid: uid, messageID: messageID, phase: .readyForGeneration,
            attachment: videoAttachment(messageID: messageID)
        ))
        scheduler.start()
        await scheduler.tick()

        XCTAssertEqual(scheduler.jobs.count, 1, "上一条发送完成时仍不能创建空视频任务")
        XCTAssertEqual(try store.load().pendingVideoBatches.count, 1)

        await scheduler.tick()

        XCTAssertEqual(scheduler.jobs.count, 2)
        XCTAssertEqual(scheduler.jobs[1].videoAttachments.map(\.messageID), [messageID])
        XCTAssertTrue(try store.load().deferredVideoTransferEvents.isEmpty)
    }

    func testMatchingVideoMarkerSupplementDoesNotCreateThirdJob() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-video-hash-dedup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "PDD-one"
        let hash = String(repeating: "a", count: 64)
        var source = AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .ready,
            capture: try makeFrozenCapture(uid: uid, ids: ["text-1"], after: .empty),
            reply: "first", deliveryOutcome: nil, confirmedServiceMessageID: nil,
            retries: 0, nextAttemptAt: nil, lastError: nil
        )
        source.pendingSupplement = try makeVideoCapture(
            uid: uid, messageID: "video:\(hash)"
        )
        let analysisCapture = try makeVideoCapture(
            uid: uid, messageID: "video-analysis:\(hash)"
        )
        let analysis = AutoReplyJob(
            id: UUID(), uid: uid, sequence: 2, state: .ready,
            capture: analysisCapture, reply: "analysis", deliveryOutcome: nil,
            confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil,
            lastError: nil,
            videoAttachments: [videoAttachment(messageID: "video-analysis:\(hash)", sha256: hash)]
        )
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 2
        state.jobs = [source, analysis]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let driver = ControlledAutoReplyDriver(capturesByUID: [:])
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: ControlledReplyGenerator(delayNanoseconds: 0),
            store: store
        )
        scheduler.start()

        await scheduler.tick()

        XCTAssertEqual(scheduler.jobs.count, 2)
        XCTAssertEqual(scheduler.jobs[0].state, .completed)
        XCTAssertNil(scheduler.jobs[0].pendingSupplement)
        XCTAssertEqual(driver.sentTexts, ["first"])
    }

    func testVideoCompletionArrivingBeforePendingBatchIsRetainedAndPromoted() async throws {
        let uid = "PDD-one"
        let f = try SchedulerFixture(capturesByUID: [uid: [["video-1"]]])
        f.driver.pendingVideoMessageIDsByUID[uid] = ["video-1"]

        await f.scheduler.receiveVideoTransferEvent(.init(
            uid: uid, messageID: "video-1", phase: .readyForGeneration,
            attachment: videoAttachment(messageID: "video-1")
        ))
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        await f.runTicks(2)

        XCTAssertEqual(f.scheduler.jobs.count, 1)
        XCTAssertEqual(f.scheduler.jobs.first?.videoAttachments.map(\.messageID), ["video-1"])
        let saved = try AutoReplyStore(rootDirectory: f.root).load()
        XCTAssertTrue(saved.pendingVideoBatches.isEmpty)
        XCTAssertTrue(saved.deferredVideoTransferEvents.isEmpty)
    }

    func testVideoRecoveryWithoutMatchingVideoRetriesOnceThenStopsBlockingDiscovery() async throws {
        let uid = "PDD-one"
        let f = try SchedulerFixture(capturesByUID: [uid: [["video-1"], ["video-1"]]])
        f.driver.pendingVideoMessageIDsByUID[uid] = ["video-1"]
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        await f.runTicks(2)
        XCTAssertEqual(try AutoReplyStore(rootDirectory: f.root).load().pendingVideoBatches.count, 1)

        f.driver.pendingVideoMessageIDsByUID[uid] = []
        f.scheduler.requestVideoRecovery(uid: uid, messageID: "video-1")
        await f.runTicks(1)

        XCTAssertTrue(f.scheduler.jobs.isEmpty)
        let state = try AutoReplyStore(rootDirectory: f.root).load()
        XCTAssertEqual(state.pendingVideoBatches.count, 1)
        XCTAssertTrue(state.pendingCaptureRequests.contains {
            $0.kind == .videoRecovery && $0.videoMessageID == "video-1"
                && $0.tailAttempt == 1
        })

        await f.runTicks(1)
        let recovered = try AutoReplyStore(rootDirectory: f.root).load()
        XCTAssertFalse(recovered.pendingCaptureRequests.contains {
            $0.kind == .videoRecovery && $0.videoMessageID == "video-1"
        })
        XCTAssertTrue(recovered.pendingVideoBatches.isEmpty)
        XCTAssertEqual(recovered.jobs.count, 1)

        let discoveryCount = f.driver.discoverCallCount
        f.scheduler.requestAXRefresh()
        await f.runTicks(4)
        XCTAssertGreaterThan(f.driver.discoverCallCount, discoveryCount)
    }

    func testVideoRecoveryCaptureTargetsOnlyRequestedVideoMessage() async throws {
        let uid = "PDD-one"
        let f = try SchedulerFixture(capturesByUID: [uid: [["video-1", "video-2"]]])
        f.driver.pendingVideoMessageIDsByUID[uid] = ["video-1", "video-2"]
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        await f.runTicks(2)

        f.scheduler.requestVideoRecovery(uid: uid, messageID: "video-2")
        await f.runTicks(1)

        XCTAssertEqual(f.driver.videoRecoveryTargets, ["video-2"])
    }

    func testTextAndVideoCaptureWaitsForEvidenceBeforeCreatingCodexJob() async throws {
        let uid = "PDD-one"
        let f = try SchedulerFixture(capturesByUID: [uid: [["text-1", "video-1"]]])
        f.driver.pendingVideoMessageIDsByUID[uid] = ["video-1"]
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]

        await f.runTicks(2)

        XCTAssertTrue(f.scheduler.jobs.isEmpty)
        XCTAssertEqual(try AutoReplyStore(rootDirectory: f.root).load().pendingVideoBatches.count, 1)

        await f.scheduler.receiveVideoTransferEvent(.init(
            uid: uid,
            messageID: "video-1",
            phase: .readyForGeneration,
            attachment: videoAttachment(messageID: "video-1")
        ))

        XCTAssertEqual(f.scheduler.jobs.count, 1)
        XCTAssertEqual(f.scheduler.jobs.first?.videoAttachments.map(\.messageID), ["video-1"])
    }

    func testTwoVideosPromoteOnceInOriginalOrderAndIgnoreDuplicateCompletion() async throws {
        let uid = "PDD-one"
        let f = try SchedulerFixture(capturesByUID: [uid: [["video-1", "video-2"]]])
        f.driver.pendingVideoMessageIDsByUID[uid] = ["video-1", "video-2"]
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        await f.runTicks(2)

        await f.scheduler.receiveVideoTransferEvent(.init(
            uid: uid, messageID: "video-2", phase: .readyForGeneration,
            attachment: videoAttachment(messageID: "video-2")
        ))
        XCTAssertTrue(f.scheduler.jobs.isEmpty)

        let first = PDDVideoTransferEvent(
            uid: uid, messageID: "video-1", phase: .readyForGeneration,
            attachment: videoAttachment(messageID: "video-1")
        )
        await f.scheduler.receiveVideoTransferEvent(first)
        await f.scheduler.receiveVideoTransferEvent(first)

        XCTAssertEqual(f.scheduler.jobs.count, 1)
        XCTAssertEqual(
            f.scheduler.jobs.first?.videoAttachments.map(\.messageID),
            ["video-1", "video-2"]
        )
    }

    func testContentDuplicateVideoCompletesPendingBatchWithoutCreatingReplyJob() async throws {
        let uid = "PDD-one"
        let f = try SchedulerFixture(capturesByUID: [uid: [["video-duplicate"]]])
        f.driver.pendingVideoMessageIDsByUID[uid] = ["video-duplicate"]
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        await f.runTicks(2)

        await f.scheduler.receiveVideoTransferEvent(.init(
            uid: uid, messageID: "video-duplicate", phase: .duplicate
        ))

        XCTAssertTrue(f.scheduler.jobs.isEmpty)
        let state = try AutoReplyStore(rootDirectory: f.root).load()
        XCTAssertTrue(state.pendingVideoBatches.isEmpty)
        XCTAssertEqual(state.answeredCursors[uid]?.count, 1)
    }

    func testContentDuplicateVideoDoesNotSuppressNewTextInSameBatch() async throws {
        let uid = "PDD-one"
        let f = try SchedulerFixture(capturesByUID: [uid: [["text-1", "video-duplicate"]]])
        f.driver.pendingVideoMessageIDsByUID[uid] = ["video-duplicate"]
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        await f.runTicks(2)

        await f.scheduler.receiveVideoTransferEvent(.init(
            uid: uid, messageID: "video-duplicate", phase: .duplicate
        ))

        XCTAssertEqual(f.scheduler.jobs.count, 1)
        XCTAssertEqual(f.scheduler.jobs[0].capture.batch?.events.map(\.messageID), ["text-1"])
        XCTAssertTrue(f.scheduler.jobs[0].videoAttachments.isEmpty)
    }

    func testVideoImmediateFailureCreatesOneFixedReadyReplyAndReleasesBatch() async throws {
        let uid = "PDD-video-fallback"
        let f = try SchedulerFixture(capturesByUID: [uid: [["video-1"]]])
        f.driver.pendingVideoMessageIDsByUID[uid] = ["video-1"]
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        await f.runTicks(2)
        let event = PDDVideoTransferEvent(
            uid: uid, messageID: "video-1", phase: .fallbackRequired,
            diagnostic: "亲，视频暂时无法加载，麻烦您先简单描述一下需要我们查看的问题。"
        )

        await f.scheduler.receiveVideoTransferEvent(event)
        await f.scheduler.receiveVideoTransferEvent(event)

        XCTAssertTrue(f.scheduler.pendingVideoBatchesSnapshot.isEmpty)
        XCTAssertEqual(f.scheduler.jobs.count, 1)
        XCTAssertEqual(f.scheduler.jobs[0].state, .ready)
        XCTAssertEqual(
            f.scheduler.jobs[0].reply,
            "亲，视频暂时无法加载，麻烦您先简单描述一下需要我们查看的问题。"
        )
    }

    func testLaterRecoveredVideoCreatesIndependentAnalysisJobExactlyOnce() async throws {
        let uid = "PDD-video-recovered"
        let f = try SchedulerFixture(capturesByUID: [uid: [["video-1"]]])
        f.driver.pendingVideoMessageIDsByUID[uid] = ["video-1"]
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        await f.runTicks(2)
        await f.scheduler.receiveVideoTransferEvent(.init(
            uid: uid, messageID: "video-1", phase: .fallbackRequired
        ))
        let recovered = PDDVideoTransferEvent(
            uid: uid, messageID: "video-1", phase: .readyForGeneration,
            attachment: videoAttachment(messageID: "video-1"), recovered: true
        )

        await f.scheduler.receiveVideoTransferEvent(recovered)
        await f.scheduler.receiveVideoTransferEvent(recovered)

        XCTAssertEqual(f.scheduler.jobs.count, 2)
        XCTAssertEqual(f.scheduler.jobs[1].state, .queued)
        XCTAssertEqual(f.scheduler.jobs[1].videoAttachments.map(\.messageID), ["video-1"])
    }

    func testExhaustedGenerationFailureParksOnlyThatRevisionWithoutSilencingOtherUID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-generation-failure-continuity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = ControlledAutoReplyDriver(capturesByUID: [
            "GZC-000001": [["A"]],
            "GZC-000002": [["B"]]
        ])
        driver.discoveries = [
            .init(uid: "GZC-000001", hasUnreadEvidence: true),
            .init(uid: "GZC-000002", hasUnreadEvidence: true)
        ]
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 100))
        let scheduler = try AutoReplyScheduler(
            driver: driver,
            generator: SelectivelyFailingReplyGenerator(failingUID: "GZC-000001"),
            store: AutoReplyStore(rootDirectory: root),
            configuredMaximumConcurrentGenerations: 2,
            availableMemoryBytes: { 64 << 30 },
            now: { clock.value }
        )
        scheduler.start()

        for _ in 0..<180 {
            await scheduler.tick()
            clock.value = clock.value.addingTimeInterval(61)
            if scheduler.jobs.contains(where: { $0.uid == "GZC-000001" && $0.state == .quarantined }),
               scheduler.jobs.contains(where: { $0.uid == "GZC-000002" && $0.state == .completed }) {
                break
            }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }

        XCTAssertEqual(scheduler.answeredCursor("GZC-000001").count, 0)
        XCTAssertEqual(scheduler.answeredCursor("GZC-000002").count, 1)
        XCTAssertEqual(driver.sentTexts, ["回复:B"])
    }

    func testDiscoveryErrorPublishesHealthWarningButKeepsRunningAndLaterRecovers() async throws {
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 100))
        let f = try SchedulerFixture(capturesByUID: [:], now: { clock.value })
        f.driver.discoverError = FixtureSchedulerError.discovery

        await f.scheduler.tick()

        XCTAssertTrue(f.scheduler.isRunning)
        XCTAssertTrue(f.scheduler.lastRuntimeIssue?.contains("fixture discovery failed") == true)
        XCTAssertNotNil(f.scheduler.latestResourceSnapshot)

        f.driver.discoverError = nil
        clock.value = Date(timeIntervalSince1970: 102)
        await f.scheduler.tick()

        XCTAssertTrue(f.scheduler.isRunning)
        XCTAssertNil(f.scheduler.lastRuntimeIssue)
    }

    func testExternalStateModificationIsNotSilentlyOverwrittenByCapture() async throws {
        let uid = "GZC-000001"
        let f = try SchedulerFixture(capturesByUID: [uid: [["A"]]])
        var external = try AutoReplyStore(rootDirectory: f.root).load()
        external.nextSequence = 99
        try AutoReplyStore(rootDirectory: f.root).save(external)
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]

        await f.runTicks(5)

        XCTAssertEqual(try AutoReplyStore(rootDirectory: f.root).load().nextSequence, 99)
        XCTAssertTrue(f.scheduler.realDeliveryPausedForPersistence)
        XCTAssertFalse(f.scheduler.isRunning)
        XCTAssertEqual(f.driver.discoverCallCount, 0)
        XCTAssertEqual(f.driver.captureCallCount, 0)
    }

    func testDeletedStateFileStopsBeforeDiscoveryTouchesUI() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-state-deleted-before-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(.empty)
        let driver = ControlledAutoReplyDriver(capturesByUID: [:])
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: ControlledReplyGenerator(delayNanoseconds: 0),
            store: store
        )
        scheduler.start()
        try FileManager.default.removeItem(at: root.appendingPathComponent("state.json"))

        await scheduler.tick()

        XCTAssertFalse(scheduler.isRunning)
        XCTAssertTrue(scheduler.realDeliveryPausedForPersistence)
        XCTAssertEqual(driver.discoverCallCount, 0)
    }
    func testCurrentConversationWithoutUnreadEvidenceCannotCreateCaptureWork() async throws {
        let f = try SchedulerFixture(capturesByUID: ["GZC-000001": [[]]])
        f.driver.baselineCustomerCountByUID["GZC-000001"] = 3
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: false)]

        await f.runTicks(5)

        XCTAssertEqual(f.scheduler.answeredCursor("GZC-000001"), .empty)
        XCTAssertEqual(f.driver.captureCallCount, 0)
        XCTAssertNil(f.scheduler.latestCapture)
    }

    func testCurrentConversationWithoutUnreadDoesNotRunOCRAgainBeforeTenSecondFallback() async throws {
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 100))
        let f = try SchedulerFixture(
            capturesByUID: ["GZC-000001": [[], []]],
            now: { clock.value }
        )
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: false)]
        await f.runTicks(2)

        clock.value = Date(timeIntervalSince1970: 102)
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: false)]
        await f.runTicks(2)

        XCTAssertEqual(f.driver.captureCallCount, 0)
    }

    func testTenSecondPollingCannotBypassUnreadRedDotGate() async throws {
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 100))
        let f = try SchedulerFixture(
            capturesByUID: ["GZC-000001": [[], []]],
            now: { clock.value }
        )
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: false)]
        await f.runTicks(2)

        clock.value = Date(timeIntervalSince1970: 110)
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: false)]
        await f.runTicks(2)

        XCTAssertEqual(f.driver.captureCallCount, 0)
    }

    func testUnreadRedDotIsTheOnlyCaptureAuthorization() async throws {
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 100))
        let f = try SchedulerFixture(
            capturesByUID: ["GZC-000001": [[], []]],
            now: { clock.value }
        )
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: false)]
        await f.runTicks(2)

        clock.value = Date(timeIntervalSince1970: 101)
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: true)]
        await f.runTicks(2)

        XCTAssertEqual(f.driver.captureCallCount, 1)
    }

    func testUnreadRedDotDuringActiveGenerationCapturesSupplementImmediately() async throws {
        let uid = "GZC-000001"
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 100))
        let f = try SchedulerFixture(
            capturesByUID: [uid: [["A"], ["B"]]],
            generationDelayNanoseconds: 1_000_000_000,
            now: { clock.value }
        )
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        await f.runTicks(3)
        XCTAssertEqual(f.scheduler.jobs.first?.state, .generating)

        clock.value = Date(timeIntervalSince1970: 102)
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        await f.runTicks(4)

        XCTAssertEqual(f.driver.captureCallCount, 2)
        XCTAssertEqual(
            f.scheduler.latestCapture?.batch?.events.map(\.messageID),
            ["B"]
        )
        XCTAssertEqual(
            f.scheduler.jobs.first?.pendingSupplement?.batch?.events.map(\.messageID),
            ["B"],
            "红点消失后，补充批次仍必须持久附着在原冻结任务上"
        )
        XCTAssertEqual(f.scheduler.jobs.count, 1, "补充消息应先附着到冻结任务，不能抢在 A 前发送")
    }

    func testCapturedSupplementIsPromotedAfterFrozenReplyCompletes() async throws {
        let uid = "GZC-000001"
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 100))
        let f = try SchedulerFixture(
            capturesByUID: [uid: [["A"], ["B"]]],
            generationDelayNanoseconds: 80_000_000,
            now: { clock.value }
        )
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        await f.runTicks(3)
        XCTAssertEqual(f.scheduler.jobs.first?.state, .generating)

        clock.value = Date(timeIntervalSince1970: 102)
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        await f.runTicks(4)
        XCTAssertEqual(
            f.scheduler.jobs.first?.pendingSupplement?.batch?.events.map(\.messageID),
            ["B"]
        )

        await f.runUntilCompletedJobs(2)

        XCTAssertEqual(f.generator.targetIDs, [["A"], ["B"]])
        XCTAssertEqual(f.driver.sentTexts, ["回复:A", "回复:B"])
        XCTAssertEqual(f.scheduler.jobs.map(\.state), [.completed, .completed])
    }

    func testCapturedSupplementSurvivesWhenFrozenGenerationIsExhausted() async throws {
        let uid = "GZC-000001"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-supplement-after-generation-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 100))
        let driver = ControlledAutoReplyDriver(capturesByUID: [uid: [["A"], ["B"]]])
        driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        let scheduler = try AutoReplyScheduler(
            driver: driver,
            generator: SelectivelyFailingReplyGenerator(failingUID: uid),
            store: AutoReplyStore(rootDirectory: root),
            configuredMaximumConcurrentGenerations: 1,
            availableMemoryBytes: { 64 << 30 },
            now: { clock.value }
        )
        scheduler.start()

        for _ in 0..<20 where (scheduler.jobs.first?.retries ?? 0) == 0 {
            await scheduler.tick()
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        clock.value = Date(timeIntervalSince1970: 102)
        driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        for _ in 0..<20 where scheduler.jobs.first?.pendingSupplement == nil {
            await scheduler.tick()
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        XCTAssertEqual(
            scheduler.jobs.first?.pendingSupplement?.batch?.events.map(\.messageID),
            ["B"]
        )

        for _ in 0..<30 {
            clock.value = clock.value.addingTimeInterval(61)
            await scheduler.tick()
            try? await Task.sleep(nanoseconds: 3_000_000)
            if scheduler.jobs.first?.state == .quarantined { break }
        }

        XCTAssertEqual(scheduler.jobs.first?.state, .quarantined)
        XCTAssertEqual(scheduler.jobs.count, 2)
        let promoted = try XCTUnwrap(scheduler.jobs.dropFirst().first)
        XCTAssertEqual(promoted.capture.batch?.events.map(\.messageID), ["B"])
    }

    func testRestartPromotesSupplementAttachedToLegacyQuarantine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-restart-supplement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "GZC-000001"
        var source = AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .quarantined,
            capture: try makeFrozenCapture(uid: uid, ids: ["A"], after: .empty),
            reply: nil, deliveryOutcome: .notSent, confirmedServiceMessageID: nil,
            retries: 3, nextAttemptAt: nil, lastError: "旧失败"
        )
        source.pendingSupplement = try makeFrozenCapture(
            uid: uid, ids: ["B"], after: source.capture.customerCursor
        )
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 1
        state.jobs = [source]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)

        let scheduler = try AutoReplyScheduler(
            driver: ControlledAutoReplyDriver(capturesByUID: [:]),
            generator: ControlledReplyGenerator(delayNanoseconds: 0),
            store: store
        )

        XCTAssertEqual(scheduler.jobs.map(\.state), [.failed, .queued])
        XCTAssertEqual(scheduler.jobs[1].capture.batch?.events.map(\.messageID), ["B"])
    }

    func testTerminalSourceBoundSupplementRequestStillPromotesAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-source-bound-supplement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "GZC-000001"
        let source = AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .quarantined,
            capture: try makeFrozenCapture(uid: uid, ids: ["A"], after: .empty),
            reply: nil, deliveryOutcome: .notSent, confirmedServiceMessageID: nil,
            retries: 3, nextAttemptAt: nil, lastError: "生成失败",
            supplementCapturePending: true
        )
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 1
        state.jobs = [source]
        state.pendingCaptureRequests = [AutoReplyCaptureRequest(
            uid: uid, kind: .supplement, baseCursor: source.capture.customerCursor,
            sourceJobID: source.id
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let driver = ControlledAutoReplyDriver(capturesByUID: [uid: [["B"]]])
        let scheduler = try AutoReplyScheduler(
            driver: driver,
            generator: ControlledReplyGenerator(delayNanoseconds: 1_000_000_000),
            store: store
        )
        scheduler.start()

        await scheduler.tick()

        XCTAssertEqual(scheduler.jobs.map(\.state), [.failed, .queued])
        XCTAssertEqual(scheduler.jobs[1].capture.batch?.events.map(\.messageID), ["B"])
    }

    func testRepeatedUnreadDotDoesNotRecaptureOrEraseDurableSupplement() async throws {
        let uid = "GZC-000001"
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 100))
        let f = try SchedulerFixture(
            capturesByUID: [uid: [["A"], ["B"], []]],
            generationDelayNanoseconds: 1_000_000_000,
            now: { clock.value }
        )
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        await f.runTicks(3)
        clock.value = Date(timeIntervalSince1970: 102)
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        await f.runTicks(4)
        clock.value = Date(timeIntervalSince1970: 104)
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        await f.runTicks(4)

        XCTAssertEqual(f.driver.captureCallCount, 2)
        XCTAssertEqual(
            f.scheduler.jobs.first?.pendingSupplement?.batch?.events.map(\.messageID), ["B"]
        )
    }

    func testReadyReplyPromotesDurableSupplementWithoutRecapturingIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-empty-duplicate-supplement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "GZC-000001"
        var source = AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .ready,
            capture: try makeFrozenCapture(uid: uid, ids: ["A"], after: .empty),
            reply: "回复:A", deliveryOutcome: nil, confirmedServiceMessageID: nil,
            retries: 0, nextAttemptAt: nil, lastError: nil,
            supplementCapturePending: true
        )
        source.pendingSupplement = try makeFrozenCapture(
            uid: uid, ids: ["B"], after: source.capture.customerCursor
        )
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 1
        state.jobs = [source]
        state.pendingCaptureRequests = [AutoReplyCaptureRequest(
            uid: uid, kind: .supplement, baseCursor: source.capture.customerCursor,
            sourceJobID: source.id
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let scheduler = try AutoReplyScheduler(
            driver: ControlledAutoReplyDriver(capturesByUID: [uid: [[]]]),
            generator: ControlledReplyGenerator(delayNanoseconds: 0), store: store
        )
        scheduler.start()

        await scheduler.tick()

        XCTAssertEqual(scheduler.jobs.count, 2)
        XCTAssertEqual(scheduler.jobs[0].state, .completed)
        XCTAssertEqual(scheduler.jobs[1].capture.batch?.events.map(\.messageID), ["B"])
    }

    func testObsoleteSchedulerPreflightErrorCannotBlockReadyReplyOrSupplement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-preflight-supplement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "GZC-000001"
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 100))
        var source = AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .ready,
            capture: try makeFrozenCapture(uid: uid, ids: ["A"], after: .empty),
            reply: "回复:A", deliveryOutcome: nil, confirmedServiceMessageID: nil,
            retries: 0, nextAttemptAt: nil, lastError: nil
        )
        source.pendingSupplement = try makeFrozenCapture(
            uid: uid, ids: ["B"], after: source.capture.customerCursor
        )
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 1
        state.jobs = [source]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let driver = ControlledAutoReplyDriver(capturesByUID: [:])
        driver.preflightError = CocoaError(.fileReadUnknown)
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: ControlledReplyGenerator(delayNanoseconds: 1_000_000_000),
            store: store, now: { clock.value }
        )
        scheduler.start()

        await scheduler.tick()
        clock.value = Date(timeIntervalSince1970: 102)
        await scheduler.tick()

        XCTAssertEqual(scheduler.jobs[0].state, .completed)
        XCTAssertEqual(scheduler.jobs[1].capture.batch?.events.map(\.messageID), ["B"])
        XCTAssertEqual(scheduler.answeredCursor(uid).count, 1)
    }

    func testSupplementCaptureErrorGetsOnlyOneImmediatePriorityAndCannotStarveReadyJobs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-supplement-error-fairness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstUID = "GZC-000001"
        let otherUID = "GZC-000002"
        var first = AutoReplyJob(
            id: UUID(), uid: firstUID, sequence: 1, state: .ready,
            capture: try makeFrozenCapture(uid: firstUID, ids: ["A"], after: .empty),
            reply: "回复:A", deliveryOutcome: nil, confirmedServiceMessageID: nil,
            retries: 0, nextAttemptAt: nil, lastError: nil, supplementCapturePending: true
        )
        first.supplementCapturePending = true
        let other = AutoReplyJob(
            id: UUID(), uid: otherUID, sequence: 2, state: .ready,
            capture: try makeFrozenCapture(uid: otherUID, ids: ["X"], after: .empty),
            reply: "回复:X", deliveryOutcome: nil, confirmedServiceMessageID: nil,
            retries: 0, nextAttemptAt: nil, lastError: nil
        )
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 2
        state.jobs = [first, other]
        state.pendingCaptureRequests = [AutoReplyCaptureRequest(
            uid: firstUID, kind: .supplement, baseCursor: first.capture.customerCursor,
            sourceJobID: first.id
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let driver = ControlledAutoReplyDriver(capturesByUID: [:])
        driver.captureErrorsByUID[firstUID] = CocoaError(.fileReadUnknown)
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: ControlledReplyGenerator(delayNanoseconds: 0), store: store
        )
        scheduler.start()

        await scheduler.tick()
        await scheduler.tick()
        await scheduler.tick()
        await scheduler.tick()

        XCTAssertEqual(driver.sendCallCount, 2)
        XCTAssertEqual(scheduler.jobs.prefix(2).map(\.state), [.completed, .completed])
    }

    func testOrdinaryCaptureFailureMovesToTailOnceThenDropsWithoutStarvingOtherUID() async throws {
        let firstUID = "GZC-000001"
        let otherUID = "GZC-000002"
        let f = try SchedulerFixture(capturesByUID: [otherUID: [["B"]]])
        f.driver.captureErrorsByUID[firstUID] = CocoaError(.fileReadUnknown)
        f.driver.discoveries = [
            .init(uid: firstUID, hasUnreadEvidence: true),
            .init(uid: otherUID, hasUnreadEvidence: true)
        ]

        await f.runTicks(8)

        XCTAssertEqual(f.driver.captureCallCountByUID[firstUID], 2)
        XCTAssertEqual(f.driver.captureCallCountByUID[otherUID], 1)
        XCTAssertTrue(f.scheduler.jobs.contains {
            $0.uid == otherUID && $0.capture.batch?.events.map(\.messageID) == ["B"]
        })
        XCTAssertTrue(try AutoReplyStore(rootDirectory: f.root).load().pendingCaptureRequests.isEmpty)
    }

    func testRestartPromotionDeletesLegacyDuplicateSupplementRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-restart-duplicate-request-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "GZC-000001"
        var source = AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .quarantined,
            capture: try makeFrozenCapture(uid: uid, ids: ["A"], after: .empty),
            reply: nil, deliveryOutcome: .notSent, confirmedServiceMessageID: nil,
            retries: 3, nextAttemptAt: nil, lastError: "旧失败", supplementCapturePending: true
        )
        source.pendingSupplement = try makeFrozenCapture(
            uid: uid, ids: ["B"], after: source.capture.customerCursor
        )
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 1
        state.jobs = [source]
        state.pendingCaptureRequests = [AutoReplyCaptureRequest(
            uid: uid, kind: .supplement, baseCursor: source.capture.customerCursor,
            sourceJobID: source.id
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let driver = ControlledAutoReplyDriver(capturesByUID: [uid: [["B"]]])
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: ControlledReplyGenerator(delayNanoseconds: 1_000_000_000),
            store: store
        )
        scheduler.start()

        await scheduler.tick()

        XCTAssertEqual(scheduler.jobs.count, 2)
        XCTAssertEqual(driver.captureCallCount, 0)
    }

    func testInflightDuplicateSupplementCannotPromoteBAgainAfterReconciliationPromotesIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-inflight-duplicate-supplement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "GZC-000001"
        var source = AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .ready,
            capture: try makeFrozenCapture(uid: uid, ids: ["previous-0"], after: .empty),
            reply: "回复:A", deliveryOutcome: nil, confirmedServiceMessageID: nil,
            retries: 0, nextAttemptAt: nil, lastError: nil, supplementCapturePending: true
        )
        source.pendingSupplement = try makeFrozenCapture(
            uid: uid, ids: ["B"], after: source.capture.customerCursor
        )
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 1
        state.jobs = [source]
        state.pendingCaptureRequests = [AutoReplyCaptureRequest(
            uid: uid, kind: .supplement, baseCursor: source.capture.customerCursor,
            sourceJobID: source.id
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let driver = ControlledAutoReplyDriver(capturesByUID: [uid: [["B"]]])
        driver.serviceMessageIDsByUID[uid] = ["service-a"]
        driver.serviceMessageContentsByID["service-a"] = "回复:A"
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: ControlledReplyGenerator(delayNanoseconds: 1_000_000_000),
            store: store
        )
        scheduler.start()

        await scheduler.tick()

        XCTAssertEqual(scheduler.jobs.count, 2)
        XCTAssertEqual(scheduler.jobs[0].state, .completed)
        XCTAssertEqual(scheduler.jobs[1].capture.batch?.events.map(\.messageID), ["B"])
    }

    func testReadyReplyPromotesFrozenSupplementBeforeObsoleteCaptureRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-inflight-supplement-superset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "GZC-000001"
        var source = AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .ready,
            capture: try makeFrozenCapture(uid: uid, ids: ["previous-0"], after: .empty),
            reply: "回复:A", deliveryOutcome: nil, confirmedServiceMessageID: nil,
            retries: 0, nextAttemptAt: nil, lastError: nil, supplementCapturePending: true
        )
        source.pendingSupplement = try makeFrozenCapture(
            uid: uid, ids: ["B"], after: source.capture.customerCursor
        )
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 1
        state.jobs = [source]
        state.pendingCaptureRequests = [AutoReplyCaptureRequest(
            uid: uid, kind: .supplement, baseCursor: source.capture.customerCursor,
            sourceJobID: source.id
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let driver = ControlledAutoReplyDriver(capturesByUID: [uid: [["B", "C"]]])
        driver.serviceMessageIDsByUID[uid] = ["service-a"]
        driver.serviceMessageContentsByID["service-a"] = "回复:A"
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: ControlledReplyGenerator(delayNanoseconds: 1_000_000_000),
            store: store
        )
        scheduler.start()

        await scheduler.tick()
        await scheduler.tick()

        XCTAssertEqual(scheduler.jobs.count, 2)
        XCTAssertEqual(scheduler.jobs[1].capture.batch?.events.map(\.messageID), ["B"])
        XCTAssertNil(scheduler.jobs[1].pendingSupplement)
        XCTAssertEqual(driver.captureCallCount, 0)
    }

    func testLegacyNilSourceSupplementResolvesByFrozenBaseCursorNotCurrentActiveJob() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-legacy-source-resolution-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "GZC-000001"
        let source = AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .failed,
            capture: try makeFrozenCapture(uid: uid, ids: ["A"], after: .empty),
            reply: nil, deliveryOutcome: .notSent, confirmedServiceMessageID: nil,
            retries: 3, nextAttemptAt: nil, lastError: "旧失败", supplementCapturePending: true
        )
        let active = AutoReplyJob(
            id: UUID(), uid: uid, sequence: 2, state: .ready,
            capture: try makeFrozenCapture(uid: uid, ids: ["B"], after: source.capture.customerCursor),
            reply: "回复:B", deliveryOutcome: nil, confirmedServiceMessageID: nil,
            retries: 0, nextAttemptAt: nil, lastError: nil
        )
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 2
        state.jobs = [source, active]
        state.pendingCaptureRequests = [AutoReplyCaptureRequest(
            uid: uid, kind: .supplement, baseCursor: source.capture.customerCursor
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let driver = ControlledAutoReplyDriver(capturesByUID: [uid: [["C"]]])
        let scheduler = try AutoReplyScheduler(
            driver: driver, generator: ControlledReplyGenerator(delayNanoseconds: 1_000_000_000),
            store: store
        )
        scheduler.start()

        await scheduler.tick()
        await scheduler.tick()

        XCTAssertEqual(scheduler.jobs.count, 3)
        XCTAssertNil(scheduler.jobs[1].pendingSupplement)
        if scheduler.jobs.count == 3 {
            XCTAssertEqual(scheduler.jobs[2].capture.batch?.events.map(\.messageID), ["C"])
        }
    }

    func testAXNotificationCannotBypassUnreadRedDotGate() async throws {
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 100))
        let f = try SchedulerFixture(
            capturesByUID: ["GZC-000001": [[], [], []]],
            now: { clock.value }
        )
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: false)]
        await f.runTicks(2)

        clock.value = Date(timeIntervalSince1970: 101)
        f.scheduler.requestAXRefresh()
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: false)]
        await f.runTicks(2)

        clock.value = Date(timeIntervalSince1970: 101.21)
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: false)]
        await f.runTicks(2)

        XCTAssertEqual(f.driver.captureCallCount, 0)
    }

    func testCaptureNormalizationPreservesOCRDiagnostic() async throws {
        let f = try SchedulerFixture(capturesByUID: ["GZC-000001": [[]]])
        f.driver.ocrDiagnosticByUID["GZC-000001"] = "OCR 已读取 2 条可见气泡"
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: true)]

        await f.runTicks(5)

        XCTAssertEqual(f.scheduler.latestCapture?.ocrDiagnostic, "OCR 已读取 2 条可见气泡")
    }

    func testCompletedReplyDoesNotProbeOrCreateTailWithoutNewUnreadDot() async throws {
        let f = try SchedulerFixture(capturesByUID: ["GZC-000001": [["A"], ["B", "C"], []]])
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: true)]
        f.driver.deliveryResults = [.sent(serviceMessageID: "s1"), .sent(serviceMessageID: "s2")]

        await f.runUntilCompletedJobs(1)
        await f.runTicks(20)

        XCTAssertEqual(f.generator.targetIDs, [["A"]])
        XCTAssertEqual(f.driver.sentTexts.count, 1)
        XCTAssertEqual(f.driver.captureCallCount, 1)
    }

    func testAppendedBCDoesNotCancelReadyReplyForA() async throws {
        let uid = "GZC-000001"
        let f = try SchedulerFixture(capturesByUID: [uid: [["A"], ["B", "C"], []]])
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        f.driver.deliveryResults = [
            .sent(serviceMessageID: "service-a"),
            .sent(serviceMessageID: "service-bc")
        ]

        await f.runUntilCompletedJobs(1)

        XCTAssertEqual(f.generator.targetIDs, [["A"]])
        XCTAssertEqual(f.driver.sentTexts, ["回复:A"])
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        f.scheduler.requestAXRefresh()
        await f.runUntilCompletedJobs(2)

        XCTAssertEqual(f.generator.targetIDs, [["A"], ["B", "C"]])
        XCTAssertEqual(f.driver.sentTexts, ["回复:A", "回复:B,C"])
        XCTAssertEqual(f.scheduler.jobs.map(\.state), [.completed, .completed])
    }

    func testCustomerTailIsQueuedAfterItsUnreadDotIsDiscovered() async throws {
        let uid = "GZC-000001"
        let f = try SchedulerFixture(capturesByUID: [uid: [["A"], ["B"]]])
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        f.driver.deliveryResults = [
            .sent(serviceMessageID: "service-a"),
            .sent(serviceMessageID: "service-b")
        ]

        await f.runUntilCompletedJobs(1)
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        f.scheduler.requestAXRefresh()
        await f.runUntilCompletedJobs(2)

        XCTAssertEqual(f.generator.targetIDs, [["A"], ["B"]])
        XCTAssertEqual(f.driver.sentTexts, ["回复:A", "回复:B"])
        XCTAssertEqual(f.scheduler.jobs.map(\.state), [.completed, .completed])
    }

    func testEmptyStaleCaptureCannotRegressAnsweredCursorAfterConfirmedSend() async throws {
        let f = try SchedulerFixture(capturesByUID: ["GZC-000001": [["A"], []]])
        f.driver.baselineCustomerCountByUID["GZC-000001"] = 0
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: true)]
        f.driver.deliveryResults = [.sent(serviceMessageID: "service-a")]

        await f.runUntilCompletedJobs(1)
        await f.runTicks(3)

        XCTAssertEqual(f.scheduler.answeredCursor("GZC-000001").count, 1)
    }

    func testImageOnlyDiscoveryProducesNoJob() async throws {
        let f = try SchedulerFixture(capturesByUID: ["GZC-000001": [[]]])
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: true)]

        await f.runTicks(5)

        XCTAssertTrue(f.scheduler.jobs.isEmpty)
        XCTAssertTrue(f.generator.targetIDs.isEmpty)
    }

    func testInitialBaselineAdvancesCursorWithoutCreatingReplyJob() async throws {
        let f = try SchedulerFixture(capturesByUID: ["GZC-000001": [[]]])
        f.driver.baselineCustomerCountByUID["GZC-000001"] = 3
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: true)]

        await f.runTicks(5)

        XCTAssertEqual(f.scheduler.answeredCursor("GZC-000001").count, 3)
        XCTAssertTrue(f.scheduler.jobs.isEmpty)
    }

    func testUnexpectedHumanServiceMessageDoesNotBlockAutomaticReply() async throws {
        let f = try SchedulerFixture(capturesByUID: ["GZC-000001": [["A"]]])
        f.driver.unexpectedServiceMessageIDsByUID["GZC-000001"] = ["human-service-1"]
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: true)]

        await f.runUntilCompletedJobs(1)

        XCTAssertEqual(f.scheduler.jobs.first?.state, .completed)
        XCTAssertEqual(f.driver.sentTexts, ["回复:A"])
        XCTAssertEqual(f.scheduler.answeredCursor("GZC-000001").count, 1)
    }

    func testCustomerCursorChangeWaitsForFreshUnreadBeforeRecapturingTail() async throws {
        let f = try SchedulerFixture(capturesByUID: ["GZC-000001": [["A"], ["A", "B", "C"]]])
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: true)]
        f.driver.deliveryResults = [
            .failedBeforeSend("客户消息游标已变化"),
            .sent(serviceMessageID: "service-new")
        ]

        await f.runTicks(20)

        XCTAssertEqual(f.generator.targetIDs, [["A"]])
        XCTAssertEqual(f.driver.sendCallCount, 1)
        XCTAssertEqual(f.scheduler.jobs.map(\.state), [.failed])

        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: true)]
        f.scheduler.requestAXRefresh()
        await f.runUntilCompletedJobs(1)

        XCTAssertEqual(f.generator.targetIDs, [["A"], ["A", "B", "C"]])
        XCTAssertEqual(f.driver.sendCallCount, 2)
        XCTAssertEqual(f.scheduler.jobs.first?.state, .failed)
        XCTAssertEqual(f.scheduler.jobs.first?.retries, 0)
    }

    func testUIDMismatchBeforeSendRetriesInsteadOfCompletingAsUncertain() async throws {
        let uid = "PDD-NAME-a1366828d04c70214f9fcb06"
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 100))
        let f = try SchedulerFixture(capturesByUID: [uid: [["A"]]], now: { clock.value })
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        f.driver.deliveryResults = [
            .failedBeforeSend("写入前 UID 不匹配"),
            .sent(serviceMessageID: "service-after-retry")
        ]

        await f.runTicks(12)

        XCTAssertEqual(f.driver.sendCallCount, 1)
        XCTAssertEqual(f.scheduler.jobs.first?.state, .ready)
        XCTAssertEqual(f.scheduler.jobs.first?.deliveryOutcome, .notSent)
        XCTAssertFalse(f.scheduler.jobs.first?.sendWasInvoked == true)
        XCTAssertEqual(
            f.scheduler.jobs.first?.lastError,
            "写入前 UID 不匹配；发送动作尚未执行，将继续重试"
        )
        XCTAssertEqual(f.scheduler.answeredCursor(uid).count, 0)

        clock.value = Date(timeIntervalSince1970: 102)
        await f.runUntilCompletedJobs(1)

        XCTAssertEqual(f.driver.sendCallCount, 2)
        XCTAssertEqual(f.scheduler.jobs.first?.deliveryOutcome, .sent)
        XCTAssertEqual(f.scheduler.answeredCursor(uid).count, 1)
    }

    func testRepeatedUIDMismatchParksOnlyThatJobAndAllowsNewCustomerToContinue() async throws {
        let blockedUID = "PDD-NAME-blocked"
        let nextUID = "PDD-NAME-next"
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 100))
        let f = try SchedulerFixture(
            capturesByUID: [blockedUID: [["A"]], nextUID: [["B"]]],
            now: { clock.value }
        )
        f.driver.discoveries = [.init(uid: blockedUID, hasUnreadEvidence: true)]
        f.driver.deliveryResults = [
            .failedBeforeSend("写入前 UID 不匹配"),
            .failedBeforeSend("写入前 UID 不匹配")
        ]

        await f.runTicks(12)
        clock.value = Date(timeIntervalSince1970: 102)
        await f.runTicks(12)

        XCTAssertEqual(f.scheduler.jobs.first?.state, .quarantined)
        XCTAssertEqual(f.scheduler.jobs.first?.stageAttempt, 2)
        XCTAssertTrue(f.scheduler.isRunning)

        f.driver.discoveries = [.init(uid: nextUID, hasUnreadEvidence: true)]
        f.scheduler.requestAXRefresh()
        await f.runUntilCompletedJobs(1)

        XCTAssertTrue(f.scheduler.jobs.contains {
            $0.uid == nextUID && $0.state == .completed && $0.deliveryOutcome == .sent
        })
    }

    func testExhaustedNicknameFallbackDropsCurrentBatchWithoutRetry() async throws {
        let uid = "PDD-NAME-masked"
        let f = try SchedulerFixture(capturesByUID: [uid: [["middlePanel_list_target"]]])
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        f.driver.deliveryResults = [
            .discardedBeforeSend("当前列表前两个同昵称会话均不包含目标消息")
        ]

        await f.runTicks(20)

        XCTAssertEqual(f.driver.sendCallCount, 1)
        XCTAssertEqual(f.driver.sentExpectedCustomerMessageIDs, [["middlePanel_list_target"]])
        XCTAssertEqual(f.scheduler.jobs.first?.state, .failed)
        XCTAssertEqual(f.scheduler.jobs.first?.stageAttempt, 0)
        XCTAssertEqual(f.scheduler.answeredCursor(uid).count, 1)
        XCTAssertTrue(f.scheduler.isRunning)
    }

    func testRestartedSchedulerUsesPersistedKnownServiceIDsToQuarantineHumanReply() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-restart-service-safety", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "GZC-000001"
        let previous = PDDChatMessage(
            id: "previous-0", sender: .customer, content: "previous-0",
            displayTime: "09:00", kind: .text,
            capturedAt: Date(timeIntervalSince1970: 1_776_000_000)
        )
        var persisted = AutoReplyPersistentState.empty
        persisted.answeredCursors[uid] = try AutoReplyTimeline.make(messages: [previous]).cursor
        persisted.baselinedUIDs = [uid]
        persisted.knownServiceMessageIDsByUID[uid] = ["service-known"]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(persisted)
        let driver = ControlledAutoReplyDriver(capturesByUID: [uid: [["B"]]])
        driver.serviceMessageIDsByUID[uid] = ["service-known", "service-human"]
        driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        let scheduler = try AutoReplyScheduler(
            driver: driver,
            generator: ControlledReplyGenerator(delayNanoseconds: 1_000_000),
            store: store,
            configuredMaximumConcurrentGenerations: 1,
            availableMemoryBytes: { 64 << 30 }
        )
        scheduler.start()

        for _ in 0..<50 {
            await scheduler.tick()
            if scheduler.jobs.first?.state == .completed { break }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }

        XCTAssertEqual(scheduler.jobs.first?.state, .completed)
        XCTAssertEqual(try store.load().knownServiceMessageIDsByUID[uid], ["service-known", "service-human"])
    }

    func testUncertainDeliveryCompletesUncertainAdvancesCursorAndKeepsRunning() async throws {
        let f = try SchedulerFixture(capturesByUID: ["GZC-000001": [["A"]]])
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: true)]
        f.driver.deliveryResults = [.uncertain("timeout")]

        await f.runTicks(20)

        XCTAssertEqual(f.driver.sendCallCount, 1)
        XCTAssertEqual(f.scheduler.answeredCursor("GZC-000001").count, 1)
        XCTAssertEqual(f.scheduler.jobs.first?.state, .completed)
        XCTAssertEqual(f.scheduler.jobs.first?.deliveryOutcome, .uncertain)
        XCTAssertEqual(f.scheduler.jobs.first?.lastError, "timeout")
    }

    func testUncertainDeliveryContinuesWithLaterCustomerTail() async throws {
        let f = try SchedulerFixture(capturesByUID: ["GZC-000001": [["A"], ["B"]]])
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: true)]
        f.driver.deliveryResults = [.uncertain("timeout")]
        await f.runUntilCompletedJobs(1)
        f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: true)]
        f.scheduler.requestAXRefresh()
        await f.runUntilCompletedJobs(2)

        XCTAssertEqual(f.generator.targetIDs, [["A"], ["B"]])
        XCTAssertEqual(f.driver.sendCallCount, 2)
        XCTAssertEqual(f.scheduler.jobs.map(\.state), [.completed, .completed])
        XCTAssertEqual(f.scheduler.jobs.first?.deliveryOutcome, .uncertain)
    }

    func testSchedulerLeavesFinalVisibleReplyValidationToSender() async throws {
        let uid = "GZC-000001"
        let f = try SchedulerFixture(capturesByUID: [uid: [["ocr-customer-100"]]])
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        f.driver.preflightMessagesByUID[uid] = [
            PDDChatMessage(
                id: "ocr-customer-100", sender: .customer, content: "ocr-customer-100",
                displayTime: "10:00", kind: .text,
                capturedAt: Date(timeIntervalSince1970: 1_777_000_000)
            ),
            PDDChatMessage(
                id: "ocr-service-101", sender: .service,
                content: "回复:ocr-customer-100", displayTime: "10:01", kind: .text,
                capturedAt: Date(timeIntervalSince1970: 1_777_000_001)
            )
        ]

        await f.runUntilCompletedJobs(1)

        XCTAssertEqual(f.driver.preflightCallCount, 0)
        XCTAssertEqual(f.driver.sendCallCount, 1)
        XCTAssertEqual(f.scheduler.jobs.first?.confirmedServiceMessageID, "service-1")
        XCTAssertEqual(f.scheduler.answeredCursor(uid).count, 1)
    }

    func testObsoleteInvalidPreflightCannotBlockSenderValidatedDelivery() async throws {
        let uid = "GZC-000001"
        let f = try SchedulerFixture(capturesByUID: [uid: [["A"]]])
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        f.driver.preflightError = AutoReplyTimelineError.invalidPrefix

        await f.runTicks(10)

        XCTAssertEqual(f.scheduler.jobs.first?.state, .completed)
        XCTAssertEqual(f.scheduler.answeredCursor(uid).count, 1)
        XCTAssertEqual(f.driver.preflightCallCount, 0)
        XCTAssertEqual(f.driver.sendCallCount, 1)
    }

    func testObsoletePreflightRuntimeErrorCannotParkReadyRevision() async throws {
        let uid = "GZC-000001"
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 100))
        let f = try SchedulerFixture(capturesByUID: [uid: [["A"]]], now: { clock.value })
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        f.driver.preflightError = CocoaError(.fileReadUnknown)

        await f.runTicks(8)
        clock.value = Date(timeIntervalSince1970: 102)
        await f.runTicks(8)

        XCTAssertEqual(f.scheduler.jobs.first?.state, .completed)
        XCTAssertEqual(f.scheduler.jobs.first?.stageAttempt, 0)
        XCTAssertEqual(f.scheduler.answeredCursor(uid).count, 1)
        XCTAssertEqual(f.driver.preflightCallCount, 0)
        XCTAssertEqual(f.driver.sendCallCount, 1)
    }

    func testSendRuntimeErrorAfterInvocationCompletesUncertainAndNeverRetries() async throws {
        let uid = "GZC-000001"
        let f = try SchedulerFixture(capturesByUID: [uid: [["A"]]])
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        f.driver.sendError = CocoaError(.fileWriteUnknown)

        await f.runTicks(12)

        XCTAssertEqual(f.scheduler.jobs.first?.state, .completed)
        XCTAssertEqual(f.scheduler.jobs.first?.deliveryOutcome, .uncertain)
        XCTAssertTrue(f.scheduler.jobs.first?.sendWasInvoked == true)
        XCTAssertNotNil(f.scheduler.jobs.first?.durableAttemptOperationID)
        XCTAssertEqual(f.scheduler.answeredCursor(uid).count, 1)
        XCTAssertEqual(f.driver.sendCallCount, 1)
    }

    func testPreflightServiceBubbleNeverSuppressesAutomaticReply() async throws {
        let uid = "GZC-000001"
        let firstID = "middlePanel_list_100"
        let f = try SchedulerFixture(capturesByUID: [uid: [[firstID]]])
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        f.driver.preflightMessagesByUID[uid] = [
            PDDChatMessage(
                id: firstID, sender: .customer, content: firstID,
                displayTime: "10:00", kind: .text,
                capturedAt: Date(timeIntervalSince1970: 1_777_000_000)
            ),
            PDDChatMessage(
                id: "middlePanel_list_101", sender: .service, content: "人工已回复",
                displayTime: "10:01", kind: .text,
                capturedAt: Date(timeIntervalSince1970: 1_777_000_001)
            ),
            PDDChatMessage(
                id: "middlePanel_list_102", sender: .customer, content: "later",
                displayTime: "10:02", kind: .text,
                capturedAt: Date(timeIntervalSince1970: 1_777_000_002)
            )
        ]

        await f.runUntilCompletedJobs(1)

        XCTAssertEqual(f.scheduler.jobs.first?.state, .completed)
        XCTAssertEqual(f.driver.sentTexts, ["回复:\(firstID)"])
        XCTAssertEqual(f.scheduler.answeredCursor(uid).count, 1)
    }

    func testDelayedEarlierAutomaticReplyDoesNotSuppressNewerCustomerBatch() async throws {
        let uid = "GZC-000001"
        let f = try SchedulerFixture(capturesByUID: [uid: [["A"], ["B", "C"]]])
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        f.driver.deliveryResults = [
            .sent(serviceMessageID: "ax-send-for-a"),
            .sent(serviceMessageID: "ax-send-for-bc")
        ]

        await f.runUntilCompletedJobs(1)

        f.driver.preflightMessagesByUID[uid] = [
            PDDChatMessage(
                id: "previous-0", sender: .customer, content: "previous-0",
                displayTime: "09:00", kind: .text,
                capturedAt: Date(timeIntervalSince1970: 1_777_000_000)
            ),
            PDDChatMessage(
                id: "B", sender: .customer, content: "B",
                displayTime: "10:00", kind: .text,
                capturedAt: Date(timeIntervalSince1970: 1_777_000_001)
            ),
            PDDChatMessage(
                id: "C", sender: .customer, content: "C",
                displayTime: "10:00", kind: .text,
                capturedAt: Date(timeIntervalSince1970: 1_777_000_002)
            ),
            PDDChatMessage(
                id: "ocr-delayed-reply-for-a", sender: .service, content: "回复:A",
                displayTime: "10:03", kind: .text,
                capturedAt: Date(timeIntervalSince1970: 1_777_000_003)
            )
        ]
        f.driver.discoveries = [.init(uid: uid, hasUnreadEvidence: true)]
        f.scheduler.requestAXRefresh()

        await f.runUntilCompletedJobs(2)

        XCTAssertEqual(f.generator.targetIDs, [["A"], ["B", "C"]])
        XCTAssertEqual(f.driver.sentTexts, ["回复:A", "回复:B,C"])
        XCTAssertEqual(f.driver.sendCallCount, 2)
        XCTAssertEqual(f.scheduler.jobs.count, 2, "同一客户批次不能因旧回复气泡而无限重建")
    }

    func testRestartMigratesLegacyQuarantineToNonBlockingFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-quarantine-cursor-repair", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "GZC-000001"
        let first = PDDChatMessage(
            id: "middlePanel_list_100", sender: .customer, content: "first",
            displayTime: nil, kind: .text, capturedAt: Date()
        )
        let later = PDDChatMessage(
            id: "middlePanel_list_102", sender: .customer, content: "later",
            displayTime: nil, kind: .text, capturedAt: Date()
        )
        let firstTimeline = try AutoReplyTimeline.make(messages: [first])
        let fullTimeline = try AutoReplyTimeline.make(messages: [first, later])
        let batch = try XCTUnwrap(try firstTimeline.freeze(after: .empty))
        let capture = AutoReplyCapture(
            uid: uid, fullHistory: [first, later], batch: batch,
            customerCursor: fullTimeline.cursor, unexpectedServiceMessageIDs: ["middlePanel_list_101"]
        )
        var persisted = AutoReplyPersistentState.empty
        persisted.nextSequence = 1
        persisted.answeredCursors[uid] = fullTimeline.cursor
        persisted.jobs = [AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .quarantined,
            capture: capture, reply: "reply", deliveryOutcome: nil,
            confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil,
            lastError: "发送前检测到未确认的人工客服消息"
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(persisted)

        let scheduler = try AutoReplyScheduler(
            driver: ControlledAutoReplyDriver(capturesByUID: [:]),
            generator: ControlledReplyGenerator(delayNanoseconds: 0),
            store: store
        )

        XCTAssertEqual(scheduler.answeredCursor(uid), batch.endCursor)
        XCTAssertEqual(try store.load().answeredCursors[uid], batch.endCursor)
        XCTAssertEqual(scheduler.jobs.first?.state, .failed)
    }

    func testRestartRollsBackCursorForLatestPrefixChangedFailureSoItCanBeRecaptured() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-prefix-change-cursor-repair", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "GZC-000001"
        let previous = PDDChatMessage(
            id: "previous", sender: .customer, content: "previous",
            displayTime: nil, kind: .text, capturedAt: Date()
        )
        let missed = PDDChatMessage(
            id: "missed", sender: .customer, content: "missed",
            displayTime: nil, kind: .text, capturedAt: Date()
        )
        let previousTimeline = try AutoReplyTimeline.make(messages: [previous])
        let fullTimeline = try AutoReplyTimeline.make(messages: [previous, missed])
        let batch = try XCTUnwrap(fullTimeline.freeze(after: previousTimeline.cursor))
        let capture = AutoReplyCapture(
            uid: uid, fullHistory: [previous, missed], batch: batch,
            customerCursor: fullTimeline.cursor, unexpectedServiceMessageIDs: []
        )
        var persisted = AutoReplyPersistentState.empty
        persisted.nextSequence = 1
        persisted.answeredCursors[uid] = AutoReplyCursor(
            count: 3, digest: String(repeating: "e", count: 64)
        )
        persisted.jobs = [AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .failed,
            capture: capture, reply: "reply", deliveryOutcome: .notSent,
            confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil,
            lastError: "客户消息前缀已变化"
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(persisted)

        let scheduler = try AutoReplyScheduler(
            driver: ControlledAutoReplyDriver(capturesByUID: [:]),
            generator: ControlledReplyGenerator(delayNanoseconds: 0),
            store: store
        )

        XCTAssertEqual(scheduler.answeredCursor(uid), batch.startCursor)
        XCTAssertEqual(try store.load().answeredCursors[uid], batch.startCursor)
    }

    func testRestartRequeuesLegacyFalseUncertainUIDMismatchWithoutLosingBatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-false-uncertain-repair", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "PDD-NAME-a1366828d04c70214f9fcb06"
        let capture = try makeFrozenCapture(uid: uid, ids: ["A"], after: .empty)
        let batch = try XCTUnwrap(capture.batch)
        var persisted = AutoReplyPersistentState.empty
        persisted.nextSequence = 1
        persisted.answeredCursors[uid] = batch.endCursor
        persisted.jobs = [AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .completed,
            capture: capture, reply: "reply", deliveryOutcome: .uncertain,
            confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil,
            lastError: "写入前 UID 不匹配", sendWasInvoked: true
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(persisted)

        let scheduler = try AutoReplyScheduler(
            driver: ControlledAutoReplyDriver(capturesByUID: [:]),
            generator: ControlledReplyGenerator(delayNanoseconds: 0),
            store: store
        )

        XCTAssertEqual(scheduler.jobs.first?.state, .ready)
        XCTAssertEqual(scheduler.jobs.first?.deliveryOutcome, .notSent)
        XCTAssertFalse(scheduler.jobs.first?.sendWasInvoked == true)
        XCTAssertEqual(scheduler.answeredCursor(uid), batch.startCursor)
        XCTAssertEqual(try store.load().answeredCursors[uid], batch.startCursor)
    }

    func testRestartMigratesLegacyUncertainJobAndAdvancesPastItsBatch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-uncertain-migration", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "GZC-000001"
        let message = PDDChatMessage(
            id: "middlePanel_list_100", sender: .customer, content: "first",
            displayTime: nil, kind: .text, capturedAt: Date()
        )
        let timeline = try AutoReplyTimeline.make(messages: [message])
        let batch = try XCTUnwrap(try timeline.freeze(after: .empty))
        let capture = AutoReplyCapture(
            uid: uid, fullHistory: [message], batch: batch,
            customerCursor: timeline.cursor, unexpectedServiceMessageIDs: []
        )
        var persisted = AutoReplyPersistentState.empty
        persisted.nextSequence = 1
        persisted.jobs = [AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .uncertain,
            capture: capture, reply: "reply", deliveryOutcome: .uncertain,
            confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil,
            lastError: "发送结果待验证"
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(persisted)

        let scheduler = try AutoReplyScheduler(
            driver: ControlledAutoReplyDriver(capturesByUID: [:]),
            generator: ControlledReplyGenerator(delayNanoseconds: 0),
            store: store
        )

        XCTAssertEqual(scheduler.jobs.first?.state, .failed)
        XCTAssertEqual(scheduler.answeredCursor(uid), batch.endCursor)
        XCTAssertEqual(try store.load().answeredCursors[uid], batch.endCursor)
    }

    func testRestartRequeuesBatchSkippedByLegacyUnknownDraftGate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-unknown-draft-migration", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "GZC-000001"
        let first = PDDChatMessage(
            id: "middlePanel_list_100", sender: .customer, content: "first",
            displayTime: nil, kind: .text, capturedAt: Date()
        )
        let later = PDDChatMessage(
            id: "middlePanel_list_101", sender: .customer, content: "later",
            displayTime: nil, kind: .text, capturedAt: Date()
        )
        let start = try AutoReplyTimeline.make(messages: [first]).cursor
        let timeline = try AutoReplyTimeline.make(messages: [first, later])
        let batch = try XCTUnwrap(try timeline.freeze(after: start))
        let capture = AutoReplyCapture(
            uid: uid, fullHistory: [first, later], batch: batch,
            customerCursor: timeline.cursor, unexpectedServiceMessageIDs: []
        )
        var persisted = AutoReplyPersistentState.empty
        persisted.nextSequence = 1
        persisted.answeredCursors[uid] = batch.endCursor
        persisted.jobs = [AutoReplyJob(
            id: UUID(), uid: uid, sequence: 1, state: .failed,
            capture: capture, reply: "reply", deliveryOutcome: .notSent,
            confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil,
            lastError: "输入区存在未知草稿；已跳过当前批次并继续"
        )]
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(persisted)

        let scheduler = try AutoReplyScheduler(
            driver: ControlledAutoReplyDriver(capturesByUID: [:]),
            generator: ControlledReplyGenerator(delayNanoseconds: 0),
            store: store
        )

        XCTAssertEqual(scheduler.answeredCursor(uid), batch.startCursor)
        XCTAssertEqual(try store.load().answeredCursors[uid], batch.startCursor)
    }

    func testTwoUIDsGenerateConcurrentlyButUIOperationsStaySerialized() async throws {
        let f = try SchedulerFixture(capturesByUID: [
            "GZC-000001": [["A"]],
            "GZC-000002": [["B"]]
        ], generationDelayNanoseconds: 40_000_000)
        f.driver.discoveries = [
            .init(uid: "GZC-000001", hasUnreadEvidence: true),
            .init(uid: "GZC-000002", hasUnreadEvidence: true)
        ]

        await f.runUntilCompletedJobs(2)

        XCTAssertGreaterThanOrEqual(f.generator.maximumConcurrentCalls, 2)
        XCTAssertEqual(f.driver.maximumConcurrentUICalls, 1)
    }

    func testStopPreventsDiscoveryAndDelivery() async throws {
        let f = try SchedulerFixture(capturesByUID: ["GZC-000001": [["A"]]])
        f.scheduler.stop()

        await f.runTicks(3)

        XCTAssertEqual(f.driver.discoverCallCount, 0)
        XCTAssertTrue(f.driver.sentTexts.isEmpty)
    }

    func testHangingDiscoveryTimesOutWithoutHoldingTickForever() async throws {
        let f = try SchedulerFixture(
            capturesByUID: [:], uiOperationTimeout: .milliseconds(30)
        )
        f.driver.discoverNeverReturns = true
        let started = Date()

        await f.scheduler.tick()

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3)
        XCTAssertTrue(f.scheduler.lastRuntimeIssue?.contains("超时") == true)
    }

    func testStopSynchronouslyRevokesLeaseOwnedByHangingDiscovery() async throws {
        let f = try SchedulerFixture(
            capturesByUID: [:], uiOperationTimeout: .seconds(10)
        )
        f.driver.discoverNeverReturns = true
        let tick = Task { await f.scheduler.tick() }
        for _ in 0..<100 where f.driver.latestLease == nil {
            await Task.yield()
        }
        let lease = try XCTUnwrap(f.driver.latestLease)

        f.scheduler.stop()

        XCTAssertThrowsError(try lease.validate())
        tick.cancel()
        _ = await tick.result
    }

    func testObsoletePerUIDPreflightFailuresCannotBlockEitherCustomer() async throws {
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 100))
        let f = try SchedulerFixture(capturesByUID: [
            "GZC-000001": [["A"]],
            "GZC-000002": [["B"]]
        ], uiOperationTimeout: .milliseconds(100), now: { clock.value })
        f.driver.discoveries = [
            .init(uid: "GZC-000001", hasUnreadEvidence: true),
            .init(uid: "GZC-000002", hasUnreadEvidence: true)
        ]
        f.driver.preflightErrorsByUID["GZC-000001"] = CocoaError(.fileReadUnknown)

        await f.runTicks(40)
        clock.value = Date(timeIntervalSince1970: 102)
        await f.runTicks(40)

        XCTAssertEqual(f.scheduler.jobs.first(where: { $0.uid == "GZC-000001" })?.state, .completed)
        XCTAssertEqual(f.scheduler.jobs.first(where: { $0.uid == "GZC-000001" })?.stageAttempt, 0)
        XCTAssertEqual(f.scheduler.jobs.first(where: { $0.uid == "GZC-000002" })?.state, .completed)
        XCTAssertEqual(f.driver.preflightCallCount, 0)
    }

    func testAXNotificationForcesImmediateDiscoveryAndTwoBoundedRetries() async throws {
        let clock = SchedulerTestClock(Date(timeIntervalSince1970: 1_777_000_000))
        let f = try SchedulerFixture(capturesByUID: [:], now: { clock.value })

        await f.scheduler.tick()
        XCTAssertEqual(f.driver.discoverCallCount, 1)

        f.scheduler.requestAXRefresh()
        await f.scheduler.tick()
        XCTAssertEqual(f.driver.discoverCallCount, 2)

        // A noisy Chromium/Electron accessibility tree can emit several related
        // notifications for one visual update. Do not restart the retry burst.
        f.scheduler.requestAXRefresh()
        await f.scheduler.tick()
        XCTAssertEqual(f.driver.discoverCallCount, 2)

        clock.value = clock.value.addingTimeInterval(0.21)
        await f.scheduler.tick()
        clock.value = clock.value.addingTimeInterval(0.21)
        await f.scheduler.tick()

        XCTAssertEqual(f.driver.discoverCallCount, 4)
        XCTAssertEqual(f.scheduler.lastAXWakeAt, Date(timeIntervalSince1970: 1_777_000_000))
    }

    func testAdaptiveGenerationCapacityMatchesQianniuMemoryPolicy() {
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let policy = AdaptiveConcurrencyPolicy(physicalMemoryBytes: 16 << 30)
        XCTAssertEqual(
            policy.limit(queueDepth: 20, availableMemoryBytes: 10 << 30, activeCleanup: 0, now: now),
            9
        )
        policy.recordBackpressure(now: now)
        XCTAssertEqual(
            policy.limit(queueDepth: 20, availableMemoryBytes: 10 << 30, activeCleanup: 0, now: now),
            4
        )
    }

    func testThreeConsecutiveDeliveriesForceDiscoveryBeforeFourth() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-send-fairness", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = AutoReplyPersistentState.empty
        for sequence in 1...4 {
            let uid = String(format: "GZC-%06d", sequence)
            let message = PDDChatMessage(
                id: "m\(sequence)", sender: .customer, content: "q\(sequence)",
                displayTime: "10:00", kind: .text,
                capturedAt: Date(timeIntervalSince1970: 1_777_000_000)
            )
            let timeline = try AutoReplyTimeline.make(messages: [message])
            let batch = try XCTUnwrap(timeline.freeze(after: .empty))
            let capture = AutoReplyCapture(
                uid: uid, fullHistory: [message], batch: batch,
                customerCursor: timeline.cursor, unexpectedServiceMessageIDs: []
            )
            state.jobs.append(AutoReplyJob(
                id: UUID(), uid: uid, sequence: sequence, state: .ready,
                capture: capture, reply: "r\(sequence)", deliveryOutcome: nil,
                confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil,
                lastError: nil
            ))
        }
        state.nextSequence = 4
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let driver = ControlledAutoReplyDriver(capturesByUID: [:])
        let scheduler = try AutoReplyScheduler(
            driver: driver,
            generator: ControlledReplyGenerator(delayNanoseconds: 0),
            store: store,
            configuredMaximumConcurrentGenerations: 1,
            availableMemoryBytes: { 64 << 30 }
        )
        scheduler.start()

        await scheduler.tick()
        await scheduler.tick()
        await scheduler.tick()
        await scheduler.tick()

        XCTAssertEqual(driver.sendCallCount, 3)
        XCTAssertEqual(driver.discoverCallCount, 1)
        await scheduler.tick()
        XCTAssertEqual(driver.sendCallCount, 4)
    }
}

@MainActor
private final class SchedulerFixture {
    let root: URL
    let driver: ControlledAutoReplyDriver
    let generator: ControlledReplyGenerator
    let scheduler: AutoReplyScheduler

    init(
        capturesByUID: [String: [[String]]],
        generationDelayNanoseconds: UInt64 = 1_000_000,
        uiOperationTimeout: Duration = .seconds(3),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-scheduler-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        driver = ControlledAutoReplyDriver(capturesByUID: capturesByUID)
        generator = ControlledReplyGenerator(delayNanoseconds: generationDelayNanoseconds)
        scheduler = try AutoReplyScheduler(
            driver: driver,
            generator: generator,
            store: AutoReplyStore(rootDirectory: root),
            configuredMaximumConcurrentGenerations: 4,
            availableMemoryBytes: { 64 << 30 },
            uiOperationTimeout: uiOperationTimeout,
            now: now
        )
        scheduler.start()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func runTicks(_ count: Int) async {
        for _ in 0..<count {
            await scheduler.tick()
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
    }

    func runUntilCompletedJobs(_ count: Int) async {
        for _ in 0..<100 {
            await scheduler.tick()
            if scheduler.jobs.filter({ $0.state == .completed }).count >= count { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("100 ticks 内未完成 \(count) 个任务")
    }
}

private final class SchedulerTestClock: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

private func makeFrozenCapture(
    uid: String,
    ids: [String],
    after cursor: AutoReplyCursor
) throws -> AutoReplyCapture {
    let previous = (0..<cursor.count).map {
        PDDChatMessage(
            id: "previous-\($0)", sender: .customer, content: "previous-\($0)",
            displayTime: "09:00", kind: .text, capturedAt: Date(timeIntervalSince1970: 1)
        )
    }
    let messages = ids.map {
        PDDChatMessage(
            id: $0, sender: .customer, content: $0,
            displayTime: "10:00", kind: .text, capturedAt: Date(timeIntervalSince1970: 2)
        )
    }
    let history = previous + messages
    let timeline = try AutoReplyTimeline.make(messages: history)
    let start = previous.isEmpty ? .empty : try AutoReplyTimeline.make(messages: previous).cursor
    return AutoReplyCapture(
        uid: uid, fullHistory: history, batch: try timeline.freeze(after: start),
        customerCursor: timeline.cursor, unexpectedServiceMessageIDs: []
    )
}

private func videoAttachment(messageID: String, sha256: String? = nil) -> AutoReplyVideoAttachment {
    AutoReplyVideoAttachment(
        messageID: messageID,
        localURL: URL(fileURLWithPath: "/tmp/\(messageID).mp4"),
        sha256: sha256 ?? messageID,
        byteCount: 1,
        durationSeconds: 1,
        width: 1,
        height: 1,
        videoCodec: "H.264",
        audioCodec: nil,
        frames: [],
        transcript: nil,
        diagnostic: nil
    )
}

private func makeVideoCapture(
    uid: String,
    messageID: String
) throws -> AutoReplyCapture {
    let video = PDDChatMessage(
        id: messageID, sender: .customer, content: "[视频]",
        displayTime: "10:00", kind: .video, capturedAt: Date(timeIntervalSince1970: 2)
    )
    let history = [video]
    let timeline = try AutoReplyTimeline.make(messages: history)
    return AutoReplyCapture(
        uid: uid, fullHistory: history, batch: try timeline.freeze(after: .empty),
        customerCursor: timeline.cursor, unexpectedServiceMessageIDs: []
    )
}

@MainActor
private final class ControlledAutoReplyDriver: AutoReplyAutomationDriver {
    var discoveries: [AutoReplyDiscovery] = []
    var deliveryResults: [AutoReplyDeliveryResult] = []
    var sentExpectedCustomerMessageIDs: [Set<String>] = []
    var transferResults: [AutoReplyTransferResult] = []
    var unexpectedServiceMessageIDsByUID: [String: [String]] = [:]
    var baselineCustomerCountByUID: [String: Int] = [:]
    var serviceMessageIDsByUID: [String: [String]] = [:]
    var serviceMessageContentsByID: [String: String] = [:]
    var ocrDiagnosticByUID: [String: String] = [:]
    var pendingVideoMessageIDsByUID: [String: [String]] = [:]
    var videoRecoveryTargets: [String] = []
    var preflightMessagesByUID: [String: [PDDChatMessage]] = [:]
    var preflightError: Error?
    var sendError: Error?
    var discoverError: Error?
    var discoverNeverReturns = false
    var captureErrorsByUID: [String: Error] = [:]
    var preflightErrorsByUID: [String: Error] = [:]
    private(set) var latestLease: UIOperationLease?
    private var capturesByUID: [String: [[String]]]
    private(set) var sentTexts: [String] = []
    private(set) var sendCallCount = 0
    private(set) var transferredUIDs: [String] = []
    private(set) var discoverCallCount = 0
    private(set) var captureCallCount = 0
    private(set) var preflightCallCount = 0
    private(set) var captureCallCountByUID: [String: Int] = [:]
    private(set) var captureIncludeImages: [Bool] = []
    private(set) var maximumConcurrentUICalls = 0
    private var concurrentUICalls = 0

    init(capturesByUID: [String: [[String]]]) {
        self.capturesByUID = capturesByUID
    }

    func discover() async throws -> [AutoReplyDiscovery] {
        beginUI(); defer { endUI() }
        discoverCallCount += 1
        if let discoverError { throw discoverError }
        let result = discoveries
        discoveries = []
        return result
    }

    func discover(lease: UIOperationLease) async throws -> [AutoReplyDiscovery] {
        latestLease = lease
        if discoverNeverReturns {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }
        try lease.validate()
        let result = try await discover()
        try lease.validate()
        return result
    }

    func capture(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture {
        beginUI(); defer { endUI() }
        captureCallCount += 1
        captureCallCountByUID[uid, default: 0] += 1
        if let error = captureErrorsByUID[uid] { throw error }
        var queue = capturesByUID[uid] ?? []
        let ids = queue.isEmpty ? [] : queue.removeFirst()
        capturesByUID[uid] = queue
        return try makeCapture(uid: uid, ids: ids, after: cursor)
    }

    func capture(
        uid: String, after cursor: AutoReplyCursor, includeImages: Bool,
        lease: UIOperationLease
    ) async throws -> AutoReplyCapture {
        captureIncludeImages.append(includeImages)
        return try await capture(uid: uid, after: cursor)
    }

    func capture(
        uid: String, after cursor: AutoReplyCursor, includeImages: Bool,
        onlyVideoMessageID: String?, lease: UIOperationLease
    ) async throws -> AutoReplyCapture {
        if let onlyVideoMessageID { videoRecoveryTargets.append(onlyVideoMessageID) }
        return try await capture(
            uid: uid, after: cursor, includeImages: includeImages, lease: lease
        )
    }

    func preflight(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture? {
        preflightCallCount += 1
        if let error = preflightErrorsByUID[uid] { throw error }
        if let preflightError { throw preflightError }
        guard let messages = preflightMessagesByUID[uid] else { return nil }
        let timeline = try AutoReplyTimeline.make(messages: messages)
        return AutoReplyCapture(
            uid: uid,
            fullHistory: messages,
            batch: try timeline.freeze(after: cursor),
            customerCursor: timeline.cursor,
            unexpectedServiceMessageIDs: []
        )
    }

    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor
    ) async throws -> AutoReplyDeliveryResult {
        beginUI(); defer { endUI() }
        sendCallCount += 1
        if let sendError { throw sendError }
        sentTexts.append(text)
        return deliveryResults.isEmpty
            ? .sent(serviceMessageID: "service-\(sendCallCount)")
            : deliveryResults.removeFirst()
    }

    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor,
        expectedCustomerMessageIDs: Set<String>
    ) async throws -> AutoReplyDeliveryResult {
        sentExpectedCustomerMessageIDs.append(expectedCustomerMessageIDs)
        return try await send(
            uid: uid,
            text: text,
            expectedCustomerCursor: expectedCustomerCursor
        )
    }

    func transferToAnyHuman(
        uid: String, lease: UIOperationLease
    ) async throws -> AutoReplyTransferResult {
        try lease.validate()
        transferredUIDs.append(uid)
        return transferResults.isEmpty
            ? .transferred(agentLabel: "任意客服")
            : transferResults.removeFirst()
    }

    private func makeCapture(uid: String, ids: [String], after cursor: AutoReplyCursor) throws -> AutoReplyCapture {
        if ids.isEmpty, let count = baselineCustomerCountByUID[uid] {
            return AutoReplyCapture(
                uid: uid,
                fullHistory: [],
                batch: nil,
                customerCursor: AutoReplyCursor(count: count, digest: String(repeating: "c", count: 64)),
                unexpectedServiceMessageIDs: unexpectedServiceMessageIDsByUID[uid] ?? []
            )
        }
        let messages = ids.map {
            PDDChatMessage(
                id: $0,
                sender: .customer,
                content: $0,
                displayTime: "10:00",
                kind: .text,
                capturedAt: Date(timeIntervalSince1970: 1_777_000_000)
            )
        }
        let previousMessages = (0..<cursor.count).map {
            PDDChatMessage(
                id: "previous-\($0)", sender: .customer, content: "previous-\($0)",
                displayTime: "09:00", kind: .text,
                capturedAt: Date(timeIntervalSince1970: 1_776_000_000)
            )
        }
        let services = (serviceMessageIDsByUID[uid] ?? []).map {
            PDDChatMessage(
                id: $0, sender: .service, content: serviceMessageContentsByID[$0] ?? $0,
                displayTime: "10:00", kind: .text,
                capturedAt: Date(timeIntervalSince1970: 1_777_000_000)
            )
        }
        let fullHistory = previousMessages + messages + services
        let timeline = try AutoReplyTimeline.make(messages: fullHistory)
        let effectiveStart = cursor.count == 0 ? AutoReplyCursor.empty : try AutoReplyTimeline.make(messages: previousMessages).cursor
        return AutoReplyCapture(
            uid: uid,
            fullHistory: fullHistory,
            batch: try timeline.freeze(after: effectiveStart),
            customerCursor: timeline.cursor,
            unexpectedServiceMessageIDs: unexpectedServiceMessageIDsByUID[uid] ?? [],
            ocrDiagnostic: ocrDiagnosticByUID[uid],
            pendingVideoMessageIDs: pendingVideoMessageIDsByUID[uid] ?? []
        )
    }

    private func beginUI() {
        concurrentUICalls += 1
        maximumConcurrentUICalls = max(maximumConcurrentUICalls, concurrentUICalls)
    }

    private func endUI() { concurrentUICalls -= 1 }
}

private enum FixtureSchedulerError: LocalizedError {
    case discovery
    var errorDescription: String? { "fixture discovery failed" }
}

private final class ControlledReplyGenerator: AutoReplyGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private let delayNanoseconds: UInt64
    private var currentCalls = 0
    private var storedMaximumConcurrentCalls = 0
    private var storedTargetIDs: [[String]] = []

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    var maximumConcurrentCalls: Int { locked { storedMaximumConcurrentCalls } }
    var targetIDs: [[String]] { locked { storedTargetIDs } }

    func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult {
        let ids = capture.batch?.events.map(\.messageID) ?? []
        locked {
            currentCalls += 1
            storedMaximumConcurrentCalls = max(storedMaximumConcurrentCalls, currentCalls)
            storedTargetIDs.append(ids)
        }
        try await Task.sleep(nanoseconds: delayNanoseconds)
        locked { currentCalls -= 1 }
        return CodexReplyResult(reply: "回复:" + ids.joined(separator: ","), threadID: "thread-\(capture.uid)")
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

private struct SelectiveGenerationError: LocalizedError {
    var errorDescription: String? { "fixture generation failed" }
}

private actor SelectivelyFailingReplyGenerator: AutoReplyGenerating {
    let failingUID: String

    init(failingUID: String) { self.failingUID = failingUID }

    func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult {
        if capture.uid == failingUID { throw SelectiveGenerationError() }
        let ids = capture.batch?.events.map(\.messageID) ?? []
        return CodexReplyResult(
            reply: "回复:" + ids.joined(separator: ","),
            threadID: "thread-\(capture.uid)"
        )
    }
}

private struct TransferReplyGenerator: AutoReplyGenerating {
    func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult {
        CodexReplyResult(
            reply: "好的，我帮您转人工处理～",
            threadID: "thread-\(capture.uid)",
            action: .replyThenTransfer,
            transferReason: .customerExplicitlyRequestedHuman
        )
    }
}

private struct TransferAwareReplyGenerator: AutoReplyGenerating {
    func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult {
        let text = capture.batch?.events.map(\.messageID).joined(separator: ",") ?? ""
        if text.contains("我要人工客服") {
            return CodexReplyResult(
                reply: "好的，我帮您转人工处理～",
                threadID: "thread-\(capture.uid)",
                action: .replyThenTransfer,
                transferReason: .customerExplicitlyRequestedHuman
            )
        }
        return CodexReplyResult(reply: "回复:\(text)", threadID: "thread-\(capture.uid)")
    }
}

private actor AlwaysFailingCodexGenerator: AutoReplyGenerating {
    let error: Error
    private(set) var callCount = 0
    init(error: Error) { self.error = error }
    func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult {
        callCount += 1
        throw error
    }
    func calls() -> Int { callCount }
}
