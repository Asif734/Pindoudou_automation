import XCTest
@testable import PDDAXReader

@MainActor
final class PDDDiscoveryRecoveryTests: XCTestCase {
    func testOldHistoryWithoutNewBatchDoesNotConsumeUnreadCaptureTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadB = false; backend.partialA = "oldA"
        let clock = InvestigationClock()
        let (driver, a, _) = try setup(root, backend: backend, clock: clock)
        let identified = try await driver.discover()
        XCTAssertEqual(identified.first?.uid, a)
        let history = [investigationMessage("oldA")]
        let timeline = try AutoReplyTimeline.make(messages: history)
        let empty = AutoReplyCapture(uid: a, fullHistory: history, batch: nil,
            customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
        try CustomerMessageReceipts(root: root).capture(empty)
        try driver.acknowledgeDiscoveryCapture(empty)
        XCTAssertEqual(try PDDPendingDiscoveryStore(root: root).load().count, 1)
        backend.partialA = "newA"; backend.aHydrated = true; clock.date += 3
        let retried = try await driver.discover()
        XCTAssertEqual(retried.first?.uid, a)
        XCTAssertEqual(retried.first?.hasUnreadEvidence, true)
        try captured(a, backend: backend, driver: driver, root: root)
        XCTAssertTrue(try PDDPendingDiscoveryStore(root: root).load().isEmpty)
    }

    func testAbsentVisitorRetryCannotSuppressAnotherCustomersVisibleMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadA = false; backend.unreadB = false
        let clock = InvestigationClock()
        let (driver, _, b) = try setup(root, backend: backend, clock: clock)
        let visitor = PDDPendingDiscovery(locator: .init(nickname: "游客"), occurrence: 0,
                                          unread: true, at: clock.date)
        try PDDPendingDiscoveryStore(root: root).save([visitor])
        let found = try await driver.discover()
        XCTAssertEqual(found.first?.uid, b)
        XCTAssertEqual(found.first?.hasUncapturedCustomerMessages, true)
        XCTAssertTrue(backend.pressed.isEmpty)
        XCTAssertEqual(try PDDPendingDiscoveryStore(root: root).load().count, 1)
    }

    func testDelayedSelectionSettlesWithoutSwitchingToTheOtherUnreadCustomer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.aHydrated = true; backend.selectionDelayReads = 3
        let clock = InvestigationClock()
        let (driver, a, b) = try setup(root, backend: backend, clock: clock)
        let first = try await driver.discover()
        XCTAssertEqual(first.first?.uid, a)
        XCTAssertEqual(backend.pressed, [2])
        try captured(a, backend: backend, driver: driver, root: root)
        let second = try await driver.discover()
        XCTAssertEqual(second.first?.uid, b)
    }

    func testHandledIncomingTransferRetiresNilBatchAndDoesNotReopenUnchangedNotice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadA = false; backend.unreadB = false
        backend.handledTransferB = true
        let clock = InvestigationClock()
        let (driver, _, b) = try setup(root, backend: backend, clock: clock)
        let history = PDDChatParser.parse(root: try backend.readSemanticTree().rootSnapshot).messages
        _ = try PerUserChatStore(rootDirectory: root).mergeAXFirst(uid: b, messages: history)
        let cursor = try AutoReplyTimeline.make(messages: history).cursor
        let found = try await driver.discover()
        XCTAssertEqual(found.first?.uid, b)
        let capture = try await driver.capture(uid: b, after: cursor)
        XCTAssertNil(capture.batch)
        try CustomerMessageReceipts(root: root).capture(capture)
        try driver.acknowledgeDiscoveryCapture(capture)
        XCTAssertTrue(try PDDPendingDiscoveryStore(root: root).load().isEmpty)
        let presses = backend.pressed.count
        clock.date += 40
        _ = try await driver.discover()
        XCTAssertEqual(backend.pressed.count, presses)
        XCTAssertTrue(try PDDPendingDiscoveryStore(root: root).load().isEmpty)
        // A fresh red-dot signal is independent of the handled transfer notice.
        backend.unreadB = true
        let fresh = try await driver.discover()
        XCTAssertEqual(fresh.first?.uid, b)
    }

    func testHandledHandoffWithUnreadDotDoesNotReopenWhenTheDotClears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadA = false; backend.unreadB = true; backend.handledTransferB = true
        let clock = InvestigationClock()
        let (driver, _, b) = try setup(root, backend: backend, clock: clock)
        let history = PDDChatParser.parse(root: try backend.readSemanticTree().rootSnapshot).messages
        _ = try PerUserChatStore(rootDirectory: root).mergeAXFirst(uid: b, messages: history)
        _ = try await driver.discover()
        let capture = try await driver.capture(uid: b, after: AutoReplyTimeline.make(messages: history).cursor)
        XCTAssertNil(capture.batch)
        try CustomerMessageReceipts(root: root).capture(capture)
        try driver.acknowledgeDiscoveryCapture(capture)
        XCTAssertTrue(try PDDPendingDiscoveryStore(root: root).load().isEmpty)
        let count = backend.pressed.count
        clock.date += 3
        _ = try await driver.discover() // red dot is now cleared, transfer notice stays
        XCTAssertEqual(backend.pressed.count, count)
        XCTAssertTrue(try PDDPendingDiscoveryStore(root: root).load().isEmpty)
    }

    func testHandledSignalSurvivesRestartButChangedPreviewCreatesNewInspection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PDDDiscoverySignalStore(root: root)
        var task = PDDPendingDiscovery(locator: .init(nickname: "A***"), occurrence: 0, unread: true, at: Date())
        task.signalKey = "row"; task.signalSignature = "old"
        try store.save(["row": .init(signature: "old", active: true, handled: false)])
        try store.finish(task)
        XCTAssertTrue(try PDDDiscoverySignalStore(root: root).load()["row"]?.handled == true)
        try store.save(["row": .init(signature: "new", active: true, handled: false)])
        try store.finish(task)
        XCTAssertFalse(try store.load()["row"]?.handled ?? true, "Old capture must not acknowledge the newer observation")
    }

    func testStaleUnreadWithExactHandledServicePreviewFinishesInspectionWithoutAnotherClick() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadA = false; backend.previewB = "已回复"
        let clock = InvestigationClock()
        let (driver, _, b) = try setup(root, backend: backend, clock: clock)
        _ = try await driver.discover()
        var history = PDDChatParser.parse(root: try backend.readSemanticTree().rootSnapshot).messages
        history.append(.init(id: "middlePanel_list_service", sender: .service, content: "已回复", displayTime: nil, kind: .text, capturedAt: clock.date))
        _ = try PerUserChatStore(rootDirectory: root).mergeAXFirst(uid: b, messages: history)
        let capture = AutoReplyCapture(uid: b, fullHistory: history, batch: nil,
            customerCursor: try AutoReplyTimeline.make(messages: history).cursor, unexpectedServiceMessageIDs: [])
        try CustomerMessageReceipts(root: root).capture(capture)
        try driver.acknowledgeDiscoveryCapture(capture)
        XCTAssertTrue(try PDDPendingDiscoveryStore(root: root).load().isEmpty)
        backend.unreadB = true // simulate a stale pixel signal that has not cleared
        let count = backend.pressed.count
        clock.date += 3
        _ = try await driver.discover()
        XCTAssertEqual(backend.pressed.count, count)
    }

    func testCoalescedUnreadWithIdenticalPreviewGetsSlowVerificationAndFindsNewMessageID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadA = false; backend.previewB = "same question"
        let clock = InvestigationClock()
        let (driver, _, b) = try setup(root, backend: backend, clock: clock)
        _ = try await driver.discover()
        try captured(b, backend: backend, driver: driver, root: root)
        backend.currentA = true; backend.unreadB = true; backend.partialB = "newB-again"
        clock.date += 31
        let found = try await driver.discover()
        XCTAssertEqual(found.first?.uid, b)
        XCTAssertTrue(found.first?.hasUncapturedCustomerMessages == true)
    }

    func testCaptureCannotAcknowledgeMessageSeenInDiscoveryButMissingFromCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadA = false
        let clock = InvestigationClock()
        let (driver, _, b) = try setup(root, backend: backend, clock: clock)
        _ = try await driver.discover()
        let history = [investigationMessage("oldB")]
        let timeline = try AutoReplyTimeline.make(messages: history)
        let capture = AutoReplyCapture(uid: b, fullHistory: history, batch: try timeline.freeze(after: .empty),
            customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
        try CustomerMessageReceipts(root: root).capture(capture)
        try driver.acknowledgeDiscoveryCapture(capture)
        XCTAssertEqual(try PDDPendingDiscoveryStore(root: root).load().count, 1)
    }

    func testHealthyAXTreeDoesNotRequireOptionalRefreshForAnOldPendingTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadB = false; backend.aHydrated = true; backend.rejectRefresh = true
        let clock = InvestigationClock()
        let (driver, a, _) = try setup(root, backend: backend, clock: clock)
        var old = PDDPendingDiscovery(locator: .init(nickname: "A***"), occurrence: 0, unread: true, at: clock.date.addingTimeInterval(-3600))
        old.attempts = 65
        try PDDPendingDiscoveryStore(root: root).save([old])
        let found = try await driver.discover()
        XCTAssertEqual(found.first?.uid, a)
        XCTAssertEqual(backend.refreshes, 0, "Usable AX must not be gated by setting an optional Chromium attribute")
    }

    func testRejectedOptionalRefreshStillUsesTheFreshReadableTree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadB = false; backend.aHydrated = true
        backend.hideAComposer = true; backend.hideAContent = true
        backend.rejectRefresh = true; backend.recoverComposerDuringRefresh = true
        let clock = InvestigationClock()
        let (driver, a, _) = try setup(root, backend: backend, clock: clock)
        _ = try await driver.discover()
        clock.date += 10
        let found = try await driver.discover()
        XCTAssertEqual(found.first?.uid, a)
        XCTAssertEqual(backend.refreshes, 1)
        let log = try String(contentsOf: root.appendingPathComponent("logs/automation-steps.jsonl"))
        XCTAssertTrue(log.contains("discovery-AX-refresh-deferred"))
        XCTAssertFalse(log.contains("discovery-AX-refresh-failed"))
    }

    func testVerifiedMessagesCaptureWithoutComposerAndWithoutOCR() async throws {
        for duplicate in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let backend = InvestigationPDD(); backend.unreadB = false; backend.aHydrated = true
            backend.hideAComposer = !duplicate; backend.duplicateAComposer = duplicate
            let (driver, a, _) = try setup(root, backend: backend, clock: InvestigationClock())
            let found = try await driver.discover()
            XCTAssertEqual(found.first?.uid, a)
            let cursor = try AutoReplyTimeline.make(messages: [investigationMessage("oldA")]).cursor
            let capture = try await driver.capture(uid: a, after: cursor)
            XCTAssertEqual(capture.batch?.events.map(\.messageID), ["middlePanel_list_newA"])
            XCTAssertTrue(capture.ocrDiagnostic?.contains("AX 权威读取") == true)
            try CustomerMessageReceipts(root: root).capture(capture)
            try driver.acknowledgeDiscoveryCapture(capture)
            XCTAssertTrue(try PDDPendingDiscoveryStore(root: root).load().isEmpty)
            XCTAssertEqual(backend.refreshes, 0)
            let tree = try backend.readSemanticTree()
            XCTAssertThrowsError(try PDDAXControlSelection.composer(in: tree.nodes))
            // Read capability must not weaken send-control selection.
            let sender = PDDAXReplySender(backend: backend, opener: driver, pollIntervalNanoseconds: 0)
            let presses = backend.pressed.count
            let result = try await sender.send(uid: a, text: "test reply", expectedCustomerCursor: cursor,
                expectedCustomerMessageIDs: ["middlePanel_list_newA"])
            guard case .failedBeforeSend = result else { return XCTFail("Unsafe composer must defer sending: \(result)") }
            XCTAssertEqual(backend.pressed.count, presses)
            XCTAssertTrue(backend.writes.isEmpty)
        }
    }

    func testMissingComposerDoesNotPreventOtherCustomerWhileIdentityWaits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.hideAComposer = true
        let (driver, _, b) = try setup(root, backend: backend, clock: InvestigationClock())
        let pending = try await driver.discover()
        XCTAssertTrue(pending.isEmpty)
        let healthy = try await driver.discover()
        XCTAssertEqual(healthy.first?.uid, b)
        let log = try String(contentsOf: root.appendingPathComponent("logs/automation-steps.jsonl"))
        XCTAssertTrue(log.contains("waiting-for-message-anchors"))
        XCTAssertTrue(log.contains("capture-readiness-diagnostic"))
    }

    func testDiagnosticFailureCannotBlockVerifiedCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("logs"), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("logs/capture-diagnostics"))
        let backend = InvestigationPDD(); backend.unreadB = false; backend.aHydrated = true; backend.hideAComposer = true
        let (driver, a, _) = try setup(root, backend: backend, clock: InvestigationClock())
        let found = try await driver.discover()
        XCTAssertEqual(found.first?.uid, a)
        let capture = try await driver.capture(uid: a, after: .empty)
        XCTAssertNotNil(capture.batch)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("logs/automation-steps.jsonl")).contains("capture-diagnostic-write-deferred"))
    }

    func testDiagnosticRoundTripReplaysIdentityAndControlsWithoutSubmission() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = investigationTree(activeA: true, ids: ["oldA", "newA"])
        let tree = PDDAXSemanticTree(rootSnapshot: base.rootSnapshot, nodes: base.nodes.filter { $0.role != "AXTextArea" })
        let task = PDDPendingDiscovery(locator: .init(nickname: "A***"), occurrence: 0, unread: true, at: Date())
        let diagnostic = PDDAXCaptureDiagnostic(reason: "waiting-for-message-anchors", task: task,
            tree: tree, ownerCandidates: ["PDD-NAME-example"], at: Date(timeIntervalSince1970: 123))
        let path = try diagnostic.save(root: root)
        let decoded = try JSONDecoder().decode(PDDAXCaptureDiagnostic.self, from: Data(contentsOf: path))
        XCTAssertEqual(decoded.reason, diagnostic.reason)
        XCTAssertEqual(decoded.taskID, task.id)
        XCTAssertEqual(decoded.composerCandidateCount, 0)
        XCTAssertEqual(decoded.semanticActiveCount, 1)
        XCTAssertTrue(decoded.readableMessagePane)
        XCTAssertFalse(decoded.submittedToCodex)
        XCTAssertEqual(PDDAXVisibleMessageEvidence.extract(root: decoded.replay.rootSnapshot).fingerprint,
            PDDAXVisibleMessageEvidence.extract(root: tree.rootSnapshot).fingerprint)
        XCTAssertEqual(try PDDAXControlSelection.currentConversationRow(in: decoded.replay.nodes)?.visibleLabel, "A***")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("conversation-identities.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("message-receipts.json").path))
    }

    func testReadableSurfaceRequiresStructuredMessagesAndPane() throws {
        let base = investigationTree(activeA: true, ids: ["newA"])
        XCTAssertTrue(PDDAXCaptureSurface.hasReadableMessages(in: base))
        let empty = investigationTree(activeA: true, ids: [])
        XCTAssertFalse(PDDAXCaptureSurface.hasReadableMessages(in: empty))
        let textOnly = PDDAXSemanticTree(rootSnapshot: .init(role: "AXWindow", children: [
            .init(role: "AXStaticText", attributes: [("AXValue", "a question")])]), nodes: base.nodes)
        XCTAssertFalse(PDDAXCaptureSurface.hasReadableMessages(in: textOnly))
        let noPane = PDDAXSemanticTree(rootSnapshot: base.rootSnapshot, nodes: [])
        XCTAssertFalse(PDDAXCaptureSurface.hasReadableMessages(in: noPane))
    }

    func testMultipleActiveRowsCannotCaptureThroughReadablePaneFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadB = false; backend.aHydrated = true
        backend.multipleActiveRows = true; backend.hideAComposer = true
        let (driver, _, _) = try setup(root, backend: backend, clock: InvestigationClock())
        let found = try await driver.discover()
        XCTAssertTrue(found.isEmpty)
        XCTAssertNil(try PDDPendingDiscoveryStore(root: root).load().first?.resolvedUID)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("message-receipts.json").path))
    }

    func testConflictingEstablishedOwnersRemainPendingAndAreDiagnosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadB = false; backend.conflictingAOwner = true; backend.hideAComposer = true
        let (driver, a, b) = try setup(root, backend: backend, clock: InvestigationClock())
        let identities = PDDConversationIdentityStore(root: root)
        let found = try await driver.discover()
        XCTAssertTrue(found.isEmpty)
        XCTAssertEqual(try identities.canonicalUID(a), a)
        XCTAssertEqual(try identities.canonicalUID(b), b)
        XCTAssertNil(try PDDPendingDiscoveryStore(root: root).load().first?.resolvedUID)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("logs/capture-diagnostics"), includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first { $0.lastPathComponent.contains("conflicting-owner-evidence") })
        let diagnostic = try JSONDecoder().decode(PDDAXCaptureDiagnostic.self, from: Data(contentsOf: file))
        XCTAssertEqual(diagnostic.ownerCandidates, [a, b])
        XCTAssertFalse(diagnostic.submittedToCodex)
    }

    func testVerifiedMessagesSurviveSwitchAndRestartWithoutSecondLiveRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadB = false; backend.aHydrated = true
        let clock = InvestigationClock()
        let (driver, a, _) = try setup(root, backend: backend, clock: clock)
        let found = try await driver.discover()
        XCTAssertEqual(found.first?.uid, a)
        let inbox = PDDVerifiedCaptureInbox(root: root)
        XCTAssertEqual(try inbox.load(uid: a)?.messages.map(\.content), ["oldA", "newA"])
        backend.currentA = false; backend.failReads = true
        let (restarted, _, _) = try setup(root, backend: backend, clock: clock)
        let restored = try await restarted.discover()
        XCTAssertEqual(restored.first?.uid, a)
        let readCount = backend.reads
        let clicks = backend.pressed.count
        let cursor = try AutoReplyTimeline.make(messages: [investigationMessage("oldA")]).cursor
        let capture = try await restarted.capture(uid: a, after: cursor)
        XCTAssertEqual(capture.batch?.events.map(\.messageID), ["middlePanel_list_newA"])
        XCTAssertEqual(backend.reads, readCount)
        XCTAssertEqual(backend.pressed.count, clicks)
        XCTAssertNotNil(try inbox.load(uid: a), "Retain until durable capture receipts exist")
        try CustomerMessageReceipts(root: root).capture(capture)
        try restarted.acknowledgeDiscoveryCapture(capture)
        XCTAssertNil(try inbox.load(uid: a))
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testComposerCannotEndSelectionReadinessBeforeHistoryAppears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadB = false; backend.aHydrated = true; backend.emptyContentReads = 3
        let (driver, a, _) = try setup(root, backend: backend, clock: InvestigationClock())
        let found = try await driver.discover()
        XCTAssertEqual(found.first?.uid, a)
        XCTAssertEqual(backend.emptyContentReads, 0)
        XCTAssertEqual(backend.pressed, [2], "Poll the selected pane without repeated clicks")
        XCTAssertNotNil(try PDDVerifiedCaptureInbox(root: root).load(uid: a))
    }

    func testPreflightNeverUsesStagedHistoryWhenLiveReadFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadB = false; backend.aHydrated = true
        let (driver, a, _) = try setup(root, backend: backend, clock: InvestigationClock())
        _ = try await driver.discover()
        backend.failReads = true
        do { _ = try await driver.preflight(uid: a, after: .empty); XCTFail("Send preflight must read live") } catch {}
        XCTAssertNotNil(try PDDVerifiedCaptureInbox(root: root).load(uid: a))
    }

    func testStagedImageCannotUseOldAXTokensOrDegradeOnLiveReadFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); let (driver, a, _) = try setup(root, backend: backend, clock: InvestigationClock())
        let image = PDDChatMessage(id: "middlePanel_list_image", sender: .customer, content: "[图片]", displayTime: nil, kind: .image, capturedAt: Date())
        let inbox = PDDVerifiedCaptureInbox(root: root)
        try inbox.stage(uid: a, locator: .init(nickname: "A***"), messages: [investigationMessage("oldA"), image],
            snapshot: investigationTree(activeA: true, ids: ["oldA"]).rootSnapshot, unread: true, at: Date())
        backend.failReads = true
        let cursor = try AutoReplyTimeline.make(messages: [investigationMessage("oldA")]).cursor
        do { _ = try await driver.capture(uid: a, after: cursor); XCTFail("Media needs verified live controls") } catch {}
        XCTAssertNotNil(try inbox.load(uid: a))
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testInboxKeepsEveryObservationAndCorruptOtherCustomerIsIsolated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = PDDVerifiedCaptureInbox(root: root)
        let a = PDDConversationKey.make(locator: .init(nickname: "A***"))
        let b = PDDConversationKey.make(locator: .init(nickname: "B***"))
        let snapshot = investigationTree(activeA: true, ids: ["one"]).rootSnapshot
        try inbox.stage(uid: a, locator: .init(nickname: "A***"), messages: [investigationMessage("one")], snapshot: snapshot, unread: true, at: Date())
        try inbox.stage(uid: a, locator: .init(nickname: "A***"), messages: [investigationMessage("two")], snapshot: snapshot, unread: false, at: Date())
        XCTAssertEqual(try inbox.load(uid: a)?.messages.map(\.id), ["middlePanel_list_one", "middlePanel_list_two"])
        XCTAssertTrue(try inbox.load(uid: a)?.unread == true)
        try Data("broken".utf8).write(to: root.appendingPathComponent("capture-inbox/\(b).json"))
        XCTAssertEqual(try inbox.entries().map(\.uid), [a])
        try inbox.acknowledge(uid: a, capturedIDs: ["middlePanel_list_one"])
        XCTAssertNotNil(try inbox.load(uid: a), "A partial capture cannot consume unseen content")
    }

    func testInboxFollowsOnlyVerifiedCanonicalAliases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); let (driver, a, _) = try setup(root, backend: backend, clock: InvestigationClock())
        let identities = PDDConversationIdentityStore(root: root)
        let alias = PDDConversationIdentityStore.anchoredUID(messageIDs: ["middlePanel_list_newA"])
        try identities.remember(uid: alias, messageIDs: ["middlePanel_list_newA"], stableID: nil, boundary: nil, provisional: true)
        let inbox = PDDVerifiedCaptureInbox(root: root)
        try inbox.stage(uid: alias, locator: .init(nickname: "A***"), messages: [investigationMessage("newA")],
            snapshot: investigationTree(activeA: true, ids: ["newA"]).rootSnapshot, unread: true, at: Date())
        _ = try identities.reconcileVerifiedThread(messageIDs: ["middlePanel_list_oldA", "middlePanel_list_newA"], stableID: nil, boundary: nil)
        backend.failReads = true
        let discoveries = try await driver.discover()
        XCTAssertEqual(discoveries.first?.uid, a)
        let cursor = try AutoReplyTimeline.make(messages: [investigationMessage("oldA")]).cursor
        let capture = try await driver.capture(uid: a, after: cursor)
        XCTAssertEqual(capture.batch?.customerMessageIDs, ["middlePanel_list_newA"])
        try driver.acknowledgeDiscoveryCapture(capture)
        XCTAssertNotNil(try inbox.load(uid: alias), "No durable receipt yet")
        try CustomerMessageReceipts(root: root).capture(capture)
        try driver.acknowledgeDiscoveryCapture(capture)
        XCTAssertNil(try inbox.load(uid: alias))
    }

    func testCaptureReceiptToJobCrashBoundaryRecoversWithoutReopeningChat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadB = false; backend.aHydrated = true
        let (driver, a, _) = try setup(root, backend: backend, clock: InvestigationClock())
        _ = try await driver.discover()
        let cursor = try AutoReplyTimeline.make(messages: [investigationMessage("oldA")]).cursor
        let capture = try await driver.capture(uid: a, after: cursor)
        try CustomerMessageReceipts(root: root).capture(capture)
        try driver.acknowledgeDiscoveryCapture(capture)
        let inbox = PDDVerifiedCaptureInbox(root: root)
        XCTAssertTrue(try inbox.entries().isEmpty, "Acknowledged content cannot create repeated discovery work")
        XCTAssertNotNil(try inbox.load(uid: a, includingAcknowledged: true))
        // Simulate restart before a queued job is persisted. The existing
        // awaitingSubmission ledger recreates its capture request.
        backend.failReads = true
        let (restarted, _, _) = try setup(root, backend: backend, clock: InvestigationClock())
        let recovered = try await restarted.capture(uid: a, after: cursor)
        XCTAssertEqual(recovered.batch?.customerMessageIDs, ["middlePanel_list_newA"])
        XCTAssertTrue(backend.writes.isEmpty)
    }

    func testStagedMediaWithInvalidCursorStillRequiresFreshLiveControls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); let (driver, a, _) = try setup(root, backend: backend, clock: InvestigationClock())
        let image = PDDChatMessage(id: "middlePanel_list_image", sender: .customer, content: "[图片]", displayTime: nil, kind: .image, capturedAt: Date())
        try PDDVerifiedCaptureInbox(root: root).stage(uid: a, locator: .init(nickname: "A***"), messages: [image],
            snapshot: investigationTree(activeA: true, ids: []).rootSnapshot, unread: true, at: Date())
        backend.failReads = true
        do { _ = try await driver.capture(uid: a, after: .init(count: 9, digest: "expired")); XCTFail("Invalid cursor must not bypass media") } catch {}
    }

    private func setup(_ root: URL, backend: InvestigationPDD, clock: InvestigationClock) throws -> (PDDAXConversationDriver, String, String) {
        let a = PDDConversationKey.make(locator: .init(nickname: "A***"))
        let b = PDDConversationKey.make(locator: .init(nickname: "B***"))
        let store = PerUserChatStore(rootDirectory: root)
        for (uid, id) in [(a, "oldA"), (b, "oldB")] {
            _ = try store.mergeAXFirst(uid: uid, messages: [investigationMessage(id)])
            try PDDConversationIdentityStore(root: root).remember(uid: uid,
                messageIDs: ["middlePanel_list_\(id)"], stableID: nil, boundary: nil)
        }
        let driver = PDDAXConversationDriver(backend: backend, chatStore: store, allowedUIDs: nil,
            unreadEvidence: backend, now: { clock.date })
        driver.restoreConversationLocators([a: .init(nickname: "A***"), b: .init(nickname: "B***")])
        driver.restoreConversationCaptureState(baselinedUIDs: [a, b], knownServiceMessageIDsByUID: [:])
        return (driver, a, b)
    }
    private func captured(_ uid: String, backend: InvestigationPDD, driver: PDDAXConversationDriver, root: URL) throws {
        let history = PDDChatParser.parse(root: try backend.readSemanticTree().rootSnapshot).messages
        let timeline = try AutoReplyTimeline.make(messages: history)
        let capture = AutoReplyCapture(uid: uid, fullHistory: history, batch: try timeline.freeze(after: .empty),
            customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
        try CustomerMessageReceipts(root: root).capture(capture)
        _ = try PerUserChatStore(rootDirectory: root).mergeAXFirst(uid: uid, messages: history)
        try driver.acknowledgeDiscoveryCapture(capture)
    }
    func testClearedUnreadChatIsRetriedWhileTheOtherCustomerContinues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); let clock = InvestigationClock()
        let (driver, a, b) = try setup(root, backend: backend, clock: clock)
        let first = try await driver.discover()
        XCTAssertTrue(first.isEmpty)
        XCTAssertFalse(backend.unreadA)
        XCTAssertEqual(try PDDPendingDiscoveryStore(root: root).load().count, 2)
        let healthy = try await driver.discover()
        XCTAssertEqual(healthy.first?.uid, b)
        try captured(b, backend: backend, driver: driver, root: root)
        backend.aHydrated = true
        clock.date += 3
        let retried = try await driver.discover()
        XCTAssertEqual(retried.first?.uid, a)
        XCTAssertEqual(retried.first?.hasUnreadEvidence, true, "Retained unread proof survives cleared red dots")
        XCTAssertEqual(backend.pressed, [2, 4, 2])
        try captured(a, backend: backend, driver: driver, root: root)
        XCTAssertTrue(try PDDPendingDiscoveryStore(root: root).load().isEmpty)
    }
    func testPendingDiscoverySurvivesNewDriverAndHasNoNewUnreadDot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadB = false
        let clock = InvestigationClock()
        let (driver, a, _) = try setup(root, backend: backend, clock: clock)
        _ = try await driver.discover()
        backend.aHydrated = true
        let reopened = PDDAXConversationDriver(backend: backend, chatStore: .init(rootDirectory: root),
            allowedUIDs: nil, unreadEvidence: backend, now: { clock.date })
        let found = try await reopened.discover()
        XCTAssertEqual(found.first?.uid, a)
        XCTAssertEqual(found.first?.hasUnreadEvidence, true)
    }
    func testChangingPartialMessagesCannotRestartTheIdentityDeadline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.currentA = true; backend.unreadA = false; backend.unreadB = false
        let clock = InvestigationClock()
        let (driver, _, _) = try setup(root, backend: backend, clock: clock)
        var found: [AutoReplyDiscovery] = []
        for index in 0..<4 {
            backend.partialA = "newA-\(index)"
            found = try await driver.discover()
            if !found.isEmpty { break }
            clock.date += 20
        }
        XCTAssertEqual(found.count, 1)
        XCTAssertLessThanOrEqual(clock.date.timeIntervalSince1970, 160)
        let pending = try XCTUnwrap(PDDPendingDiscoveryStore(root: root).load().first)
        XCTAssertEqual(pending.firstSeenAt, Date(timeIntervalSince1970: 100))
    }
    func testRefreshAndBackoffDoNotRepeatedlyReselectTheAlreadySelectedChat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.unreadB = false; backend.hideAContent = true; backend.hideAComposer = true
        let clock = InvestigationClock()
        let (driver, a, _) = try setup(root, backend: backend, clock: clock)
        _ = try await driver.discover()
        clock.date += 10
        _ = try await driver.discover()
        XCTAssertEqual(backend.refreshes, 1)
        clock.date += 5
        _ = try await driver.discover()
        XCTAssertEqual(backend.pressed, [2])
        backend.hideAContent = false; backend.hideAComposer = false; backend.aHydrated = true; clock.date += 20
        let found = try await driver.discover()
        XCTAssertEqual(found.first?.uid, a)
        try captured(a, backend: backend, driver: driver, root: root)
        let refreshesAtCapture = backend.refreshes
        clock.date += 20
        _ = try await driver.discover()
        XCTAssertEqual(backend.refreshes, refreshesAtCapture)
        XCTAssertTrue(try PDDPendingDiscoveryStore(root: root).load().isEmpty)
    }
    func testOldVisibleChatIsNotAttributedToTheNewlySelectedCustomer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = InvestigationPDD(); backend.ignoreASelection = true; backend.unreadB = false
        let clock = InvestigationClock()
        let (driver, _, _) = try setup(root, backend: backend, clock: clock)
        let found = try await driver.discover()
        XCTAssertTrue(found.isEmpty)
        XCTAssertNil(try PDDPendingDiscoveryStore(root: root).load().first?.resolvedUID)
    }
}

private final class InvestigationClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 100)
}

@MainActor
private final class InvestigationPDD: PDDAXBackend, PDDUnreadEvidenceDetecting {
    var unreadA = true
    var failReads = false
    var reads = 0
    var emptyContentReads = 0
    var unreadB = true
    var currentA = false
    var aHydrated = false
    var partialA = "newA"
    var hideAContent = false
    var hideAComposer = false
    var duplicateAComposer = false
    var conflictingAOwner = false
    var multipleActiveRows = false
    var writes: [String] = []
    var rejectRefresh = false
    var recoverComposerDuringRefresh = false
    var ignoreASelection = false
    var previewB: String?
    var partialB = "newB"
    var handledTransferB = false
    var selectionDelayReads = 0
    var pendingSelectionReads: Int?
    var refreshes = 0
    var pressed: [Int] = []
    func readSemanticTree() throws -> PDDAXSemanticTree {
        reads += 1
        if failReads { throw CocoaError(.fileReadUnknown) }
        if let remaining = pendingSelectionReads {
            if remaining == 0 { currentA = true; pendingSelectionReads = nil }
            else { pendingSelectionReads = remaining - 1 }
        }
        var base = investigationTree(activeA: currentA, ids: currentA ? (hideAContent ? [] : (aHydrated ? ["oldA", partialA] : [partialA])) : ["oldB", partialB])
        if currentA && emptyContentReads > 0 {
            emptyContentReads -= 1
            base = investigationTree(activeA: true, ids: [])
        }
        if currentA && conflictingAOwner {
            base = investigationTree(activeA: true, ids: ["oldA", "oldB", partialA])
        }
        if multipleActiveRows {
            base = .init(rootSnapshot: base.rootSnapshot, nodes: base.nodes.map { node in
                guard node.id.rawValue == 4 else { return node }
                return .init(id: node.id, parentID: node.parentID, role: node.role, value: node.value,
                    title: node.title, domIdentifier: node.domIdentifier, domClasses: node.domClasses.union(["active"]),
                    actionNames: node.actionNames, isSettable: node.isSettable, frame: node.frame)
            })
        }
        if currentA && hideAComposer {
            base = .init(rootSnapshot: base.rootSnapshot, nodes: base.nodes.filter { $0.role != "AXTextArea" })
        }
        if currentA && duplicateAComposer {
            let extra = PDDAXSemanticNode<AXElementToken>(id: .init(rawValue: 12), parentID: .init(rawValue: 10),
                role: "AXTextArea", value: nil, title: nil, domIdentifier: nil, domClasses: [],
                actionNames: [], isSettable: true)
            base = .init(rootSnapshot: base.rootSnapshot, nodes: base.nodes + [extra])
        }
        if let previewB {
            let preview = PDDAXSemanticNode<AXElementToken>(id: .init(rawValue: 7), parentID: .init(rawValue: 4), role: "AXStaticText", value: previewB, title: nil, domIdentifier: nil, domClasses: [], actionNames: [], isSettable: false)
            base = .init(rootSnapshot: base.rootSnapshot, nodes: base.nodes + [preview])
        }
        guard handledTransferB && !currentA else { return base }
        let notice = AXNodeSnapshot(role: "AXStaticText", attributes: [("AXValue", "主账号 将该会话转移给 客服，留言：咨询"), ("AXDOMIdentifier", "transfer-1")])
        let service = AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[onemsg]"), ("AXDOMIdentifier", "middlePanel_list_service")], children: [
            .init(role: "AXGroup", attributes: [("AXDOMClassList", "[cs-item]")], children: [
                .init(role: "AXGroup", attributes: [("AXDOMClassList", "[msg-content-box]"), ("AXValue", "已回复")])])])
        let web = AXNodeSnapshot(role: "AXWebArea", attributes: [("AXTitle", "客服")], children: base.rootSnapshot.children + [notice, service])
        let trigger = PDDAXSemanticNode<AXElementToken>(id: .init(rawValue: 6), parentID: .init(rawValue: 4), role: "AXStaticText", value: "主账号 将该会话转移给 客服，留言：咨询", title: nil, domIdentifier: nil, domClasses: [], actionNames: [], isSettable: false)
        return .init(rootSnapshot: .init(role: "AXWindow", children: [web]), nodes: base.nodes + [trigger])
    }
    func performPress(_ id: AXElementToken) throws {
        pressed.append(id.rawValue)
        if id.rawValue == 2 {
            if !ignoreASelection {
                if selectionDelayReads > 0 { pendingSelectionReads = selectionDelayReads } else { currentA = true }
            }
            unreadA = false
        }
        if id.rawValue == 4 { currentA = false; unreadB = false }
    }
    func unreadRows(in tree: PDDAXSemanticTree) async throws -> [PDDConversationRow<AXElementToken>] {
        var rows: [PDDConversationRow<AXElementToken>] = []
        if unreadA { rows.append(.init(rowID: .init(rawValue: 2), visibleLabel: "A***")) }
        if unreadB { rows.append(.init(rowID: .init(rawValue: 4), visibleLabel: "B***")) }
        return rows
    }
    func requestAccessibilityRefresh() throws {
        refreshes += 1
        if recoverComposerDuringRefresh { hideAComposer = false; hideAContent = false }
        if rejectRefresh { throw PDDAXBackendError.refreshRequestRejected }
    }
    func setValue(_ text: String, on id: AXElementToken) throws { writes.append(text) }
    func value(of id: AXElementToken) throws -> String { "" }
}

private func investigationMessage(_ id: String) -> PDDChatMessage {
    .init(id: "middlePanel_list_\(id)", sender: .customer, content: id,
          displayTime: nil, kind: .text, capturedAt: Date(timeIntervalSince1970: 1))
}

private func investigationTree(activeA: Bool, ids: [String]) -> PDDAXSemanticTree {
    func node(_ id: Int, parent: Int? = nil, role: String = "AXGroup", value: String? = nil,
              classes: [String] = [], actions: [String] = [], settable: Bool = false) -> PDDAXSemanticNode<AXElementToken> {
        .init(id: .init(rawValue: id), parentID: parent.map { .init(rawValue: $0) }, role: role,
              value: value, title: nil, domIdentifier: nil, domClasses: Set(classes),
              actionNames: Set(actions), isSettable: settable)
    }
    let messages = ids.map { id in AXNodeSnapshot(role: "AXGroup", attributes: [
        ("AXDOMClassList", "[onemsg]"), ("AXDOMIdentifier", "middlePanel_list_\(id)")], children: [
            AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[buyer-item]")], children: [
                AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[msg-content-box]"), ("AXValue", id)])])]) }
    return .init(rootSnapshot: .init(role: "AXWindow", children: messages), nodes: [
        node(1, classes: ["chat-list-box"]),
        node(2, parent: 1, role: "AXRow", classes: ["chat-item-box"] + (activeA ? ["active"] : []), actions: ["AXPress"]),
        node(3, parent: 2, role: "AXStaticText", value: "A***", classes: ["chat-nickname"]),
        node(4, parent: 1, role: "AXRow", classes: ["chat-item-box"] + (activeA ? [] : ["active"]), actions: ["AXPress"]),
        node(5, parent: 4, role: "AXStaticText", value: "B***", classes: ["chat-nickname"]),
        node(10, classes: ["middle-panel"]), node(11, parent: 10, role: "AXTextArea", settable: true)
    ])
}
