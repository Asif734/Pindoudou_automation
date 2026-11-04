import XCTest
@testable import PDDAXReader

final class LatencyRepairLiveTests: XCTestCase {
    func testSolSocialTurnsSkipToolsAndMixedQuestionReadsDatasetWithoutDelivery() async throws {
        guard ProcessInfo.processInfo.environment["PDD_LIVE_LATENCY_REPAIR"] == "1" else {
            throw XCTSkip("Set PDD_LIVE_LATENCY_REPAIR=1 for isolated real-history latency checks")
        }
        let production = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/PDDAutoReplyTaskIsolationCandidate/拼多多AX记录-任务隔离候选版")
        let protected = ["state.json", "run-intent.json", "message-receipts.json", "customer-transfer-policy.json"]
        let before = try protected.map { try Data(contentsOf: production.appendingPathComponent($0)) }
        let state = try AutoReplyStore(rootDirectory: production).load()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pdd-latency-repair-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("outputs/verification/20261104-latency-fix")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let environment = try CodexHomeManager(dataRoot: temporary,
            sourceHome: production.appendingPathComponent("codex-home")).prepare()
        let registry = CodexSessionRegistry(rootDirectory: temporary)
        let generator = AutoReplyCodexGenerator(executableURL: try XCTUnwrap(CodexInstallation.resolve()),
            runner: CodexProcessRunner(environment: environment.values), sessionRegistry: registry,
            evidencePreparer: DirectLocalKnowledge(versionCache: KnowledgeFolderVersionCache()), timeout: 180)
        let original = try XCTUnwrap(state.jobs.first { $0.sequence == 133 }).capture
        var capture = AutoReplyCapture(uid: "GZC-9800133", fullHistory: original.fullHistory,
            batch: original.batch, customerCursor: original.customerCursor, unexpectedServiceMessageIDs: [])
        let names = ["greeting", "thanks", "acknowledgment", "mixed-tutorial"]
        let following = ["Thank you", "OK", "OK, can you send me the M880 ribbon replacement tutorial?"]
        var measurements: [[String: Any]] = []
        for index in names.indices {
            let started = Date()
            let result = try await generator.generate(capture)
            XCTAssertEqual(result.action, .reply)
            XCTAssertEqual(result.diagnostic?.model, "gpt-6.1-sol")
            XCTAssertEqual(result.diagnostic?.reasoningEffort, "medium")
            XCTAssertEqual(result.diagnostic?.tokenUsageScope, "turn")
            XCTAssertNil(CustomerFacingReplyPolicy.violation(in: result.reply))
            let summary = try trace(home: environment.homeURL, thread: result.threadID, output: output)
            if index < 3 {
                XCTAssertEqual(summary.toolCalls, 0, "Pure social messages must not invoke knowledge/file tools")
            } else {
                XCTAssertGreaterThan(summary.toolCalls, 0, "A mixed acknowledgment/question still needs source evidence")
                XCTAssertTrue(result.reply.contains("https://jvod.300hu.com/vod/product/1621802063/21852/6f64a1d65b3a4004862da086df5d1296.mp4"))
            }
            XCTAssertEqual(result.diagnostic?.tokenUsage?.inputTokens, summary.inputTokens)
            XCTAssertEqual(result.diagnostic?.tokenUsage?.outputTokens, summary.outputTokens)
            measurements.append(["case": names[index], "seconds": Date().timeIntervalSince(started),
                "toolCalls": summary.toolCalls, "inputTokens": summary.inputTokens,
                "outputTokens": summary.outputTokens, "reply": result.reply])
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                .write(to: output.appendingPathComponent("live-results.json"), options: .atomic)
            if index < following.count {
                let history = capture.fullHistory + [
                    PDDChatMessage(id: "latency-service-\(index)", sender: .service, content: result.reply,
                        displayTime: nil, kind: .text, capturedAt: Date()),
                    PDDChatMessage(id: "latency-customer-\(index)", sender: .customer, content: following[index],
                        displayTime: nil, kind: .text, capturedAt: Date())]
                let timeline = try AutoReplyTimeline.make(messages: history)
                capture = AutoReplyCapture(uid: capture.uid, fullHistory: history,
                    batch: try timeline.freeze(after: capture.customerCursor), customerCursor: timeline.cursor,
                    unexpectedServiceMessageIDs: [])
            }
        }
        let handoff = try XCTUnwrap(state.jobs.first { $0.sequence == 134 }).capture
        let handoffStarted = Date()
        let result = try await generator.generate(AutoReplyCapture(uid: "GZC-9800134", fullHistory: handoff.fullHistory,
            batch: handoff.batch, customerCursor: handoff.customerCursor, unexpectedServiceMessageIDs: []))
        XCTAssertEqual(result.action, .reply)
        XCTAssertFalse(result.reply.isEmpty)
        _ = try trace(home: environment.homeURL, thread: result.threadID, output: output)
        measurements.append(["case": "previously-timed-out-handoff", "seconds": Date().timeIntervalSince(handoffStarted), "reply": result.reply])
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: output.appendingPathComponent("live-results.json"), options: .atomic)
        for (index, file) in protected.enumerated() {
            XCTAssertEqual(try Data(contentsOf: production.appendingPathComponent(file)), before[index], file)
        }
        try FileManager.default.copyItem(at: temporary.appendingPathComponent("logs/automation-steps.jsonl"),
            to: output.appendingPathComponent("live-steps-\(UUID()).jsonl"))
    }

    private func trace(home: URL, thread: String, output: URL) throws -> (toolCalls: Int, inputTokens: Int, outputTokens: Int) {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: home.appendingPathComponent("sessions"),
            includingPropertiesForKeys: nil)?.allObjects as? [URL])
        let file = try XCTUnwrap(files.first { $0.lastPathComponent.contains(thread) && $0.pathExtension == "jsonl" })
        let data = try Data(contentsOf: file)
        try data.write(to: output.appendingPathComponent("rollout-\(thread).jsonl"), options: .atomic)
        var calls = 0
        var usage: [String: [String: Int]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = row["payload"] as? [String: Any] else { continue }
            if row["type"] as? String == "turn_context" { calls = 0; usage = [:] }
            if row["type"] as? String == "response_item",
               ["function_call", "custom_tool_call"].contains(payload["type"] as? String ?? "") { calls += 1 }
            if row["type"] as? String == "token_usage_record", let id = payload["response_id"] as? String,
               let values = payload["usage"] as? [String: Int] { usage[id] = values }
        }
        return (calls, usage.values.reduce(0) { $0 + ($1["input_tokens"] ?? 0) },
            usage.values.reduce(0) { $0 + ($1["output_tokens"] ?? 0) })
    }
}
