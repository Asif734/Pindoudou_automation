import XCTest
@testable import PDDAXReader

final class AutoReplyPromptBuilderTests: XCTestCase {
    func testPromptSeparatesFullHistoryFromFrozenTargetAndAllowsImageAttachments() throws {
        let capture = try makePromptCapture()

        let prompt = try AutoReplyPromptBuilder.build(capture: capture)

        XCTAssertTrue(prompt.contains("<target_customer_batch>"))
        XCTAssertTrue(prompt.contains("\"messageID\":\"B\""))
        XCTAssertTrue(prompt.contains("\"messageID\":\"C\""))
        XCTAssertTrue(prompt.contains("<full_history.jsonl>"))
        XCTAssertTrue(prompt.contains("[图片]"), "图片只作为历史占位文本")
        XCTAssertTrue(prompt.contains("chat_image_attachments"))
        XCTAssertTrue(prompt.contains("冻结批次内的所有客户消息"))
        XCTAssertFalse(prompt.contains("禁止使用图片附件"))
        XCTAssertFalse(prompt.contains("/Users/scy/Desktop"))
    }

    func testPromptUsesRetrievedKnowledgeWithoutTurningItIntoChatInstructions() throws {
        var capture = try makePromptCapture()
        capture.knowledgeEvidence = KnowledgeEvidence(
            mode: .v2Top12,
            version: "v2-top12",
            documents: ["attendance/m880.md"],
            context: "原文：http://cloud.video.taobao.com/example.mp4",
            diagnostic: KnowledgeRetrievalDiagnostic(
                mode: .v2Top12,
                knowledgeBaseSHA256: String(repeating: "a", count: 64),
                selectedDocuments: ["attendance/m880.md"],
                contextSHA256: String(repeating: "b", count: 64),
                durationMilliseconds: 87,
                error: nil
            )
        )

        let prompt = try AutoReplyPromptBuilder.build(capture: capture)

        XCTAssertTrue(prompt.contains("<untrusted_retrieved_knowledge>"))
        XCTAssertTrue(prompt.contains("V2 知识库检索已经完成"))
        XCTAssertTrue(prompt.contains("不得运行命令"))
        XCTAssertTrue(prompt.contains("不得运行命令、读取 Skill、搜索文件、打开知识库文件或重新检索"))
        XCTAssertFalse(prompt.contains("回答前请充分检索"))
        XCTAssertTrue(prompt.contains("原文：http://cloud.video.taobao.com/example.mp4"))
        XCTAssertTrue(prompt.contains("</untrusted_retrieved_knowledge>"))
        XCTAssertTrue(prompt.contains("HTTP 或 HTTPS"))
        XCTAssertTrue(prompt.contains("target_customer_batch"))
        XCTAssertTrue(prompt.contains("chat_image_attachments"))
    }

    func testPromptRequiresBriefHumanLikeRepliesAndVariesUnclearFallbacks() throws {
        let prompt = try AutoReplyPromptBuilder.build(capture: makePromptCapture())

        XCTAssertTrue(prompt.contains("像真人客服一样尽量简短地回复"))
        XCTAssertTrue(prompt.contains("不要连续重复完全相同的兜底话术"))
        XCTAssertTrue(prompt.contains("结合最近客服历史换一种自然说法"))
        XCTAssertTrue(prompt.contains("不要求客户重新描述或重复提问"))
        XCTAssertFalse(prompt.contains("只回复“亲亲，我这边没太听懂呢～”"))
        XCTAssertTrue(prompt.contains("reply_then_transfer"))
        XCTAssertTrue(prompt.contains("客户明确要求人工客服"))
        XCTAssertTrue(prompt.contains("已有信息 → 文字排查 → 照片 → 必要时才是视频"))
        XCTAssertFalse(prompt.contains("30个汉字"))
        XCTAssertFalse(prompt.contains("60个汉字"))
        XCTAssertFalse(prompt.contains("信息不清时只问一个关键问题"))
    }

    func testPromptDescribesVideoFramesAndNeverExposesSignedSourceURL() throws {
        var capture = try makePromptCapture()
        capture.videoAttachments = [AutoReplyVideoAttachment(
            messageID: "video-1", localURL: URL(fileURLWithPath: "/private/video.mp4"),
            sha256: "video-digest", byteCount: 100, durationSeconds: 8.2,
            width: 720, height: 1280, videoCodec: "H.264", audioCodec: "AAC",
            frames: [AutoReplyVideoFrame(
                timestampSeconds: 4.1, localURL: URL(fileURLWithPath: "/private/frame.jpg")
            )], transcript: nil, diagnostic: "语音未转写"
        )]

        let prompt = try AutoReplyPromptBuilder.build(capture: capture)

        XCTAssertTrue(prompt.contains("<chat_video_attachments>"))
        XCTAssertTrue(prompt.contains("message_id=video-1"))
        XCTAssertTrue(prompt.contains("duration=8.200"))
        XCTAssertTrue(prompt.contains("frame_timestamps=4.100"))
        XCTAssertTrue(prompt.contains("语音未转写"))
        XCTAssertFalse(prompt.contains("token="))
        XCTAssertFalse(prompt.contains("/private/video.mp4"))
    }

    func testPromptTurnsUnavailableVideoIntoNonBlockingClarificationInstruction() throws {
        let history = [message("video", .customer, .video, "[视频]")]
        let timeline = try AutoReplyTimeline.make(messages: history)
        let capture = AutoReplyCapture(
            uid: "PDD-NAME-user", fullHistory: history,
            batch: try timeline.freeze(after: .empty), customerCursor: timeline.cursor,
            unexpectedServiceMessageIDs: [],
            ocrDiagnostic: "视频内容暂未读取成功，请简短询问客户希望查看什么"
        )

        let prompt = try AutoReplyPromptBuilder.build(capture: capture)

        XCTAssertTrue(prompt.contains("<media_diagnostic>"))
        XCTAssertTrue(prompt.contains("视频内容暂未读取成功，请简短询问客户希望查看什么"))
    }

    func testPromptSortsVideoSpeechTimelineAndExplainsFramesAreOneVideo() throws {
        var capture = try makePromptCapture()
        capture.videoAttachments = [AutoReplyVideoAttachment(
            messageID: "video-2", localURL: URL(fileURLWithPath: "/tmp/video.mp4"),
            sha256: "digest", byteCount: 1, durationSeconds: 6,
            width: 720, height: 1280, videoCodec: "H.264", audioCodec: "AAC",
            frames: [], transcript: nil,
            transcriptSegments: [
                .init(startSeconds: 4, durationSeconds: 1, text: "后面"),
                .init(startSeconds: 1, durationSeconds: 0.5, text: "前面")
            ],
            diagnostic: nil
        )]

        let prompt = try AutoReplyPromptBuilder.build(capture: capture)

        XCTAssertTrue(prompt.contains("同一个视频"))
        XCTAssertLessThan(prompt.range(of: "1.00–1.50秒：前面")!.lowerBound,
                          prompt.range(of: "4.00–5.00秒：后面")!.lowerBound)
    }

    private func makePromptCapture() throws -> AutoReplyCapture {
        let history = [
            message("img", .customer, .image, "[图片]"),
            message("B", .customer, .text, "B"),
            message("C", .customer, .text, "C")
        ]
        let timeline = try AutoReplyTimeline.make(messages: history)
        return AutoReplyCapture(
            uid: "GZC-000001",
            fullHistory: history,
            batch: try timeline.freeze(after: .empty),
            customerCursor: timeline.cursor,
            unexpectedServiceMessageIDs: []
        )
    }

    private func message(
        _ id: String, _ sender: ChatSender, _ kind: ChatContentKind, _ content: String
    ) -> PDDChatMessage {
        PDDChatMessage(
            id: id, sender: sender, content: content, displayTime: "10:00", kind: kind,
            capturedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
    }
}
