import XCTest
@testable import PDDAXReader

final class CodexSessionRegistryTests: XCTestCase {
    func testBindingIsActiveUntilOneHourLeaseExpires() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = CodexSessionRegistry(rootDirectory: root)
        let start = Date(timeIntervalSince1970: 1_777_000_000)
        let binding = CodexSessionBinding(uid: "GZC-000001", threadID: "thread-exact-1", lastUsedAt: start)

        try registry.save(binding)

        XCTAssertEqual(
            try registry.activeBinding(uid: "GZC-000001", now: start.addingTimeInterval(3_599)),
            binding
        )
        XCTAssertNil(try registry.activeBinding(uid: "GZC-000001", now: start.addingTimeInterval(3_601)))
    }

    func testDifferentUsersCannotReadEachOthersThreadID() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = CodexSessionRegistry(rootDirectory: root)
        let now = Date(timeIntervalSince1970: 1_777_000_000)

        try registry.save(CodexSessionBinding(uid: "GZC-000001", threadID: "thread-a", lastUsedAt: now))

        XCTAssertNil(try registry.activeBinding(uid: "GZC-000002", now: now))
    }

    func testRejectsBindingWhoseStoredUIDDoesNotMatchDirectoryUID() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("用户/GZC-000001", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("codex-session.json")
        try Data(
            "{\"uid\":\"GZC-000002\",\"threadID\":\"wrong\",\"lastUsedAt\":\"2026-08-28T00:00:00Z\"}".utf8
        ).write(to: url)
        let registry = CodexSessionRegistry(rootDirectory: root)

        XCTAssertThrowsError(try registry.activeBinding(uid: "GZC-000001", now: Date()))
    }

    func testInvalidateRemovesOnlyTargetUsersBinding() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = CodexSessionRegistry(rootDirectory: root)
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        try registry.save(CodexSessionBinding(uid: "GZC-000001", threadID: "a", lastUsedAt: now))
        try registry.save(CodexSessionBinding(uid: "GZC-000002", threadID: "b", lastUsedAt: now))

        try registry.invalidate(uid: "GZC-000001")

        XCTAssertNil(try registry.activeBinding(uid: "GZC-000001", now: now))
        XCTAssertEqual(try registry.activeBinding(uid: "GZC-000002", now: now)?.threadID, "b")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-session-registry-\(UUID().uuidString)")
    }
}
