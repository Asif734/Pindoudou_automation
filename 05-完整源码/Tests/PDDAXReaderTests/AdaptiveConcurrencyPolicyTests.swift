import XCTest
@testable import PDDAXReader

final class AdaptiveConcurrencyPolicyTests: XCTestCase {
    func testBackpressureDoesNotStarveSingleWaitingCustomer() {
        let policy = AdaptiveConcurrencyPolicy(physicalMemoryBytes: 16 << 30)
        let now = Date()
        policy.recordBackpressure(now: now)
        XCTAssertEqual(policy.limit(queueDepth: 1, availableMemoryBytes: 8 << 30,
            activeCleanup: 0, now: now), 1)
        XCTAssertEqual(policy.limit(queueDepth: 1, availableMemoryBytes: 2 << 30,
            activeCleanup: 0, now: now.addingTimeInterval(59)), 1)
    }

    func testBackpressureRetainsMemoryReserveAndReducesLargerQueues() {
        let policy = AdaptiveConcurrencyPolicy(physicalMemoryBytes: 16 << 30)
        let now = Date()
        policy.recordBackpressure(now: now)
        XCTAssertEqual(policy.limit(queueDepth: 10, availableMemoryBytes: 1 << 30,
            activeCleanup: 0, now: now), 0)
        XCTAssertEqual(policy.limit(queueDepth: 10, availableMemoryBytes: (1 << 30) + 1,
            activeCleanup: 0, now: now), 0)
        XCTAssertEqual(policy.limit(queueDepth: 10, availableMemoryBytes: 10 << 30,
            activeCleanup: 0, now: now), 4)
        XCTAssertEqual(policy.limit(queueDepth: 10, availableMemoryBytes: 10 << 30,
            activeCleanup: 0, now: now.addingTimeInterval(61)), 9)
    }
}
