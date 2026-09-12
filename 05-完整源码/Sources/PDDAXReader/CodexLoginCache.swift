import Foundation

enum CodexLoginStatus: Equatable, Sendable {
    case chatGPT
    case notLoggedIn
}

protocol CodexLoginChecking: Sendable {
    func check(executable: URL) async throws -> CodexLoginStatus
}

protocol CodexLoginStatusProviding: Sendable {
    func status(executable: URL, now: Date) async throws -> CodexLoginStatus
}

struct LiveCodexLoginChecker: CodexLoginChecking {
    let runner: any CodexProcessRunning

    init(runner: any CodexProcessRunning = CodexProcessRunner()) {
        self.runner = runner
    }

    func check(executable: URL) async throws -> CodexLoginStatus {
        let result = try await runner.run(
            executable: executable,
            arguments: ["login", "status"],
            stdin: "",
            timeout: 30
        )
        guard result.exitCode == 0 else { return .notLoggedIn }
        let output = result.stdout + "\n" + result.stderr
        return output.localizedCaseInsensitiveContains("Logged in using ChatGPT")
            ? .chatGPT : .notLoggedIn
    }
}

actor CodexLoginCache: CodexLoginStatusProviding {
    private struct Entry { let executablePath: String; let expiresAt: Date }

    private let checker: any CodexLoginChecking
    private let successTTL: TimeInterval
    private var entry: Entry?
    private var inFlight: (path: String, task: Task<CodexLoginStatus, Error>)?

    init(checker: any CodexLoginChecking = LiveCodexLoginChecker(), successTTL: TimeInterval = 60) {
        self.checker = checker
        self.successTTL = successTTL
    }

    func status(executable: URL, now: Date = Date()) async throws -> CodexLoginStatus {
        if let entry, entry.executablePath == executable.path, now < entry.expiresAt {
            return .chatGPT
        }
        let task: Task<CodexLoginStatus, Error>
        if let inFlight, inFlight.path == executable.path {
            task = inFlight.task
        } else {
            task = Task { try await checker.check(executable: executable) }
            inFlight = (executable.path, task)
        }
        let status: CodexLoginStatus
        do {
            status = try await task.value
        } catch {
            if inFlight?.path == executable.path { inFlight = nil }
            throw error
        }
        if inFlight?.path == executable.path { inFlight = nil }
        if status == .chatGPT {
            entry = Entry(executablePath: executable.path, expiresAt: now.addingTimeInterval(successTTL))
        } else {
            entry = nil
        }
        return status
    }
}
