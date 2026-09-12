import Darwin
import Foundation

struct CodexProcessResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

protocol CodexProcessRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        stdin: String,
        timeout: TimeInterval
    ) async throws -> CodexProcessResult

    func runStreaming(
        executable: URL,
        arguments: [String],
        stdin: String,
        timeout: TimeInterval,
        onStandardOutput: @escaping @Sendable (Data) -> Void,
        onStandardInputClosed: @escaping @Sendable () -> Void
    ) async throws -> CodexProcessResult
}

extension CodexProcessRunning {
    func runStreaming(
        executable: URL,
        arguments: [String],
        stdin: String,
        timeout: TimeInterval,
        onStandardOutput: @escaping @Sendable (Data) -> Void,
        onStandardInputClosed: @escaping @Sendable () -> Void
    ) async throws -> CodexProcessResult {
        onStandardInputClosed()
        let result = try await run(
            executable: executable, arguments: arguments, stdin: stdin, timeout: timeout
        )
        onStandardOutput(Data(result.stdout.utf8))
        return result
    }
}

enum CodexProcessError: LocalizedError {
    case executableMissing(String)
    case timeout(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            return "未找到可执行的 Codex CLI：\(path)"
        case .timeout(let seconds):
            return "Codex CLI 超过 \(Int(seconds)) 秒仍未完成。"
        }
    }
}

struct CodexProcessRunner: CodexProcessRunning {
    let environment: [String: String]?

    init(environment: [String: String]? = nil) {
        self.environment = environment
    }

    func run(
        executable: URL,
        arguments: [String],
        stdin: String,
        timeout: TimeInterval
    ) async throws -> CodexProcessResult {
        try await runStreaming(
            executable: executable,
            arguments: arguments,
            stdin: stdin,
            timeout: timeout,
            onStandardOutput: { _ in },
            onStandardInputClosed: {}
        )
    }

    func runStreaming(
        executable: URL,
        arguments: [String],
        stdin: String,
        timeout: TimeInterval,
        onStandardOutput: @escaping @Sendable (Data) -> Void,
        onStandardInputClosed: @escaping @Sendable () -> Void
    ) async throws -> CodexProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CodexProcessError.executableMissing(executable.path)
        }
        var sanitized = environment ?? ProcessInfo.processInfo.environment
        sanitized.removeValue(forKey: "OPENAI_API_KEY")
        sanitized.removeValue(forKey: "CODEX_API_KEY")
        let result = await BoundedProcess.run(
            .init(
                executable: executable,
                arguments: arguments,
                environment: sanitized,
                standardInput: Data(stdin.utf8),
                onStandardOutput: onStandardOutput,
                onStandardInputClosed: onStandardInputClosed
            ),
            softDeadline: .seconds(min(90, max(1, timeout))),
            hardDeadline: .seconds(max(1, timeout))
        )
        let exitCode: Int32
        switch result.termination {
        case .exited(let code): exitCode = code
        case .hardDeadline: throw CodexProcessError.timeout(timeout)
        case .launchFailed(_, let message):
            throw CodexProcessError.executableMissing(message)
        }
        return CodexProcessResult(
            exitCode: exitCode,
            stdout: String(decoding: result.stdout, as: UTF8.self),
            stderr: String(decoding: result.stderr, as: UTF8.self)
        )
    }
}
