import XCTest
@testable import PDDAXReader

final class PDDAXIncomingTransferTests: XCTestCase {
    func testRepeatedIncomingTransfersWithDistinctNoticeIDsCreateDistinctRevisions() throws {
        func systemNotice(_ id: String) -> AXNodeSnapshot {
            AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[onemsg]"),
                ("AXDOMIdentifier", id)], children: [notice("主账号 将该会话转移给 小硕，请及时处理")])
        }
        let first = try XCTUnwrap(PDDAXIncomingTransfer.unansweredHandoff(in: page([systemNotice("transfer-1")])))
        let second = try XCTUnwrap(PDDAXIncomingTransfer.unansweredHandoff(in: page([systemNotice("transfer-2")])))
        XCTAssertNotEqual(first.boundaryKey, second.boundaryKey)
        func capture(_ key: String) -> AutoReplyCapture {
            AutoReplyCapture(uid: "customer", fullHistory: [], batch: .incomingHandoff(key: key, cursor: .empty),
                customerCursor: .empty, unexpectedServiceMessageIDs: [])
        }
        XCTAssertNotEqual(try AutoReplyRevision.derived(from: capture(first.boundaryKey), legacyOrdinal: 1),
            try AutoReplyRevision.derived(from: capture(second.boundaryKey), legacyOrdinal: 1))
        XCTAssertEqual(PDDAXIncomingTransfer.latestTransferRecipient(in: page([systemNotice("transfer-1")])), "小硕")
    }

    func testTransferDoesNotRestoreRequestsBeforeBoundary() throws {
        let root = page([message("1", true, "教程"), message("2", true, "把使用教程发给我"),
                         message("3", false, "您好，亲爱的"), notice("花儿 将该会话转移给 小硕，并留言：催发货")])
        let handoff = try XCTUnwrap(PDDAXIncomingTransfer.unansweredHandoff(in: root))
        XCTAssertEqual(handoff.priorCustomerIDs, ["middlePanel_list_1", "middlePanel_list_2"])
        XCTAssertTrue(handoff.currentCustomerIDs.isEmpty)
        XCTAssertTrue(PDDAXIncomingTransfer.customerIDsForUnansweredHandoff(in: root).isEmpty)
        let history = PDDChatParser.parse(root: root).messages
        XCTAssertNil(try PDDAXIncomingTransfer.recoveryCursor(
            in: history, customerIDs: handoff.currentCustomerIDs
        ))
    }

    func testTransferProcessesOnlyCustomerMessagesAfterBoundary() throws {
        let root = page([
            message("1", true, "transfer me"),
            message("2", false, "How can I help?"),
            notice("花儿 将该会话转移给 小硕，请及时处理"),
            message("3", true, "My printer has no power"),
            message("4", true, "The model is M880")
        ])
        let handoff = try XCTUnwrap(PDDAXIncomingTransfer.unansweredHandoff(in: root))
        XCTAssertEqual(handoff.priorCustomerIDs, ["middlePanel_list_1"])
        XCTAssertEqual(handoff.currentCustomerIDs, ["middlePanel_list_3", "middlePanel_list_4"])
        let history = PDDChatParser.parse(root: root).messages
        let cursor = try XCTUnwrap(PDDAXIncomingTransfer.recoveryCursor(
            in: history, customerIDs: handoff.currentCustomerIDs
        ))
        XCTAssertEqual(cursor.count, 1)
        XCTAssertEqual(
            try AutoReplyTimeline.make(messages: history).freeze(after: cursor)?.events.map(\.messageID),
            ["middlePanel_list_3", "middlePanel_list_4"]
        )
    }

    func testIgnoresOutgoingTransferAndCompletedIncomingHandoff() {
        XCTAssertTrue(PDDAXIncomingTransfer.customerIDsForUnansweredHandoff(in: page([
            message("1", true, "教程"), notice("小硕 将该会话转移给 主账号，请及时处理")])).isEmpty)
        XCTAssertTrue(PDDAXIncomingTransfer.customerIDsForUnansweredHandoff(in: page([
            message("1", true, "教程"), notice("主账号 将该会话转移给 小硕，请及时处理"),
            message("2", false, "请确认具体型号")])).isEmpty)
    }

    func testCustomerQuotedTransferIsNotAPlatformNotice() {
        let root = page([message("1", true, "主账号 将该会话转移给 小硕，请及时处理")])
        XCTAssertTrue(PDDAXIncomingTransfer.customerIDsForUnansweredHandoff(in: root).isEmpty)
    }

    func testTransferPreviewFindsSidebarRowWithoutScreenshotRedDot() {
        func node(_ id: Int, _ parent: Int?, _ role: String, _ value: String?, _ classes: Set<String> = []) -> PDDAXSemanticNode<AXElementToken> {
            PDDAXSemanticNode(id: AXElementToken(rawValue: id), parentID: parent.map { AXElementToken(rawValue: $0) },
                role: role, value: value, title: nil, domIdentifier: nil, domClasses: classes,
                actionNames: [], isSettable: false)
        }
        let tree = PDDAXSemanticTree(rootSnapshot: page([]), nodes: [
            node(1, nil, "AXList", nil, ["conversation-list"]),
            node(2, 1, "AXRow", "o***"),
            node(3, 2, "AXStaticText", "花儿 将该会话转移给 小硕，并留言：催发货")])
        XCTAssertEqual(PDDAXIncomingTransfer.pendingRows(in: tree).map(\.rowID), [AXElementToken(rawValue: 2)])
    }

    private func page(_ children: [AXNodeSnapshot]) -> AXNodeSnapshot {
        AXNodeSnapshot(role: "AXWebArea", attributes: [("AXTitle", "小硕")], children: children)
    }
    private func notice(_ text: String) -> AXNodeSnapshot {
        AXNodeSnapshot(role: "AXStaticText", attributes: [("AXValue", text)])
    }
    private func message(_ id: String, _ customer: Bool, _ text: String) -> AXNodeSnapshot {
        AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[onemsg]"),
            ("AXDOMIdentifier", "middlePanel_list_\(id)")], children: [
                AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", customer ? "[buyer-item]" : "[cs-item]")], children: [
                    AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[msg-content-box]")], children: [notice(text)])
                ])
            ])
    }
}
