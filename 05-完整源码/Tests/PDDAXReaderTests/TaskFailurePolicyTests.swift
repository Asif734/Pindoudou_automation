import XCTest
@testable import PDDAXReader

final class TaskFailurePolicyTests: XCTestCase {
    func testFirstUIFailureRequeuesAtTail() {
        XCTAssertEqual(TaskFailurePolicy.uiDecision(previousFailures: 0), .requeueAtTail)
        XCTAssertEqual(TaskFailurePolicy.firstRetryDelay, 1)
    }

    func testSecondUIFailureParksOnlyThatRevision() {
        XCTAssertEqual(TaskFailurePolicy.uiDecision(previousFailures: 1), .parkRevision)
    }
}
