import XCTest
@testable import PDDAXReader

final class PDDVideoAnalysisReportCacheTests: XCTestCase {
    func testReportSurvivesRestartAndSessionResetWithoutResendingFramesButNewQuestionReachesCodex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let frame = root.appendingPathComponent("frame.jpg")
        let mp4 = root.appendingPathComponent("video.mp4")
        try Data([0xff, 0xd8, 0xff]).write(to: frame)
        try Data("video".utf8).write(to: mp4)
        let runner = ReportRunner()
        let registry = CodexSessionRegistry(rootDirectory: root)
        func input(_ id: String, question: String, uid: String = "GZC-000001") throws -> AutoReplyCapture {
            let history = [PDDChatMessage(id: id, sender: .customer, content: question,
                displayTime: nil, kind: .video, capturedAt: Date())]
            let timeline = try AutoReplyTimeline.make(messages: history)
            return AutoReplyCapture(uid: uid, fullHistory: history,
                batch: try timeline.freeze(after: .empty), customerCursor: timeline.cursor,
                unexpectedServiceMessageIDs: [], videoAttachments: [video(id, mp4: mp4, frame: frame)])
        }
        func generator() -> AutoReplyCodexGenerator {
            .init(executableURL: URL(fileURLWithPath: "/bin/echo"), runner: runner,
                sessionRegistry: registry, evidencePreparer: FallbackKnowledgeEvidencePreparer())
        }
        _ = try await generator().generate(input("morning", question: "What does this show?"))
        try registry.invalidate(uid: "GZC-000001")
        // A recreated generator and a fresh Codex session must still reuse the saved report.
        _ = try await generator().generate(input("afternoon", question: "Why is that red light still on?"))
        _ = try await generator().generate(input("other", question: "What does this show?", uid: "GZC-000002"))
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls[0].arguments.contains("-i"))
        XCTAssertFalse(calls[1].arguments.contains("-i"), "report reuse avoids image input tokens")
        XCTAssertTrue(calls[1].prompt.contains("Why is that red light still on?"))
        XCTAssertTrue(calls[1].prompt.contains("message_id=afternoon"))
        XCTAssertTrue(calls[1].prompt.contains("At 1s the red indicator is lit"))
        XCTAssertTrue(calls[1].prompt.contains(frame.path), "new detail can be checked if missing from report")
        XCTAssertTrue(calls[2].arguments.contains("-i"), "customers never share analysis state")
    }

    func testInvalidMissingOrMismatchedReportsFallBackToNormalAnalysis() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PDDVideoAnalysisReportCache(root: root)
        let original = video("morning")
        let submission = HistorySubmission(mode: .full, historyJSONL: "", imageAttachments: [],
            videoAttachments: [original], checkpoint: .init(historyByteCount: 0, prefixSHA256: "", attachmentSHA256: [:]))
        XCTAssertEqual(cache.reusingReports(in: submission, uid: "one").videoAttachments.count, 1)
        try cache.save([.init(sha256: "same", observations: "", limitations: "unclear")], uid: "one", analyzedVideos: [original])
        XCTAssertEqual(cache.reusingReports(in: submission, uid: "one").videoAttachments.count, 1)
        try cache.save([.init(sha256: "same", observations: "red light", limitations: "cause unknown")], uid: "one", analyzedVideos: [original])
        XCTAssertEqual(cache.reusingReports(in: submission, uid: "one").reusedVideoAnalyses.count, 1)
        var changed = submission
        changed.videoAttachments = [video("afternoon", sha: "different")]
        XCTAssertEqual(cache.reusingReports(in: changed, uid: "one").videoAttachments.count, 1)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let file as URL in enumerator where file.pathExtension == "json" {
            try Data("broken".utf8).write(to: file)
        }
        XCTAssertEqual(cache.reusingReports(in: submission, uid: "one").videoAttachments.count, 1)
    }

    private func video(_ id: String, mp4: URL = URL(fileURLWithPath: "/tmp/video.mp4"),
                       frame: URL = URL(fileURLWithPath: "/tmp/frame.jpg"), sha: String = "same") -> AutoReplyVideoAttachment {
        .init(messageID: id, localURL: mp4, sha256: sha, byteCount: 5, durationSeconds: 3,
            width: 100, height: 100, videoCodec: "H.264", audioCodec: nil,
            frames: [.init(timestampSeconds: 1, localURL: frame)], transcript: nil, diagnostic: nil)
    }
}

private actor ReportRunner: CodexProcessRunning {
    struct Call { let arguments: [String]; let prompt: String }
    var calls: [Call] = []
    func run(executable: URL, arguments: [String], stdin: String, timeout: TimeInterval) async throws -> CodexProcessResult {
        calls.append(.init(arguments: arguments, prompt: stdin))
        let schemaIndex = try XCTUnwrap(arguments.firstIndex(of: "--output-schema"))
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: arguments[schemaIndex + 1]))) as? [String: Any])
        XCTAssertTrue((schema["required"] as? [String] ?? []).contains("video_analysis_reports"))
        let resultIndex = try XCTUnwrap(arguments.firstIndex(of: "-o"))
        let report: [[String: String]] = arguments.contains("-i")
            ? [["sha256": "same", "observations": "At 1s the red indicator is lit", "limitations": "Cause not visible"]] : []
        let doc: [String: Any] = ["action": "reply", "reply_text": "The red indicator is lit.",
            "transfer_reason": "none", "video_analysis_reports": report]
        try JSONSerialization.data(withJSONObject: doc).write(to: URL(fileURLWithPath: arguments[resultIndex + 1]))
        return .init(exitCode: 0, stdout: "{\"type\":\"thread.started\",\"thread_id\":\"report-thread\"}\n{\"type\":\"turn.completed\"}\n", stderr: "")
    }
}
