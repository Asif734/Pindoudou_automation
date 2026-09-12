import XCTest
@testable import PDDAXReader

final class RuntimeResourceMonitorTests: XCTestCase {
    func testSnapshotReportsInjectedMemoryAndCurrentWorkload() {
        let date = Date(timeIntervalSince1970: 123)
        let monitor = RuntimeResourceMonitor(availableMemoryBytes: { 7 << 30 }, now: { date })

        let snapshot = monitor.snapshot(activeCLI: 3, queueDepth: 8, lastLatencyMilliseconds: 450)

        XCTAssertEqual(snapshot.date, date)
        XCTAssertEqual(snapshot.availableMemoryBytes, 7 << 30)
        XCTAssertEqual(snapshot.activeCLI, 3)
        XCTAssertEqual(snapshot.queueDepth, 8)
        XCTAssertEqual(snapshot.lastLatencyMilliseconds, 450)
    }
}
