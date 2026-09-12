import Foundation

enum CodexCompatibilityResult: Equatable, Sendable {
    case missingExecutable
    case unsupportedCLI
    case missingAuthentication
    case ready

    var compatibilityItem: PDDCompatibilityItem {
        switch self {
        case .missingExecutable:
            return .init(kind: .codex, status: .fail, detail: BilingualText.lines("未找到 Codex CLI", "Codex CLI was not found"))
        case .unsupportedCLI:
            return .init(kind: .codex, status: .fail, detail: BilingualText.lines("Codex CLI 版本不兼容", "Codex CLI version is incompatible"))
        case .missingAuthentication:
            return .init(kind: .codex, status: .fail, detail: BilingualText.lines("Codex CLI 未登录 ChatGPT", "Codex CLI is not signed in with ChatGPT"))
        case .ready:
            return .init(kind: .codex, status: .pass, detail: BilingualText.lines("Codex CLI 已登录 ChatGPT", "Codex CLI is signed in with ChatGPT"))
        }
    }
}

struct CodexCompatibilityProbe: Sendable {
    let runner: any CodexProcessRunning

    init(runner: any CodexProcessRunning = CodexProcessRunner()) {
        self.runner = runner
    }

    func check(executableURL: URL?) async -> CodexCompatibilityResult {
        guard let executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return .missingExecutable
        }
        do {
            let version = try await runner.run(
                executable: executableURL,
                arguments: ["--version"],
                stdin: "",
                timeout: 5
            )
            guard version.exitCode == 0 else { return .unsupportedCLI }
            let login = try await runner.run(
                executable: executableURL,
                arguments: ["login", "status"],
                stdin: "",
                timeout: 10
            )
            let output = login.stdout + "\n" + login.stderr
            guard login.exitCode == 0,
                  output.localizedCaseInsensitiveContains("Logged in using ChatGPT") else {
                return .missingAuthentication
            }
            return .ready
        } catch {
            return .unsupportedCLI
        }
    }
}
