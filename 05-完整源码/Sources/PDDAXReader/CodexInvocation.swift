import Foundation

enum CodexTurnMode: Equatable, Sendable {
    case create
    case resume(sessionID: String)
}

struct CodexInvocation: Equatable, Sendable {
    static let model = "gpt-5.6-sol"
    static let reasoningEffort = "medium"

    let arguments: [String]

    init(
        mode: CodexTurnMode,
        schemaURL: URL,
        resultURL: URL,
        workingDirectoryURL: URL? = nil,
        imageURLs: [URL] = []
    ) {
        var arguments = ["-a", "never", "--disable", "shell_tool", "exec"]
        if case .resume = mode { arguments.append("resume") }
        arguments.append(contentsOf: [
            "--json",
            "--ignore-user-config",
            "--ignore-rules",
            "-m", Self.model,
            "-c", "model_reasoning_effort=\"\(Self.reasoningEffort)\"",
            "--skip-git-repo-check"
        ])
        if let workingDirectoryURL {
            arguments.append(contentsOf: ["-C", workingDirectoryURL.path])
        }
        if case .create = mode {
            arguments.append(contentsOf: ["-s", "read-only"])
        }
        arguments.append(contentsOf: [
            "--output-schema", schemaURL.path,
            "-o", resultURL.path
        ])
        for imageURL in imageURLs {
            arguments.append(contentsOf: ["-i", imageURL.path])
        }
        if case .resume(let sessionID) = mode { arguments.append(sessionID) }
        arguments.append("-")
        self.arguments = arguments
    }

    static func arguments(
        sessionID: String?,
        schemaURL: URL,
        resultURL: URL,
        imageURLs: [URL] = []
    ) -> [String] {
        CodexInvocation(
            mode: sessionID.map(CodexTurnMode.resume(sessionID:)) ?? .create,
            schemaURL: schemaURL,
            resultURL: resultURL,
            imageURLs: imageURLs
        ).arguments
    }
}
