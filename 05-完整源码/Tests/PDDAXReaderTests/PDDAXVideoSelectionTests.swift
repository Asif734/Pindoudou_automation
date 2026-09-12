import XCTest
@testable import PDDAXReader

final class PDDAXVideoSelectionTests: XCTestCase {
    func testSelectsRequestedCustomerVideoFromExplicitMarker() throws {
        let nodes = [
            node(1, nil, ["msg-list"], frame: CGRect(x: 0, y: 0, width: 500, height: 500)),
            node(2, 1, ["onemsg", "buyer-item"], domID: "middlePanel_list_100"),
            node(3, 2, ["video-msg"], frame: CGRect(x: 20, y: 30, width: 120, height: 90)),
            node(4, 1, ["onemsg", "cs-item"], domID: "middlePanel_list_101"),
            node(5, 4, ["video-msg"], frame: CGRect(x: 200, y: 30, width: 120, height: 90))
        ]

        XCTAssertEqual(
            PDDAXVideoSelection.customerVideos(in: nodes, messageIDs: ["middlePanel_list_100", "middlePanel_list_101"]),
            [PDDCustomerVideoCandidate(messageID: "middlePanel_list_100", frame: CGRect(x: 20, y: 30, width: 120, height: 90))]
        )
    }

    func testSelectsDurationOverThumbnailAndRejectsPlainImage() throws {
        let nodes = [
            node(1, nil, ["msg-list"], frame: CGRect(x: 0, y: 0, width: 500, height: 500)),
            node(2, 1, ["onemsg", "buyer-item"], domID: "middlePanel_list_200"),
            node(3, 2, ["image-msg"], frame: CGRect(x: 20, y: 30, width: 120, height: 90), role: "AXImage"),
            node(4, 2, [], value: "00:08", frame: CGRect(x: 25, y: 95, width: 40, height: 18), role: "AXStaticText"),
            node(5, 1, ["onemsg", "buyer-item"], domID: "middlePanel_list_201"),
            node(6, 5, ["image-msg"], frame: CGRect(x: 20, y: 150, width: 120, height: 90), role: "AXImage")
        ]

        let videos = PDDAXVideoSelection.customerVideos(
            in: nodes, messageIDs: ["middlePanel_list_200", "middlePanel_list_201"]
        )

        XCTAssertEqual(videos.map(\.messageID), ["middlePanel_list_200"])
        XCTAssertEqual(videos.first?.frame, CGRect(x: 20, y: 30, width: 120, height: 90))
    }

    private func node(
        _ id: Int,
        _ parentID: Int?,
        _ classes: Set<String>,
        value: String? = nil,
        domID: String? = nil,
        frame: CGRect = .zero,
        role: String = "AXGroup"
    ) -> PDDAXSemanticNode<Int> {
        PDDAXSemanticNode(
            id: id, parentID: parentID, role: role, value: value, title: nil,
            domIdentifier: domID, domClasses: classes, actionNames: [],
            isSettable: false, frame: frame
        )
    }
}
