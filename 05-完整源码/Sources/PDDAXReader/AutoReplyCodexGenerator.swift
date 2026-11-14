import Foundation

enum AutoReplyCodexGeneratorError: LocalizedError {
    case missingBatch
    case commandFailed(Int32, String)
    case missingCompletion
    case missingThreadID
    case invalidReply(String)
    case customerFacingWording(String)
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
        case .customerFacingWording(let reason): return "客服回复措辞需修正：\(reason)"
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
    let outgoingImageDatasetRoot: URL

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
        now: @escaping @Sendable () -> Date = { Date() },
        outgoingImageDatasetRoot: URL = DirectLocalKnowledge.configuredURL
    ) {
        self.executableURL = executableURL
        self.runner = runner
        self.sessionRegistry = sessionRegistry
        self.evidencePreparer = evidencePreparer
        self.loginStatusProvider = loginStatusProvider
        self.timeout = timeout
        self.now = now
        self.outgoingImageDatasetRoot = outgoingImageDatasetRoot
    }

    func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult {
        AutomationStepLog.record(root: sessionRegistry.rootDirectory, uid: capture.uid,
            step: "generation-started", detail: "incoming_handoff=\(capture.batch?.incomingHandoffKey != nil)")
        guard capture.batch != nil else { throw AutoReplyCodexGeneratorError.missingBatch }
        try CustomerMessageReceipts(root: sessionRegistry.rootDirectory).capture(capture)
        if let loginStatusProvider {
            guard try await loginStatusProvider.status(executable: executableURL, now: now()) == .chatGPT else {
                throw AutoReplyCodexGeneratorError.chatGPTLoginRequired
            }
        }
        let activeBinding = try sessionRegistry.activeBinding(uid: capture.uid, now: now())
        var enrichedCapture = HistoryContinuation.retainingRecentMedia(in: capture,
            images: activeBinding?.historyCheckpoint?.contextImages ?? [],
            videos: activeBinding?.historyCheckpoint?.contextVideos ?? [])
        if let activeBinding, activeBinding.historyCheckpoint?.historyMessageLimit == nil {
            // Upgrade only attachment metadata, never old chat text. Reading this
            // snapshot is optional and cannot block an otherwise valid reply.
            struct MediaSnapshot: Decodable {
                struct Job: Decodable {
                    struct Capture: Decodable {
                        let imageAttachments: [AutoReplyImageAttachment]?
                        let videoAttachments: [AutoReplyVideoAttachment]?
                    }
                    let uid: String
                    let capture: Capture
                }
                let jobs: [Job]
            }
            if let data = try? Data(contentsOf: sessionRegistry.rootDirectory.appendingPathComponent("state.json")),
               let snapshot = try? JSONDecoder().decode(MediaSnapshot.self, from: data) {
                let ownJobs = snapshot.jobs.filter { $0.uid == capture.uid }
                enrichedCapture = HistoryContinuation.retainingRecentMedia(in: enrichedCapture,
                    images: ownJobs.flatMap { $0.capture.imageAttachments ?? [] },
                    videos: ownJobs.flatMap { $0.capture.videoAttachments ?? [] })
            }
        }
        let evidence = await evidencePreparer.prepare(capture: capture)
        enrichedCapture.knowledgeEvidence = evidence
        AutomationStepLog.record(root: sessionRegistry.rootDirectory, uid: capture.uid,
            step: "knowledge-prepared", detail: "mode=\(evidence.mode.rawValue) duration_ms=\(evidence.diagnostic.durationMilliseconds) hash_cache_hit=\(evidence.diagnostic.hashCacheHit.map(String.init) ?? "unknown") hashed_bytes=\(evidence.diagnostic.hashedByteCount ?? 0)")
        let promptSHA256 = try CustomerServicePrompt.runtimeSHA256()
        let knowledgeSHA256 = evidence.diagnostic.knowledgeBaseSHA256

        var retriedAfterContinuationFailure = false
        if let binding = activeBinding {
            let legacyCheckpoint = binding.historyCheckpoint?.requiresFullHistoryContinuation == true
            let directKnowledgeCompatible = evidence.mode != .directLocal
                || (binding.knowledgeSHA256 == knowledgeSHA256 && binding.promptSHA256 == promptSHA256)
            let compatible = binding.matchesCurrentModel && directKnowledgeCompatible && !binding.contaminated
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
                            continuation: true,
                            previousTokenUsage: binding.threadTokenUsage
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
                            contaminated: turn.contaminated,
                            threadTokenUsage: turn.threadTokenUsage
                        ))
                        return CodexReplyResult(
                            reply: turn.reply,
                            threadID: turn.startedThreadID ?? binding.threadID,
                            diagnostic: diagnostic(evidence: evidence, turn: turn),
                            action: turn.action,
                            transferReason: turn.transferReason,
                            outgoingImages: turn.outgoingImages
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try sessionRegistry.invalidate(uid: capture.uid)
                        retriedAfterContinuationFailure = true
                    }
                } else {
                    AutomationStepLog.record(root: sessionRegistry.rootDirectory, uid: capture.uid,
                        step: "codex-session-history-window-reset", detail: "history_limit=\(HistoryContinuation.maximumHistoryMessages); previous context is unbounded or the history window changed; durable history retained")
                    try sessionRegistry.invalidate(uid: capture.uid)
                }
            } else {
                if !binding.matchesCurrentModel {
                    AutomationStepLog.record(root: sessionRegistry.rootDirectory, uid: capture.uid,
                        step: "codex-session-model-reset", detail: "previous_model=\(binding.model ?? "unknown") model=\(CodexInvocation.model) reasoning=\(CodexInvocation.reasoningEffort); full history retained")
                }
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
            contaminated: turn.contaminated,
            threadTokenUsage: turn.threadTokenUsage
        ))
        return CodexReplyResult(
            reply: turn.reply,
            threadID: threadID,
            diagnostic: diagnostic(evidence: evidence, turn: turn),
            action: turn.action,
            transferReason: turn.transferReason,
            outgoingImages: turn.outgoingImages
        )
    }

    private struct TurnResult {
        var tokenUsage: CodexTokenUsage? = nil
        var threadTokenUsage: CodexTokenUsage? = nil
        var submissionID: UUID? = nil
        var answerFound = true
        var imagePaths: [String] = []
        var videoAnalysisReports: [PDDVideoAnalysisReport] = []
        var outgoingImages: [DatasetReplyImage] = []
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
        let imagePaths: [String]?
        let videoAnalysisReports: [PDDVideoAnalysisReport]?
        let requestKind: CustomerRequestKind?
        let issueHasNoSolution: Bool?
        let clarificationReply: String?
        let handoffReply: String?
        let action: CodexReplyAction
        let replyText: String
        let transferReason: CodexTransferReason

        private enum CodingKeys: String, CodingKey {
            case answerFound = "answer_found"
            case imagePaths = "image_paths"
            case videoAnalysisReports = "video_analysis_reports"
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
        continuation: Bool,
        previousTokenUsage: CodexTokenUsage? = nil
    ) async throws -> TurnResult {
        let reportCache = PDDVideoAnalysisReportCache(root: sessionRegistry.rootDirectory)
        let preparedSubmission = reportCache.reusingReports(in: submission, uid: capture.uid)
        if !capture.videoAttachments.isEmpty {
            AutomationStepLog.record(root: sessionRegistry.rootDirectory, uid: capture.uid,
                step: "video-analysis-report-cache", detail: "reused=\(preparedSubmission.reusedVideoAnalyses.count) analyze=\(preparedSubmission.videoAttachments.count)")
        }
        var turn = try await runSingleTurn(capture: capture, submission: preparedSubmission,
                                           sessionID: sessionID, continuation: continuation)
        // This CLI reports cumulative thread usage, including resumed turns.
        // Preserve the counter for the next turn; expose only this turn's delta.
        turn.threadTokenUsage = turn.tokenUsage
        if continuation {
            turn.tokenUsage = previousTokenUsage.flatMap { previous in
                turn.threadTokenUsage?.subtracting(previous)
            }
        }
        let usage = turn.tokenUsage
        AutomationStepLog.record(root: sessionRegistry.rootDirectory, uid: capture.uid,
            step: "codex-invocation-completed", detail: "model=\(CodexInvocation.model) duration_ms=\(turn.durationMilliseconds) usage_scope=\(usage == nil ? "unavailable" : "turn") input_tokens=\(usage.map { String($0.inputTokens) } ?? "unknown") cached_input_tokens=\(usage.map { String($0.cachedInputTokens) } ?? "unknown") output_tokens=\(usage.map { String($0.outputTokens) } ?? "unknown") total_tokens=\(usage.map { String($0.totalTokens) } ?? "unknown")")
        if capture.batch?.incomingHandoffKey != nil {
            // The platform event requests a continuation reply, never a new transfer.
            if turn.action == .replyThenTransfer, let clarification = turn.clarificationReply {
                turn.reply = clarification
            }
            turn.action = .reply
            turn.transferReason = .none
            AutomationStepLog.record(root: sessionRegistry.rootDirectory, uid: capture.uid,
                step: "incoming-handoff-reply-policy", detail: "reply-only; historical requests not counted")
        } else if let kind = turn.requestKind {
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
        if let violation = CustomerFacingReplyPolicy.violation(in: turn.reply) {
            var alternate = turn.action == .replyThenTransfer
                ? CustomerFacingFallback.handoff(history: capture.fullHistory) : turn.clarificationReply
            if violation == "video processing status", turn.action == .reply,
               alternate.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || CustomerFacingReplyPolicy.violation(in: $0) != nil }) ?? true {
                alternate = CustomerFacingFallback.videoQuestion(history: capture.fullHistory)
            }
            if let alternate, !alternate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               CustomerFacingReplyPolicy.violation(in: alternate) == nil {
                turn.reply = alternate.trimmingCharacters(in: .whitespacesAndNewlines)
                AutomationStepLog.record(root: sessionRegistry.rootDirectory, uid: capture.uid,
                    step: "reply-policy-corrected", detail: "\(violation); action preserved; same-turn alternative")
            } else {
                AutomationStepLog.record(root: sessionRegistry.rootDirectory, uid: capture.uid,
                    step: "reply-policy-rejected", detail: violation)
                throw AutoReplyCodexGeneratorError.customerFacingWording(violation)
            }
        }
        if turn.action == .reply, !turn.imagePaths.isEmpty {
            turn.outgoingImages = try DatasetReplyImageResolver(
                datasetRoot: outgoingImageDatasetRoot, outputRoot: sessionRegistry.rootDirectory
            ).resolve(turn.imagePaths)
            AutomationStepLog.record(root: sessionRegistry.rootDirectory, uid: capture.uid,
                step: "reply-images-prepared", detail: turn.outgoingImages.map {
                    "\($0.datasetRelativePath) sha256=\($0.sha256) bytes=\($0.byteCount)"
                }.joined(separator: "; "))
        }
        try CustomerMessageReceipts(root: sessionRegistry.rootDirectory)
            .completed(capture, submissionID: turn.submissionID, at: now())
        do {
            try reportCache.save(turn.videoAnalysisReports, uid: capture.uid,
                                 analyzedVideos: preparedSubmission.videoAttachments)
            if !turn.videoAnalysisReports.isEmpty {
                AutomationStepLog.record(root: sessionRegistry.rootDirectory, uid: capture.uid,
                    step: "video-analysis-report-saved", detail: "reports=\(turn.videoAnalysisReports.count)")
            }
        } catch {
            AutomationStepLog.record(root: sessionRegistry.rootDirectory, uid: capture.uid,
                step: "video-analysis-report-cache-write-failed", detail: error.localizedDescription)
        }
        AutomationStepLog.record(root: sessionRegistry.rootDirectory, uid: capture.uid,
            step: "generation-completed", detail: "action=\(turn.action.rawValue) reason=\(turn.transferReason.rawValue)")
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
        let textSchema = """
        {"type":"object","properties":{"answer_found":{"type":"boolean"},"action":{"type":"string","enum":["reply","reply_then_transfer"]},"reply_text":{"type":"string","minLength":1},"transfer_reason":{"type":"string","enum":["customer_explicitly_requested_human","explicit_return_refund","remote_assistance","refund_operation","logistics_lookup","troubleshooting_exhausted","none"]},"request_kind":{"type":"string","enum":["other","human_request","refund_return","technical"]},"issue_has_no_solution":{"type":"boolean"},"clarification_reply":{"type":"string","minLength":1},"handoff_reply":{"type":"string","minLength":1}},"required":["answer_found","action","reply_text","transfer_reason","request_kind","issue_has_no_solution","clarification_reply","handoff_reply"],"additionalProperties":false}
        """
        var schema = try JSONSerialization.jsonObject(with: Data(textSchema.utf8)) as! [String: Any]
        var properties = schema["properties"] as! [String: Any]
        properties["image_paths"] = ["type": "array", "items": ["type": "string"], "maxItems": 3]
        if !capture.videoAttachments.isEmpty {
            properties["video_analysis_reports"] = ["type": "array", "maxItems": capture.videoAttachments.count,
                "items": ["type": "object", "properties": [
                    "sha256": ["type": "string"], "observations": ["type": "string", "maxLength": 12000],
                    "limitations": ["type": "string", "maxLength": 4000]],
                    "required": ["sha256", "observations", "limitations"], "additionalProperties": false]]
        }
        schema["properties"] = properties
        schema["required"] = (schema["required"] as! [String]) + ["image_paths"]
            + (capture.videoAttachments.isEmpty ? [] : ["video_analysis_reports"])
        try JSONSerialization.data(withJSONObject: schema, options: .sortedKeys).write(to: schemaURL, options: .atomic)
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
        AutomationStepLog.record(root: sessionRegistry.rootDirectory, uid: capture.uid,
            step: "codex-invocation-started", detail: "model=\(CodexInvocation.model) reasoning=\(CodexInvocation.reasoningEffort) session=\(continuation ? "resume" : "new") history_limit=\(HistoryContinuation.maximumHistoryMessages) submitted_history_messages=\(submission.historyJSONL.split(separator: "\n").count) prompt_bytes=\(prompt.utf8.count) images=\(imageURLs.count) video_frames=\(videoFrameURLs.count)")
        let submissionID = UUID()
        try CustomerMessageReceipts(root: sessionRegistry.rootDirectory).begin(capture, submissionID: submissionID)
        let stream = AutoReplyCLIStream()
        let cancellation = CodexTurnCancellation()
        var turn: TurnResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { checked in
                let handoff = CodexTurnHandoff<TurnResult>(checked)
                let task = Task.detached(priority: .userInitiated) {
                    do {
                        let process = try await runner.runStreaming(
                            executable: executableURL,
                            arguments: arguments,
                            stdin: prompt,
                            timeout: capture.batch?.incomingHandoffKey != nil ? min(timeout, 60) : timeout,
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
                            onStandardInputClosed: {
                                do {
                                    try CustomerMessageReceipts(root: sessionRegistry.rootDirectory)
                                        .submitted(capture, prompt: prompt, submissionID: submissionID, at: now())
                                    handoff.didWriteInput()
                                } catch {
                                    AutomationStepLog.record(root: sessionRegistry.rootDirectory, uid: capture.uid,
                                        step: "codex-input-not-confirmed", detail: error.localizedDescription)
                                    handoff.finish(.failure(error))
                                }
                            }
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
                cancellation.install(task) { handoff.finish(.failure(CancellationError())) }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        turn.submissionID = submissionID
        return turn
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
        var tokenUsage: CodexTokenUsage?
        for line in process.stdout.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "turn.completed" {
                completed = true
                tokenUsage = CodexTokenUsage(json: object["usage"] as? [String: Any])
            }
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
            tokenUsage: tokenUsage,
            answerFound: document.answerFound ?? true,
            imagePaths: document.imagePaths ?? [],
            videoAnalysisReports: document.videoAnalysisReports ?? [],
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
            events: turn.events,
            model: CodexInvocation.model,
            reasoningEffort: CodexInvocation.reasoningEffort,
            tokenUsage: turn.tokenUsage,
            tokenUsageScope: turn.tokenUsage == nil ? nil : "turn"
        )
    }
}
