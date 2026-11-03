import XCTest
@testable import PDDAXReader

@MainActor
final class PDDAXReplySenderTests: XCTestCase {
    func testUniqueAXRecipientSendsWhenOCRIsUnavailableAndTriggerMessageIsMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = PDDConversationLocator(nickname: "~***")
        let targetUID = PDDConversationKey.make(locator: locator)
        let tree = controlOnlyTree(nickname: locator.nickname)
        let backend = ReplyFakeBackend(trees: [tree, tree, tree, tree], composerReadValues: ["", reply, reply, ""])
        let ocr = UnavailableReplyOCR()
        let opener = PDDAXConversationDriver(backend: backend, chatStore: .init(rootDirectory: root),
            allowedUIDs: nil, ocrSupplement: ocr)
        opener.restoreConversationLocators([targetUID: locator])
        let sender = PDDAXReplySender(backend: backend, opener: opener, pollIntervalNanoseconds: 0, logRoot: root)

        let result = try await sender.send(uid: targetUID, text: reply, expectedCustomerCursor: .empty,
            expectedCustomerMessageIDs: ["middlePanel_list_not_rendered"])

        guard case .sent = result else { return XCTFail("AX identity must permit delivery, got \(result)") }
        XCTAssertEqual(ocr.calls, 0)
        XCTAssertEqual(backend.pressSendCount, 1)
        XCTAssertEqual(backend.setValues, [reply])
        let log = try String(contentsOf: root.appendingPathComponent("logs/automation-steps.jsonl"))
        XCTAssertTrue(log.contains("ax-unique-active-conversation"))
        XCTAssertTrue(log.contains("ocr_required=false"))
    }

    func testAXConversationIDChangeBeforeSendStopsEvenWhenMaskedNicknameIsIdentical() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = PDDConversationLocator(nickname: "S***")
        let targetUID = PDDConversationKey.make(locator: locator)
        func identified(_ identifier: String) -> PDDAXSemanticTree {
            let controls = controlOnlyTree(nickname: "S***")
            let row = AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[chat-item-box,active]"),
                ("AXDOMIdentifier", identifier)], children: [
                    .init(role: "AXStaticText", attributes: [("AXDOMClassList", "[chat-nickname]"), ("AXValue", "S***")])])
            return .init(rootSnapshot: .init(role: "AXWindow", children: [row]), nodes: controls.nodes)
        }
        let initial = identified("buyer-a")
        let backend = ReplyFakeBackend(trees: [initial, initial, identified("buyer-b")], composerReadValues: ["", reply, reply])
        let opener = PDDAXConversationDriver(backend: backend, chatStore: .init(rootDirectory: root), allowedUIDs: nil)
        opener.restoreConversationLocators([targetUID: locator])
        let sender = PDDAXReplySender(backend: backend, opener: opener, pollIntervalNanoseconds: 0)

        let result = try await sender.send(uid: targetUID, text: reply, expectedCustomerCursor: .empty,
            expectedCustomerMessageIDs: ["ocr-provisional-missing"])

        XCTAssertEqual(result, .failedBeforeSend("发送前 UID 变化"))
        XCTAssertEqual(backend.pressSendCount, 0)
    }

    func testOCRMessageUsesRealReceiptAliasThroughOpeningWritingAndSend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let locator = PDDConversationLocator(domIdentifier: nil, nickname: "~***")
        let customerUID = PDDConversationKey.make(locator: locator)
        let controls = controlOnlyTree(nickname: "~***")
        let bubble = AXNodeSnapshot(role: "AXGroup", attributes: [
            ("AXDOMClassList", "[onemsg]"), ("AXDOMIdentifier", "middlePanel_list_actual")])
        let tree = PDDAXSemanticTree(rootSnapshot: .init(role: "AXWindow",
            children: controls.rootSnapshot.children + [bubble]), nodes: controls.nodes)
        let backend = ReplyFakeBackend(trees: [tree, tree, tree, tree], composerReadValues: ["", reply, reply, ""])
        let opener = PDDAXConversationDriver(backend: backend, chatStore: PerUserChatStore(rootDirectory: root), allowedUIDs: nil)
        opener.restoreConversationLocators([customerUID: locator])
        opener.restoreProvisionalReceipts([customerUID: [.init(provisionalMessageID: "ocr-provisional-temp",
            normalizedContent: "没有,我时间报给你", firstObservedAt: Date(), answered: false,
            absorbedAXMessageID: "middlePanel_list_actual")]])
        let sender = PDDAXReplySender(backend: backend, opener: opener, pollIntervalNanoseconds: 0)

        let result = try await sender.send(uid: customerUID, text: reply, expectedCustomerCursor: .empty,
            expectedCustomerMessageIDs: ["ocr-provisional-temp"])

        guard case .sent = result else { return XCTFail("Expected OCR reply to send, got \(result)") }
        XCTAssertEqual(backend.pressSendCount, 1)
        XCTAssertEqual(backend.setValues, [reply])
    }

    func testSendPreservesSnapshotsBeforeClickAndAfterConfirmation() async throws {
        let initial = controlOnlyTree(uid: uid, messages: [AXNodeSnapshot(role: "AXStaticText", attributes: [("AXValue", "initial")])])
        let beforePress = controlOnlyTree(uid: uid, messages: [AXNodeSnapshot(role: "AXStaticText", attributes: [("AXValue", "new-before-send")])])
        let confirmation = controlOnlyTree(uid: uid, messages: [AXNodeSnapshot(role: "AXStaticText", attributes: [("AXValue", "new-after-send")])])
        let backend = ReplyFakeBackend(trees: [initial, initial, beforePress, confirmation], composerReadValues: ["", reply, reply, ""])
        var observations: [String] = []
        let sender = PDDAXReplySender(backend: backend, opener: ReplyFakeOpener(backend: backend), pollIntervalNanoseconds: 0,
            observeSnapshot: { _, snapshot in observations.append(snapshot.children[0].attribute(named: "AXValue") ?? "") })
        let result = try await sender.send(uid: uid, text: reply, expectedCustomerCursor: .empty)
        guard case .sent = result else { return XCTFail("Expected sent") }
        XCTAssertEqual(observations, ["initial", "new-before-send", "new-after-send"])
        XCTAssertEqual(backend.pressSendCount, 1)
    }

    func testIncomingHandoffMarkerVerifiesBoundaryWithoutSearchingForFakeCustomerMessage() async throws {
        let tree = incomingHandoffTree()
        let key = try XCTUnwrap(PDDAXIncomingTransfer.unansweredHandoff(in: tree.rootSnapshot)?.boundaryKey)
        let backend = ReplyFakeBackend(trees: [tree, tree, tree, tree], composerReadValues: ["", reply, reply, ""])
        let opener = ReplyFakeOpener(backend: backend)
        let sender = PDDAXReplySender(backend: backend, opener: opener, pollIntervalNanoseconds: 0)
        let result = try await sender.send(uid: uid, text: reply, expectedCustomerCursor: .empty,
            expectedCustomerMessageIDs: [FrozenCustomerBatch.incomingHandoffPrefix + key])
        guard case .sent = result else { return XCTFail("Expected confirmed handoff reply, got \(result)") }
        XCTAssertEqual(opener.receivedExpectedMessageIDs, [[]])
        XCTAssertEqual(backend.pressSendCount, 1)
    }

    func testIncomingHandoffIsDiscardedIfAnotherReplyArrivesBeforeSend() async throws {
        let initial = incomingHandoffTree()
        let key = try XCTUnwrap(PDDAXIncomingTransfer.unansweredHandoff(in: initial.rootSnapshot)?.boundaryKey)
        let backend = ReplyFakeBackend(trees: [initial, initial, controlOnlyTree(uid: uid)],
            composerReadValues: ["", reply, reply])
        let result = try await makeSender(backend: backend).send(uid: uid, text: reply,
            expectedCustomerCursor: .empty,
            expectedCustomerMessageIDs: [FrozenCustomerBatch.incomingHandoffPrefix + key])
        XCTAssertEqual(result, .discardedBeforeSend("转入会话已回复或转接边界已变化"))
        XCTAssertEqual(backend.pressSendCount, 0)
    }

    private func incomingHandoffTree() -> PDDAXSemanticTree {
        controlOnlyTree(uid: uid, messages: [
            AXNodeSnapshot(role: "AXWebArea", attributes: [("AXTitle", "小硕")], children: [
                AXNodeSnapshot(role: "AXStaticText", attributes: [("AXValue", "主账号 将该会话转移给 小硕，请及时处理")])
            ])
        ])
    }

    func testSendSucceedsWithoutAnyAXChatMessageNodes() async throws {
        let backend = ReplyFakeBackend(
            trees: [controlOnlyTree(uid: uid), controlOnlyTree(uid: uid), controlOnlyTree(uid: uid), controlOnlyTree(uid: uid)],
            composerReadValues: ["", reply, reply, ""]
        )
        let result = try await makeSender(backend: backend).send(
            uid: uid, text: reply,
            expectedCustomerCursor: AutoReplyCursor(count: 7, digest: String(repeating: "a", count: 64))
        )
        guard case .sent(let messageID) = result else { return XCTFail("expected sent, got \(result)") }
        XCTAssertTrue(messageID.hasPrefix("ax-send-"))
        XCTAssertEqual(backend.pressSendCount, 1)
        XCTAssertEqual(backend.setValues, [reply])
        XCTAssertGreaterThanOrEqual(backend.readTreeCount, 4)
    }

    func testUnknownDraftIsOverwrittenAndDoesNotBlockAutomaticSend() async throws {
        let backend = ReplyFakeBackend(
            trees: [controlOnlyTree(uid: uid), controlOnlyTree(uid: uid), controlOnlyTree(uid: uid), controlOnlyTree(uid: uid)],
            composerValue: "人工草稿", composerReadValues: ["人工草稿", reply, reply, ""]
        )
        let result = try await makeSender(backend: backend).send(
            uid: uid, text: reply, expectedCustomerCursor: .empty
        )
        guard case .sent = result else { return XCTFail("expected sent, got \(result)") }
        XCTAssertEqual(backend.setValues, [reply])
        XCTAssertEqual(backend.pressSendCount, 1)
    }

    func testMaskedNicknameConversationUsesActiveRowKeyForSendVerification() async throws {
        let nickname = "S***"
        let nicknameUID = PDDConversationKey.make(
            locator: PDDConversationLocator(domIdentifier: nil, nickname: nickname)
        )
        let tree = controlOnlyTree(nickname: nickname)
        let backend = ReplyFakeBackend(
            trees: [tree, tree, tree, tree],
            composerReadValues: ["", reply, reply, ""]
        )

        let result = try await makeSender(backend: backend).send(
            uid: nicknameUID, text: reply, expectedCustomerCursor: .empty
        )

        guard case .sent = result else { return XCTFail("expected sent, got \(result)") }
        XCTAssertEqual(backend.setValues, [reply])
        XCTAssertEqual(backend.pressSendCount, 1)
    }

    func testComposerWithoutRecipientEvidenceWaitsBeforeWriting() async throws {
        let nicknameUID = PDDConversationKey.make(
            locator: PDDConversationLocator(domIdentifier: nil, nickname: "c*y")
        )
        let tree = controlOnlyTree(uid: "")
        let backend = ReplyFakeBackend(
            trees: [tree, tree, tree, tree],
            composerReadValues: ["", reply, reply, ""]
        )

        let result = try await makeSender(backend: backend).send(
            uid: nicknameUID, text: reply, expectedCustomerCursor: .empty
        )

        XCTAssertEqual(result, .failedBeforeSend("写入前 UID 不匹配"))
        XCTAssertEqual(backend.pressSendCount, 0)
        XCTAssertTrue(backend.setValues.isEmpty)
    }

    func testExactExistingDraftSendsWithoutRewriting() async throws {
        let backend = ReplyFakeBackend(
            trees: [controlOnlyTree(uid: uid), controlOnlyTree(uid: uid), controlOnlyTree(uid: uid), controlOnlyTree(uid: uid)],
            composerValue: reply, composerReadValues: [reply, reply, ""]
        )
        let result = try await makeSender(backend: backend).send(
            uid: uid, text: reply, expectedCustomerCursor: .empty
        )
        guard case .sent = result else { return XCTFail("expected sent, got \(result)") }
        XCTAssertTrue(backend.setValues.isEmpty)
        XCTAssertEqual(backend.pressSendCount, 1)
    }

    func testUIDChangesAfterWriteFailsBeforeSend() async throws {
        let backend = ReplyFakeBackend(
            trees: [controlOnlyTree(uid: uid), controlOnlyTree(uid: "GZC-000002")],
            composerReadValues: ["", reply]
        )
        let result = try await makeSender(backend: backend).send(
            uid: uid, text: reply, expectedCustomerCursor: .empty
        )
        XCTAssertEqual(result, .failedBeforeSend("写入后 UID 变化"))
        XCTAssertEqual(backend.pressSendCount, 0)
    }

    func testNoComposerClearAfterPressReturnsUncertainAndNeverPressesAgain() async throws {
        let tree = controlOnlyTree(uid: uid)
        let backend = ReplyFakeBackend(
            trees: [tree, tree, tree, tree], composerReadValues: ["", reply, reply, reply]
        )
        let result = try await makeSender(backend: backend, confirmationTimeout: 0).send(
            uid: uid, text: reply, expectedCustomerCursor: .empty
        )
        XCTAssertEqual(result, .uncertain("发送后输入框未清空，发送结果待后续会话核对"))
        XCTAssertEqual(backend.pressSendCount, 1)
    }

    func testAXMessageContentsCannotChangeSendDecision() async throws {
        let poison = AXNodeSnapshot(
            role: "AXGroup",
            attributes: [("AXDOMClassList", "[onemsg]"), ("AXDOMIdentifier", "middlePanel_list_invalid")],
            children: [AXNodeSnapshot(role: "AXStaticText", attributes: [("AXValue", "错误的AX正文")])]
        )
        let tree = controlOnlyTree(uid: uid, messages: [poison])
        let backend = ReplyFakeBackend(
            trees: [tree, tree, tree, tree], composerReadValues: ["", reply, reply, ""]
        )
        let result = try await makeSender(backend: backend).send(
            uid: uid, text: reply,
            expectedCustomerCursor: AutoReplyCursor(count: 99, digest: String(repeating: "f", count: 64))
        )
        guard case .sent = result else { return XCTFail("expected sent, got \(result)") }
        XCTAssertEqual(backend.pressSendCount, 1)
    }

    func testSendPassesTargetCustomerMessageIDsToConversationOpener() async throws {
        let tree = controlOnlyTree(uid: uid)
        let backend = ReplyFakeBackend(
            trees: [tree, tree, tree, tree],
            composerReadValues: ["", reply, reply, ""]
        )
        let opener = ReplyFakeOpener(backend: backend)
        let sender = PDDAXReplySender(
            backend: backend, opener: opener,
            confirmationTimeout: 0.1, pollIntervalNanoseconds: 0
        )

        _ = try await sender.send(
            uid: uid, text: reply, expectedCustomerCursor: .empty,
            expectedCustomerMessageIDs: ["middlePanel_list_target"]
        )

        XCTAssertEqual(opener.receivedExpectedMessageIDs, [["middlePanel_list_target"]])
    }

    private let uid = "GZC-000001"
    private let reply = "请重新插拔电源"

    private func makeSender(backend: ReplyFakeBackend, confirmationTimeout: TimeInterval = 0.1) -> PDDAXReplySender {
        PDDAXReplySender(
            backend: backend, opener: ReplyFakeOpener(backend: backend),
            confirmationTimeout: confirmationTimeout, pollIntervalNanoseconds: 0
        )
    }

    private func controlOnlyTree(uid: String, messages: [AXNodeSnapshot] = []) -> PDDAXSemanticTree {
        PDDAXSemanticTree(
            rootSnapshot: AXNodeSnapshot(
                role: "AXWindow", attributes: [("AXValue", uid)], children: messages
            ),
            nodes: [
                semantic(1, role: "AXGroup", classes: ["chat-panel"]),
                semantic(2, parent: 1, role: "AXTextArea", settable: true),
                semantic(3, parent: 1, role: "AXButton", value: "发送", actions: ["AXPress"])
            ]
        )
    }

    private func controlOnlyTree(nickname: String) -> PDDAXSemanticTree {
        PDDAXSemanticTree(
            rootSnapshot: AXNodeSnapshot(
                role: "AXWindow",
                children: [
                    AXNodeSnapshot(
                        role: "AXGroup",
                        attributes: [("AXDOMClassList", "[chat-item-box, active]")],
                        children: [
                            AXNodeSnapshot(
                                role: "AXGroup",
                                attributes: [("AXDOMClassList", "[chat-nickname]")],
                                children: [
                                    AXNodeSnapshot(
                                        role: "AXStaticText",
                                        attributes: [("AXValue", nickname)]
                                    )
                                ]
                            )
                        ]
                    )
                ]
            ),
            nodes: [
                semantic(1, role: "AXGroup", classes: ["chat-panel"]),
                semantic(2, parent: 1, role: "AXTextArea", settable: true),
                semantic(3, parent: 1, role: "AXButton", value: "发送", actions: ["AXPress"])
            ]
        )
    }

    private func semantic(
        _ id: Int, parent: Int? = nil, role: String, value: String? = nil,
        classes: Set<String> = [], actions: Set<String> = [], settable: Bool = false
    ) -> PDDAXSemanticNode<AXElementToken> {
        .init(
            id: .init(rawValue: id), parentID: parent.map { .init(rawValue: $0) },
            role: role, value: value, title: nil, domIdentifier: nil,
            domClasses: classes, actionNames: actions, isSettable: settable
        )
    }
}

@MainActor
private final class ReplyFakeOpener: PDDConversationOpening {
    let backend: ReplyFakeBackend
    private(set) var receivedExpectedMessageIDs: [Set<String>] = []
    init(backend: ReplyFakeBackend) { self.backend = backend }
    func openAndResolve(uid: String) async throws -> PDDAXSemanticTree { try backend.readSemanticTree() }
    func openAndResolve(
        uid: String, expectedCustomerMessageIDs: Set<String>
    ) async throws -> PDDAXSemanticTree {
        receivedExpectedMessageIDs.append(expectedCustomerMessageIDs)
        return try backend.readSemanticTree()
    }
}

@MainActor
private final class ReplyFakeBackend: PDDAXBackend {
    var trees: [PDDAXSemanticTree]
    var composerValue: String
    private(set) var setValues: [String] = []
    private(set) var pressSendCount = 0
    private(set) var readTreeCount = 0
    private var composerReadValues: [String]

    init(trees: [PDDAXSemanticTree], composerValue: String = "", composerReadValues: [String] = []) {
        self.trees = trees
        self.composerValue = composerValue
        self.composerReadValues = composerReadValues
    }
    func readSemanticTree() throws -> PDDAXSemanticTree {
        readTreeCount += 1
        guard !trees.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return trees.count == 1 ? trees[0] : trees.removeFirst()
    }
    func performPress(_ id: AXElementToken) throws { pressSendCount += 1 }
    func setValue(_ text: String, on id: AXElementToken) throws {
        composerValue = text
        setValues.append(text)
    }
    func value(of id: AXElementToken) throws -> String {
        if !composerReadValues.isEmpty { return composerReadValues.removeFirst() }
        return composerValue
    }
}

@MainActor
private final class UnavailableReplyOCR: PDDOCRSupplementing {
    var calls = 0
    func messages(uid: String) async throws -> [PDDOCRMessage] {
        calls += 1
        throw CocoaError(.fileReadUnknown)
    }
}
