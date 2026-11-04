import XCTest
@testable import PDDAXReader

final class HistoryContinuationTests: XCTestCase {
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
