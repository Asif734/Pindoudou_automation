import XCTest
@testable import PDDAXReader

final class CodexCompatibilityProbeTests: XCTestCase {
    func testMissingAuthenticationProducesActionableFailure() async throws {
        let runner = CodexProbeRunner(results: [
            .init(exitCode: 0, stdout: "codex-cli 1.2.3", stderr: ""),
            .init(exitCode: 1, stdout: "", stderr: "Not logged in"),
        ])
        let probe = CodexCompatibilityProbe(runner: runner)

        let result = await probe.check(executableURL: URL(fileURLWithPath: "/bin/echo"))

        XCTAssertEqual(result, .missingAuthentication)
    }

    func testUnsupportedInvocationIsNotReportedAsReady() async throws {
        let runner = CodexProbeRunner(results: [
            .init(exitCode: 2, stdout: "", stderr: "unknown option --version")
        ])
        let probe = CodexCompatibilityProbe(runner: runner)

        let result = await probe.check(executableURL: URL(fileURLWithPath: "/bin/echo"))

        XCTAssertEqual(result, .unsupportedCLI)
    }

    func testChatGPTLoginIsReadyWithoutSubmittingPrompt() async throws {
        let runner = CodexProbeRunner(results: [
            .init(exitCode: 0, stdout: "codex-cli 1.2.3", stderr: ""),
            .init(exitCode: 0, stdout: "Logged in using ChatGPT", stderr: ""),
        ])
        let probe = CodexCompatibilityProbe(runner: runner)

        let result = await probe.check(executableURL: URL(fileURLWithPath: "/bin/echo"))

        XCTAssertEqual(result, .ready)
        let calls = await runner.calls
        XCTAssertEqual(calls.map(\.arguments), [["--version"], ["login", "status"]])
        XCTAssertTrue(calls.allSatisfy { $0.stdin.isEmpty })
    }
}

private actor CodexProbeRunner: CodexProcessRunning {
    struct Call: Sendable {
        let arguments: [String]
        let stdin: String
    }
    private var results: [CodexProcessResult]
    private(set) var calls: [Call] = []

    init(results: [CodexProcessResult]) { self.results = results }

    func run(
        executable: URL, arguments: [String], stdin: String, timeout: TimeInterval
    ) async throws -> CodexProcessResult {
        calls.append(.init(arguments: arguments, stdin: stdin))
        return results.removeFirst()
    }
}
