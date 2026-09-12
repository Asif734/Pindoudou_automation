import Foundation
import XCTest
@testable import PDDVideoProbeCore

final class PDDVideoAXSelectionTests: XCTestCase {
    func testForegroundActivationRequestsAndRaisesThenWaitsUntilFrontmost() async throws {
        let state = ActivationState()

        try await PDDVideoForegroundActivation.run(
            request: {
                state.recordRequest()
                return true
            },
            raise: {
                state.recordRaise()
                return true
            },
            isFrontmost: {
                state.frontmostChecks >= 2
            },
            sleep: { _ in
                state.recordSleep()
            }
        )

        XCTAssertEqual(state.requestCount, 1)
        XCTAssertEqual(state.raiseCount, 1)
        XCTAssertGreaterThanOrEqual(state.frontmostChecks, 2)
    }

    func testWaiterKeepsScanningUntilVideoAppears() async throws {
        let attempts = AttemptCounter()
        let expected = PDDVideoAXCandidate(
            messageID: "middlePanel_list_400",
            frame: CGRect(x: 20, y: 30, width: 100, height: 80)
        )

        let result = try await PDDVideoAXCandidateWaiter(pollInterval: .milliseconds(5)).wait(
            timeout: .seconds(1)
        ) {
            let count = await attempts.increment()
            return count < 3 ? nil : expected
        }

        XCTAssertEqual(result, expected)
        let finalCount = await attempts.value
        XCTAssertEqual(finalCount, 3)
    }

    func testWaiterReportsNoVideoAfterDeadline() async throws {
        do {
            _ = try await PDDVideoAXCandidateWaiter(pollInterval: .milliseconds(5)).wait(
                timeout: .milliseconds(20),
                scan: { nil }
            )
            XCTFail("missing video must time out")
        } catch let error as PDDVideoProbeError {
            XCTAssertEqual(error, .videoMessageNotFound)
        }
    }

    func testSelectsLatestVisibleCustomerVideoAndRejectsServiceVideoAndImage() throws {
        let nodes = [
            node(1, nil, ["msg-list"], frame: CGRect(x: 0, y: 0, width: 500, height: 500)),
            node(2, 1, ["onemsg", "buyer-item"], domID: "middlePanel_list_100"),
            node(3, 2, ["video-msg"], frame: CGRect(x: 10, y: 20, width: 80, height: 60)),
            node(4, 1, ["onemsg", "cs-item"], domID: "middlePanel_list_101"),
            node(5, 4, ["video-msg"], frame: CGRect(x: 400, y: 20, width: 80, height: 60)),
            node(6, 1, ["onemsg", "buyer-item"], domID: "middlePanel_list_102"),
            node(7, 6, ["image-msg"], frame: CGRect(x: 10, y: 100, width: 80, height: 60)),
            node(8, 1, ["onemsg", "buyer-item"], domID: "middlePanel_list_103"),
            node(9, 8, ["msg-video-player"], frame: CGRect(x: 10, y: 180, width: 120, height: 90))
        ]

        let selected = try XCTUnwrap(PDDVideoAXCandidateSelector.latestCustomerVideo(in: nodes))

        XCTAssertEqual(selected.messageID, "middlePanel_list_103")
        XCTAssertEqual(selected.frame, CGRect(x: 10, y: 180, width: 120, height: 90))
    }

    func testRejectsVideoMarkerWithoutItsOwnClickableFrame() {
        let nodes = [
            node(1, nil, ["msg-list"], frame: CGRect(x: 0, y: 0, width: 500, height: 500)),
            node(2, 1, ["onemsg", "buyer-item"], domID: "middlePanel_list_200"),
            node(4, 2, ["msg-content-box"], frame: CGRect(x: 50, y: 60, width: 160, height: 100)),
            node(3, 4, ["video-msg"], value: "正在加载")
        ]

        XCTAssertNil(PDDVideoAXCandidateSelector.latestCustomerVideo(in: nodes))
    }

    func testRejectsVideoLikeContentOutsideCustomerMessage() {
        let nodes = [
            node(1, nil, ["help-panel"]),
            node(2, 1, ["video-player"], value: "货物打包视频", frame: CGRect(x: 1, y: 2, width: 3, height: 4)),
            node(3, nil, ["onemsg", "buyer-item"], domID: "middlePanel_list_300"),
            node(4, 3, ["video-msg"])
        ]

        XCTAssertNil(PDDVideoAXCandidateSelector.latestCustomerVideo(in: nodes))
    }

    func testRejectsHiddenVideoAndVideoOutsideMessageViewport() {
        let nodes = [
            node(1, nil, ["msg-list"], frame: CGRect(x: 100, y: 100, width: 400, height: 400)),
            node(2, 1, ["onemsg", "buyer-item"], domID: "middlePanel_list_500"),
            node(3, 2, ["video-player"], frame: CGRect(x: 150, y: 150, width: 100, height: 80), isHidden: true),
            node(4, 1, ["onemsg", "buyer-item"], domID: "middlePanel_list_501"),
            node(5, 4, ["video-player"], frame: CGRect(x: 600, y: 150, width: 100, height: 80))
        ]

        XCTAssertNil(PDDVideoAXCandidateSelector.latestCustomerVideo(in: nodes))
    }

    func testChoosesHighestNumericMessageIdentifierInsteadOfLastDFSMatch() throws {
        let nodes = [
            node(1, nil, ["msg-list"], frame: CGRect(x: 0, y: 0, width: 500, height: 500)),
            node(2, 1, ["onemsg", "buyer-item"], domID: "middlePanel_list_900"),
            node(3, 2, ["video-player"], frame: CGRect(x: 20, y: 200, width: 100, height: 80)),
            node(4, 1, ["onemsg", "buyer-item"], domID: "middlePanel_list_800"),
            node(5, 4, ["video-player"], frame: CGRect(x: 20, y: 300, width: 100, height: 80))
        ]

        let selected = try XCTUnwrap(PDDVideoAXCandidateSelector.latestCustomerVideo(in: nodes))

        XCTAssertEqual(selected.messageID, "middlePanel_list_900")
    }

    func testAcceptsMessageViewportIdentifiedOnlyByDOMIdentifier() throws {
        let nodes = [
            node(1, nil, [], domID: "msgListContainer", frame: CGRect(x: 0, y: 0, width: 500, height: 500)),
            node(2, 1, ["onemsg", "buyer-item"], domID: "middlePanel_list_901"),
            node(3, 2, ["video-player"], frame: CGRect(x: 20, y: 200, width: 100, height: 80))
        ]

        let selected = try XCTUnwrap(PDDVideoAXCandidateSelector.latestCustomerVideo(in: nodes))

        XCTAssertEqual(selected.messageID, "middlePanel_list_901")
    }

    func testRejectsCandidateFromTruncatedAXTree() {
        let partialNodes = [
            node(1, nil, ["msg-list"], frame: CGRect(x: 0, y: 0, width: 500, height: 500)),
            node(2, 1, ["onemsg", "buyer-item"], domID: "middlePanel_list_100"),
            node(3, 2, ["video-player"], frame: CGRect(x: 20, y: 200, width: 100, height: 80))
        ]

        XCTAssertNil(PDDVideoAXCandidateSelector.latestCustomerVideo(in: partialNodes, isComplete: false))
    }

    func testSelectsCustomerVideoFromDurationAndThumbnailWhenVideoClassIsMissing() throws {
        let nodes = [
            node(1, nil, ["msg-list"], frame: CGRect(x: 0, y: 0, width: 500, height: 500)),
            node(2, 1, ["onemsg", "buyer-item"], domID: "middlePanel_list_920"),
            node(3, 2, ["msg-content-box"], frame: CGRect(x: 20, y: 200, width: 140, height: 110)),
            node(
                4, 3, [], value: "/6fb00c16-bb50-45b6-bbb7-8bb35a1ab216.jpeg",
                frame: CGRect(x: 20, y: 200, width: 140, height: 90), role: "AXImage"
            ),
            node(5, 3, [], value: "00:08", frame: CGRect(x: 25, y: 275, width: 36, height: 18), role: "AXStaticText")
        ]

        let selected = try XCTUnwrap(PDDVideoAXCandidateSelector.latestCustomerVideo(in: nodes))

        XCTAssertEqual(selected.messageID, "middlePanel_list_920")
        XCTAssertEqual(selected.frame, CGRect(x: 20, y: 200, width: 140, height: 90))
    }

    func testRejectsOrdinaryCustomerImageWithoutVideoDuration() {
        let nodes = [
            node(1, nil, ["msg-list"], frame: CGRect(x: 0, y: 0, width: 500, height: 500)),
            node(2, 1, ["onemsg", "buyer-item"], domID: "middlePanel_list_921"),
            node(3, 2, ["image-msg"], frame: CGRect(x: 20, y: 200, width: 140, height: 90), role: "AXImage")
        ]

        XCTAssertNil(PDDVideoAXCandidateSelector.latestCustomerVideo(in: nodes))
    }

    private func node(
        _ id: Int,
        _ parentID: Int?,
        _ classes: Set<String>,
        domID: String? = nil,
        value: String? = nil,
        frame: CGRect = .zero,
        isHidden: Bool = false,
        role: String = "AXGroup"
    ) -> PDDVideoAXNode {
        PDDVideoAXNode(
            id: id,
            parentID: parentID,
            role: role,
            value: value,
            title: nil,
            description: nil,
            domIdentifier: domID,
            domClasses: classes,
            frame: frame,
            isHidden: isHidden
        )
    }
}

private actor AttemptCounter {
    private(set) var value = 0

    func increment() -> Int {
        value += 1
        return value
    }
}

private final class ActivationState: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private var raises = 0
    private var checks = 0

    var requestCount: Int { lock.withLock { requests } }
    var raiseCount: Int { lock.withLock { raises } }
    var frontmostChecks: Int {
        lock.withLock {
            checks += 1
            return checks
        }
    }

    func recordRequest() { lock.withLock { requests += 1 } }
    func recordRaise() { lock.withLock { raises += 1 } }
    func recordSleep() {}
}
