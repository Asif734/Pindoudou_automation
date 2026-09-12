import XCTest
@testable import PDDAXReader

final class PDDAXBackendPolicyTests: XCTestCase {
    func testSemanticWalkRequestsAllTextAndMediaAttributes() {
        XCTAssertEqual(
            Set(PDDAXBackendPolicy.semanticAttributeNames),
            Set(["AXValue", "AXTitle", "AXDescription", "AXURL", "AXDOMClassList", "AXDOMIdentifier"])
        )
    }

    func testMissingWebAreaRequestsRecoveryThenThrottlesUntilChromiumWindowExpires() {
        var policy = PDDAXWebTreeRecoveryPolicy(cooldown: 3)
        let shell = [PDDAXSemanticNode(
            id: 1, parentID: Optional<Int>.none, role: "AXWindow", value: nil, title: nil,
            domIdentifier: nil, domClasses: [], actionNames: [], isSettable: false
        )]

        XCTAssertEqual(policy.evaluate(nodes: shell, now: Date(timeIntervalSince1970: 100)), .request)
        XCTAssertEqual(policy.evaluate(nodes: shell, now: Date(timeIntervalSince1970: 102)), .waiting)
        XCTAssertEqual(policy.evaluate(nodes: shell, now: Date(timeIntervalSince1970: 103)), .request)
    }

    func testRecoveredWebAreaResetsRecoveryThrottleForFutureDetach() {
        var policy = PDDAXWebTreeRecoveryPolicy(cooldown: 3)
        let shell = [PDDAXSemanticNode(
            id: 1, parentID: Optional<Int>.none, role: "AXWindow", value: nil, title: nil,
            domIdentifier: nil, domClasses: [], actionNames: [], isSettable: false
        )]
        let healthy = [
            PDDAXSemanticNode(
                id: 2, parentID: Optional<Int>.none, role: "AXWebArea", value: nil, title: nil,
                domIdentifier: nil, domClasses: [], actionNames: [], isSettable: false
            ),
            PDDAXSemanticNode(
                id: 3, parentID: 2, role: "AXGroup", value: nil, title: nil,
                domIdentifier: nil, domClasses: ["chat-list-box"], actionNames: [], isSettable: false
            )
        ]
        _ = policy.evaluate(nodes: shell, now: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(policy.evaluate(nodes: healthy, now: Date(timeIntervalSince1970: 101)), .healthy)
        XCTAssertEqual(policy.evaluate(nodes: shell, now: Date(timeIntervalSince1970: 101)), .request)
    }

    func testUnrelatedWorkOrderWebAreaDoesNotCountAsRecoveredChatTree() {
        var policy = PDDAXWebTreeRecoveryPolicy(cooldown: 3)
        let workOrderTree = [
            PDDAXSemanticNode(
                id: 1, parentID: Optional<Int>.none, role: "AXWebArea", value: "工单管理", title: nil,
                domIdentifier: nil, domClasses: [], actionNames: [], isSettable: false
            ),
            PDDAXSemanticNode(
                id: 2, parentID: 1, role: "AXGroup", value: "工单查询", title: nil,
                domIdentifier: nil, domClasses: ["work-order-list"], actionNames: [], isSettable: false
            )
        ]

        XCTAssertEqual(
            policy.evaluate(nodes: workOrderTree, now: Date(timeIntervalSince1970: 100)),
            .request
        )
    }

    func testTransferDialogCountsAsHealthyChatSurfaceWhileItCoversTheChatTree() {
        var policy = PDDAXWebTreeRecoveryPolicy(cooldown: 3)
        let transferDialog = [
            PDDAXSemanticNode(
                id: 1, parentID: Optional<Int>.none, role: "AXWebArea", value: nil, title: nil,
                domIdentifier: nil, domClasses: [], actionNames: [], isSettable: false
            ),
            PDDAXSemanticNode(
                id: 2, parentID: 1, role: "AXTextField", value: "请输入内容", title: nil,
                domIdentifier: nil, domClasses: [], actionNames: [], isSettable: true
            ),
            PDDAXSemanticNode(
                id: 3, parentID: 1, role: "AXStaticText", value: "转移", title: nil,
                domIdentifier: nil, domClasses: [], actionNames: [], isSettable: false
            )
        ]

        XCTAssertEqual(
            policy.evaluate(nodes: transferDialog, now: Date(timeIntervalSince1970: 100)),
            .healthy
        )

        let modalOnly = Array(transferDialog.dropFirst())
        XCTAssertEqual(
            policy.evaluate(nodes: modalOnly, now: Date(timeIntervalSince1970: 101)),
            .healthy
        )
    }

    func testPersistentMissingChatTreeEscalatesToForcedRestartAndPreventsRestartLoop() {
        var policy = PDDAXWebTreeRecoveryPolicy(
            cooldown: 3,
            restartAfter: 12,
            restartCooldown: 60
        )
        let shell = [PDDAXSemanticNode(
            id: 1, parentID: Optional<Int>.none, role: "AXWindow", value: nil, title: nil,
            domIdentifier: nil, domClasses: [], actionNames: [], isSettable: false
        )]

        XCTAssertEqual(policy.evaluate(nodes: shell, now: Date(timeIntervalSince1970: 100)), .request)
        XCTAssertEqual(policy.evaluate(nodes: shell, now: Date(timeIntervalSince1970: 103)), .request)
        XCTAssertEqual(policy.evaluate(nodes: shell, now: Date(timeIntervalSince1970: 111)), .request)
        XCTAssertEqual(policy.evaluate(nodes: shell, now: Date(timeIntervalSince1970: 112)), .restart)
        XCTAssertNotEqual(policy.evaluate(nodes: shell, now: Date(timeIntervalSince1970: 130)), .restart)
        XCTAssertEqual(policy.evaluate(nodes: shell, now: Date(timeIntervalSince1970: 172)), .restart)
    }

    func testHealthyChatTreeClearsMissingDurationBeforeFutureDetach() {
        var policy = PDDAXWebTreeRecoveryPolicy(
            cooldown: 3,
            restartAfter: 12,
            restartCooldown: 60
        )
        let shell = [PDDAXSemanticNode(
            id: 1, parentID: Optional<Int>.none, role: "AXWindow", value: nil, title: nil,
            domIdentifier: nil, domClasses: [], actionNames: [], isSettable: false
        )]
        let healthy = [
            PDDAXSemanticNode(
                id: 2, parentID: Optional<Int>.none, role: "AXWebArea", value: nil, title: nil,
                domIdentifier: nil, domClasses: [], actionNames: [], isSettable: false
            ),
            PDDAXSemanticNode(
                id: 3, parentID: 2, role: "AXGroup", value: nil, title: nil,
                domIdentifier: nil, domClasses: ["middle-panel"], actionNames: [], isSettable: false
            )
        ]

        _ = policy.evaluate(nodes: shell, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(policy.evaluate(nodes: healthy, now: Date(timeIntervalSince1970: 111)), .healthy)
        XCTAssertEqual(policy.evaluate(nodes: shell, now: Date(timeIntervalSince1970: 112)), .request)
        XCTAssertNotEqual(policy.evaluate(nodes: shell, now: Date(timeIntervalSince1970: 121)), .restart)
    }

    func testRootPreferenceChoosesMerchantWorkbenchOverFocusedBrowserWindow() {
        let selected = PDDAXRootWindowPreference.select(
            titledWindows: [
                (title: "拼多多商家浏览器", element: 1),
                (title: "拼多多商家工作台", element: 2)
            ],
            focusedWindow: 1,
            mainWindow: 1,
            application: 0
        )

        XCTAssertEqual(selected, 2)
    }

    func testRootPreferenceFallsBackToFocusedThenMainThenApplication() {
        XCTAssertEqual(PDDAXRootWindowPreference.select(
            titledWindows: [(title: "其他窗口", element: 3)],
            focusedWindow: 1,
            mainWindow: 2,
            application: 0
        ), 1)
        XCTAssertEqual(PDDAXRootWindowPreference.select(
            titledWindows: [], focusedWindow: nil, mainWindow: 2, application: 0
        ), 2)
        XCTAssertEqual(PDDAXRootWindowPreference.select(
            titledWindows: [], focusedWindow: nil, mainWindow: nil, application: 0
        ), 0)
    }

    func testReadsActionsForPDDPressableSendGroupEvenWhenItsOwnValueIsEmpty() {
        XCTAssertTrue(PDDAXActionPolicy.shouldReadActions(
            role: "AXGroup", value: "", title: "", domClasses: ["send-btn"]
        ))
    }

    func testReadsActionsInsideRealPDDChatListSoGroupsCanBePressed() {
        XCTAssertTrue(PDDAXActionPolicy.shouldReadActions(
            role: "AXGroup", value: "", title: nil, domClasses: [],
            insideConversationList: true
        ))
    }

    func testDoesNotReadActionsForOrdinaryMessageGroup() {
        XCTAssertFalse(PDDAXActionPolicy.shouldReadActions(
            role: "AXGroup", value: "", title: "", domClasses: ["onemsg"]
        ))
    }

    func testOnlyEditableRolesPayForAXSettableQuery() {
        XCTAssertTrue(PDDAXActionPolicy.shouldReadSettable(role: "AXTextArea"))
        XCTAssertTrue(PDDAXActionPolicy.shouldReadSettable(role: "AXTextField"))
        XCTAssertFalse(PDDAXActionPolicy.shouldReadSettable(role: "AXGroup"))
        XCTAssertFalse(PDDAXActionPolicy.shouldReadSettable(role: "AXStaticText"))
    }
}
