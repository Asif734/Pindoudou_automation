import XCTest
@testable import PDDAXReader

final class LogRepairLiveTests: XCTestCase {
    func testSolAnswersHistoricalRibbonQuestionsUsingRepairedKnowledgeWithoutDelivery() async throws {
        guard ProcessInfo.processInfo.environment["PDD_LIVE_LOG_REPAIR"] == "1" else {
            throw XCTSkip("Set PDD_LIVE_LOG_REPAIR=1 for isolated historical-query generation")
        }
        XCTAssertEqual(CodexInvocation.model, "gpt-6.1-sol")
        let production = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/PDDAutoReplyTaskIsolationCandidate/拼多多AX记录-任务隔离候选版")
        let protected = ["state.json", "run-intent.json", "message-receipts.json", "customer-transfer-policy.json"]
        let before = try protected.map { try Data(contentsOf: production.appendingPathComponent($0)) }
        let state = try AutoReplyStore(rootDirectory: production).load()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pdd-log-repair-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let environment = try CodexHomeManager(dataRoot: temporary,
            sourceHome: production.appendingPathComponent("codex-home")).prepare()
        let generator = AutoReplyCodexGenerator(executableURL: try XCTUnwrap(CodexInstallation.resolve()),
            runner: CodexProcessRunner(environment: environment.values),
            sessionRegistry: CodexSessionRegistry(rootDirectory: temporary),
            evidencePreparer: DirectLocalKnowledge(versionCache: KnowledgeFolderVersionCache()), timeout: 180)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("outputs/verification/20261104-log-repair")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var results: [[String: String]] = []
        for sequence in [131, 132] {
            let original = try XCTUnwrap(state.jobs.first { $0.sequence == sequence }).capture
            let capture = AutoReplyCapture(uid: "GZC-9900\(sequence)", fullHistory: original.fullHistory,
                batch: original.batch, customerCursor: original.customerCursor, unexpectedServiceMessageIDs: [],
                imageAttachments: original.imageAttachments, videoAttachments: original.videoAttachments)
            let result = try await generator.generate(capture)
            XCTAssertEqual(result.action, .reply)
            XCTAssertNil(CustomerFacingReplyPolicy.violation(in: result.reply))
            XCTAssertEqual(result.diagnostic?.model, "gpt-6.1-sol")
            XCTAssertEqual(result.diagnostic?.reasoningEffort, "medium")
            if sequence == 131 {
                XCTAssertNotNil(result.reply.range(of: "middle|cent(er|re)", options: .regularExpression),
                    "Replacement steps must retain preparation before removing the cartridge")
            } else {
                XCTAssertTrue(result.reply.contains("https://jvod.300hu.com/vod/product/1621802063/21852/6f64a1d65b3a4004862da086df5d1296.mp4"),
                    "The customer asked for the existing M880 ribbon tutorial")
            }
            results.append(["sequence": String(sequence), "reply": result.reply,
                "model": result.diagnostic?.model ?? "", "seconds": String(Double(result.diagnostic?.codexDurationMilliseconds ?? 0) / 1000)])
            try encoder.encode(results).write(to: output.appendingPathComponent("live-replies.json"), options: .atomic)
        }
        for (index, file) in protected.enumerated() {
            XCTAssertEqual(try Data(contentsOf: production.appendingPathComponent(file)), before[index], file)
        }
        try FileManager.default.copyItem(at: temporary.appendingPathComponent("logs/automation-steps.jsonl"),
            to: output.appendingPathComponent("live-steps-\(UUID()).jsonl"))
    }
}
