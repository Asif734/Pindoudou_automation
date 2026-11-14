import XCTest
@testable import PDDAXReader

final class HistoryContinuationTests: XCTestCase {
    func testOnlyLatestFiftyHistoryMessagesAreSubmittedWithoutTruncatingCurrentTargets() throws {
        let history = (1...80).map { message("id-\($0)", "context-\($0)") }
        let capture = try makeCapture(history)
        let submission = try HistoryContinuation.plan(capture: capture, after: nil)
        let lines = submission.historyJSONL.split(separator: "\n")
        XCTAssertEqual(lines.count, 50)
        XCTAssertTrue(lines.first?.contains("context-31") == true)
        XCTAssertTrue(lines.last?.contains("context-80") == true)
        XCTAssertFalse(submission.historyJSONL.contains("\"id\":\"id-1\""))
        let prompt = try AutoReplyPromptBuilder.buildInitial(capture: capture, submission: submission)
        let target = try XCTUnwrap(prompt.components(separatedBy: "<target_customer_batch>").last?
            .components(separatedBy: "</target_customer_batch>").first)
        XCTAssertEqual(target.split(separator: "\n").count, 80, "All current unanswered messages remain targets")
        XCTAssertEqual(capture.fullHistory.count, 80, "Durable history is not shortened")
        XCTAssertEqual(submission.checkpoint.historyMessageLimit, 50)
    }

    func testSlidingWindowRequiresFreshSessionInsteadOfRetainingDroppedHistory() throws {
        let history = (1...50).map { message("id-\($0)", "context-\($0)") }
        let checkpoint = try HistoryContinuation.plan(capture: makeCapture(history), after: nil).checkpoint
        let submission = try HistoryContinuation.plan(
            capture: makeCapture(history + [message("id-51", "context-51")]), after: checkpoint)
        XCTAssertEqual(submission.mode, .full)
        XCTAssertEqual(submission.historyJSONL.split(separator: "\n").count, 50)
        XCTAssertFalse(submission.historyJSONL.contains("\"id\":\"id-1\""))
        XCTAssertTrue(submission.historyJSONL.contains("context-51"))
    }

    func testUnboundedCheckpointCannotResumeEvenWhenPrefixStillMatches() throws {
        let capture = try makeCapture([message("1", "old")])
        let modern = try HistoryContinuation.plan(capture: capture, after: nil).checkpoint
        let unbounded = CodexHistoryCheckpoint(historyByteCount: modern.historyByteCount,
            prefixSHA256: modern.prefixSHA256, attachmentSHA256: modern.attachmentSHA256)
        let submission = try HistoryContinuation.plan(capture: capture, after: unbounded)
        XCTAssertEqual(submission.mode, .full)
        let roundtrip = try JSONDecoder().decode(CodexHistoryCheckpoint.self,
            from: JSONEncoder().encode(submission.checkpoint))
        XCTAssertEqual(roundtrip.historyMessageLimit, 50)
    }

    func testSlidingWindowStillSuppliesCurrentImagesAndVideo() throws {
        let history = (1...70).map { message("id-\($0)", "context-\($0)") }
        var capture = try makeCapture(history)
        capture.imageAttachments = [attachment("id-70", path: "/tmp/current.jpg", digest: "image")]
        capture.videoAttachments = [video("id-69", path: "/tmp/current.mp4", digest: "video")]
        let submission = try HistoryContinuation.plan(capture: capture, after: nil)
        XCTAssertEqual(submission.imageAttachments.map(\.messageID), ["id-70"])
        XCTAssertEqual(submission.videoAttachments.map(\.messageID), ["id-69"])
    }

    func testRecentCachedImageSurvivesFreshWindowButMissingAndOlderMediaDoNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("image.jpg")
        try Data([1]).write(to: imageURL)
        let image = attachment("id-50", path: imageURL.path, digest: "same")
        let outside = attachment("id-1", path: imageURL.path, digest: "same")
        let missing = attachment("id-49", path: root.appendingPathComponent("missing.jpg").path, digest: "missing")
        let history = (1...70).map { message("id-\($0)", "context-\($0)") }
        var original = try makeCapture(Array(history.prefix(50)))
        original.imageAttachments = [image, outside, missing]
        let checkpoint = try HistoryContinuation.plan(capture: original, after: nil).checkpoint
        let restoredCheckpoint = try JSONDecoder().decode(CodexHistoryCheckpoint.self,
            from: JSONEncoder().encode(checkpoint))
        let submission = try HistoryContinuation.plan(capture: makeCapture(history), after: restoredCheckpoint)
        XCTAssertEqual(submission.mode, .full)
        XCTAssertEqual(submission.imageAttachments.map(\.messageID), ["id-50"])
        XCTAssertEqual(submission.checkpoint.contextImages?.map(\.messageID), ["id-50"])
    }

    func testCachedVideoReportIsReusedAfterHistoryWindowRotates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("video.mp4")
        try Data([1]).write(to: videoURL)
        let media = video("id-50", path: videoURL.path, digest: "same-video")
        let history = (1...60).map { message("id-\($0)", "context-\($0)") }
        var original = try makeCapture(Array(history.prefix(50)))
        original.videoAttachments = [media]
        let checkpoint = try HistoryContinuation.plan(capture: original, after: nil).checkpoint
        let cache = PDDVideoAnalysisReportCache(root: root)
        try cache.save([.init(sha256: "same-video", observations: "observed evidence", limitations: "uncertain label")],
            uid: original.uid, analyzedVideos: [media])
        let fresh = try HistoryContinuation.plan(capture: makeCapture(history), after: checkpoint)
        let reused = cache.reusingReports(in: fresh, uid: original.uid)
        XCTAssertEqual(fresh.mode, .full)
        XCTAssertEqual(fresh.videoAttachments.map(\.messageID), ["id-50"])
        XCTAssertTrue(reused.videoAttachments.isEmpty, "Do not analyze the same cached video again")
        XCTAssertEqual(reused.reusedVideoAnalyses.first?.report.observations, "observed evidence")
    }

    func testFirstSubmissionContainsFullHistory() throws {
        let capture = try makeCapture([message("1", "first"), message("2", "second")])

        let submission = try HistoryContinuation.plan(capture: capture, after: nil)

        XCTAssertEqual(submission.mode, .full)
        XCTAssertTrue(submission.historyJSONL.contains("first"))
        XCTAssertTrue(submission.historyJSONL.contains("second"))
    }

    func testStrictAppendSubmitsOnlyHistorySuffix() throws {
        let original = try makeCapture([message("1", "first")])
        let checkpoint = try HistoryContinuation.plan(capture: original, after: nil).checkpoint
        let updated = try makeCapture([message("1", "first"), message("2", "second")])

        let submission = try HistoryContinuation.plan(capture: updated, after: checkpoint)

        XCTAssertEqual(submission.mode, .incremental)
        XCTAssertFalse(submission.historyJSONL.contains("first"))
        XCTAssertTrue(submission.historyJSONL.contains("second"))
    }

    func testEditedHistoryForcesFullSubmission() throws {
        let original = try makeCapture([message("1", "first")])
        let checkpoint = try HistoryContinuation.plan(capture: original, after: nil).checkpoint
        let rewritten = try makeCapture([message("1", "changed"), message("2", "second")])

        let submission = try HistoryContinuation.plan(capture: rewritten, after: checkpoint)

        XCTAssertEqual(submission.mode, .full)
        XCTAssertTrue(submission.historyJSONL.contains("changed"))
    }

    func testSameImageDigestAtNewPathIsNotResubmitted() throws {
        var original = try makeCapture([message("1", "first")])
        original.imageAttachments = [attachment("old", path: "/tmp/old.jpg", digest: "same")]
        let checkpoint = try HistoryContinuation.plan(capture: original, after: nil).checkpoint
        var updated = try makeCapture([message("1", "first"), message("2", "second")])
        updated.imageAttachments = [
            attachment("old", path: "/tmp/old.jpg", digest: "same"),
            attachment("copy", path: "/tmp/copy.jpg", digest: "same"),
        ]

        let submission = try HistoryContinuation.plan(capture: updated, after: checkpoint)

        XCTAssertTrue(submission.imageAttachments.isEmpty)
    }

    func testResentVideoWithSameDigestAndNewMessageIDIsSubmittedAgain() throws {
        var original = try makeCapture([message("1", "[视频]")])
        original.videoAttachments = [video("old", path: "/tmp/old.mp4", digest: "same-video")]
        let checkpoint = try HistoryContinuation.plan(capture: original, after: nil).checkpoint
        var updated = try makeCapture([message("1", "[视频]"), message("2", "new")])
        updated.videoAttachments = [video("copy", path: "/tmp/copy.mp4", digest: "same-video")]

        let submission = try HistoryContinuation.plan(capture: updated, after: checkpoint)

        XCTAssertEqual(submission.videoAttachments.map(\.messageID), ["copy"])
    }

    func testSameVideoMessageIsNotResubmittedAfterInterveningTextOnlyTurn() throws {
        var morning = try makeCapture([message("morning", "[视频]")])
        morning.videoAttachments = [video("morning", path: "/tmp/morning.mp4", digest: "same")]
        let checkpoint = try HistoryContinuation.plan(capture: morning, after: nil).checkpoint
        let textOnly = try makeCapture(morning.fullHistory + [message("thanks", "thank you")])
        let textCheckpoint = try HistoryContinuation.plan(capture: textOnly, after: checkpoint).checkpoint
        let encoded = try JSONEncoder().encode(textCheckpoint)
        let restored = try JSONDecoder().decode(CodexHistoryCheckpoint.self, from: encoded)
        var later = try makeCapture(textOnly.fullHistory + [message("question", "explain the old video")])
        later.videoAttachments = [video("morning", path: "/tmp/restored.mp4", digest: "same")]
        XCTAssertTrue(try HistoryContinuation.plan(capture: later, after: restored).videoAttachments.isEmpty)
        later.videoAttachments.append(video("afternoon", path: "/tmp/afternoon.mp4", digest: "same"))
        XCTAssertEqual(try HistoryContinuation.plan(capture: later, after: restored).videoAttachments.map(\.messageID), ["afternoon"])
    }

    func testLegacyHashOnlyCheckpointCannotSuppressNewVideoMessage() throws {
        let morning = try makeCapture([message("morning", "[视频]")])
        let modern = try HistoryContinuation.plan(capture: morning, after: nil).checkpoint
        let legacy = CodexHistoryCheckpoint(historyByteCount: modern.historyByteCount,
            prefixSHA256: modern.prefixSHA256, attachmentSHA256: ["/tmp/old.mp4": "same"])
        var afternoon = try makeCapture(morning.fullHistory + [message("afternoon", "[视频]")])
        afternoon.videoAttachments = [video("afternoon", path: "/tmp/afternoon.mp4", digest: "same")]
        XCTAssertEqual(try HistoryContinuation.plan(capture: afternoon, after: legacy).videoAttachments.map(\.messageID), ["afternoon"])
    }

    private func makeCapture(_ history: [PDDChatMessage]) throws -> AutoReplyCapture {
        let timeline = try AutoReplyTimeline.make(messages: history)
        return AutoReplyCapture(
            uid: "GZC-000001", fullHistory: history,
            batch: try timeline.freeze(after: .empty), customerCursor: timeline.cursor,
            unexpectedServiceMessageIDs: []
        )
    }

    private func message(_ id: String, _ content: String) -> PDDChatMessage {
        PDDChatMessage(
            id: id, sender: .customer, content: content, displayTime: "10:00", kind: .text,
            capturedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
    }

    private func attachment(_ id: String, path: String, digest: String) -> AutoReplyImageAttachment {
        AutoReplyImageAttachment(
            messageID: id, sourceURL: URL(string: "https://example.com/\(id)")!,
            localURL: URL(fileURLWithPath: path), mimeType: "image/jpeg", byteCount: 1,
            sha256: digest
        )
    }

    private func video(_ id: String, path: String, digest: String) -> AutoReplyVideoAttachment {
        AutoReplyVideoAttachment(
            messageID: id, localURL: URL(fileURLWithPath: path), sha256: digest,
            byteCount: 100, durationSeconds: 8, width: 720, height: 1280,
            videoCodec: "H.264", audioCodec: "AAC", frames: [], transcript: nil,
            diagnostic: nil
        )
    }
}
