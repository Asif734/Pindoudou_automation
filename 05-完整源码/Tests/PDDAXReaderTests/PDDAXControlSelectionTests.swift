import XCTest
@testable import PDDAXReader

final class PDDAXControlSelectionTests: XCTestCase {
    func testSelectsOnlyComposerUnderChatPanel() throws {
        XCTAssertEqual(try PDDAXControlSelection.composer(in: fixtureNodes), "composer")
    }

    func testSelectsUnreadConversationRowWithoutTreatingOrderListAsConversation() throws {
        XCTAssertEqual(
            try PDDAXControlSelection.conversationCandidates(in: fixtureNodes).map(\.rowID),
            ["conversation-row"]
        )
    }

    func testSelectsRealPDDChatListGroupWithRedDotAndIgnoresUnreadMessageBubble() throws {
        let nodes = [
            node("root", role: "AXWindow"),
            node("chat-list", parent: "root", role: "AXGroup", classes: ["chat-list-box", "custom-scroll"]),
            node("row", parent: "chat-list", role: "AXGroup", actions: ["AXPress"]),
            node("nickname", parent: "row", role: "AXStaticText", value: "新客户甲"),
            node("preview", parent: "row", role: "AXStaticText", value: "打印不了怎么办"),
            node("red-dot", parent: "row", role: "AXStaticText", value: "2", classes: ["unread-count"]),
            node("chat-panel", parent: "root", role: "AXGroup", classes: ["middle-panel"]),
            node("message", parent: "chat-panel", role: "AXGroup", classes: ["cs-item", "unread"]),
            node("message-value", parent: "message", role: "AXStaticText", value: "1")
        ]

        XCTAssertEqual(
            try PDDAXControlSelection.conversationCandidates(in: nodes),
            [.init(rowID: "row", visibleLabel: "新客户甲", unreadCount: 2)]
        )
    }

    func testTreatsEmptyRedDotAsOneUnreadConversation() throws {
        let nodes = [
            node("root", role: "AXWindow"),
            node("chat-list", parent: "root", role: "AXGroup", classes: ["chat-list-box"]),
            node("row", parent: "chat-list", role: "AXGroup", actions: ["AXPress"]),
            node("nickname", parent: "row", role: "AXStaticText", value: "新客户乙"),
            node("red-dot", parent: "row", role: "AXGroup", value: "", classes: ["red-dot"])
        ]

        XCTAssertEqual(
            try PDDAXControlSelection.conversationCandidates(in: nodes),
            [.init(rowID: "row", visibleLabel: "新客户乙", unreadCount: 1)]
        )
    }

    func testTreatsUnreadClassOnConversationRowAsUnread() throws {
        let nodes = [
            node("root", role: "AXWindow"),
            node("chat-list", parent: "root", role: "AXGroup", classes: ["chat-list-box"]),
            node("row", parent: "chat-list", role: "AXGroup", classes: ["conversation-item", "unread"], actions: ["AXPress"]),
            node("nickname", parent: "row", role: "AXStaticText", value: "新客户丙")
        ]

        XCTAssertEqual(
            try PDDAXControlSelection.conversationCandidates(in: nodes),
            [.init(rowID: "row", visibleLabel: "新客户丙", unreadCount: 1)]
        )
    }

    func testIgnoresUnrelatedBadgeInsideConversationRow() throws {
        let nodes = [
            node("root", role: "AXWindow"),
            node("chat-list", parent: "root", role: "AXGroup", classes: ["chat-list-box"]),
            node("row", parent: "chat-list", role: "AXGroup", actions: ["AXPress"]),
            node("nickname", parent: "row", role: "AXStaticText", value: "普通客户"),
            node("vip", parent: "row", role: "AXStaticText", value: "VIP", classes: ["status-badge"])
        ]

        XCTAssertTrue(try PDDAXControlSelection.conversationCandidates(in: nodes).isEmpty)
    }

    func testListsNonUnreadRowsForReturningToVerifiedUID() throws {
        let nodes = [
            node("root", role: "AXWindow"),
            node("chat-list", parent: "root", role: "AXGroup", classes: ["chat-list-box"]),
            node("row", parent: "chat-list", role: "AXGroup", actions: ["AXPress"]),
            node("nickname", parent: "row", role: "AXStaticText", value: "已验证客户")
        ]

        XCTAssertEqual(
            try PDDAXControlSelection.conversationRows(in: nodes).map(\.visibleLabel),
            ["已验证客户"]
        )
    }

    func testConversationRowsExcludeTimesActionsAndFooterAndExposeUniqueDOMIdentifiers() throws {
        let nodes = [
            node("root", role: "AXWindow"),
            node("chat-list", parent: "root", role: "AXGroup", classes: ["chat-list-box"]),
            node("row-a", parent: "chat-list", role: "AXGroup", identifier: "buyer-a", classes: ["conversation-item"], actions: ["AXPress"]),
            node("nickname-a", parent: "row-a", role: "AXStaticText", value: "S*** 1", classes: ["nickname"]),
            node("preview-a", parent: "row-a", role: "AXStaticText", value: "请问什么时候发货"),
            node("time-a", parent: "chat-list", role: "AXRow", value: "10:44"),
            node("transfer-a", parent: "chat-list", role: "AXGroup", value: "转移会话", actions: ["AXPress"]),
            node("row-b", parent: "chat-list", role: "AXGroup", identifier: "buyer-b", classes: ["conversation-item"], actions: ["AXPress"]),
            node("nickname-b", parent: "row-b", role: "AXStaticText", value: "c*y", classes: ["nickname"]),
            node("time-b", parent: "chat-list", role: "AXRow", value: "00:16"),
            node("footer", parent: "chat-list", role: "AXRow", value: "已经没有更多了哦~")
        ]

        XCTAssertEqual(
            try PDDAXControlSelection.conversationRows(in: nodes),
            [
                .init(rowID: "row-a", visibleLabel: "S***", domIdentifier: "buyer-a"),
                .init(rowID: "row-b", visibleLabel: "c*y", domIdentifier: "buyer-b")
            ]
        )
    }

    func testConversationRowsDiscardDuplicatedDOMIdentifier() throws {
        let nodes = [
            node("root", role: "AXWindow"),
            node("chat-list", parent: "root", role: "AXGroup", classes: ["chat-list-box"]),
            node("row-a", parent: "chat-list", role: "AXGroup", identifier: "duplicate", classes: ["conversation-item"], actions: ["AXPress"]),
            node("nickname-a", parent: "row-a", role: "AXStaticText", value: "S***", classes: ["nickname"]),
            node("row-b", parent: "chat-list", role: "AXGroup", identifier: "duplicate", classes: ["conversation-item"], actions: ["AXPress"]),
            node("nickname-b", parent: "row-b", role: "AXStaticText", value: "S***", classes: ["nickname"])
        ]

        XCTAssertEqual(
            try PDDAXControlSelection.conversationRows(in: nodes).map(\.domIdentifier),
            [nil, nil]
        )
    }

    func testNicknameClassContainerUsesItsTextDescendantBeforeMessagePreview() throws {
        let nodes = [
            node("root", role: "AXWindow"),
            node("chat-list", parent: "root", role: "AXGroup", classes: ["chat-list-box"]),
            node("row", parent: "chat-list", role: "AXGroup", classes: ["active", "chat-item-box"], actions: ["AXPress"]),
            node("detail", parent: "row", role: "AXGroup", classes: ["chat-detail"]),
            node("nickname-box", parent: "detail", role: "AXGroup", classes: ["chat-nickname"]),
            node("nickname", parent: "nickname-box", role: "AXStaticText", value: "山**川"),
            node("orders", parent: "nickname-box", role: "AXStaticText", value: "下单数(1)"),
            node("preview-box", parent: "detail", role: "AXGroup", classes: ["chat-message-content"]),
            node("preview", parent: "preview-box", role: "AXStaticText", value: "你好下班了")
        ]

        XCTAssertEqual(
            try PDDAXControlSelection.conversationRows(in: nodes).map(\.visibleLabel),
            ["山**川"]
        )
    }

    func testCurrentConversationRowReturnsOnlyActiveOuterRow() throws {
        let nodes = [
            node("root", role: "AXWindow"),
            node("chat-list", parent: "root", role: "AXGroup", classes: ["chat-list-box"]),
            node("row-a", parent: "chat-list", role: "AXGroup", classes: ["chat-item-box"], actions: ["AXPress"]),
            node("name-a", parent: "row-a", role: "AXStaticText", value: "S***"),
            node("row-b", parent: "chat-list", role: "AXGroup", classes: ["chat-item-box", "active"], actions: ["AXPress"]),
            node("name-b", parent: "row-b", role: "AXStaticText", value: "山**川")
        ]

        XCTAssertEqual(
            try PDDAXControlSelection.currentConversationRow(in: nodes)?.rowID,
            "row-b"
        )
    }

    func testSelectsPressableSendGroupWhoseExactLabelIsAChildTextNode() throws {
        let nodes = fixtureNodes.filter { !["send"].contains($0.id) } + [
            node(
                "send-group", parent: "chat-panel", role: "AXGroup",
                classes: ["send-btn"], actions: ["AXPress"]
            ),
            node("send-label", parent: "send-group", role: "AXStaticText", value: "发送")
        ]

        XCTAssertEqual(try PDDAXControlSelection.sendControl(in: nodes), "send-group")
    }

    func testSelectsHeaderTransferTriggerOutsideConversationListAndDialog() throws {
        let nodes = [
            node("root", role: "AXWindow"),
            node("chat-list", parent: "root", role: "AXGroup", classes: ["chat-list-box"]),
            node("row-transfer", parent: "chat-list", role: "AXStaticText", value: "转移会话"),
            node("chat-panel", parent: "root", role: "AXGroup", classes: ["middle-panel"]),
            node("header", parent: "chat-panel", role: "AXGroup"),
            node("header-transfer", parent: "header", role: "AXStaticText", value: "转移会话"),
            node("dialog", parent: "root", role: "AXGroup", value: "转移会话"),
            node("dialog-title", parent: "dialog", role: "AXStaticText", value: "转移会话"),
            node("dialog-search", parent: "dialog", role: "AXTextField", value: "请输入内容", settable: true)
        ]

        XCTAssertEqual(
            try PDDAXControlSelection.transferConversationTrigger(in: nodes),
            "header-transfer"
        )
    }

    func testListsOnlyOrdinaryTransferActionsInVisualStaffOrder() throws {
        let nodes = [
            node("root", role: "AXWindow"),
            node("dialog", parent: "root", role: "AXGroup", value: "转移会话"),
            node("dialog-search", parent: "dialog", role: "AXTextField", value: "请输入内容", settable: true),
            node("table", parent: "dialog", role: "AXTable"),
            node("row-b", parent: "table", role: "AXRow"),
            node("name-b", parent: "row-b", role: "AXStaticText", value: "客服乙"),
            node("ordinary-b", parent: "row-b", role: "AXGroup", value: "转移", frame: .init(x: 500, y: 240, width: 48, height: 24)),
            node("wechat-b", parent: "row-b", role: "AXGroup", value: "转移并微信通知", frame: .init(x: 560, y: 240, width: 120, height: 24)),
            node("row-a", parent: "table", role: "AXRow"),
            node("name-a", parent: "row-a", role: "AXStaticText", value: "客服甲"),
            node("ordinary-a", parent: "row-a", role: "AXGroup", value: "转移", frame: .init(x: 500, y: 180, width: 48, height: 24)),
            node("wechat-a", parent: "row-a", role: "AXGroup", value: "转移并微信通知", frame: .init(x: 560, y: 180, width: 120, height: 24))
        ]

        let actions = try PDDAXControlSelection.ordinaryTransferActions(in: nodes)

        XCTAssertEqual(actions.map(\.controlID), ["ordinary-a", "ordinary-b"])
        XCTAssertEqual(actions.map(\.agentLabel), ["客服甲", "客服乙"])
    }

    func testListsTransfersFromChromiumColumnOrientedTableByMatchingRowFrames() throws {
        let nodes = [
            node("root", role: "AXWindow"),
            node("dialog", parent: "root", role: "AXGroup"),
            node("title", parent: "dialog", role: "AXStaticText", value: "转移会话"),
            node("search", parent: "dialog", role: "AXTextField", classes: ["el-input__inner"], settable: true),
            node("table", parent: "dialog", role: "AXTable"),
            node("name-column", parent: "table", role: "AXColumn"),
            node("name-a", parent: "name-column", role: "AXStaticText", value: "客服甲", frame: .init(x: 100, y: 200, width: 60, height: 15)),
            node("name-b", parent: "name-column", role: "AXStaticText", value: "客服乙", frame: .init(x: 100, y: 250, width: 60, height: 15)),
            node("action-column", parent: "table", role: "AXColumn"),
            node("ordinary-a", parent: "action-column", role: "AXGroup", classes: ["item-btn-transfer"], frame: .init(x: 500, y: 198, width: 48, height: 18)),
            node("ordinary-a-label", parent: "ordinary-a", role: "AXStaticText", value: "转移", frame: .init(x: 500, y: 200, width: 24, height: 15)),
            node("wechat-a", parent: "action-column", role: "AXStaticText", value: "转移并微信通知", frame: .init(x: 560, y: 200, width: 85, height: 15)),
            node("ordinary-b", parent: "action-column", role: "AXGroup", classes: ["item-btn-transfer"], frame: .init(x: 500, y: 248, width: 48, height: 18)),
            node("ordinary-b-label", parent: "ordinary-b", role: "AXStaticText", value: "转移", frame: .init(x: 500, y: 250, width: 24, height: 15)),
            node("wechat-b", parent: "action-column", role: "AXStaticText", value: "转移并微信通知", frame: .init(x: 560, y: 250, width: 85, height: 15))
        ]

        let actions = try PDDAXControlSelection.ordinaryTransferActions(in: nodes)

        XCTAssertEqual(actions.map(\.controlID), ["ordinary-a", "ordinary-b"])
        XCTAssertEqual(actions.map(\.agentLabel), ["客服甲", "客服乙"])
    }


    func testRejectsTwoSendControlsInsteadOfGuessing() {
        let secondSend = node(
            "send-2", parent: "chat-panel", role: "AXButton", value: "发送",
            actions: ["AXPress"]
        )
        XCTAssertThrowsError(try PDDAXControlSelection.sendControl(in: fixtureNodes + [secondSend]))
    }

    func testRejectsSendControlWithoutAXPress() {
        let nodes = fixtureNodes.map { item in
            item.id == "send" ? node(
                "send", parent: "chat-panel", role: "AXButton", value: "发送", actions: []
            ) : item
        }
        XCTAssertThrowsError(try PDDAXControlSelection.sendControl(in: nodes))
    }

    func testRejectsAmbiguousSettableTextAreas() {
        let secondComposer = node(
            "composer-2", parent: "chat-panel", role: "AXTextArea", settable: true
        )
        XCTAssertThrowsError(try PDDAXControlSelection.composer(in: fixtureNodes + [secondComposer]))
    }

    private var fixtureNodes: [PDDAXSemanticNode<String>] {
        [
            node("root", role: "AXWindow"),
            node("conversation-list", parent: "root", role: "AXList", classes: ["conversation-list"]),
            node("conversation-row", parent: "conversation-list", role: "AXRow", value: "张三 2"),
            node("unread", parent: "conversation-row", role: "AXStaticText", value: "2", classes: ["unread"]),
            node("order-list", parent: "root", role: "AXList", classes: ["order-list"]),
            node("order-row", parent: "order-list", role: "AXRow", value: "订单 2"),
            node("chat-panel", parent: "root", role: "AXGroup", classes: ["chat-panel"]),
            node("sidebar-text", parent: "root", role: "AXTextArea", value: "备注", settable: true),
            node("composer", parent: "chat-panel", role: "AXTextArea", settable: true),
            node("send", parent: "chat-panel", role: "AXButton", value: "发送", actions: ["AXPress"])
        ]
    }

    private func node(
        _ id: String,
        parent: String? = nil,
        role: String,
        value: String? = nil,
        title: String? = nil,
        identifier: String? = nil,
        classes: Set<String> = [],
        actions: Set<String> = [],
        settable: Bool = false,
        frame: CGRect = .zero
    ) -> PDDAXSemanticNode<String> {
        PDDAXSemanticNode(
            id: id,
            parentID: parent,
            role: role,
            value: value,
            title: title,
            domIdentifier: identifier,
            domClasses: classes,
            actionNames: actions,
            isSettable: settable,
            frame: frame
        )
    }
}
