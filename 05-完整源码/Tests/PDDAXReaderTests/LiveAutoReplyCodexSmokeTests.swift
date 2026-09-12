import XCTest
@testable import PDDAXReader

final class LiveAutoReplyCodexSmokeTests: XCTestCase {
    func testLiveChatGPTCodexGeneratesReplyFromPackagedV2Evidence() async throws {
        guard ProcessInfo.processInfo.environment["PDD_LIVE_CODEX_SMOKE"] == "1" else {
            throw XCTSkip("set PDD_LIVE_CODEX_SMOKE=1 to run the real local Codex smoke test")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let resources = root.appendingPathComponent("Resources", isDirectory: true)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-live-codex-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let codex = try XCTUnwrap(CodexInstallation.resolve())
        let knowledgeBaseURL = resources.appendingPathComponent(
            "KnowledgeBase/Grozziie-China-KB-2026-08-24.zip"
        )
        let knowledgeSHA256 = try await KnowledgeBaseVersioner().version(url: knowledgeBaseURL)
        let retriever = V2KnowledgeRetriever(
            pythonURL: URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12"),
            scriptURL: resources.appendingPathComponent("V2Knowledge/retrieve_top12.py"),
            workerScriptURL: resources.appendingPathComponent("V2Knowledge/serve_top12.py"),
            sitePackagesURL: resources.appendingPathComponent("V2Knowledge/site-packages", isDirectory: true),
            seedCacheURL: resources.appendingPathComponent("V2Knowledge/cache", isDirectory: true),
            writableCacheURL: temporary.appendingPathComponent("cache", isDirectory: true),
            knowledgeBaseSHA256: knowledgeSHA256
        )
        let evidence = KnowledgeEvidenceService(
            retriever: retriever,
            versioner: KnowledgeBaseVersioner(),
            knowledgeBaseURL: knowledgeBaseURL
        )
        let generator = AutoReplyCodexGenerator(
            executableURL: codex,
            sessionRegistry: CodexSessionRegistry(rootDirectory: temporary),
            evidencePreparer: evidence,
            loginStatusProvider: CodexLoginCache(),
            timeout: 180
        )
        let message = PDDChatMessage(
            id: "smoke-customer-1", sender: .customer, content: "M880如何安装？",
            displayTime: "10:00", kind: .text, capturedAt: Date()
        )
        let timeline = try AutoReplyTimeline.make(messages: [message])
        let capture = AutoReplyCapture(
            uid: "GZC-999999999", fullHistory: [message],
            batch: try timeline.freeze(after: .empty), customerCursor: timeline.cursor,
            unexpectedServiceMessageIDs: []
        )

        let result = try await generator.generate(capture)

        XCTAssertFalse(result.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(result.diagnostic?.knowledge.mode, .v2Top12)
        XCTAssertFalse(result.diagnostic?.knowledge.selectedDocuments.isEmpty ?? true)
        XCTAssertTrue(result.diagnostic?.events.contains(where: { $0.type == "turn.completed" }) == true)
        XCTAssertFalse(result.diagnostic?.events.contains(where: {
            let type = $0.type.lowercased()
            return type.contains("command") || type.contains("tool")
                || type.contains("mcp") || type.contains("web")
        }) == true)
    }

    func testLiveChatGPTCodexGeneratesReplyFromPDDVideoFrames() async throws {
        guard ProcessInfo.processInfo.environment["PDD_LIVE_VIDEO_CODEX_SMOKE"] == "1",
              let videoPath = ProcessInfo.processInfo.environment["PDD_LIVE_VIDEO_FILE"] else {
            throw XCTSkip("set PDD_LIVE_VIDEO_CODEX_SMOKE=1 and PDD_LIVE_VIDEO_FILE")
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-live-video-codex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let videoURL = URL(fileURLWithPath: videoPath)
        let summary = try await PDDVideoFileInspector.inspect(videoURL)
        let frames = try await PDDVideoFrameExtractor().extractFrames(
            from: videoURL, durationSeconds: summary.durationSeconds,
            destinationDirectory: temporary.appendingPathComponent("frames")
        )
        let message = PDDChatMessage(
            id: "live-video-1", sender: .customer, content: "[视频]",
            displayTime: "20:29", kind: .video, capturedAt: Date()
        )
        let timeline = try AutoReplyTimeline.make(messages: [message])
        var capture = AutoReplyCapture(
            uid: "PDD-NAME-0123456789abcdef01234567", fullHistory: [message],
            batch: try timeline.freeze(after: .empty), customerCursor: timeline.cursor,
            unexpectedServiceMessageIDs: []
        )
        capture.videoAttachments = [AutoReplyVideoAttachment(
            messageID: message.id, localURL: videoURL, sha256: summary.sha256,
            byteCount: summary.byteCount, durationSeconds: summary.durationSeconds,
            width: summary.width, height: summary.height, videoCodec: summary.videoCodec,
            audioCodec: summary.audioCodec, frames: frames, transcript: nil,
            diagnostic: "语音未转写"
        )]
        let generator = AutoReplyCodexGenerator(
            executableURL: try XCTUnwrap(CodexInstallation.resolve()),
            sessionRegistry: CodexSessionRegistry(rootDirectory: temporary),
            loginStatusProvider: CodexLoginCache(), timeout: 180
        )

        let result = try await generator.generate(capture)

        XCTAssertFalse(result.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(result.diagnostic?.events.contains { $0.type == "turn.completed" } == true)
        print("LIVE_PDD_VIDEO_CODEX_REPLY=\(result.reply)")
    }
}
