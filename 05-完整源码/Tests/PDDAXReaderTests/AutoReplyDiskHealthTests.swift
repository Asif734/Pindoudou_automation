import XCTest
@testable import PDDAXReader

final class AutoReplyDiskHealthTests: XCTestCase {
    func testCheckCreatesSynchronizesAndRemovesProbeInsideExactRoot() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let checker = AutoReplyDiskHealthChecker(
            rootDirectory: root,
            minimumFreeBytes: 512 * 1024 * 1024,
            availableCapacity: { 600 * 1024 * 1024 }
        )

        XCTAssertNoThrow(try checker.check())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testCheckRejectsLessThanFiveHundredTwelveMiB() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let checker = AutoReplyDiskHealthChecker(
            rootDirectory: root,
            minimumFreeBytes: 512 * 1024 * 1024,
            availableCapacity: { 512 * 1024 * 1024 - 1 }
        )

        XCTAssertThrowsError(try checker.check()) { error in
            XCTAssertEqual(error as? AutoReplyDiskHealthError, .insufficientSpace)
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-disk-health-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
