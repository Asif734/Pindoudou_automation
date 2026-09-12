import XCTest
@testable import PDDAXReader

final class AutoReplyCodexGeneratorTests: XCTestCase {
    func testGeneratedOutputSchemaSatisfiesCodexConstTypeContract() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runner = SchemaValidatingCodexRunner()
        let generator = AutoReplyCodexGenerator(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner,
            sessionRegistry: CodexSessionRegistry(rootDirectory: root)
        )

        let result = try await generator.generate(try capture(uid: "GZC-000001"))

        XCTAssertEqual(result.reply, "schema accepted")
    }

    func testGeneratorReturnsReplyThenTransferDecisionAndReason() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let generator = AutoReplyCodexGenerator(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: DocumentCodexRunner(document: [
                "action": "reply_then_transfer",
                "reply_text": "好的，我帮您转人工处理～",
                "transfer_reason": "customer_explicitly_requested_human"
            ]),
            sessionRegistry: CodexSessionRegistry(rootDirectory: root)
        )

        let result = try await generator.generate(
            try capture(uid: "PDD-NAME-111111111111111111111111")
        )

        XCTAssertEqual(result.action, .replyThenTransfer)
        XCTAssertEqual(result.transferReason, .customerExplicitlyRequestedHuman)
        XCTAssertEqual(result.reply, "好的，我帮您转人工处理～")
    }

    func testGeneratorRejectsReplyWithTransferReason() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let generator = AutoReplyCodexGenerator(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: DocumentCodexRunner(document: [
                "action": "reply",
                "reply_text": "物流一般三到五天",
                "transfer_reason": "logistics_lookup"
            ]),
            sessionRegistry: CodexSessionRegistry(rootDirectory: root)
        )

        do {
            _ = try await generator.generate(
                try capture(uid: "PDD-NAME-222222222222222222222222")
            )
            XCTFail("reply 不得携带转人工原因")
        } catch let error as AutoReplyCodexGeneratorError {
            guard case .invalidReply(let detail) = error else {
                return XCTFail("错误类型不符合预期：\(error)")
            }
            XCTAssertTrue(detail.contains("不匹配"))
        }
    }

    func testGeneratorResumesExactUIDThreadAndNeverUsesLast() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let registry = CodexSessionRegistry(rootDirectory: root)
        let emptyCapture = AutoReplyCapture(
            uid: "GZC-000001", fullHistory: [], batch: nil, customerCursor: .empty,
            unexpectedServiceMessageIDs: []
        )
        let emptyCheckpoint = try HistoryContinuation.plan(
            capture: emptyCapture, after: nil
        ).checkpoint
        try registry.save(.init(
            uid: "GZC-000001", threadID: "thread-A", lastUsedAt: now,
            historyCheckpoint: emptyCheckpoint
        ))
        let runner = AutoReplyFakeCodexRunner(responses: [
            .init(exitCode: 0, stdout: "{\"type\":\"turn.completed\"}\n", reply: "回复")
        ])
        let generator = AutoReplyCodexGenerator(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner,
            sessionRegistry: registry,
            now: { now }
        )

        _ = try await generator.generate(try capture(uid: "GZC-000001"))
        let arguments = await runner.invocations[0]

        XCTAssertTrue(arguments.contains("thread-A"))
        XCTAssertTrue(arguments.contains("resume"))
        XCTAssertFalse(arguments.contains("--last"))
        let prompt = await runner.recorded[0].stdin
        XCTAssertTrue(prompt.contains("appended_history.jsonl"))
        XCTAssertFalse(prompt.contains("full_history.jsonl"))
    }

    func testFailedContinuationAndFailedFreshSessionAreReportedAsRetryExhausted() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let registry = CodexSessionRegistry(rootDirectory: root)
        let emptyCapture = AutoReplyCapture(
            uid: "GZC-000001", fullHistory: [], batch: nil, customerCursor: .empty,
            unexpectedServiceMessageIDs: []
        )
        let checkpoint = try HistoryContinuation.plan(capture: emptyCapture, after: nil).checkpoint
        try registry.save(.init(
            uid: "GZC-000001", threadID: "stale-thread", lastUsedAt: now,
            historyCheckpoint: checkpoint
        ))
        let runner = AutoReplyFakeCodexRunner(responses: [
            .init(exitCode: 1, stdout: "", reply: "", stderr: "HTTP 404 model not found"),
            .init(exitCode: 1, stdout: "", reply: "", stderr: "HTTP 404 model not found")
        ])
        let generator = AutoReplyCodexGenerator(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner,
            sessionRegistry: registry,
            now: { now }
        )

        do {
            _ = try await generator.generate(try capture(uid: "GZC-000001"))
            XCTFail("旧会话和唯一一次新会话都失败后必须停止重试")
        } catch let error as AutoReplyCodexGeneratorError {
            guard case .freshSessionRetryFailed(let detail) = error else {
                return XCTFail("错误类型不符合预期：\(error)")
            }
            XCTAssertTrue(detail.contains("404"))
        }

        let invocations = await runner.invocations
        XCTAssertEqual(invocations.count, 2)
        XCTAssertTrue(invocations[0].contains("resume"))
        XCTAssertFalse(invocations[1].contains("resume"))
    }

    func testGeneratorContinuesLegacyCheckpointOnSameThreadAndRewritesModernCheckpoint() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("用户/GZC-000001", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bindingURL = directory.appendingPathComponent("codex-session.json")
        let legacy = """
        {
          "uid": "GZC-000001",
          "threadID": "legacy-thread-A",
          "lastUsedAt": "2026-04-25T02:40:00Z",
          "historyCheckpoint": {
            "messageDigests": ["old-message-digest"],
            "submittedImageSHA256": ["old-image-digest"]
          },
          "promptSHA256": "legacy-prompt-sha",
          "knowledgeSHA256": "legacy-knowledge-sha",
          "turnCount": 2,
          "submittedBytes": 9284,
          "contaminated": false
        }
        """
        try Data(legacy.utf8).write(to: bindingURL)
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let runner = AutoReplyFakeCodexRunner(responses: [
            .init(exitCode: 0, stdout: "{\"type\":\"turn.completed\"}\n", reply: "兼容成功")
        ])
        let generator = AutoReplyCodexGenerator(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner,
            sessionRegistry: CodexSessionRegistry(rootDirectory: root),
            now: { now }
        )

        let result = try await generator.generate(try capture(uid: "GZC-000001"))

        XCTAssertEqual(result.threadID, "legacy-thread-A")
        let invocation = await runner.recorded[0]
        XCTAssertTrue(invocation.arguments.contains("resume"))
        XCTAssertTrue(invocation.arguments.contains("legacy-thread-A"))
        XCTAssertTrue(invocation.stdin.contains("appended_history.jsonl"))
        XCTAssertTrue(invocation.stdin.contains("怎么安装"), "旧 checkpoint 首次续传必须补交完整历史")
        let rewritten = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: bindingURL)) as? [String: Any]
        )
        let checkpoint = try XCTUnwrap(rewritten["historyCheckpoint"] as? [String: Any])
        XCTAssertNotNil(checkpoint["historyByteCount"])
        XCTAssertNotNil(checkpoint["prefixSHA256"])
        XCTAssertNotNil(checkpoint["attachmentSHA256"])
        XCTAssertNil(checkpoint["messageDigests"])
        XCTAssertNil(checkpoint["submittedImageSHA256"])
    }

    func testReplyOverOneThousandCharactersIsAccepted() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = AutoReplyFakeCodexRunner(responses: [
            .init(
                exitCode: 0,
                stdout: "{\"type\":\"thread.started\",\"thread_id\":\"new-thread\"}\n{\"type\":\"turn.completed\"}\n",
                reply: String(repeating: "字", count: 1001)
            )
        ])
        let generator = AutoReplyCodexGenerator(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner,
            sessionRegistry: CodexSessionRegistry(rootDirectory: root)
        )

        let result = try await generator.generate(try capture(uid: "GZC-000001"))
        XCTAssertEqual(result.reply.count, 1001)
    }

    func testValidatedStreamingReplyReturnsBeforeProcessCleanupFinishes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let generator = AutoReplyCodexGenerator(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: EarlyStreamingCodexRunner(),
            sessionRegistry: CodexSessionRegistry(rootDirectory: root)
        )
        let started = Date()

        let result = try await generator.generate(try capture(uid: "GZC-000001"))

        XCTAssertEqual(result.reply, "流式回复")
        XCTAssertEqual(result.threadID, "stream-thread")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.25)
    }

    func testGeneratorPreparesKnowledgeBeforeBuildingCodexPrompt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = AutoReplyFakeCodexRunner(responses: [
            .init(
                exitCode: 0,
                stdout: "{\"type\":\"thread.started\",\"thread_id\":\"new-thread\"}\n{\"type\":\"turn.completed\"}\n",
                reply: "请检查电源"
            )
        ])
        let evidence = KnowledgeEvidence(
            mode: .v2Top12, version: "v2-top12", documents: ["m880.md"], context: "M880可信原文",
            diagnostic: KnowledgeRetrievalDiagnostic(
                mode: .v2Top12, knowledgeBaseSHA256: "kb", selectedDocuments: ["m880.md"],
                contextSHA256: "ctx", durationMilliseconds: 12, error: nil
            )
        )
        let generator = AutoReplyCodexGenerator(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner,
            sessionRegistry: CodexSessionRegistry(rootDirectory: root),
            evidencePreparer: FixedEvidencePreparer(evidence: evidence)
        )

        let result = try await generator.generate(try capture(uid: "GZC-000001"))
        let invocation = await runner.recorded[0]

        XCTAssertTrue(invocation.stdin.contains("M880可信原文"))
        XCTAssertTrue(invocation.stdin.contains("<untrusted_retrieved_knowledge>"))
        XCTAssertFalse(invocation.arguments.contains("--image"), "纯文本任务不应附加图片")
        XCTAssertTrue(invocation.arguments.contains("--disable"))
        XCTAssertTrue(invocation.arguments.contains("shell_tool"))
        XCTAssertEqual(result.diagnostic?.knowledge, evidence.diagnostic)
    }

    func testGeneratorPassesEachValidatedLocalImageToCodexInMessageOrder() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.jpeg")
        let second = root.appendingPathComponent("second.png")
        try Data([0xff, 0xd8, 0xff]).write(to: first)
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: second)
        let runner = AutoReplyFakeCodexRunner(responses: [
            .init(
                exitCode: 0,
                stdout: "{\"type\":\"thread.started\",\"thread_id\":\"new-thread\"}\n{\"type\":\"turn.completed\"}\n",
                reply: "已看到图片"
            )
        ])
        let generator = AutoReplyCodexGenerator(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner,
            sessionRegistry: CodexSessionRegistry(rootDirectory: root)
        )
        var capture = try capture(uid: "GZC-000001")
        capture.imageAttachments = [
            attachment(messageID: "m1", localURL: first),
            attachment(messageID: "m2", localURL: second)
        ]

        _ = try await generator.generate(capture)
        let arguments = await runner.invocations[0]

        let pairs = arguments.indices.compactMap { index -> String? in
            guard arguments[index] == "-i", index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        XCTAssertEqual(pairs, [first.path, second.path])
    }

    func testGeneratorPassesVideoFramesButNeverMP4ToImageArguments() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mp4 = root.appendingPathComponent("source.mp4")
        let frames = (0..<20).map { root.appendingPathComponent("frame-\($0).jpg") }
        let audio = root.appendingPathComponent("audio.m4a")
        let manifest = root.appendingPathComponent("manifest.json")
        try Data("mp4".utf8).write(to: mp4)
        for frame in frames { try Data([0xff, 0xd8, 0xff]).write(to: frame) }
        try Data("audio".utf8).write(to: audio)
        try Data("{}".utf8).write(to: manifest)
        let runner = AutoReplyFakeCodexRunner(responses: [
            .init(exitCode: 0, stdout: "{\"type\":\"thread.started\",\"thread_id\":\"video-thread\"}\n{\"type\":\"turn.completed\"}\n", reply: "看到了")
        ])
        let generator = AutoReplyCodexGenerator(
            executableURL: URL(fileURLWithPath: "/bin/echo"), runner: runner,
            sessionRegistry: CodexSessionRegistry(rootDirectory: root)
        )
        var value = try capture(uid: "GZC-000001")
        value.videoAttachments = [AutoReplyVideoAttachment(
            messageID: "video", localURL: mp4, sha256: "digest", byteCount: 3,
            durationSeconds: 3, width: 10, height: 20, videoCodec: "H.264",
            audioCodec: nil,
            frames: frames.enumerated().reversed().map {
                .init(timestampSeconds: Double($0.offset), localURL: $0.element)
            }, transcript: nil, diagnostic: nil,
            audioLocalURL: audio, manifestLocalURL: manifest
        )]

        _ = try await generator.generate(value)
        let arguments = await runner.invocations[0]
        let images = arguments.indices.compactMap { index in
            arguments[index] == "-i" && index + 1 < arguments.count ? arguments[index + 1] : nil
        }

        XCTAssertEqual(images, frames.map(\.path))
        XCTAssertEqual(images.count, 20)
        XCTAssertFalse(images.contains(mp4.path))
        XCTAssertFalse(images.contains(audio.path))
        XCTAssertFalse(images.contains(manifest.path))
    }

    func testGeneratorRejectsNonChatGPTLoginBeforeCodexExecution() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = AutoReplyFakeCodexRunner(responses: [])
        let login = CodexLoginCache(
            checker: FixedLoginChecker(status: .notLoggedIn),
            successTTL: 60
        )
        let generator = AutoReplyCodexGenerator(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner,
            sessionRegistry: CodexSessionRegistry(rootDirectory: root),
            loginStatusProvider: login
        )

        do {
            _ = try await generator.generate(try capture(uid: "GZC-000001"))
            XCTFail("非 ChatGPT 登录不得运行生成")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ChatGPT"))
        }
        let recorded = await runner.recorded
        XCTAssertTrue(recorded.isEmpty)
    }

    private func capture(uid: String) throws -> AutoReplyCapture {
        let history = [PDDChatMessage(
            id: "A", sender: .customer, content: "怎么安装", displayTime: "10:00", kind: .text,
            capturedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )]
        let timeline = try AutoReplyTimeline.make(messages: history)
        return AutoReplyCapture(
            uid: uid, fullHistory: history, batch: try timeline.freeze(after: .empty),
            customerCursor: timeline.cursor, unexpectedServiceMessageIDs: []
        )
    }

    private func attachment(messageID: String, localURL: URL) -> AutoReplyImageAttachment {
        AutoReplyImageAttachment(
            messageID: messageID,
            sourceURL: URL(string: "https://chat-img.pddugc.com/\(messageID)")!,
            localURL: localURL,
            mimeType: localURL.pathExtension == "png" ? "image/png" : "image/jpeg",
            byteCount: 4,
            sha256: String(repeating: "a", count: 64)
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pdd-auto-codex-\(UUID().uuidString)")
    }
}

private struct EarlyStreamingCodexRunner: CodexProcessRunning {
    func run(
        executable: URL, arguments: [String], stdin: String, timeout: TimeInterval
    ) async throws -> CodexProcessResult {
        throw CocoaError(.featureUnsupported)
    }

    func runStreaming(
        executable: URL,
        arguments: [String],
        stdin: String,
        timeout: TimeInterval,
        onStandardOutput: @escaping @Sendable (Data) -> Void,
        onStandardInputClosed: @escaping @Sendable () -> Void
    ) async throws -> CodexProcessResult {
        onStandardInputClosed()
        let reply = #"{"action":"reply","reply_text":"流式回复","transfer_reason":"none"}"#
        let rows = [
            #"{"type":"thread.started","thread_id":"stream-thread"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.started","item":{"id":"item-1","type":"agent_message"}}"#,
            "{\"type\":\"item.completed\",\"item\":{\"id\":\"item-1\",\"type\":\"agent_message\",\"phase\":\"final_answer\",\"text\":\(try String(data: JSONEncoder().encode(reply), encoding: .utf8)!)}}",
            #"{"type":"turn.completed"}"#,
        ].joined(separator: "\n") + "\n"
        onStandardOutput(Data(rows.utf8))
        try await Task.sleep(for: .milliseconds(400))
        return CodexProcessResult(exitCode: 1, stdout: rows, stderr: "cleanup failure")
    }
}

private actor SchemaValidatingCodexRunner: CodexProcessRunning {
    func run(
        executable: URL,
        arguments: [String],
        stdin: String,
        timeout: TimeInterval
    ) async throws -> CodexProcessResult {
        let schemaIndex = try XCTUnwrap(arguments.firstIndex(of: "--output-schema"))
        let resultIndex = try XCTUnwrap(arguments.firstIndex(of: "-o"))
        let schemaURL = URL(fileURLWithPath: arguments[schemaIndex + 1])
        let schema = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any]
        )
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let action = try XCTUnwrap(properties["action"] as? [String: Any])
        let transferReason = try XCTUnwrap(properties["transfer_reason"] as? [String: Any])
        guard Set(properties.keys) == Set(["action", "reply_text", "transfer_reason"]),
              action["enum"] as? [String] == ["reply", "reply_then_transfer"],
              transferReason["enum"] as? [String] == [
                "customer_explicitly_requested_human", "explicit_return_refund",
                "remote_assistance", "refund_operation", "logistics_lookup",
                "troubleshooting_exhausted", "none"
              ] else {
            return CodexProcessResult(
                exitCode: 1,
                stdout: "",
                stderr: "invalid_json_schema: reply action contract mismatch"
            )
        }
        let result = [
            "action": "reply",
            "reply_text": "schema accepted",
            "transfer_reason": "none"
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: arguments[resultIndex + 1]))
        return CodexProcessResult(
            exitCode: 0,
            stdout: "{\"type\":\"thread.started\",\"thread_id\":\"schema-thread\"}\n"
                + "{\"type\":\"turn.completed\"}\n",
            stderr: ""
        )
    }
}

private struct DocumentCodexRunner: CodexProcessRunning {
    let document: [String: String]

    func run(
        executable: URL, arguments: [String], stdin: String, timeout: TimeInterval
    ) async throws -> CodexProcessResult {
        let resultIndex = try XCTUnwrap(arguments.firstIndex(of: "-o"))
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: arguments[resultIndex + 1]))
        return CodexProcessResult(
            exitCode: 0,
            stdout: "{\"type\":\"thread.started\",\"thread_id\":\"document-thread\"}\n"
                + "{\"type\":\"turn.completed\"}\n",
            stderr: ""
        )
    }
}

private struct AutoReplyFakeCodexResponse: Sendable {
    let exitCode: Int32
    let stdout: String
    let reply: String
    let stderr: String

    init(exitCode: Int32, stdout: String, reply: String, stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.reply = reply
        self.stderr = stderr
    }
}

private actor AutoReplyFakeCodexRunner: CodexProcessRunning {
    private var responses: [AutoReplyFakeCodexResponse]
    private(set) var invocations: [[String]] = []
    private(set) var recorded: [(arguments: [String], stdin: String)] = []

    init(responses: [AutoReplyFakeCodexResponse]) { self.responses = responses }

    func run(
        executable: URL,
        arguments: [String],
        stdin: String,
        timeout: TimeInterval
    ) async throws -> CodexProcessResult {
        invocations.append(arguments)
        recorded.append((arguments, stdin))
        let response = responses.removeFirst()
        if let index = arguments.firstIndex(of: "-o") {
            let data = try JSONSerialization.data(withJSONObject: [
                "action": "reply",
                "reply_text": response.reply,
                "transfer_reason": "none"
            ], options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: arguments[index + 1]))
        }
        return CodexProcessResult(
            exitCode: response.exitCode,
            stdout: response.stdout,
            stderr: response.stderr
        )
    }
}

private struct FixedEvidencePreparer: KnowledgeEvidencePreparing {
    let evidence: KnowledgeEvidence
    func prepare(capture: AutoReplyCapture) async -> KnowledgeEvidence { evidence }
}

private struct FixedLoginChecker: CodexLoginChecking {
    let status: CodexLoginStatus
    func check(executable: URL) async throws -> CodexLoginStatus { status }
}
