import XCTest
@testable import PDDAXReader

final class PDDAXRecipientVerificationTests: XCTestCase {
    func testExactCustomerMessageVerifiesAfterMaskedNicknameChanges() {
        let known = PDDConversationLocator(nickname: "A**f")
        for label in ["A***", "游客"] {
            let current = PDDConversationLocator(nickname: label)
            XCTAssertEqual(PDDAXRecipientVerification.reason(uid: PDDConversationKey.make(locator: known), locator: known,
                expectedAXMessageIDs: ["middlePanel_list_target"],
                tree: makeTree(rows: [(current, true)], messages: [customer("target")])), "ax-customer-message-id")
        }
    }

    func testChangedMaskAloneCannotVerifyRecipient() {
        let known = PDDConversationLocator(nickname: "A**f")
        XCTAssertNil(PDDAXRecipientVerification.reason(uid: PDDConversationKey.make(locator: known), locator: known,
            expectedAXMessageIDs: ["middlePanel_list_missing"], tree: makeTree(rows: [(.init(nickname: "A***"), true)])))
    }

    func testUniqueActiveChatVerifiesWithoutOCRorMessageIDs() {
        let locator = PDDConversationLocator(nickname: "~***")
        let tree = makeTree(rows: [(locator, true)])
        XCTAssertEqual(PDDAXRecipientVerification.reason(uid: PDDConversationKey.make(locator: locator),
            expectedAXMessageIDs: ["missing-message"], tree: tree), "ax-unique-active-conversation")
    }

    func testStableConversationIDWorksWithDuplicateNicknamesAndMissingMessages() {
        let target = PDDConversationLocator(domIdentifier: "buyer-b", nickname: "S***")
        let other = PDDConversationLocator(domIdentifier: "buyer-a", nickname: "S***")
        XCTAssertEqual(PDDAXRecipientVerification.reason(uid: PDDConversationKey.make(locator: target), locator: target,
            tree: makeTree(rows: [(other, false), (target, true)])), "ax-conversation-id")
    }

    func testStableActiveIDVerifiesEvenWhenNicknameTextIsUnavailable() {
        let target = PDDConversationLocator(domIdentifier: "buyer-b", nickname: "S***")
        let row = AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[chat-item-box,active]"),
            ("AXDOMIdentifier", "buyer-b")])
        let tree = PDDAXSemanticTree(rootSnapshot: .init(role: "AXWindow", children: [row]), nodes: [])
        XCTAssertEqual(PDDAXRecipientVerification.reason(uid: PDDConversationKey.make(locator: target), locator: target,
            tree: tree), "ax-conversation-id")
    }

    func testConflictingActiveRowsBetweenSnapshotAndSemanticTreeWait() {
        let target = PDDConversationLocator(domIdentifier: "buyer-a", nickname: "S***")
        let base = makeTree(rows: [(target, true)])
        let nodes: [PDDAXSemanticNode<AXElementToken>] = [
            .init(id: .init(rawValue: 1), parentID: nil, role: "AXGroup", value: nil, title: nil,
                domIdentifier: nil, domClasses: ["chat-list-box"], actionNames: [], isSettable: false),
            .init(id: .init(rawValue: 2), parentID: .init(rawValue: 1), role: "AXRow", value: nil, title: nil,
                domIdentifier: "buyer-b", domClasses: ["active"], actionNames: ["AXPress"], isSettable: false),
            .init(id: .init(rawValue: 3), parentID: .init(rawValue: 2), role: "AXStaticText", value: "S***", title: nil,
                domIdentifier: nil, domClasses: ["nickname"], actionNames: [], isSettable: false)]
        XCTAssertNil(PDDAXRecipientVerification.reason(uid: PDDConversationKey.make(locator: target), locator: target,
            tree: .init(rootSnapshot: base.rootSnapshot, nodes: nodes)))
    }

    func testDuplicateNicknamesWithoutIndependentEvidenceWait() {
        let locator = PDDConversationLocator(nickname: "S***")
        XCTAssertNil(PDDAXRecipientVerification.reason(uid: PDDConversationKey.make(locator: locator), locator: locator,
            expectedAXMessageIDs: ["ocr-provisional-temp"], tree: makeTree(rows: [(locator, false), (locator, true)])))
    }

    func testContradictoryActiveIDRejectsEvenStaleMessageEvidence() {
        let target = PDDConversationLocator(domIdentifier: "buyer-a", nickname: "S***")
        let other = PDDConversationLocator(domIdentifier: "buyer-b", nickname: "S***")
        XCTAssertNil(PDDAXRecipientVerification.reason(uid: PDDConversationKey.make(locator: target), locator: target,
            expectedAXMessageIDs: ["middlePanel_list_target"], tree: makeTree(rows: [(other, true)], messages: [customer("target")])))
    }

    func testActualCustomerMessageCanVerifyWhenActiveMarkerIsTemporarilyMissing() {
        let locator = PDDConversationLocator(nickname: "S***")
        XCTAssertEqual(PDDAXRecipientVerification.reason(uid: PDDConversationKey.make(locator: locator), locator: locator,
            expectedAXMessageIDs: ["middlePanel_list_target"], tree: makeTree(rows: [], messages: [customer("target")])),
            "ax-customer-message-id")
    }

    func testMultipleActiveRowsCannotVerifyRecipient() {
        let locator = PDDConversationLocator(nickname: "S***")
        XCTAssertNil(PDDAXRecipientVerification.reason(uid: PDDConversationKey.make(locator: locator), locator: locator,
            expectedAXMessageIDs: ["middlePanel_list_target"], tree: makeTree(rows: [(locator, true), (locator, true)], messages: [customer("target")])))
    }

    func testServiceMessageCannotImpersonateCustomerIdentityEvidence() {
        let locator = PDDConversationLocator(nickname: "S***")
        let service = AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[onemsg]"),
            ("AXDOMIdentifier", "middlePanel_list_target")], children: [
                AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[cs-item]")], children: [
                    AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[msg-content-box]"), ("AXValue", "text")])])])
        XCTAssertNil(PDDAXRecipientVerification.reason(uid: PDDConversationKey.make(locator: locator), locator: locator,
            expectedAXMessageIDs: ["middlePanel_list_target"], tree: makeTree(rows: [], messages: [service])))
    }

    private func makeTree(rows: [(PDDConversationLocator, Bool)], messages: [AXNodeSnapshot] = []) -> PDDAXSemanticTree {
        let snapshots = rows.map { locator, active in
            var attrs = [("AXDOMClassList", active ? "[chat-item-box,active]" : "[chat-item-box]")]
            if let id = locator.domIdentifier { attrs.append(("AXDOMIdentifier", id)) }
            return AXNodeSnapshot(role: "AXGroup", attributes: attrs, children: [
                AXNodeSnapshot(role: "AXStaticText", attributes: [("AXDOMClassList", "[chat-nickname]"), ("AXValue", locator.nickname)])])
        }
        return .init(rootSnapshot: .init(role: "AXWindow", children: snapshots + messages), nodes: [])
    }

    private func customer(_ id: String) -> AXNodeSnapshot {
        .init(role: "AXGroup", attributes: [("AXDOMClassList", "[onemsg]"), ("AXDOMIdentifier", "middlePanel_list_\(id)")], children: [
            .init(role: "AXGroup", attributes: [("AXDOMClassList", "[buyer-item]")], children: [
                .init(role: "AXGroup", attributes: [("AXDOMClassList", "[msg-content-box]"), ("AXValue", "customer text")])])])
    }
}
