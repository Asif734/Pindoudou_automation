import XCTest
@testable import PDDAXReader

final class PDDAXImageSelectionTests: XCTestCase {
    func testSelectsOnlyCustomerImageMessageWithStableMessageIDAndFrame() {
        let nodes = [
            node(1, nil, ["chat-panel"]),
            node(2, 1, ["onemsg", "buyer-item"], domID: "middlePanel_list_100"),
            node(3, 2, ["image-msg"], frame: CGRect(x: 100, y: 200, width: 80, height: 90)),
            node(4, 1, ["onemsg", "cs-item"], domID: "middlePanel_list_101"),
            node(5, 4, ["image-msg"], frame: CGRect(x: 400, y: 200, width: 80, height: 90))
        ]

        let selected = PDDAXImageSelection.customerImages(
            in: nodes, messageIDs: ["middlePanel_list_100", "middlePanel_list_101"]
        )

        XCTAssertEqual(selected, [PDDCustomerImageCandidate(
            messageID: "middlePanel_list_100",
            frame: CGRect(x: 100, y: 200, width: 80, height: 90)
        )])
    }

    func testDeduplicatesMessageIDAndRejectsZeroFrame() {
        let nodes = [
            node(1, nil, ["onemsg", "buyer-item"], domID: "m1"),
            node(2, 1, ["image-msg"], frame: .zero),
            node(3, 1, ["image-msg"], frame: CGRect(x: 1, y: 2, width: 3, height: 4)),
            node(4, 1, ["image-msg"], frame: CGRect(x: 5, y: 6, width: 7, height: 8))
        ]

        let selected = PDDAXImageSelection.customerImages(in: nodes, messageIDs: ["m1"])

        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.frame, CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    func testRejectsOnePointImageResidueAtTopOfVisibleChatArea() {
        let nodes = [
            node(1, nil, ["history-box", "custom-scroll"], frame: CGRect(x: 581, y: 389, width: 513, height: 320)),
            node(2, 1, ["onemsg", "buyer-item"], domID: "m1"),
            node(3, 2, ["image-msg"], frame: CGRect(x: 641, y: 389, width: 220, height: 1))
        ]

        let selected = PDDAXImageSelection.customerImages(in: nodes, messageIDs: ["m1"])

        XCTAssertTrue(selected.isEmpty)
    }

    func testRejectsPartiallyVisibleImageWhoseOriginalCenterIsOutsideChatArea() {
        let nodes = [
            node(1, nil, ["history-box", "custom-scroll"], frame: CGRect(x: 581, y: 389, width: 513, height: 320)),
            node(2, 1, ["onemsg", "buyer-item"], domID: "m1"),
            node(3, 2, ["image-msg"], frame: CGRect(x: 641, y: 704, width: 220, height: 112))
        ]

        let selected = PDDAXImageSelection.customerImages(in: nodes, messageIDs: ["m1"])

        XCTAssertTrue(selected.isEmpty)
    }

    private func node(
        _ id: Int,
        _ parentID: Int?,
        _ classes: Set<String>,
        domID: String? = nil,
        frame: CGRect = .zero
    ) -> PDDAXSemanticNode<Int> {
        PDDAXSemanticNode(
            id: id, parentID: parentID, role: "AXGroup", value: nil, title: nil,
            domIdentifier: domID, domClasses: classes, actionNames: [],
            isSettable: false, frame: frame
        )
    }
}
