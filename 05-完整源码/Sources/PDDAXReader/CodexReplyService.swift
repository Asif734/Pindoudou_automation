import Foundation

enum CodexReplyAction: String, Codable, Equatable, Sendable {
    case reply
    case replyThenTransfer = "reply_then_transfer"
}

enum CodexTransferReason: String, Codable, Equatable, Sendable, CaseIterable {
    case customerExplicitlyRequestedHuman = "customer_explicitly_requested_human"
    case explicitReturnRefund = "explicit_return_refund"
    case remoteAssistance = "remote_assistance"
    case refundOperation = "refund_operation"
    case logisticsLookup = "logistics_lookup"
    case troubleshootingExhausted = "troubleshooting_exhausted"
    case none
}

struct CodexReplyResult: Equatable, Sendable {
    let reply: String
    let threadID: String
    var diagnostic: AutoReplyGenerationDiagnostic? = nil
    var action: CodexReplyAction = .reply
    var transferReason: CodexTransferReason = .none
}

enum CodexReplyServiceError: LocalizedError {
    case commandFailed(Int32, String)
    case missingCompletion
    case missingThreadID
    case invalidResult(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let code, let stderr):
            return "Codex CLI 退出码 \(code)：\(stderr)"
        case .missingCompletion:
            return "Codex CLI 没有返回 turn.completed，建议未被接受。"
        case .missingThreadID:
            return "Codex CLI 没有返回新会话 thread ID。"
        case .invalidResult(let reason):
            return "Codex 建议结果无效：\(reason)"
        }
    }
}

struct CodexReplyService: Sendable {
    let executableURL: URL
    let runner: any CodexProcessRunning
    let sessionRegistry: CodexSessionRegistry
    let timeout: TimeInterval
    let now: @Sendable () -> Date

    init(
        executableURL: URL = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
        runner: any CodexProcessRunning = CodexProcessRunner(),
        sessionRegistry: CodexSessionRegistry = CodexSessionRegistry(),
        timeout: TimeInterval = 180,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.sessionRegistry = sessionRegistry
        self.timeout = timeout
        self.now = now
    }

    func generate(uid: String, history: [PDDChatMessage]) async throws -> CodexReplyResult {
        if let binding = try sessionRegistry.activeBinding(uid: uid, now: now()) {
            do {
                let reply = try await runTurn(uid: uid, history: history, sessionID: binding.threadID)
                try sessionRegistry.save(CodexSessionBinding(
                    uid: uid,
                    threadID: binding.threadID,
                    lastUsedAt: now()
                ))
                return CodexReplyResult(reply: reply.reply, threadID: binding.threadID)
            } catch {
                try sessionRegistry.invalidate(uid: uid)
            }
        }

        let created = try await runTurn(uid: uid, history: history, sessionID: nil)
        guard let threadID = created.startedThreadID, !threadID.isEmpty else {
            throw CodexReplyServiceError.missingThreadID
        }
        try sessionRegistry.save(CodexSessionBinding(uid: uid, threadID: threadID, lastUsedAt: now()))
        return CodexReplyResult(reply: created.reply, threadID: threadID)
    }

    private struct TurnResult {
        let reply: String
        let startedThreadID: String?
    }

    private struct ReplyDocument: Decodable {
        let reply: String
    }

    private func runTurn(
        uid: String,
        history: [PDDChatMessage],
        sessionID: String?
    ) async throws -> TurnResult {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-codex-reply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let schemaURL = temporary.appendingPathComponent("reply.schema.json")
        let resultURL = temporary.appendingPathComponent("result.json")
        let schema = """
        {"type":"object","properties":{"reply":{"type":"string","minLength":1}},"required":["reply"],"additionalProperties":false}
        """
        try Data(schema.utf8).write(to: schemaURL, options: .atomic)

        let processResult = try await runner.run(
            executable: executableURL,
            arguments: CodexInvocation.arguments(
                sessionID: sessionID,
                schemaURL: schemaURL,
                resultURL: resultURL
            ),
            stdin: CustomerReplyPromptBuilder.build(uid: uid, history: history),
            timeout: timeout
        )
        guard processResult.exitCode == 0 else {
            throw CodexReplyServiceError.commandFailed(
                processResult.exitCode,
                processResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        var completed = false
        var startedThreadID: String?
        for line in processResult.stdout.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "turn.completed" { completed = true }
            if type == "thread.started", let threadID = object["thread_id"] as? String {
                startedThreadID = threadID
            }
        }
        guard completed else { throw CodexReplyServiceError.missingCompletion }
        guard FileManager.default.fileExists(atPath: resultURL.path) else {
            throw CodexReplyServiceError.invalidResult("没有生成结果文件")
        }
        let document: ReplyDocument
        do {
            document = try JSONDecoder().decode(ReplyDocument.self, from: Data(contentsOf: resultURL))
        } catch {
            throw CodexReplyServiceError.invalidResult(error.localizedDescription)
        }
        let reply = document.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw CodexReplyServiceError.invalidResult("reply 为空") }
        return TurnResult(reply: reply, startedThreadID: startedThreadID)
    }
}
