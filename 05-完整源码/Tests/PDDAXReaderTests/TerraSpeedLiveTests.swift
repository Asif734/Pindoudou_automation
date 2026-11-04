import CryptoKit
import XCTest
@testable import PDDAXReader

final class TerraSpeedLiveTests: XCTestCase {
    private struct Measurement: Codable {
        let caseName: String
        let totalMilliseconds: Int
        let diagnostic: AutoReplyGenerationDiagnostic?
        let reply: String
        let action: CodexReplyAction
    }

    func testLiveTerraTextImageVideoAndResumeWithoutCustomerDelivery() async throws {
        guard ProcessInfo.processInfo.environment["PDD_LIVE_TERRA_SPEED_TEST"] == "1" else {
            throw XCTSkip("Set PDD_LIVE_TERRA_SPEED_TEST=1 for isolated historical-media generation checks")
        }
        guard CodexInvocation.model == "gpt-6.1-terra" else {
            throw XCTSkip("Historical Terra benchmark requires the Terra model; preserve its baseline artifacts")
        }
        let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = project.appendingPathComponent("outputs/verification/20261104-terra-speed")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let production = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/PDDAutoReplyTaskIsolationCandidate/拼多多AX记录-任务隔离候选版")
        let protectedFiles = ["state.json", "customer-transfer-policy.json", "message-receipts.json", "run-intent.json"]
        let before = try protectedFiles.map { try Data(contentsOf: production.appendingPathComponent($0)) }
        let state = try AutoReplyStore(rootDirectory: production).load()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pdd-terra-speed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let environment = try CodexHomeManager(dataRoot: temporary,
            sourceHome: production.appendingPathComponent("codex-home")).prepare()
        let registry = CodexSessionRegistry(rootDirectory: temporary)
        let evidence = DirectLocalKnowledge(versionCache: KnowledgeFolderVersionCache())
        try await measureKnowledgeVersioning(evidence, output: output)
        let generator = AutoReplyCodexGenerator(executableURL: try XCTUnwrap(CodexInstallation.resolve()),
            runner: CodexProcessRunner(environment: environment.values), sessionRegistry: registry,
            evidencePreparer: evidence, timeout: 180)
        var measurements: [Measurement] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        func generate(_ capture: AutoReplyCapture, name: String) async throws -> CodexReplyResult {
            let started = Date()
            let result = try await generator.generate(capture)
            XCTAssertEqual(result.action, .reply)
            XCTAssertNil(CustomerFacingReplyPolicy.violation(in: result.reply))
            XCTAssertEqual(result.diagnostic?.model, "gpt-6.1-terra")
            XCTAssertEqual(result.diagnostic?.reasoningEffort, "medium")
            XCTAssertEqual(result.diagnostic?.knowledge.hashCacheHit, true)
            XCTAssertEqual(result.diagnostic?.knowledge.hashedByteCount, 0)
            XCTAssertNotNil(result.diagnostic?.tokenUsage)
            XCTAssertTrue(try XCTUnwrap(registry.activeBinding(uid: capture.uid)).matchesCurrentModel)
            let receipts = try CustomerMessageReceipts(root: temporary).receipts(uid: capture.uid)
            for id in capture.batch?.customerMessageIDs ?? [] { XCTAssertNotNil(receipts[id]?.completedAt) }
            measurements.append(Measurement(caseName: name,
                totalMilliseconds: Int(Date().timeIntervalSince(started) * 1000), diagnostic: result.diagnostic,
                reply: result.reply, action: result.action))
            try encoder.encode(measurements).write(to: output.appendingPathComponent("live-generation.json"), options: .atomic)
            print("TERRA_LIVE \(name) total_ms=\(measurements.last!.totalMilliseconds) reply=\(result.reply)")
            return result
        }

        for (name, sequence) in [("text", 113), ("image", 123), ("video", 98)] {
            let original = try XCTUnwrap(state.jobs.first { $0.sequence == sequence }).capture
            let uid = "GZC-9999999\(sequence)"
            let capture = AutoReplyCapture(uid: uid, fullHistory: original.fullHistory, batch: original.batch,
                customerCursor: original.customerCursor, unexpectedServiceMessageIDs: [],
                ocrDiagnostic: original.ocrDiagnostic, imageAttachments: original.imageAttachments,
                videoAttachments: original.videoAttachments)
            let first = try await generate(capture, name: name)
            if name == "text" {
                let history = capture.fullHistory + [
                    PDDChatMessage(id: "benchmark-service", sender: .service, content: first.reply,
                        displayTime: nil, kind: .text, capturedAt: Date()),
                    PDDChatMessage(id: "benchmark-followup", sender: .customer, content: "Thank you, I will try that.",
                        displayTime: nil, kind: .text, capturedAt: Date())]
                let timeline = try AutoReplyTimeline.make(messages: history)
                let followup = AutoReplyCapture(uid: uid, fullHistory: history,
                    batch: try timeline.freeze(after: capture.customerCursor), customerCursor: timeline.cursor,
                    unexpectedServiceMessageIDs: [])
                _ = try await generate(followup, name: "text-resume")
                XCTAssertEqual(try registry.activeBinding(uid: uid)?.turnCount, 2)
            }
        }
        for (index, file) in protectedFiles.enumerated() {
            XCTAssertEqual(try Data(contentsOf: production.appendingPathComponent(file)), before[index], "Production \(file) changed")
        }
        let log = try String(contentsOf: temporary.appendingPathComponent("logs/automation-steps.jsonl"))
        XCTAssertTrue(log.contains("session=resume"))
        XCTAssertTrue(log.contains("knowledge-prepared"))
        XCTAssertTrue(log.contains("codex-invocation-completed"))
        try Data(log.utf8).write(to: output.appendingPathComponent("live-generation-steps.jsonl"))
    }

    private func measureKnowledgeVersioning(_ evidence: DirectLocalKnowledge, output: URL) async throws {
        let started = Date()
        let cold = try await evidence.versionCache.version(folder: evidence.folderURL)
        let coldMS = Date().timeIntervalSince(started) * 1000
        var warmMS: [Double] = []
        for _ in 0..<5 {
            let start = Date()
            let warm = try await evidence.versionCache.version(folder: evidence.folderURL)
            warmMS.append(Date().timeIntervalSince(start) * 1000)
            XCTAssertTrue(warm.cacheHit)
            XCTAssertEqual(warm.hashedByteCount, 0)
            XCTAssertEqual(warm.digest, cold.digest)
        }
        var legacy = SHA256()
        legacy.update(data: Data(evidence.folderURL.path.utf8))
        let files = (FileManager.default.enumerator(at: evidence.folderURL,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])!.allObjects as! [URL])
            .sorted { $0.path < $1.path }
        for file in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            legacy.update(data: Data(file.path.utf8))
            legacy.update(data: try Data(contentsOf: file))
        }
        XCTAssertEqual(cold.digest, legacy.finalize().map { String(format: "%02x", $0) }.joined())
        let report: [String: Any] = ["coldMilliseconds": coldMS, "warmMilliseconds": warmMS,
            "coldHashedBytes": cold.hashedByteCount, "warmHashedBytes": 0, "sha256": cold.digest,
            "legacyHashPreserved": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("knowledge-cache-benchmark.json"))
    }
}
