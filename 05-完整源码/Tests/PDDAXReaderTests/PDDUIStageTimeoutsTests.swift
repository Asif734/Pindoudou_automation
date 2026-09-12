import XCTest
@testable import PDDAXReader

final class PDDUIStageTimeoutsTests: XCTestCase {
    func testEachStageUsesApprovedInnerTimeout() {
        let timeouts = PDDUIStageTimeouts.approved

        XCTAssertEqual(timeouts.innerSeconds(for: .discovery), 5)
        XCTAssertEqual(timeouts.innerSeconds(for: .openConversation), 5)
        XCTAssertEqual(timeouts.innerSeconds(for: .capture), 25)
        XCTAssertEqual(timeouts.innerSeconds(for: .ocr), 20)
        XCTAssertEqual(timeouts.innerSeconds(for: .preflight), 8)
        XCTAssertEqual(timeouts.innerSeconds(for: .send), 15)
    }

    func testCaptureOperationNameMapsToCaptureInsteadOfOCR() {
        XCTAssertEqual(PDDUIStageTimeouts.approved.innerSeconds(forOperationNamed: "capture"), 25)
    }

    func testSchedulerOuterFusesMatchCurrentQianniuRuntime() {
        let timeouts = PDDUIStageTimeouts.approved

        XCTAssertEqual(timeouts.outerSeconds(forOperationNamed: "discover"), 8)
        XCTAssertEqual(timeouts.outerSeconds(forOperationNamed: "capture"), 75)
        XCTAssertEqual(timeouts.outerSeconds(forOperationNamed: "supplement"), 75)
        XCTAssertEqual(timeouts.outerSeconds(forOperationNamed: "send"), 25)
    }

    func testEveryOuterFuseIsLongerThanItsInnerTimeout() {
        let timeouts = PDDUIStageTimeouts.approved

        for stage in PDDUIStage.allCases {
            XCTAssertGreaterThan(
                timeouts.outerFuseSeconds(for: stage),
                timeouts.innerSeconds(for: stage),
                "\(stage) 的外层熔断必须晚于内层超时"
            )
        }
    }

    func testVideoAddressAndDownloadDoNotUseUIStageTimeouts() {
        XCTAssertNil(PDDUIStage(rawValue: "video"))
    }
}
