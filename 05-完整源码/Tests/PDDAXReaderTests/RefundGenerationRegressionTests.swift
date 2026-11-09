import XCTest
@testable import PDDAXReader

final class RefundGenerationRegressionTests: XCTestCase {
    func testUnavailableVideoWordingBecomesUsefulQuestionWithoutExtraCallOrTransfer() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = try RegressionReplyRunner(documents: [document(kind: "technical", reply: "I can’t view the video here.")])
        let result = try await makeGenerator(root: root, runner: runner).generate(capture("Please check this video."))
        XCTAssertEqual(result.reply, "What would you like me to check in the video?")
        XCTAssertEqual(result.action, .reply)
        let calls = await runner.prompts; XCTAssertEqual(calls.count, 1)
    }
    func testClarificationThenConfirmedRefundPreservesHandoffWithoutExtraModelCalls() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let runner = try RegressionReplyRunner(documents: [
            document(kind: "refund_return", reply: "Are you returning the M880 for a refund?"),
            document(kind: "refund_return", action: "reply_then_transfer", reason: "refund_operation", reply: "I’ll transfer you to a colleague for further assistance."),
            document(kind: "refund_return", action: "reply_then_transfer", reason: "refund_operation", reply: "I’ll transfer you to a colleague for further assistance.")
        ])
        let generator = makeGenerator(root: root, runner: runner)
        var history: [PDDChatMessage] = []; var cursor = AutoReplyCursor.empty
        for (index, question) in ["i want refund", "you may take your product", "yes, please do this"].enumerated() {
            history.append(message(String(index), .customer, question))
            let timeline = try AutoReplyTimeline.make(messages: history)
            let capture = AutoReplyCapture(uid: "GZC-000001", fullHistory: history,
                batch: try timeline.freeze(after: cursor), customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
            let result = try await generator.generate(capture)
            XCTAssertEqual(result.action, index == 0 ? .reply : .replyThenTransfer)
            XCTAssertEqual(result.transferReason, index == 0 ? .none : .refundOperation)
            cursor = timeline.cursor
            history.append(message("s\(index)", .service, result.reply))
        }
        let calls = await runner.prompts
        XCTAssertEqual(calls.count, 3, "one generation per customer batch")
        XCTAssertTrue(calls.last!.contains("yes, please do this"))
    }

    func testRecordedPolicyExplanationPassesOnFirstAttemptWithoutTransfer() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let reply = "Replacement eligibility depends on your order’s after-sales terms and confirmation of the fault. I can’t confirm those details for your order yet."
        let runner = try RegressionReplyRunner(documents: [document(kind: "other", reply: reply)])
        let result = try await makeGenerator(root: root, runner: runner).generate(capture("what is your replacement policy?"))
        XCTAssertEqual(result.action, .reply)
        XCTAssertEqual(result.reply, reply)
        let prompts = await runner.prompts; XCTAssertEqual(prompts.count, 1)
    }

    func testUnsafeWordingUsesSafeSameTurnAlternativeWithoutChangingAction() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        var doc = document(kind: "other", reply: "I am an AI assistant.")
        doc["clarification_reply"] = "Which printer model are you using?"
        let runner = try RegressionReplyRunner(documents: [doc])
        let result = try await makeGenerator(root: root, runner: runner).generate(capture("Can you help with my printer?"))
        XCTAssertEqual(result.action, .reply)
        XCTAssertEqual(result.reply, "Which printer model are you using?")
        let prompts = await runner.prompts; XCTAssertEqual(prompts.count, 1)
    }

    private func document(kind: String, action: String = "reply", reason: String = "none", reply: String) -> [String: Any] {
        ["request_kind": kind, "action": action, "transfer_reason": reason, "reply_text": reply,
         "answer_found": false, "issue_has_no_solution": false, "clarification_reply": reply,
         "handoff_reply": "I’ll transfer you to a colleague for further assistance.", "image_paths": []]
    }
    private func capture(_ text: String) throws -> AutoReplyCapture {
        let history = [message("q", .customer, text)]; let timeline = try AutoReplyTimeline.make(messages: history)
        return AutoReplyCapture(uid: "GZC-000001", fullHistory: history, batch: try timeline.freeze(after: .empty),
            customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
    }
    private func message(_ id: String, _ sender: ChatSender, _ text: String) -> PDDChatMessage {
        .init(id: id, sender: sender, content: text, displayTime: nil, kind: .text, capturedAt: Date())
    }
    private func makeGenerator(root: URL, runner: RegressionReplyRunner) -> AutoReplyCodexGenerator {
        .init(executableURL: URL(fileURLWithPath: "/bin/echo"), runner: runner,
            sessionRegistry: .init(rootDirectory: root), evidencePreparer: FallbackKnowledgeEvidencePreparer())
    }
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
}

private actor RegressionReplyRunner: CodexProcessRunning {
    var prompts: [String] = []; var documents: [Data]
    init(documents: [[String: Any]]) throws { self.documents = try documents.map { try JSONSerialization.data(withJSONObject: $0) } }
    func run(executable: URL, arguments: [String], stdin: String, timeout: TimeInterval) async throws -> CodexProcessResult {
        prompts.append(stdin)
        guard !documents.isEmpty else { throw AutoReplyCodexGeneratorError.missingCompletion }
        let index = try XCTUnwrap(arguments.firstIndex(of: "-o"))
        try documents.removeFirst().write(to: URL(fileURLWithPath: arguments[index + 1]))
        return .init(exitCode: 0, stdout: "{\"type\":\"thread.started\",\"thread_id\":\"refund-regression-thread\"}\n{\"type\":\"turn.completed\"}\n", stderr: "")
    }
}
