import XCTest
@testable import PDDAXReader

final class CustomerMessageReceiptsTests: XCTestCase {
    func testEveryBatchMessageHasSeparateCaptureSubmissionAndCompletionReceipts() throws {
        let root = temporaryCoverageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CustomerMessageReceipts(root: root)
        let capture = try coverageCapture(["A", "B"])
        try store.capture(capture)
        XCTAssertEqual(Set(try store.receipts(uid: coverageUID).keys), ["A", "B"])
        XCTAssertEqual(try store.awaitingSubmission()[coverageUID], ["A", "B"])
        let attempt = UUID()
        try store.begin(capture, submissionID: attempt)
        try store.submitted(capture, prompt: capture.batch!.targetCustomerJSONL, submissionID: attempt)
        XCTAssertTrue(try store.receipts(uid: coverageUID).values.allSatisfy { $0.submittedAt != nil && $0.completedAt == nil })
        try store.completed(capture, submissionID: attempt)
        XCTAssertTrue(try CustomerMessageReceipts(root: root).receipts(uid: coverageUID).values.allSatisfy {
            $0.capturedAt <= $0.submittedAt! && $0.completedAt != nil && $0.replySentAt == nil
        })
    }

    func testPartialBatchCannotMarkAnyMessageAsSubmitted() throws {
        let root = temporaryCoverageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CustomerMessageReceipts(root: root)
        let original = try coverageCapture(["A", "B"])
        let batch = try XCTUnwrap(original.batch)
        let broken = AutoReplyCapture(uid: original.uid, fullHistory: original.fullHistory,
            batch: FrozenCustomerBatch(startCursor: batch.startCursor, endCursor: batch.endCursor,
                events: batch.events, targetCustomerJSONL: String(batch.targetCustomerJSONL.split(separator: "\n")[0])),
            customerCursor: original.customerCursor, unexpectedServiceMessageIDs: [])
        try store.capture(broken)
        let attempt = UUID()
        try store.begin(broken, submissionID: attempt)
        XCTAssertThrowsError(try store.submitted(broken, prompt: broken.batch!.targetCustomerJSONL, submissionID: attempt))
        XCTAssertTrue(try store.receipts(uid: coverageUID).values.allSatisfy { $0.submittedAt == nil })
    }

    func testEarlierAttemptCannotConfirmNewAttemptAndContextIsNotNewWork() throws {
        let root = temporaryCoverageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CustomerMessageReceipts(root: root)
        let first = try coverageCapture(["old"])
        let current = try coverageCapture(["old", "new"], after: first.customerCursor)
        try store.capture(current)
        XCTAssertEqual(try store.awaitingSubmission()[coverageUID], ["new"])
        let attempt1 = UUID(), attempt2 = UUID()
        try store.begin(current, submissionID: attempt1)
        try store.submitted(current, prompt: current.batch!.targetCustomerJSONL, submissionID: attempt1)
        try store.begin(current, submissionID: attempt2)
        XCTAssertThrowsError(try store.completed(current, submissionID: attempt1))
        XCTAssertThrowsError(try store.submitted(current, prompt: current.batch!.targetCustomerJSONL, submissionID: attempt1))
        XCTAssertNil(try store.receipts(uid: coverageUID)["new"]?.submittedAt)
    }

    func testRealGeneratorConfirmsBothMessagesOnlyAfterInputAndCompletedTurn() async throws {
        let root = temporaryCoverageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try coverageCapture(["A", "B"])
        let generator = AutoReplyCodexGenerator(executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: CoverageCodexRunner(mode: .success), sessionRegistry: CodexSessionRegistry(rootDirectory: root),
            evidencePreparer: FallbackKnowledgeEvidencePreparer())
        _ = try await generator.generate(input)
        let receipts = try CustomerMessageReceipts(root: root).receipts(uid: input.uid)
        XCTAssertEqual(receipts.count, 2)
        XCTAssertTrue(receipts.values.allSatisfy { $0.submittedAt != nil && $0.completedAt != nil && $0.promptSHA256 != nil })
    }

    func testMissingInputConfirmationAndFailedTurnCannotClaimCompletedReceipt() async throws {
        for mode in [CoverageCodexRunner.Mode.noInputConfirmation, .failedTurn] {
            let root = temporaryCoverageRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let input = try coverageCapture(["A", "B"])
            let generator = AutoReplyCodexGenerator(executableURL: URL(fileURLWithPath: "/bin/echo"),
                runner: CoverageCodexRunner(mode: mode), sessionRegistry: CodexSessionRegistry(rootDirectory: root),
                evidencePreparer: FallbackKnowledgeEvidencePreparer())
            do { _ = try await generator.generate(input); XCTFail("Unconfirmed input or failed turn must fail") }
            catch { }
            let receipts = try CustomerMessageReceipts(root: root).receipts(uid: input.uid)
            XCTAssertTrue(receipts.values.allSatisfy { $0.completedAt == nil })
            if mode == .noInputConfirmation { XCTAssertTrue(receipts.values.allSatisfy { $0.submittedAt == nil }) }
            else { XCTAssertTrue(receipts.values.allSatisfy { $0.submittedAt != nil }) }
        }
    }
}

@MainActor
final class CustomerMessageCoverageTests: XCTestCase {
    func testMessageArrivingDuringSendIsCapturedAndGeneratedAfterFrozenSupplementWithoutRedDot() async throws {
        let root = temporaryCoverageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try coverageCapture(["A"])
        let second = try coverageCapture(["A", "B"], after: first.customerCursor)
        var source = AutoReplyJob(id: UUID(), uid: coverageUID, sequence: 1, state: .ready,
            capture: first, reply: "reply-A", deliveryOutcome: nil, confirmedServiceMessageID: nil,
            retries: 0, nextAttemptAt: nil, lastError: nil)
        source.pendingSupplement = second
        var state = AutoReplyPersistentState.empty
        state.jobs = [source]
        state.nextSequence = 1
        let store = AutoReplyStore(rootDirectory: root)
        try store.save(state)
        let driver = CoverageAutomationDriver(history: second.fullHistory)
        driver.onSend = { count in
            if count == 1 {
                XCTAssertTrue(try store.load().pendingCaptureRequests.contains { $0.kind == .tail })
                driver.history.append(coverageMessage("C"))
            }
        }
        let generator = CoverageGenerator()
        let scheduler = try AutoReplyScheduler(driver: driver, generator: generator, store: store)
        scheduler.start()
        for _ in 0..<150 {
            await scheduler.tick()
            if driver.sentIDs.count == 3 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        scheduler.stop()
        XCTAssertEqual(driver.sentIDs, [["A"], ["B"], ["C"]])
        let generated = await generator.batches
        XCTAssertEqual(generated, [["B"], ["C"]])
        XCTAssertEqual(try CustomerMessageReceipts(root: root).receipts(uid: coverageUID)["C"]?.requiresSubmission, true)
    }

    func testCapturedUnsubmittedMessageIsRecoveredAfterRestartWithoutUnreadEvidence() async throws {
        let root = temporaryCoverageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try coverageCapture(["A", "B"])
        try CustomerMessageReceipts(root: root).capture(input)
        let driver = CoverageAutomationDriver(history: input.fullHistory)
        let generator = CoverageGenerator()
        let scheduler = try AutoReplyScheduler(driver: driver, generator: generator, store: AutoReplyStore(rootDirectory: root))
        scheduler.start()
        for _ in 0..<80 {
            await scheduler.tick()
            if !driver.sentIDs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        scheduler.stop()
        XCTAssertEqual(driver.sentIDs, [["A", "B"]])
        let generated = await generator.batches
        XCTAssertEqual(generated, [["A", "B"]])
    }
}

private let coverageUID = "GZC-000001"

private func temporaryCoverageRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("coverage-\(UUID().uuidString)")
}

private func coverageMessage(_ id: String) -> PDDChatMessage {
    PDDChatMessage(id: id, sender: .customer, content: id, displayTime: nil, kind: .text, capturedAt: Date())
}

private func coverageCapture(_ ids: [String], after cursor: AutoReplyCursor = .empty) throws -> AutoReplyCapture {
    let history = ids.map(coverageMessage)
    let timeline = try AutoReplyTimeline.make(messages: history)
    return AutoReplyCapture(uid: coverageUID, fullHistory: history, batch: try timeline.freeze(after: cursor),
        customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
}

private struct CoverageCodexRunner: CodexProcessRunning {
    enum Mode { case success, noInputConfirmation, failedTurn }
    let mode: Mode
    func run(executable: URL, arguments: [String], stdin: String, timeout: TimeInterval) async throws -> CodexProcessResult {
        throw CocoaError(.featureUnsupported)
    }
    func runStreaming(executable: URL, arguments: [String], stdin: String, timeout: TimeInterval,
        onStandardOutput: @escaping @Sendable (Data) -> Void,
        onStandardInputClosed: @escaping @Sendable () -> Void) async throws -> CodexProcessResult {
        if mode != .noInputConfirmation { onStandardInputClosed() }
        if mode == .failedTurn { return CodexProcessResult(exitCode: 1, stdout: "", stderr: "failed turn") }
        let index = try XCTUnwrap(arguments.firstIndex(of: "-o"))
        let resultURL = URL(fileURLWithPath: arguments[index + 1])
        try Data(#"{"action":"reply","reply_text":"Captured.","transfer_reason":"none"}"#.utf8).write(to: resultURL)
        return CodexProcessResult(exitCode: 0,
            stdout: "{\"type\":\"thread.started\",\"thread_id\":\"coverage\"}\n{\"type\":\"turn.completed\"}\n", stderr: "")
    }
}

@MainActor
private final class CoverageAutomationDriver: AutoReplyAutomationDriver {
    var history: [PDDChatMessage]
    var onSend: ((Int) throws -> Void)?
    var sentIDs: [Set<String>] = []
    init(history: [PDDChatMessage]) { self.history = history }
    func discover() async throws -> [AutoReplyDiscovery] { [.init(uid: coverageUID, hasUnreadEvidence: false)] }
    func capture(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture {
        let timeline = try AutoReplyTimeline.make(messages: history)
        return AutoReplyCapture(uid: uid, fullHistory: history, batch: try timeline.freeze(after: cursor),
            customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
    }
    func preflight(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture? { nil }
    func send(uid: String, text: String, expectedCustomerCursor: AutoReplyCursor) async throws -> AutoReplyDeliveryResult {
        .sent(serviceMessageID: "reply-\(sentIDs.count)")
    }
    func send(uid: String, text: String, expectedCustomerCursor: AutoReplyCursor,
        expectedCustomerMessageIDs: Set<String>) async throws -> AutoReplyDeliveryResult {
        sentIDs.append(expectedCustomerMessageIDs)
        try onSend?(sentIDs.count)
        return .sent(serviceMessageID: "reply-\(sentIDs.count)")
    }
}

private actor CoverageGenerator: AutoReplyGenerating {
    var batches: [Set<String>] = []
    func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult {
        batches.append(capture.batch?.customerMessageIDs ?? [])
        try await Task.sleep(for: .milliseconds(5))
        return CodexReplyResult(reply: "reply", threadID: "coverage")
    }
}
