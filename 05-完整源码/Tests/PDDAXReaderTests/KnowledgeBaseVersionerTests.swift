import XCTest
@testable import PDDAXReader

final class KnowledgeBaseVersionerTests: XCTestCase {
    func testVersionIsStableForUnchangedBytesAndChangesWithContent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kb-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("first".utf8).write(to: url)
        let versioner = KnowledgeBaseVersioner()

        let first = try await versioner.version(url: url)
        let repeated = try await versioner.version(url: url)
        try Data("second-value".utf8).write(to: url, options: .atomic)
        let changed = try await versioner.version(url: url)

        XCTAssertEqual(first, "a7937b64b8caa58f03721bb6bacf5c78cb235febe0e70b1b84cd99541461a08e")
        XCTAssertEqual(repeated, first)
        XCTAssertEqual(changed, "e3ae6d0f1fc09e6a11e25aefa4cb66d73da71a6b2ef9b4d989ea2d5a6caf69f1")
    }
}
