import XCTest
@testable import PDDAXReader

@MainActor
final class PDDAXConversationTransfererTests: XCTestCase {
    func testTriesOrdinaryAgentsInOrderAndStopsAfterFirstConfirmedSuccess() async throws {
        let dialog = transferDialogTree()
        let backend = TransferBackendStub(tree: dialog)
        let opener = TransferOpenerStub(tree: chatTree())
        let clicker = TransferClickerSpy {
            if $0 == 2 { backend.tree = self.chatTree() }
        }
        let transferer = PDDAXConversationTransferer(
            backend: backend, opener: opener, clicker: clicker,
            sleep: { _ in }
        )
        let lease = UIOperationLeaseRegistry().acquire(uid: "PDD-customer")

        let result = try await transferer.transferToAnyHuman(
            uid: "PDD-customer", lease: lease
        )

        XCTAssertEqual(result, .transferred(agentLabel: "客服乙"))
        XCTAssertEqual(opener.openedUIDs, ["PDD-customer"])
        XCTAssertEqual(clicker.clickedPoints.count, 3) // header + two ordinary transfer controls
        XCTAssertEqual(clicker.noReasonAnchors.count, 2)
    }

    func testReportsFailureAfterEveryOrdinaryAgentWasTried() async throws {
        let dialog = transferDialogTree()
        let backend = TransferBackendStub(tree: dialog)
        let clicker = TransferClickerSpy()
        let transferer = PDDAXConversationTransferer(
            backend: backend, opener: TransferOpenerStub(tree: chatTree()),
            clicker: clicker, sleep: { _ in }
        )
        let lease = UIOperationLeaseRegistry().acquire(uid: "PDD-customer")

        let result = try await transferer.transferToAnyHuman(
            uid: "PDD-customer", lease: lease
        )

        XCTAssertEqual(result, .failed("已尝试全部普通客服，均未确认转移成功"))
        XCTAssertEqual(clicker.noReasonAnchors.count, 2)
    }

    private func chatTree() -> PDDAXSemanticTree {
        tree([
            node(0, role: "AXWindow"),
            node(1, parent: 0, role: "AXGroup", classes: ["middle-panel"]),
            node(2, parent: 1, role: "AXStaticText", value: "转移会话",
                 frame: .init(x: 800, y: 100, width: 70, height: 24))
        ])
    }

    private func transferDialogTree() -> PDDAXSemanticTree {
        tree([
            node(0, role: "AXWindow"),
            node(1, parent: 0, role: "AXGroup", value: "转移会话"),
            node(2, parent: 1, role: "AXTextField", value: "请输入内容", settable: true),
            node(3, parent: 1, role: "AXTable"),
            node(4, parent: 3, role: "AXRow"),
            node(5, parent: 4, role: "AXStaticText", value: "客服甲"),
            node(6, parent: 4, role: "AXGroup", value: "转移",
                 frame: .init(x: 500, y: 180, width: 48, height: 24)),
            node(7, parent: 4, role: "AXGroup", value: "转移并微信通知"),
            node(8, parent: 3, role: "AXRow"),
            node(9, parent: 8, role: "AXStaticText", value: "客服乙"),
            node(10, parent: 8, role: "AXGroup", value: "转移",
                 frame: .init(x: 500, y: 220, width: 48, height: 24)),
            node(11, parent: 8, role: "AXGroup", value: "转移并微信通知")
        ])
    }

    private func tree(_ nodes: [PDDAXSemanticNode<AXElementToken>]) -> PDDAXSemanticTree {
        PDDAXSemanticTree(rootSnapshot: AXNodeSnapshot(role: "AXWindow"), nodes: nodes)
    }

    private func node(
        _ rawID: Int, parent: Int? = nil, role: String, value: String? = nil,
        classes: Set<String> = [], settable: Bool = false, frame: CGRect = .zero
    ) -> PDDAXSemanticNode<AXElementToken> {
        PDDAXSemanticNode(
            id: AXElementToken(rawValue: rawID),
            parentID: parent.map(AXElementToken.init(rawValue:)), role: role,
            value: value, title: nil, domIdentifier: nil, domClasses: classes,
            actionNames: [], isSettable: settable, frame: frame
        )
    }
}

@MainActor
private final class TransferBackendStub: PDDAXBackend {
    var tree: PDDAXSemanticTree
    init(tree: PDDAXSemanticTree) { self.tree = tree }
    func readSemanticTree() throws -> PDDAXSemanticTree { tree }
    func performPress(_ id: AXElementToken) throws {}
    func setValue(_ text: String, on id: AXElementToken) throws {}
    func value(of id: AXElementToken) throws -> String { "" }
}

@MainActor
private final class TransferOpenerStub: PDDConversationOpening {
    let tree: PDDAXSemanticTree
    private(set) var openedUIDs: [String] = []
    init(tree: PDDAXSemanticTree) { self.tree = tree }
    func openAndResolve(uid: String) async throws -> PDDAXSemanticTree {
        openedUIDs.append(uid)
        return tree
    }
}

@MainActor
private final class TransferClickerSpy: PDDTransferClicking {
    private let onSubmit: (Int) -> Void
    private(set) var clickedPoints: [CGPoint] = []
    private(set) var noReasonAnchors: [CGRect] = []
    init(onSubmit: @escaping (Int) -> Void = { _ in }) { self.onSubmit = onSubmit }
    func click(at point: CGPoint) throws { clickedPoints.append(point) }
    func submitNoReasonTransfer(anchorFrame: CGRect) async throws {
        noReasonAnchors.append(anchorFrame)
        onSubmit(noReasonAnchors.count)
    }
}
