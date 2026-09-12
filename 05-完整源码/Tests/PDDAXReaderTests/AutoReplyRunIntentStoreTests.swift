import XCTest
@testable import PDDAXReader

final class AutoReplyRunIntentStoreTests: XCTestCase {
    func testMissingIntentDefaultsToStoppedAndExplicitValuesRoundTrip() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AutoReplyRunIntentStore(rootDirectory: root)

        XCTAssertFalse(try store.load())
        try store.save(desiredRunning: true)
        XCTAssertTrue(try store.load())
        try store.save(desiredRunning: false)
        XCTAssertFalse(try store.load())
    }

    func testCorruptIntentIsReportedWithoutBeingOverwritten() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("run-intent.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)

        XCTAssertThrowsError(try AutoReplyRunIntentStore(rootDirectory: root).load())
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-run-intent-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
