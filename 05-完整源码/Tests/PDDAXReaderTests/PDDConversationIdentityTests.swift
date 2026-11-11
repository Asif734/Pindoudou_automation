import XCTest
@testable import PDDAXReader

@MainActor
final class PDDConversationIdentityTests: XCTestCase {
    func testTransferRecordRetainsIdentityAfterReplyAndGenericNoticeTextIsNotGlobalIdentity() throws {
        let before = customerNode("before")
        let service = AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[onemsg]"), ("AXDOMIdentifier", "service-after")], children: [
            .init(role: "AXGroup", attributes: [("AXDOMClassList", "[cs-item]")], children: [
                .init(role: "AXGroup", attributes: [("AXDOMClassList", "[msg-content-box]"), ("AXValue", "ok")])])])
        func root(before: [AXNodeSnapshot], after: [AXNodeSnapshot], marker: String?) -> AXNodeSnapshot {
            var attributes = [("AXDOMClassList", "[onemsg]")]
            if let marker { attributes.append(("AXDOMIdentifier", marker)) }
            let notice = AXNodeSnapshot(role: "AXGroup", attributes: attributes, children: [
                .init(role: "AXStaticText", attributes: [("AXValue", "其他客服 将该会话转移给 当前客服，请及时处理")])])
            return .init(role: "AXWebArea", attributes: [("AXTitle", "当前客服")], children: before + [notice] + after)
        }
        let initial = root(before: [before], after: [], marker: "transfer-unique")
        let answered = root(before: [before], after: [service], marker: "transfer-unique")
        let original = try XCTUnwrap(PDDAXIncomingTransfer.incomingRecord(in: initial))
        let later = try XCTUnwrap(PDDAXIncomingTransfer.incomingRecord(in: answered))
        XCTAssertEqual(original.identityBoundaryKey, later.identityBoundaryKey)
        XCTAssertTrue(later.hasServiceReply)
        XCTAssertNil(PDDAXIncomingTransfer.unansweredHandoff(in: answered))
        let genericText = root(before: [], after: [], marker: nil)
        XCTAssertNotNil(PDDAXIncomingTransfer.incomingRecord(in: genericText))
        XCTAssertNil(PDDAXIncomingTransfer.incomingRecord(in: genericText)?.identityBoundaryKey)
    }

    func testOpeningVisitorUsesFreshMaskedLabelAndKeepsIdentityAcrossRestart() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = Backend([tree("游客", ids: []), tree("A***", ids: ["one"])])
        let driver = PDDAXConversationDriver(backend: backend, chatStore: .init(rootDirectory: root), allowedUIDs: nil,
            unreadEvidence: Unread([.init(rowID: .init(rawValue: 2), visibleLabel: "游客")]))
        let firstDiscoveries = try await driver.discover()
        let first = try XCTUnwrap(firstDiscoveries.first)
        XCTAssertFalse(PDDConversationIdentityStore.isSharedVisitorUID(first.uid))
        XCTAssertEqual(driver.conversationLocatorsSnapshot()?[first.uid]?.nickname, "A***")
        let reopened = PDDAXConversationDriver(backend: Backend([tree("游客", ids: ["one", "two"])]), chatStore: .init(rootDirectory: root), allowedUIDs: nil,
            unreadEvidence: Unread([]))
        let secondDiscoveries = try await reopened.discover()
        let second = try XCTUnwrap(secondDiscoveries.first)
        XCTAssertEqual(first.uid, second.uid)
        XCTAssertEqual(try PDDConversationIdentityStore(root: root).owner(messageIDs: ["middlePanel_list_two"]), first.uid)
    }

    func testTwoVisitorsWithDifferentMessageIDsGetDifferentPersistentIdentities() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let first = tree("游客", ids: ["one"]); let second = tree("游客", ids: ["two"], activeRow: 4)
        let backend = Backend([first, first, second, second])
        let driver = PDDAXConversationDriver(backend: backend, chatStore: .init(rootDirectory: root), allowedUIDs: nil,
            unreadEvidence: Unread([.init(rowID: .init(rawValue: 2), visibleLabel: "游客"), .init(rowID: .init(rawValue: 4), visibleLabel: "游客")]))
        let oneDiscoveries = try await driver.discover()
        let twoDiscoveries = try await driver.discover()
        let one = try XCTUnwrap(oneDiscoveries.first)
        let two = try XCTUnwrap(twoDiscoveries.first)
        XCTAssertNotEqual(one.uid, two.uid)
        XCTAssertEqual(backend.pressed, [.init(rawValue: 2), .init(rawValue: 4)])
        XCTAssertFalse(PDDConversationIdentityStore.isSharedVisitorUID(one.uid))
        XCTAssertFalse(PDDConversationIdentityStore.isSharedVisitorUID(two.uid))
        XCTAssertTrue(try PerUserChatStore(rootDirectory: root).loadAXFirst(uid: PDDConversationKey.make(locator: .init(nickname: "游客"))).isEmpty)
    }

    func testSameMaskedNameWithDifferentMessagesDoesNotReuseAnotherCustomerRecord() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var identities: [String] = []
        for id in ["customer-one", "customer-two"] {
            let clock = Clock()
            let driver = PDDAXConversationDriver(backend: Backend([tree("A***", ids: [id])]), chatStore: .init(rootDirectory: root), allowedUIDs: nil,
                unreadEvidence: Unread([]), now: { clock.date })
            var discoveries = try await driver.discover()
            if discoveries.isEmpty { clock.date += 31; discoveries = try await driver.discover() }
            identities.append(try XCTUnwrap(discoveries.first?.uid))
        }
        XCTAssertNotEqual(identities[0], identities[1])
    }

    func testPartialSnapshotDoesNotSplitExistingCustomerAndFullReadResumesImmediately() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let uid = PDDConversationKey.make(locator: .init(nickname: "A***"))
        let registry = PDDConversationIdentityStore(root: root)
        try registry.remember(uid: uid, messageIDs: ["middlePanel_list_old"], stableID: nil, boundary: nil)
        _ = try PerUserChatStore(rootDirectory: root).mergeAXFirst(uid: uid, messages: [message("middlePanel_list_old", "old")])
        let backend = Backend([tree("A***", ids: ["new"]), tree("A***", ids: ["old", "new"])])
        let driver = PDDAXConversationDriver(backend: backend, chatStore: .init(rootDirectory: root), allowedUIDs: nil, unreadEvidence: Unread([]))
        let partial = try await driver.discover()
        XCTAssertTrue(partial.isEmpty)
        XCTAssertNil(try registry.owner(messageIDs: ["middlePanel_list_new"]))
        let full = try await driver.discover()
        XCTAssertEqual(full.first?.uid, uid)
        XCTAssertEqual(try registry.owner(messageIDs: ["middlePanel_list_new"]), uid)
        XCTAssertTrue(try registry.aliases().isEmpty)
    }

    func testVerifiedCurrentThreadRepairsLegacySplitAndKeepsAliasAcrossRestart() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let canonical = PDDConversationKey.make(locator: .init(nickname: "A***"))
        let alias = PDDConversationIdentityStore.anchoredUID(messageIDs: ["middlePanel_list_new"])
        let registry = PDDConversationIdentityStore(root: root)
        try registry.remember(uid: canonical, messageIDs: ["middlePanel_list_old"], stableID: nil, boundary: "handoff")
        try registry.remember(uid: alias, messageIDs: ["middlePanel_list_new"], stableID: nil, boundary: nil, provisional: true)
        let store = PerUserChatStore(rootDirectory: root)
        _ = try store.mergeAXFirst(uid: alias, messages: [message("middlePanel_list_new", "only new")])
        let driver = PDDAXConversationDriver(backend: Backend([]), chatStore: store, allowedUIDs: nil)
        try driver.reconcileVisibleIdentity(in: tree("A***", ids: ["old", "new", "latest"]))
        XCTAssertEqual(try registry.owner(messageIDs: ["middlePanel_list_old", "middlePanel_list_new"]), canonical)
        XCTAssertEqual(try PDDConversationIdentityStore(root: root).canonicalUID(alias), canonical)
        XCTAssertEqual(Set(try store.loadAXFirst(uid: canonical).map(\.id)), ["middlePanel_list_old", "middlePanel_list_new", "middlePanel_list_latest"])
        XCTAssertEqual(try store.loadAXFirst(uid: alias).map(\.content), ["only new"], "No old folder merge or rewrite")
        XCTAssertNotNil(driver.recipientVerificationReason(uid: canonical, expectedCustomerMessageIDs: ["middlePanel_list_new"], in: tree("游客", ids: ["new"])))
        XCTAssertNil(driver.recipientVerificationReason(uid: alias, expectedCustomerMessageIDs: ["middlePanel_list_new"], in: tree("A***", ids: ["new"])))
    }

    func testContradictoryStableIDsNeverMergeEvenWhenBothMessagesAreVisible() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = PDDConversationIdentityStore(root: root)
        let canonical = PDDConversationKey.make(locator: .init(nickname: "A***"))
        let alias = PDDConversationIdentityStore.anchoredUID(messageIDs: ["new"])
        try registry.remember(uid: canonical, messageIDs: ["old"], stableID: "one", boundary: nil)
        try registry.remember(uid: alias, messageIDs: ["new"], stableID: "two", boundary: nil)
        XCTAssertThrowsError(try registry.reconcileVerifiedThread(messageIDs: ["old", "new"], stableID: nil, boundary: nil))
        XCTAssertTrue(try registry.aliases().isEmpty)
        XCTAssertEqual(try registry.owner(messageIDs: ["new"]), alias)
    }

    func testLegacyLedgerWithoutAliasMetadataCanRecoverSingleMessageSplit() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let canonical = PDDConversationKey.make(locator: .init(nickname: "A***"))
        let alias = PDDConversationIdentityStore.anchoredUID(messageIDs: ["new"])
        let legacy: [String: Any] = ["owners": [
            canonical: ["messageIDs": ["old"], "stableIDs": [], "incomingBoundaries": ["handoff"]],
            alias: ["messageIDs": ["new"], "stableIDs": [], "incomingBoundaries": []]
        ]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: root.appendingPathComponent("conversation-identities.json"))
        let registry = PDDConversationIdentityStore(root: root)
        let repair = try registry.reconcileVerifiedThread(messageIDs: ["old", "new"], stableID: nil, boundary: "handoff")
        XCTAssertEqual(repair?.canonicalUID, canonical)
        XCTAssertEqual(try PDDConversationIdentityStore(root: root).canonicalUID(alias), canonical)
    }

    func testTwoProvisionalRecordsKeepEarliestIdentityWhenSameThreadProvesTheyAreAliases() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = PDDConversationIdentityStore(root: root)
        let first = PDDConversationIdentityStore.anchoredUID(messageIDs: ["old"])
        let second = PDDConversationIdentityStore.anchoredUID(messageIDs: ["new"])
        try registry.remember(uid: first, messageIDs: ["old"], stableID: nil, boundary: nil, provisional: true, at: Date(timeIntervalSince1970: 100))
        try registry.remember(uid: second, messageIDs: ["new", "newer"], stableID: nil, boundary: nil, provisional: true, at: Date(timeIntervalSince1970: 101))
        XCTAssertEqual(try registry.reconcileVerifiedThread(messageIDs: ["old", "new", "newer"], stableID: nil, boundary: nil)?.canonicalUID, first)
        XCTAssertEqual(try registry.canonicalUID(second), first)
    }

    func testConflictingChatDoesNotAbortDiscoveryOfOtherCustomer() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = PDDConversationIdentityStore(root: root)
        for (name, id) in [("A***", "one"), ("C***", "two")] {
            try registry.remember(uid: PDDConversationKey.make(locator: .init(nickname: name)),
                messageIDs: ["middlePanel_list_\(id)"], stableID: nil, boundary: nil)
        }
        let bad = tree("A***", ids: ["one", "two"]); let good = tree("B***", ids: ["healthy"], activeRow: 4)
        let driver = PDDAXConversationDriver(backend: Backend([bad, bad, good, good]), chatStore: .init(rootDirectory: root), allowedUIDs: nil,
            unreadEvidence: Unread([.init(rowID: .init(rawValue: 2), visibleLabel: "A***"), .init(rowID: .init(rawValue: 4), visibleLabel: "B***")]))
        let first = try await driver.discover(); let second = try await driver.discover()
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second.first?.uid, PDDConversationKey.make(locator: .init(nickname: "B***")))
        XCTAssertTrue(try registry.aliases().isEmpty)
    }

    func testMultipleActiveRowsCannotRepairASplit() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = PDDConversationIdentityStore(root: root)
        try registry.remember(uid: PDDConversationKey.make(locator: .init(nickname: "A***")), messageIDs: ["middlePanel_list_old"], stableID: nil, boundary: nil)
        try registry.remember(uid: PDDConversationIdentityStore.anchoredUID(messageIDs: ["new"]), messageIDs: ["middlePanel_list_new"], stableID: nil, boundary: nil, provisional: true)
        let normal = tree("A***", ids: ["old", "new"])
        let second = tree("B***", ids: [], activeRow: 4).nodes.filter { [4, 5].contains($0.id.rawValue) }
        let ambiguous = PDDAXSemanticTree(rootSnapshot: normal.rootSnapshot, nodes: normal.nodes + second)
        let driver = PDDAXConversationDriver(backend: Backend([]), chatStore: .init(rootDirectory: root), allowedUIDs: nil)
        XCTAssertThrowsError(try driver.reconcileVisibleIdentity(in: ambiguous))
        XCTAssertTrue(try registry.aliases().isEmpty)
    }

    func testStoppedReadOnlyRecoveryCombinesPendingJobsWithLatestQuestionAndPreservesOtherCustomer() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let canonical = PDDConversationKey.make(locator: .init(nickname: "A***"))
        let alias = PDDConversationIdentityStore.anchoredUID(messageIDs: ["middlePanel_list_new"])
        let registry = PDDConversationIdentityStore(root: root)
        try registry.remember(uid: canonical, messageIDs: ["middlePanel_list_old", "middlePanel_list_image"], stableID: nil, boundary: "handoff")
        try registry.remember(uid: alias, messageIDs: ["middlePanel_list_new"], stableID: nil, boundary: nil, provisional: true)
        let history = [message("middlePanel_list_old", "question"), message("middlePanel_list_image", "question")]
        let timeline = try AutoReplyTimeline.make(messages: history)
        let answered = try XCTUnwrap(timeline.prefixCursor(at: 1))
        let one = AutoReplyCapture(uid: canonical, fullHistory: history, batch: try timeline.freeze(after: answered), customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
        let newHistory = [message("middlePanel_list_new", "downloaded app")]; let newTimeline = try AutoReplyTimeline.make(messages: newHistory)
        let two = AutoReplyCapture(uid: alias, fullHistory: newHistory, batch: try newTimeline.freeze(after: .empty), customerCursor: newTimeline.cursor, unexpectedServiceMessageIDs: [])
        func pending(_ capture: AutoReplyCapture, sequence: Int) -> AutoReplyJob {
            .init(id: UUID(), uid: capture.uid, sequence: sequence, state: .ready, capture: capture, reply: "stale \(sequence)",
                deliveryOutcome: .notSent, confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil, lastError: nil)
        }
        var healthy = job(uid: "GZC-10", boundary: "healthy", state: .ready); healthy.sequence = 3
        var state = AutoReplyPersistentState(); state.jobs = [pending(one, sequence: 1), pending(two, sequence: 2), healthy]
        state.nextSequence = 3; state.answeredCursors[canonical] = answered
        try AutoReplyStore(rootDirectory: root).save(state)
        _ = try PerUserChatStore(rootDirectory: root).mergeAXFirst(uid: canonical, messages: history)
        try CustomerMessageReceipts(root: root).capture(one); try CustomerMessageReceipts(root: root).capture(two)
        let identity = PDDAXConversationDriver(backend: Backend([]), chatStore: .init(rootDirectory: root), allowedUIDs: nil)
        let driver = SchedulerDriver(); driver.identity = identity
        let generator = RecordingGenerator()
        let scheduler = try AutoReplyScheduler(driver: driver, generator: generator, store: .init(rootDirectory: root))
        try scheduler.reconcileVisibleIdentity(in: tree("A***", ids: ["old", "image", "new", "latest"]))
        let recovered = try XCTUnwrap(scheduler.jobs.last)
        XCTAssertEqual(recovered.state, .queued); XCTAssertNil(recovered.reply)
        XCTAssertEqual(recovered.uid, canonical)
        XCTAssertEqual(recovered.capture.batch?.customerMessageIDs, ["middlePanel_list_image", "middlePanel_list_new", "middlePanel_list_latest"])
        XCTAssertEqual(Array(scheduler.jobs.prefix(2)).map(\.deliveryOutcome), [.notSent, .notSent])
        XCTAssertEqual(Array(scheduler.jobs.prefix(2)).map(\.state), [.failed, .failed])
        XCTAssertEqual(scheduler.jobs[2], healthy)
        XCTAssertTrue(driver.sentUIDs.isEmpty)
        let beforeGeneration = await generator.recorded(); XCTAssertTrue(beforeGeneration.isEmpty)
        let oldReceipt = try CustomerMessageReceipts(root: root).receipts(uid: alias)["middlePanel_list_new"]
        XCTAssertNotNil(oldReceipt?.closedAt); XCTAssertNil(oldReceipt?.replySentAt)
        // After Start, other customer and repaired customer both proceed; neither stale text is sent.
        scheduler.start()
        for _ in 0..<16 { await scheduler.tick(); try await Task.sleep(for: .milliseconds(2)) }
        scheduler.stop()
        XCTAssertEqual(Set(driver.sentUIDs), ["GZC-10", canonical])
        XCTAssertFalse(driver.sentTexts.contains { $0.hasPrefix("stale") })
        let generated = await generator.recorded()
        XCTAssertEqual(generated.first?.batch?.customerMessageIDs, recovered.capture.batch?.customerMessageIDs)
    }

    func testAliasRecoveryWaitsForFreshProofHistoryWhileHealthyJobStillSends() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = PDDConversationIdentityStore(root: root)
        let canonical = PDDConversationKey.make(locator: .init(nickname: "A***"))
        let alias = PDDConversationIdentityStore.anchoredUID(messageIDs: ["new"])
        try registry.remember(uid: canonical, messageIDs: ["old"], stableID: nil, boundary: nil)
        try registry.remember(uid: alias, messageIDs: ["new"], stableID: nil, boundary: nil, provisional: true)
        _ = try registry.reconcileVerifiedThread(messageIDs: ["old", "new"], stableID: nil, boundary: nil)
        let history = [message("new", "question")]; let timeline = try AutoReplyTimeline.make(messages: history)
        let capture = AutoReplyCapture(uid: alias, fullHistory: history, batch: try timeline.freeze(after: .empty), customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
        let broken = AutoReplyJob(id: UUID(), uid: alias, sequence: 1, state: .ready, capture: capture, reply: "do not send", deliveryOutcome: .notSent,
            confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil, lastError: nil)
        var healthy = job(uid: "GZC-10", boundary: "healthy", state: .ready); healthy.sequence = 2
        var state = AutoReplyPersistentState(); state.jobs = [broken, healthy]; state.nextSequence = 2
        try AutoReplyStore(rootDirectory: root).save(state)
        let driver = SchedulerDriver(); let scheduler = try AutoReplyScheduler(driver: driver, generator: Generator(), store: .init(rootDirectory: root))
        scheduler.start()
        for _ in 0..<6 { await scheduler.tick(); try await Task.sleep(for: .milliseconds(2)) }
        scheduler.stop()
        XCTAssertEqual(driver.sentUIDs, ["GZC-10"])
        XCTAssertEqual(scheduler.jobs.first?.state, .ready)
        XCTAssertEqual(scheduler.jobs.count, 2)
        XCTAssertEqual(try AutoReplyStore(rootDirectory: root).load().events.filter { $0.kind == "identity-recovery-waiting" }.count, 1)
    }

    func testAlreadyAnsweredAliasClosesWithoutReplayOrWaitingForever() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let canonical = PDDConversationKey.make(locator: .init(nickname: "A***"))
        let alias = PDDConversationIdentityStore.anchoredUID(messageIDs: ["new"])
        let registry = PDDConversationIdentityStore(root: root)
        try registry.remember(uid: canonical, messageIDs: ["old"], stableID: nil, boundary: nil)
        try registry.remember(uid: alias, messageIDs: ["new"], stableID: nil, boundary: nil, provisional: true)
        _ = try registry.reconcileVerifiedThread(messageIDs: ["old", "new"], stableID: nil, boundary: nil)
        let history = [message("new", "question")]; let timeline = try AutoReplyTimeline.make(messages: history)
        let original = AutoReplyCapture(uid: alias, fullHistory: history, batch: try timeline.freeze(after: .empty), customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
        let answered = AutoReplyCapture(uid: canonical, fullHistory: history, batch: original.batch, customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
        let receipts = CustomerMessageReceipts(root: root)
        try receipts.capture(original); try receipts.capture(answered); try receipts.replied(answered)
        var state = AutoReplyPersistentState()
        state.jobs = [.init(id: UUID(), uid: alias, sequence: 1, state: .ready, capture: original, reply: "stale",
            deliveryOutcome: .notSent, confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil, lastError: nil)]
        state.nextSequence = 1; try AutoReplyStore(rootDirectory: root).save(state)
        let driver = SchedulerDriver(); let scheduler = try AutoReplyScheduler(driver: driver, generator: Generator(), store: .init(rootDirectory: root))
        scheduler.start(); await scheduler.tick(); scheduler.stop()
        XCTAssertTrue(driver.sentUIDs.isEmpty)
        XCTAssertEqual(scheduler.jobs.count, 1)
        XCTAssertEqual(scheduler.jobs[0].state, .failed)
        XCTAssertEqual(scheduler.jobs[0].deliveryOutcome, .notSent)
        XCTAssertNil(try receipts.receipts(uid: alias)["new"]?.replySentAt)
        XCTAssertNotNil(try receipts.receipts(uid: alias)["new"]?.closedAt)
    }

    private actor RecordingGenerator: AutoReplyGenerating {
        private var captures: [AutoReplyCapture] = []
        func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult {
            captures.append(capture); return .init(reply: "fresh complete answer", threadID: "test")
        }
        func recorded() -> [AutoReplyCapture] { captures }
    }

    func testUnresolvedVisitorDoesNotBlockHealthyChatAndReportsAfterThirtySeconds() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let visitor = tree("游客", ids: []); let healthy = tree("B***", ids: ["healthy"], activeRow: 4)
        let backend = Backend([visitor, visitor, healthy, healthy, visitor, visitor])
        let driver = PDDAXConversationDriver(backend: backend, chatStore: .init(rootDirectory: root), allowedUIDs: nil,
            unreadEvidence: Unread([.init(rowID: .init(rawValue: 2), visibleLabel: "游客"), .init(rowID: .init(rawValue: 4), visibleLabel: "B***")]), now: { clock.date })
        let unresolved = try await driver.discover()
        let resolved = try await driver.discover()
        XCTAssertTrue(unresolved.isEmpty)
        XCTAssertNotNil(resolved.first)
        clock.date += 30
        let stillUnresolved = try await driver.discover()
        XCTAssertTrue(stillUnresolved.isEmpty)
        XCTAssertTrue(driver.takeConversationDiagnostics().contains { $0.kind == "conversation-identity-attention" })
        XCTAssertFalse(driver.conversationLocatorsSnapshot()?.keys.contains(where: PDDConversationIdentityStore.isSharedVisitorUID) == true)
    }

    func testGenericLabelAloneCannotVerifyRecipientButExactRecordedMessagesCan() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let current = tree("游客", ids: ["proof"])
        let canonical = PDDConversationIdentityStore.anchoredUID(messageIDs: ["proven"])
        let registry = PDDConversationIdentityStore(root: root)
        try registry.remember(uid: canonical, messageIDs: ["middlePanel_list_proof"], stableID: nil, boundary: nil)
        let driver = PDDAXConversationDriver(backend: Backend([current]), chatStore: .init(rootDirectory: root), allowedUIDs: nil)
        driver.restoreConversationLocators([canonical: .init(nickname: "A***")])
        XCTAssertNil(PDDAXRecipientVerification.reason(uid: canonical, locator: .init(nickname: "游客"), tree: current))
        XCTAssertNotNil(driver.recipientVerificationReason(uid: canonical, expectedCustomerMessageIDs: [], in: current))
        XCTAssertNil(driver.recipientVerificationReason(uid: PDDConversationIdentityStore.anchoredUID(messageIDs: ["other"]), expectedCustomerMessageIDs: [], in: current))
    }

    func testIdentityStoreRejectsConflictsWithoutReassigningAnotherCustomersMessages() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = PDDConversationIdentityStore(root: root)
        try registry.remember(uid: "GZC-1", messageIDs: ["m1"], stableID: "platform-one", boundary: "t1")
        XCTAssertThrowsError(try registry.remember(uid: "GZC-2", messageIDs: ["m1"], stableID: nil, boundary: nil))
        try registry.remember(uid: "GZC-2", messageIDs: ["m2"], stableID: "platform-two", boundary: "t2")
        XCTAssertThrowsError(try registry.owner(messageIDs: ["m1", "m2"]))
        XCTAssertEqual(try registry.owner(messageIDs: ["m1"]), "GZC-1")
        XCTAssertThrowsError(try registry.remember(uid: PDDConversationKey.make(locator: .init(nickname: "游客")), messageIDs: ["new"], stableID: nil, boundary: nil))
    }

    func testLegacyRetryClosesOnlyWhenSameIncomingBoundaryHasAProvenTerminalDisposition() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var state = AutoReplyPersistentState()
        let source = job(uid: "visitor-alias", boundary: "same", state: .ready)
        var proof = job(uid: "canonical", boundary: "same", state: .failed)
        proof.lastError = "转入会话已回复或转接边界已变化；已丢弃当前批次并继续"
        let other = job(uid: "other-customer", boundary: "different", state: .ready)
        state.jobs = [source, proof, other]
        state.pendingCaptureRequests = [.init(uid: source.uid, kind: .tail, baseCursor: source.capture.customerCursor)]
        XCTAssertTrue(PDDConversationIdentityRecovery.retireSupersededHandoffs(in: &state, root: root, at: Date()))
        XCTAssertEqual(state.jobs[0].state, .failed)
        XCTAssertEqual(state.jobs[0].deliveryOutcome, .notSent)
        XCTAssertEqual(state.jobs[2].state, .ready)
        XCTAssertTrue(state.pendingCaptureRequests.isEmpty)
        XCTAssertFalse(PDDConversationIdentityRecovery.retireSupersededHandoffs(in: &state, root: root, at: Date()))
    }

    func testRecoveryCopiesOnlyProvenTargetsAndKeepsVideoEvidence() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PerUserChatStore(rootDirectory: root)
        _ = try store.mergeAXFirst(uid: "GZC-10", messages: [message("context", "own history")])
        let history = [message("foreign", "another customer's history"), message("target", "current question")]
        let timeline = try AutoReplyTimeline.make(messages: history)
        let event = try XCTUnwrap(timeline.freeze(after: timeline.prefixCursor(at: 1)!))
        let attachment = AutoReplyVideoAttachment(messageID: "target", localURL: URL(fileURLWithPath: "/tmp/kept.mp4"), sha256: "sha", byteCount: 1,
            durationSeconds: 1, width: 1, height: 1, videoCodec: "H264", audioCodec: nil, frames: [], transcript: nil, diagnostic: nil)
        let source = AutoReplyCapture(uid: "legacy", fullHistory: history, batch: event, customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [], videoAttachments: [attachment])
        let recovered = try XCTUnwrap(PDDConversationIdentityRecovery.capture(source, canonicalUID: "GZC-10", root: root))
        XCTAssertEqual(recovered.fullHistory.map(\.id), ["context", "target"])
        XCTAssertEqual(recovered.videoAttachments, [attachment])
        XCTAssertEqual(recovered.batch?.customerMessageIDs, ["target"])
        XCTAssertEqual(source.fullHistory.count, 2)
    }

    func testUnverifiedLegacyVisitorWaitsWithoutSendingOrBlockingHealthyCustomer() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let alias = PDDConversationKey.make(locator: .init(nickname: "游客"))
        let source = job(uid: alias, boundary: "unknown", state: .ready)
        var healthy = job(uid: "GZC-10", boundary: "healthy", state: .ready)
        healthy.sequence = 2
        var state = AutoReplyPersistentState(); state.jobs = [source, healthy]; state.nextSequence = 2
        state.pendingCaptureRequests = [.init(uid: alias, kind: .tail, baseCursor: .empty)]
        try AutoReplyStore(rootDirectory: root).save(state)
        let driver = SchedulerDriver()
        let scheduler = try AutoReplyScheduler(driver: driver, generator: Generator(), store: .init(rootDirectory: root))
        scheduler.start()
        for _ in 0..<8 { await scheduler.tick(); try await Task.sleep(for: .milliseconds(2)) }
        scheduler.stop()
        XCTAssertEqual(driver.sentUIDs, ["GZC-10"])
        XCTAssertEqual(scheduler.jobs.first?.state, .ready)
        XCTAssertEqual(scheduler.jobs.first?.deliveryOutcome, .notSent)
        XCTAssertFalse(driver.capturedUIDs.contains(alias))
        XCTAssertEqual(try AutoReplyStore(rootDirectory: root).load().pendingCaptureRequests.first?.uid, alias)
    }

    func testSchedulerReassignsUnsentAliasWorkWithoutSendingItsOldReplyOrMarkingItSent() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let canonical = PDDConversationIdentityStore.anchoredUID(messageIDs: ["canonical"]); let alias = PDDConversationKey.make(locator: .init(nickname: "游客"))
        let history = [message("target", "current question")]; let timeline = try AutoReplyTimeline.make(messages: history)
        let capture = AutoReplyCapture(uid: alias, fullHistory: history, batch: try timeline.freeze(after: .empty), customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
        var state = AutoReplyPersistentState()
        state.jobs = [.init(id: UUID(), uid: alias, sequence: 1, state: .ready, capture: capture, reply: "old alias reply", deliveryOutcome: .notSent,
            confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil, lastError: nil)]
        state.nextSequence = 1
        try AutoReplyStore(rootDirectory: root).save(state)
        try CustomerMessageReceipts(root: root).capture(capture)
        try PDDConversationIdentityStore(root: root).remember(uid: canonical, messageIDs: ["target"], stableID: nil, boundary: nil)
        let driver = SchedulerDriver()
        let scheduler = try AutoReplyScheduler(driver: driver, generator: Generator(), store: .init(rootDirectory: root))
        scheduler.start()
        for _ in 0..<12 { await scheduler.tick(); try await Task.sleep(for: .milliseconds(2)) }
        scheduler.stop()
        XCTAssertEqual(driver.sentUIDs, [canonical])
        XCTAssertEqual(driver.sentTexts, ["recovered reply"])
        let oldReceipt = try CustomerMessageReceipts(root: root).receipts(uid: alias)["target"]
        XCTAssertNotNil(oldReceipt?.closedAt); XCTAssertNil(oldReceipt?.replySentAt)
        XCTAssertEqual(scheduler.jobs.first?.deliveryOutcome, .notSent)
    }

    private final class Clock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 100) }
    private final class Backend: PDDAXBackend {
        var trees: [PDDAXSemanticTree]; var pressed: [AXElementToken] = []
        init(_ trees: [PDDAXSemanticTree]) { self.trees = trees }
        func readSemanticTree() throws -> PDDAXSemanticTree { trees.count > 1 ? trees.removeFirst() : trees[0] }
        func performPress(_ id: AXElementToken) throws { pressed.append(id) }
        func setValue(_ text: String, on id: AXElementToken) throws {}
        func value(of id: AXElementToken) throws -> String { "" }
    }
    private final class Unread: PDDUnreadEvidenceDetecting {
        let rows: [PDDConversationRow<AXElementToken>]
        init(_ rows: [PDDConversationRow<AXElementToken>]) { self.rows = rows }
        func unreadRows(in tree: PDDAXSemanticTree) async throws -> [PDDConversationRow<AXElementToken>] { rows }
    }
    private final class SchedulerDriver: AutoReplyAutomationDriver {
        var identity: PDDAXConversationDriver?
        func reconcileVisibleIdentity(in tree: PDDAXSemanticTree) throws { try identity?.reconcileVisibleIdentity(in: tree) }
        var sentUIDs: [String] = []; var sentTexts: [String] = []; var capturedUIDs: [String] = []
        func discover() async throws -> [AutoReplyDiscovery] { [] }
        func capture(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture { capturedUIDs.append(uid); return .init(uid: uid, fullHistory: [], batch: nil, customerCursor: cursor, unexpectedServiceMessageIDs: []) }
        func preflight(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture? { nil }
        func send(uid: String, text: String, expectedCustomerCursor: AutoReplyCursor) async throws -> AutoReplyDeliveryResult {
            sentUIDs.append(uid); sentTexts.append(text); return .sent(serviceMessageID: "sent")
        }
    }
    private actor Generator: AutoReplyGenerating {
        func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult { .init(reply: "recovered reply", threadID: "test") }
    }
}

private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
private func message(_ id: String, _ text: String) -> PDDChatMessage { .init(id: id, sender: .customer, content: text, displayTime: nil, kind: .text, capturedAt: Date()) }
private func customerNode(_ id: String) -> AXNodeSnapshot {
    .init(role: "AXGroup", attributes: [("AXDOMClassList", "[onemsg]"), ("AXDOMIdentifier", "middlePanel_list_\(id)")], children: [
        .init(role: "AXGroup", attributes: [("AXDOMClassList", "[buyer-item]")], children: [
            .init(role: "AXGroup", attributes: [("AXDOMClassList", "[msg-content-box]"), ("AXValue", "question")])])])
}
private func tree(_ label: String, ids: [String], activeRow: Int = 2) -> PDDAXSemanticTree {
    func node(_ id: Int, parent: Int? = nil, role: String, value: String? = nil, classes: [String] = [], actions: [String] = [], settable: Bool = false) -> PDDAXSemanticNode<AXElementToken> {
        .init(id: .init(rawValue: id), parentID: parent.map { .init(rawValue: $0) }, role: role, value: value, title: nil, domIdentifier: nil,
              domClasses: Set(classes), actionNames: Set(actions), isSettable: settable)
    }
    return .init(rootSnapshot: .init(role: "AXWindow", children: ids.map(customerNode)), nodes: [
        node(1, role: "AXGroup", classes: ["chat-list-box"]),
        node(activeRow, parent: 1, role: "AXRow", classes: ["chat-item-box", "active"], actions: ["AXPress"]),
        node(activeRow + 1, parent: activeRow, role: "AXStaticText", value: label, classes: ["chat-nickname"]),
        node(10, role: "AXGroup", classes: ["middle-panel"]), node(11, parent: 10, role: "AXTextArea", settable: true)])
}
private func job(uid: String, boundary: String, state: AutoReplyJobState) -> AutoReplyJob {
    .init(id: UUID(), uid: uid, sequence: 1, state: state,
        capture: .init(uid: uid, fullHistory: [], batch: .incomingHandoff(key: boundary, cursor: .empty), customerCursor: .empty, unexpectedServiceMessageIDs: []),
        reply: "ack", deliveryOutcome: .notSent, confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil, lastError: nil)
}
