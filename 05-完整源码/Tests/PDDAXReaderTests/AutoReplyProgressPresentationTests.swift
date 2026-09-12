import XCTest
@testable import PDDAXReader

final class AutoReplyProgressPresentationTests: XCTestCase {
    func testMessageSourceLabelDistinguishesAXAndProvisionalOCR() {
        let axImage = PDDChatMessage(
            id: "middlePanel_list_100", sender: .customer, content: "[图片]",
            displayTime: nil, kind: .image, capturedAt: Date()
        )
        let axText = PDDChatMessage(
            id: "middlePanel_list_text", sender: .customer, content: "文字",
            displayTime: nil, kind: .text, capturedAt: Date()
        )
        let ocrText = PDDChatMessage(
            id: "ocr-provisional-text", sender: .customer, content: "临时文字",
            displayTime: nil, kind: .text, capturedAt: Date()
        )
        let axFallbackImage = PDDChatMessage(
            id: "fallback-image", sender: .customer, content: "[图片]",
            displayTime: nil, kind: .image, capturedAt: Date()
        )
        let axVideo = PDDChatMessage(
            id: "middlePanel_list_video", sender: .customer, content: "[视频]",
            displayTime: nil, kind: .video, capturedAt: Date()
        )

        XCTAssertEqual(AutoReplyProgressPresentation.messageSourceLabel(axImage), BilingualText.lines("AX图片", "AX image"))
        XCTAssertEqual(AutoReplyProgressPresentation.messageSourceLabel(axFallbackImage), BilingualText.lines("AX图片", "AX image"))
        XCTAssertEqual(AutoReplyProgressPresentation.messageSourceLabel(axVideo), BilingualText.lines("AX视频", "AX video"))
        XCTAssertEqual(AutoReplyProgressPresentation.messageSourceLabel(axText), BilingualText.lines("AX", "AX"))
        XCTAssertEqual(AutoReplyProgressPresentation.messageSourceLabel(ocrText), BilingualText.lines("OCR临时", "Temporary OCR"))
    }

    func testCurrentAXOwnerTakesPriorityOverBackgroundGeneration() {
        let headline = AutoReplyProgressPresentation.headline(
            isRunning: true,
            currentUIOwner: "capture:GZC-000001",
            jobs: [job(state: .generating)],
            liveGenerationCount: 1
        )

        XCTAssertEqual(headline, BilingualText.lines("GZC-000001 · AX 正在读取；失效时才启用尾部 OCR", "GZC-000001 · Reading with AX; tail OCR is used only if AX fails"))
    }

    func testTransferOwnerShowsHumanTransferProgress() {
        XCTAssertEqual(
            AutoReplyProgressPresentation.headline(
                isRunning: true, currentUIOwner: "transfer:PDD-NAME-customer",
                jobs: [], liveGenerationCount: 0
            ),
            BilingualText.lines("PDD-NAME-customer · 正在无原因直接转人工", "PDD-NAME-customer · Transferring directly to a human without a reason")
        )
        XCTAssertEqual(
            AutoReplyProgressPresentation.progressValue(
                currentUIOwner: "transfer:PDD-NAME-customer", jobs: []
            ),
            0.97
        )
    }

    func testGeneratingJobShowsCustomerAndCLICount() {
        let headline = AutoReplyProgressPresentation.headline(
            isRunning: true,
            currentUIOwner: nil,
            jobs: [job(state: .generating)],
            liveGenerationCount: 1
        )

        XCTAssertEqual(headline, BilingualText.lines("GZC-000001 · Codex 正在生成回复 · CLI 1", "GZC-000001 · Codex is generating a reply · CLI 1"))
    }

    func testIdleRunningStateExplainsPixelRedDotWait() {
        XCTAssertEqual(
            AutoReplyProgressPresentation.headline(
                isRunning: true, currentUIOwner: nil, jobs: [], liveGenerationCount: 0
            ),
            BilingualText.lines("等待截图红点；无红点不读取正文、不生成、不发送", "Waiting for a screenshot red dot; without one, no text is read, generated, or sent")
        )
    }

    func testCaptureProgressExplainsAXFirstAndConditionalOCR() {
        XCTAssertEqual(
            AutoReplyProgressPresentation.headline(
                isRunning: true, currentUIOwner: "capture:GZC-000001",
                jobs: [], liveGenerationCount: 0
            ),
            BilingualText.lines("GZC-000001 · AX 正在读取；失效时才启用尾部 OCR", "GZC-000001 · Reading with AX; tail OCR is used only if AX fails")
        )
    }

    func testProgressTracksTheAutomaticReplyPipeline() {
        XCTAssertEqual(
            AutoReplyProgressPresentation.progressValue(
                currentUIOwner: nil, jobs: [job(state: .generating)]
            ),
            0.55
        )
        XCTAssertEqual(
            AutoReplyProgressPresentation.progressValue(
                currentUIOwner: "send:GZC-000001", jobs: [job(state: .sending)]
            ),
            0.90
        )
        XCTAssertNil(AutoReplyProgressPresentation.progressValue(currentUIOwner: nil, jobs: []))
    }

    func testKnowledgeSummaryDistinguishesV2AndFallback() {
        let v2 = KnowledgeRetrievalDiagnostic(
            mode: .v2Top12, knowledgeBaseSHA256: "abcdef", selectedDocuments: ["a.md", "b.md"],
            contextSHA256: "ctx", durationMilliseconds: 88, error: nil
        )
        let fallback = KnowledgeRetrievalDiagnostic(
            mode: .fullZipFallback, knowledgeBaseSHA256: "abcdef", selectedDocuments: [],
            contextSHA256: nil, durationMilliseconds: 40, error: "模型缓存缺失"
        )

        XCTAssertEqual(AutoReplyProgressPresentation.knowledgeSummary(v2), BilingualText.lines("V2 Top-12 · 2份资料 · 88ms", "V2 Top-12 · 2 documents · 88ms"))
        XCTAssertEqual(AutoReplyProgressPresentation.knowledgeSummary(fallback), BilingualText.lines("完整 ZIP 回退 · 40ms · 模型缓存缺失", "Full-ZIP fallback · 40ms · 模型缓存缺失"))
    }

    func testIdleWarningSaysSchedulerContinues() {
        XCTAssertEqual(
            AutoReplyProgressPresentation.headline(
                isRunning: true, currentUIOwner: nil, jobs: [], liveGenerationCount: 0,
                lastRuntimeIssue: "AX 暂时失败"
            ),
            BilingualText.lines("错误后继续扫描 · AX 暂时失败", "Continuing to scan after an error · AX 暂时失败")
        )
    }

    func testIdleScannerDoesNotRemainStuckOnLatestVideoCompletion() {
        let status = PDDVideoProgressStatus(
            uid: "PDD-one", messageID: "v1", phase: .readyForGeneration,
            detail: nil, timestamp: Date()
        )
        XCTAssertEqual(
            AutoReplyProgressPresentation.headline(
                isRunning: true, currentUIOwner: nil, jobs: [], liveGenerationCount: 0,
                latestVideoStatus: status
            ),
            BilingualText.lines("等待截图红点；无红点不读取正文、不生成、不发送", "Waiting for a screenshot red dot; without one, no text is read, generated, or sent")
        )
    }

    func testActiveDownloadOverridesReadyReplyAndCaptureHeadline() {
        let status = PDDVideoProgressStatus(
            uid: "PDD-video", messageID: "v1", phase: .downloading,
            detail: nil, timestamp: Date()
        )

        XCTAssertEqual(
            AutoReplyProgressPresentation.headline(
                isRunning: true,
                currentUIOwner: "capture:PDD-video",
                jobs: [job(state: .ready)],
                liveGenerationCount: 0,
                latestVideoStatus: status
            ),
            BilingualText.lines("PDD-video · 视频后台下载中", "PDD-video · Downloading video in the background")
        )
    }

    func testVideoRetryAndFallbackStatusesRemainVisible() {
        XCTAssertEqual(
            AutoReplyProgressPresentation.videoStageName(.waitingForRetry),
            BilingualText.lines("视频下载等待后台重试", "Video download is waiting for a background retry")
        )
        XCTAssertEqual(
            AutoReplyProgressPresentation.videoStageName(.fallbackRequired),
            BilingualText.lines("视频暂不可用，已进入回复队列", "Video is temporarily unavailable and has entered the reply queue")
        )
    }

    func testParkedRevisionAndCompletedUncertainHaveHonestNonBlockingLabels() {
        var parked = job(state: .quarantined)
        parked.stageAttempt = 2
        var uncertain = job(state: .completed)
        uncertain.deliveryOutcome = .uncertain

        XCTAssertEqual(
            AutoReplyProgressPresentation.jobStageName(parked),
            BilingualText.lines("revision 1 已停放（第 2 次失败，不阻塞其他用户）", "Revision 1 parked (failure 2; other users are not blocked)")
        )
        XCTAssertEqual(
            AutoReplyProgressPresentation.jobStageName(uncertain),
            BilingualText.lines("已完成 · 发送结果不确定（不会自动重发）", "Completed · send result uncertain (will not resend automatically)")
        )
    }

    private func job(state: AutoReplyJobState) -> AutoReplyJob {
        AutoReplyJob(
            id: UUID(), uid: "GZC-000001", sequence: 8, state: state,
            capture: AutoReplyCapture(
                uid: "GZC-000001", fullHistory: [], batch: nil,
                customerCursor: .empty, unexpectedServiceMessageIDs: []
            ),
            reply: nil, deliveryOutcome: nil, confirmedServiceMessageID: nil,
            retries: 0, nextAttemptAt: nil, lastError: nil
        )
    }
}
