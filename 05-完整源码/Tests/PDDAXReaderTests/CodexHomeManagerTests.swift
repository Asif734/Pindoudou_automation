import XCTest
@testable import PDDAXReader

final class CodexHomeManagerTests: XCTestCase {
    func testPrepareCreatesIsolatedHomeAndCopiesOnlyAuthentication() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ambient")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("skills"), withIntermediateDirectories: true
        )
        try Data("secret".utf8).write(to: source.appendingPathComponent("auth.json"))
        try Data("rule".utf8).write(to: source.appendingPathComponent("AGENTS.md"))
        try Data("skill".utf8).write(to: source.appendingPathComponent("skills/a"))

        let runtime = try CodexHomeManager(dataRoot: root, sourceHome: source).prepare()

        XCTAssertTrue(runtime.homeURL.path.hasPrefix(root.path + "/"))
        XCTAssertEqual(runtime.values["CODEX_HOME"], runtime.homeURL.path)
        XCTAssertNil(runtime.values["OPENAI_API_KEY"])
        XCTAssertNil(runtime.values["CODEX_API_KEY"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: runtime.homeURL.appendingPathComponent("auth.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: runtime.homeURL.appendingPathComponent("AGENTS.md").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: runtime.homeURL.appendingPathComponent("skills").path
        ))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-codex-home-\(UUID().uuidString)")
    }
}
