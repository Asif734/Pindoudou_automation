import Foundation

enum AutoReplyCodexGeneratorError: LocalizedError {
    case missingBatch
    case commandFailed(Int32, String)
    case missingCompletion
    case missingThreadID
    case invalidReply(String)
    case freshSessionRetryFailed(String)
    case chatGPTLoginRequired
    case invalidImageAttachment(String)

    var errorDescription: String? {
        switch self {
        case .missingBatch: return "冻结批次为空"
        case .commandFailed(let code, let stderr): return "Codex CLI 退出码 \(code)：\(stderr)"
        case .missingCompletion: return "Codex CLI 没有返回 turn.completed"
        case .missingThreadID: return "Codex CLI 没有返回 thread ID"
        case .invalidReply(let reason): return "Codex 回复无效：\(reason)"
        case .freshSessionRetryFailed(let reason):
            return "Codex 新会话或新进程重试仍失败：\(reason)"
        case .chatGPTLoginRequired: return "Codex CLI 必须使用本机 ChatGPT 账号登录"
        case .invalidImageAttachment(let path): return "Codex 图片附件不存在或不是本地文件：\(path)"
        }
    }
}

struct AutoReplyCodexGenerator: AutoReplyGenerating, Sendable {
    let executableURL: URL
    let runner: any CodexProcessRunning
    let sessionRegistry: CodexSessionRegistry
    let evidencePreparer: any KnowledgeEvidencePreparing
    let loginStatusProvider: (any CodexLoginStatusProviding)?
    let timeout: TimeInterval
    let now: @Sendable () -> Date

    init(
        executableURL: URL = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
        runner: any CodexProcessRunning = CodexProcessRunner(),
        sessionRegistry: CodexSessionRegistry = CodexSessionRegistry(
            rootDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/拼多多AX记录/自动回复", isDirectory: true)
        ),
        evidencePreparer: any KnowledgeEvidencePreparing = DirectLocalKnowledge(),
        loginStatusProvider: (any CodexLoginStatusProviding)? = nil,
        timeout: TimeInterval = 180,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.sessionRegistry = sessionRegistry
        self.evidencePreparer = evidencePreparer
        self.loginStatusProvider = loginStatusProvider
        self.timeout = timeout
        self.now = now
    }

    func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult {
        guard capture.batch != nil else { throw AutoReplyCodexGeneratorError.missingBatch }
        if let loginStatusProvider {
            guard try await loginStatusProvider.status(executable: executableURL, now: now()) == .chatGPT else {
                throw AutoReplyCodexGeneratorError.chatGPTLoginRequired
            }
        }
        var enrichedCapture = capture
        let evidence = await evidencePreparer.prepare(capture: capture)
        enrichedCapture.knowledgeEvidence = evidence
        let promptSHA256 = try CustomerServicePrompt.runtimeSHA256()
        let knowledgeSHA256 = evidence.diagnostic.knowledgeBaseSHA256

        var retriedAfterContinuationFailure = false
        if let binding = try sessionRegistry.activeBinding(uid: capture.uid, now: now()) {
            let legacyCheckpoint = binding.historyCheckpoint?.requiresFullHistoryContinuation == true
            let directKnowledgeCompatible = evidence.mode != .directLocal
                || (binding.knowledgeSHA256 == knowledgeSHA256 && binding.promptSHA256 == promptSHA256)
            let compatible = directKnowledgeCompatible && !binding.contaminated
                && binding.turnCount < 40
                && binding.submittedBytes < 4_000_000
                && (legacyCheckpoint
                    || binding.promptSHA256 == nil || binding.promptSHA256 == promptSHA256)
                && (legacyCheckpoint
                    || binding.knowledgeSHA256 == nil || binding.knowledgeSHA256 == knowledgeSHA256)
            if compatible {
                let submission = try HistoryContinuation.plan(
                    capture: enrichedCapture,
                    after: binding.historyCheckpoint
                )
                if submission.mode == .incremental {
                    do {
                        let turn = try await runTurn(
                            capture: enrichedCapture,
                            submission: submission,
                            sessionID: binding.threadID,
                            continuation: true
                        )
                        let submittedPrompt = try AutoReplyPromptBuilder.buildContinuation(
                            capture: enrichedCapture,
                            submission: submission
                        )
                        try sessionRegistry.save(.init(
                            uid: capture.uid,
                            threadID: turn.startedThreadID ?? binding.threadID,
                            lastUsedAt: now(),
                            historyCheckpoint: submission.checkpoint,
                            promptSHA256: promptSHA256,
                            knowledgeSHA256: knowledgeSHA256,
                            turnCount: binding.turnCount + 1,
                            submittedBytes: binding.submittedBytes + submittedPrompt.utf8.count,
                            contaminated: turn.contaminated
                        ))
                        return CodexReplyResult(
                            reply: turn.reply,
                            threadID: turn.startedThreadID ?? binding.threadID,
                            diagnostic: diagnostic(evidence: evidence, turn: turn),
                            action: turn.action,
                            transferReason: turn.transferReason
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try sessionRegistry.invalidate(uid: capture.uid)
                        retriedAfterContinuationFailure = true
                    }
                } else {
                    try sessionRegistry.invalidate(uid: capture.uid)
                }
            } else {
                try sessionRegistry.invalidate(uid: capture.uid)
            }
        }

        let submission = try HistoryContinuation.plan(capture: enrichedCapture, after: nil)
        let turn: TurnResult
        do {
            turn = try await runTurn(
                capture: enrichedCapture,
                submission: submission,
                sessionID: nil,
                continuation: false
            )
        } catch {
            if retriedAfterContinuationFailure {
                switch CodexFailureClassifier.classify(error) {
                case .transferImmediately, .retryOnceThenTransfer:
                    throw AutoReplyCodexGeneratorError.freshSessionRetryFailed(
                        error.localizedDescription
                    )
                case .ordinaryRetry, .cancelled:
                    break
                }
            }
            throw error
        }
        guard let threadID = turn.startedThreadID, !threadID.isEmpty else {
            throw AutoReplyCodexGeneratorError.missingThreadID
        }
        try sessionRegistry.save(.init(
            uid: capture.uid,
            threadID: threadID,
            lastUsedAt: now(),
            historyCheckpoint: submission.checkpoint,
            promptSHA256: promptSHA256,
            knowledgeSHA256: knowledgeSHA256,
            turnCount: 1,
            submittedBytes: try AutoReplyPromptBuilder.buildInitial(
                capture: enrichedCapture,
                submission: submission
            ).utf8.count,
            contaminated: turn.contaminated
        ))
        return CodexReplyResult(
            reply: turn.reply,
            threadID: threadID,
            diagnostic: diagnostic(evidence: evidence, turn: turn),
            action: turn.action,
            transferReason: turn.transferReason
        )
    }

    private struct TurnResult {
        var answerFound = true
        var semanticEvidence: KnowledgeEvidence? = nil
        var reply: String
        var action: CodexReplyAction
        var transferReason: CodexTransferReason
        var requestKind: CustomerRequestKind? = nil
        var issueHasNoSolution = false
        var clarificationReply: String? = nil
        var handoffReply: String? = nil
        let startedThreadID: String?
        let durationMilliseconds: Int
        let events: [CodexExecutionEvent]
        let contaminated: Bool
    }
    private struct ReplyDocument: Decodable {
        let answerFound: Bool?
        let requestKind: CustomerRequestKind?
        let issueHasNoSolution: Bool?
        let clarificationReply: String?
        let handoffReply: String?
        let action: CodexReplyAction
        let replyText: String
        let transferReason: CodexTransferReason

        private enum CodingKeys: String, CodingKey {
            case answerFound = "answer_found"
            case requestKind = "request_kind"
            case issueHasNoSolution = "issue_has_no_solution"
            case clarificationReply = "clarification_reply"
            case handoffReply = "handoff_reply"
            case action
            case replyText = "reply_text"
            case transferReason = "transfer_reason"
        }
    }

    private func runTurn(
        capture: AutoReplyCapture,
        submission: HistorySubmission,
        sessionID: String?,
        continuation: Bool
    ) async throws -> TurnResult {
        var turn = try await runSingleTurn(capture: capture, submission: submission,
                                           sessionID: sessionID, continuation: continuation)
        if let kind = turn.requestKind {
            let decision = try await CustomerTransferPolicyStore.shared.decide(
                root: sessionRegistry.rootDirectory, uid: capture.uid,
                messageIDs: capture.batch?.events.map(\.messageID) ?? [], kind: kind,
                answerFound: turn.answerFound, issueHasNoSolution: turn.issueHasNoSolution,
                proposedAction: turn.action, proposedReason: turn.transferReason, now: now())
            let needsClarification = decision.action == .reply
                && (kind == .humanRequest || kind == .refundReturn)
            let selectedReply = decision.action == .replyThenTransfer ? turn.handoffReply
                : needsClarification || turn.action == .replyThenTransfer ? turn.clarificationReply : turn.reply
            guard let selectedReply, !selectedReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutoReplyCodexGeneratorError.invalidReply("缺少转人工或澄清话术")
            }
            turn.reply = selectedReply.trimmingCharacters(in: .whitespacesAndNewlines)
            turn.action = decision.action
            turn.transferReason = decision.reason
        }
        guard turn.reply.range(of: #"\bAI\b"#, options: [.regularExpression, .caseInsensitive]) == nil else {
            throw AutoReplyCodexGeneratorError.invalidReply("Customer-facing identity wording is not allowed")
        }
        return turn
    }

    private func runSingleTurn(
        capture: AutoReplyCapture,
        submission: HistorySubmission,
        sessionID: String?,
        continuation: Bool
    ) async throws -> TurnResult {
        for video in submission.videoAttachments {
            try validateLocalFile(video.localURL)
            if let audio = video.audioLocalURL { try validateLocalFile(audio) }
            if let manifest = video.manifestLocalURL { try validateLocalFile(manifest) }
        }
        let imageURLs = try submission.imageAttachments.map { attachment in
            let url = attachment.localURL
            var isDirectory: ObjCBool = false
            guard url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw AutoReplyCodexGeneratorError.invalidImageAttachment(url.path)
            }
            return url
        }
        let videoFrameURLs = try submission.videoAttachments.flatMap { video in
            video.frames.sorted { $0.timestampSeconds < $1.timestampSeconds }.map(\.localURL)
        }.map { url in
            var isDirectory: ObjCBool = false
            guard url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw AutoReplyCodexGeneratorError.invalidImageAttachment(url.path)
            }
            return url
        }
        let startedAt = now()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-auto-reply-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let schemaURL = temporary.appendingPathComponent("reply.schema.json")
        let resultURL = temporary.appendingPathComponent("result.json")
        let schema = """
        {"type":"object","properties":{"answer_found":{"type":"boolean"},"action":{"type":"string","enum":["reply","reply_then_transfer"]},"reply_text":{"type":"string","minLength":1},"transfer_reason":{"type":"string","enum":["customer_explicitly_requested_human","explicit_return_refund","remote_assistance","refund_operation","logistics_lookup","troubleshooting_exhausted","none"]},"request_kind":{"type":"string","enum":["other","human_request","refund_return","technical"]},"issue_has_no_solution":{"type":"boolean"},"clarification_reply":{"type":"string","minLength":1},"handoff_reply":{"type":"string","minLength":1}},"required":["answer_found","action","reply_text","transfer_reason","request_kind","issue_has_no_solution","clarification_reply","handoff_reply"],"additionalProperties":false}
        """
        try Data(schema.utf8).write(to: schemaURL, options: .atomic)
        let arguments = CodexInvocation.arguments(
            sessionID: sessionID,
            schemaURL: schemaURL,
            resultURL: resultURL,
            imageURLs: imageURLs + videoFrameURLs,
            workingDirectoryURL: DirectLocalKnowledge.configuredURL
        )
        let policyContext = try await CustomerTransferPolicyStore.shared.context(
            root: sessionRegistry.rootDirectory, uid: capture.uid, now: now())
        let basePrompt = continuation
            ? try AutoReplyPromptBuilder.buildContinuation(capture: capture, submission: submission)
            : try AutoReplyPromptBuilder.buildInitial(capture: capture, submission: submission)
        let prompt = basePrompt + "\n<application_transfer_state>\n" + policyContext + "\n</application_transfer_state>"
        let stream = AutoReplyCLIStream()
        return try await withCheckedThrowingContinuation { checked in
            let handoff = CodexTurnHandoff<TurnResult>(checked)
            Task.detached(priority: .userInitiated) {
                do {
                    let process = try await runner.runStreaming(
                        executable: executableURL,
                        arguments: arguments,
                        stdin: prompt,
                        timeout: timeout,
                        onStandardOutput: { chunk in
                            guard let candidate = stream.consume(chunk) else { return }
                            handoff.offer(TurnResult(
                                answerFound: candidate.answerFound,
                                reply: candidate.reply,
                                action: candidate.action,
                                transferReason: candidate.transferReason,
                                startedThreadID: candidate.threadID,
                                durationMilliseconds: max(
                                    0, Int(now().timeIntervalSince(startedAt) * 1_000)
                                ),
                                events: candidate.events,
                                contaminated: Self.isContaminated(candidate.events)
                            ))
                        },
                        onStandardInputClosed: { handoff.didWriteInput() }
                    )
                    stream.finish()
                    let final = Result {
                        try Self.decodeCompletedProcess(
                            process,
                            resultURL: resultURL,
                            startedAt: startedAt,
                            now: now
                        )
                    }
                    try? FileManager.default.removeItem(at: temporary)
                    handoff.finish(final)
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    handoff.finish(.failure(error))
                }
            }
        }
    }

    private func validateLocalFile(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw AutoReplyCodexGeneratorError.invalidImageAttachment(url.path)
        }
    }

    private static func decodeCompletedProcess(
        _ process: CodexProcessResult,
        resultURL: URL,
        startedAt: Date,
        now: @Sendable () -> Date
    ) throws -> TurnResult {
        guard process.exitCode == 0 else {
            throw AutoReplyCodexGeneratorError.commandFailed(process.exitCode, process.stderr)
        }

        var completed = false
        var startedThreadID: String?
        var events: [CodexExecutionEvent] = []
        for line in process.stdout.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "turn.completed" { completed = true }
            if type == "thread.started" { startedThreadID = object["thread_id"] as? String }
            events.append(CodexExecutionEvent(type: type, threadID: object["thread_id"] as? String))
        }
        guard completed else { throw AutoReplyCodexGeneratorError.missingCompletion }
        let document: ReplyDocument
        do {
            document = try JSONDecoder().decode(ReplyDocument.self, from: Data(contentsOf: resultURL))
        } catch {
            throw AutoReplyCodexGeneratorError.invalidReply(error.localizedDescription)
        }
        guard (document.action == .reply && document.transferReason == .none)
                || (document.action == .replyThenTransfer && document.transferReason != .none)
        else {
            throw AutoReplyCodexGeneratorError.invalidReply("action 与 transfer_reason 不匹配")
        }
        let reply = document.replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { throw AutoReplyCodexGeneratorError.invalidReply("reply_text 为空") }
        return TurnResult(
            answerFound: document.answerFound ?? true,
            reply: reply,
            action: document.action,
            transferReason: document.transferReason,
            requestKind: document.requestKind,
            issueHasNoSolution: document.issueHasNoSolution ?? false,
            clarificationReply: document.clarificationReply,
            handoffReply: document.handoffReply,
            startedThreadID: startedThreadID,
            durationMilliseconds: max(0, Int(now().timeIntervalSince(startedAt) * 1_000)),
            events: events,
            contaminated: isContaminated(events)
        )
    }

    private static func isContaminated(_ events: [CodexExecutionEvent]) -> Bool {
        events.contains {
            let type = $0.type.lowercased()
            return type.contains("tool") || type.contains("command")
                || type.contains("mcp") || type.contains("web")
        }
    }

    private func diagnostic(
        evidence: KnowledgeEvidence,
        turn: TurnResult
    ) -> AutoReplyGenerationDiagnostic {
        AutoReplyGenerationDiagnostic(
            knowledge: (turn.semanticEvidence ?? evidence).diagnostic,
            codexDurationMilliseconds: turn.durationMilliseconds,
            events: turn.events
        )
    }
}
