import XCTest
@testable import PDDAXReader

final class AutoReplyFaultInjectionTests: XCTestCase {
    func testThousandsOfLeaseGenerationsLeaveOnlyNewestTokenValid() throws {
        let registry = UIOperationLeaseRegistry()
        var previous: UIOperationLease?
        for index in 0..<2_000 {
            let next = registry.acquire(uid: "uid-\(index % 7)")
            if let previous { XCTAssertThrowsError(try previous.validate()) }
            XCTAssertNoThrow(try next.validate())
            previous = next
        }
    }

    func testFailureMatrixNeverProducesGlobalStopDecision() {
        for failureCount in 0..<2_000 {
            let decision = TaskFailurePolicy.uiDecision(previousFailures: failureCount)
            XCTAssertTrue(decision == .requeueAtTail || decision == .parkRevision)
        }
    }
}
