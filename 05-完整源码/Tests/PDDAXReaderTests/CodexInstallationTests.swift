import XCTest
@testable import PDDAXReader

final class CodexInstallationTests: XCTestCase {
    func testDefaultCandidatesIncludeUserApplicationsForCodexAndChatGPT() {
        let home = URL(fileURLWithPath: "/Users/colleague", isDirectory: true)

        XCTAssertEqual(
            Array(CodexInstallation.defaultAppCandidates(homeDirectory: home).prefix(2)),
            [
                URL(fileURLWithPath: "/Users/colleague/Applications/ChatGPT.app/Contents/Resources/codex"),
                URL(fileURLWithPath: "/Users/colleague/Applications/Codex.app/Contents/Resources/codex"),
            ]
        )
    }

    func testExplicitExecutableWinsOverAppAndPATHCandidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let explicit = try executable(root.appendingPathComponent("explicit-codex"))
        let app = try executable(root.appendingPathComponent("app-codex"))
        let path = try executable(root.appendingPathComponent("path-codex"))

        let result = CodexInstallation.resolve(
            environment: ["PDD_CODEX_PATH": explicit.path, "PATH": root.path],
            appCandidates: [app],
            pathExecutableName: path.lastPathComponent,
            fileManager: .default
        )

        XCTAssertEqual(result, explicit)
    }

    func testFallsBackToFirstExecutableAppCandidate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing")
        let app = try executable(root.appendingPathComponent("app-codex"))

        XCTAssertEqual(CodexInstallation.resolve(
            environment: [:], appCandidates: [missing, app], pathExecutableName: "codex", fileManager: .default
        ), app)
    }

    private func executable(_ url: URL) throws -> URL {
        try Data("#!/bin/zsh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
