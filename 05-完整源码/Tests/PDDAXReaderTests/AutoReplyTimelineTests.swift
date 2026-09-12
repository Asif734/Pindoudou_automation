import XCTest
@testable import PDDAXReader

final class AutoReplyTimelineTests: XCTestCase {
    func testEarlierCursorRemainsValidPrefixAfterLaterMessagesAppend() throws {
        let first = message("A", .customer, .text, "A")
        let firstTimeline = try AutoReplyTimeline.make(messages: [first])
        let appended = try AutoReplyTimeline.make(messages: [
            first,
            message("B", .customer, .text, "B"),
            message("C", .customer, .text, "C")
        ])

        XCTAssertTrue(appended.validatesPrefix(firstTimeline.cursor))
        XCTAssertFalse(appended.validatesPrefix(AutoReplyCursor(
            count: 1, digest: String(repeating: "f", count: 64)
        )))
    }
    func testTimelineIncludesCustomerImagesButExcludesServiceMessages() throws {
        let messages = [
            message("m1", .customer, .image, "[图片]"),
            message("m2", .customer, .text, "怎么安装"),
            message("m3", .customer, .link, "https://example.test/manual"),
            message("m4", .service, .text, "旧回复")
        ]

        let timeline = try AutoReplyTimeline.make(messages: messages)

        XCTAssertEqual(timeline.events.map(\.messageID), ["m1", "m2", "m3"])
        XCTAssertEqual(timeline.cursor.count, 3)
        XCTAssertEqual(try timeline.freeze(after: .empty)?.events.map(\.messageID), ["m1", "m2", "m3"])
    }

    func testRepeatedTextWithDifferentMessageIDsRemainsTwoEvents() throws {
        let timeline = try AutoReplyTimeline.make(messages: [
            message("m1", .customer, .text, "重复"),
            message("m2", .customer, .text, "重复")
        ])

        XCTAssertEqual(timeline.events.map(\.messageID), ["m1", "m2"])
        XCTAssertEqual(timeline.cursor.count, 2)
    }

    func testFreezeRejectsCursorWhoseDigestIsNotCurrentPrefix() throws {
        let timeline = try AutoReplyTimeline.make(messages: [message("m1", .customer, .text, "A")])
        let invalid = AutoReplyCursor(count: 1, digest: String(repeating: "f", count: 64))

        XCTAssertThrowsError(try timeline.freeze(after: invalid)) { error in
            XCTAssertEqual(error as? AutoReplyTimelineError, .invalidPrefix)
        }
    }

    func testCustomerImageAloneCreatesFrozenBatch() throws {
        let timeline = try AutoReplyTimeline.make(messages: [message("img", .customer, .image, "[图片]")])

        let batch = try XCTUnwrap(timeline.freeze(after: .empty))
        XCTAssertEqual(batch.events, [
            ActionableCustomerEvent(
                messageID: "img", kind: .image, content: "[图片]", displayTime: "10:00"
            )
        ])
    }

    private func message(
        _ id: String,
        _ sender: ChatSender,
        _ kind: ChatContentKind,
        _ content: String
    ) -> PDDChatMessage {
        PDDChatMessage(
            id: id,
            sender: sender,
            content: content,
            displayTime: "10:00",
            kind: kind,
            capturedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
    }
}
