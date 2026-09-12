import XCTest
@testable import PDDAXReader

final class PerUserChatStoreTests: XCTestCase {
    func testAXFirstHistoryStartsEmptyWithoutTouchingPollutedLegacyHistory() throws {
        let root = temporaryRoot("ax-first-isolation")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PerUserChatStore(rootDirectory: root)
        let uid = "PDD-NAME-111111111111111111111111"
        _ = try store.merge(uid: uid, messages: [message("ocr-polluted", .customer, "水印误识别")])
        let legacyURL = root.appendingPathComponent("用户/\(uid)/history.jsonl")
        let legacyBefore = try Data(contentsOf: legacyURL)

        XCTAssertTrue(try store.loadAXFirst(uid: uid).isEmpty)
        let ax = message("middlePanel_list_ax", .customer, "真实AX消息")
        let result = try store.mergeAXFirst(uid: uid, messages: [ax])

        XCTAssertEqual(result.history, [ax])
        XCTAssertEqual(result.fileURL.lastPathComponent, "history-ax-first.jsonl")
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyBefore)
        XCTAssertEqual(try store.load(uid: uid).map(\.id), ["ocr-polluted"])
        XCTAssertEqual(try store.loadAXFirst(uid: uid), [ax])
    }

    func testAXFirstMergeUpdatesSameStableIDWithoutDuplicatingIt() throws {
        let root = temporaryRoot("ax-first-update")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PerUserChatStore(rootDirectory: root)
        let uid = "PDD-NAME-222222222222222222222222"
        let first = PDDChatMessage(
            id: "middlePanel_list_same", sender: .customer, content: "旧解析",
            displayTime: nil, kind: .text, capturedAt: Date(timeIntervalSince1970: 100)
        )
        let corrected = PDDChatMessage(
            id: "middlePanel_list_same", sender: .customer, content: "新解析",
            displayTime: "12:00", kind: .text, capturedAt: Date(timeIntervalSince1970: 200)
        )
        _ = try store.mergeAXFirst(uid: uid, messages: [first])

        let result = try store.mergeAXFirst(uid: uid, messages: [corrected])

        XCTAssertEqual(result.insertedCount, 0)
        XCTAssertEqual(result.history.count, 1)
        XCTAssertEqual(result.history[0].content, "新解析")
        XCTAssertEqual(result.history[0].capturedAt, first.capturedAt)
    }

    func testOCRAuthoritativeMergeRetainsAXImageEvidenceButDropsAXText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-chat-store-hybrid-\(UUID().uuidString)")
        let store = PerUserChatStore(rootDirectory: root)
        _ = try store.merge(uid: "GZC-000001", messages: [
            PDDChatMessage(
                id: "middlePanel_list_image", sender: .customer, content: "[图片]",
                displayTime: nil, kind: .image, capturedAt: .distantPast
            ),
            PDDChatMessage(
                id: "middlePanel_list_service_image", sender: .service, content: "[图片]",
                displayTime: nil, kind: .image, capturedAt: .distantPast
            ),
            PDDChatMessage(
                id: "middlePanel_list_text", sender: .customer, content: "AX文字",
                displayTime: nil, kind: .text, capturedAt: .distantPast
            )
        ])
        let ocrText = PDDChatMessage(
            id: "ocr-text", sender: .customer, content: "OCR文字",
            displayTime: nil, kind: .text, capturedAt: Date()
        )

        let result = try store.mergeOCRAuthoritative(uid: "GZC-000001", messages: [ocrText])

        XCTAssertEqual(result.history.map(\.id), ["middlePanel_list_image", "ocr-text"])
        XCTAssertEqual(result.history.map(\.kind), [.image, .text])
    }

    func testOCRAuthoritativeMergeReordersVisibleImageWhenOCRLaterFindsEarlierText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-chat-store-late-ocr-\(UUID().uuidString)")
        let store = PerUserChatStore(rootDirectory: root)
        let image = PDDChatMessage(
            id: "middlePanel_list_image", sender: .customer, content: "[图片]",
            displayTime: nil, kind: .image, capturedAt: Date(timeIntervalSince1970: 10)
        )
        _ = try store.mergeOCRAuthoritative(uid: "GZC-000001", messages: [image])
        let text = PDDChatMessage(
            id: "ocr-text", sender: .customer, content: "先发的文字",
            displayTime: nil, kind: .text, capturedAt: Date(timeIntervalSince1970: 20)
        )

        let result = try store.mergeOCRAuthoritative(
            uid: "GZC-000001", messages: [text, image]
        )

        XCTAssertEqual(result.history.map(\.id), ["ocr-text", "middlePanel_list_image"])
        XCTAssertEqual(result.history.last?.capturedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(result.insertedCount, 1)
    }

    func testOCRAuthoritativeMergeNeverDeletesTemporarilyMissedMessageBetweenVisibleAnchors() throws {
        let root = temporaryRoot("ocr-missed-middle")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PerUserChatStore(rootDirectory: root)
        let a = message("ocr-a", .customer, "A")
        let b = message("ocr-b", .customer, "B")
        let c = message("ocr-c", .customer, "C")
        _ = try store.mergeOCRAuthoritative(uid: "GZC-000001", messages: [a, b, c])

        let result = try store.mergeOCRAuthoritative(uid: "GZC-000001", messages: [a, c])

        XCTAssertEqual(result.history.map(\.id), ["ocr-a", "ocr-b", "ocr-c"])
        XCTAssertEqual(result.insertedCount, 0)
    }

    func testCrossedImageAnchorPreservesDurableHistoryAndAppendsNewCustomerAtTail() throws {
        let root = temporaryRoot("crossed-image-anchor")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PerUserChatStore(rootDirectory: root)
        let old = message("ocr-old", .customer, "old")
        let image = PDDChatMessage(
            id: "middlePanel_list_image", sender: .customer, content: "[图片]",
            displayTime: nil, kind: .image, capturedAt: Date(timeIntervalSince1970: 101)
        )
        let baki = message("ocr-baki", .customer, "baki")
        let copy = message("ocr-copy", .customer, "复制")
        let tp732 = message("ocr-tp732", .customer, "tp732是什么机器")
        _ = try store.merge(
            uid: "GZC-000001", messages: [old, image, baki, copy, tp732]
        )
        let m880 = message("ocr-m880", .customer, "m880可以打印卷子吗")

        let result = try store.mergeOCRAuthoritative(
            uid: "GZC-000001", messages: [baki, copy, tp732, m880, image]
        )

        XCTAssertEqual(
            result.history.map(\.id),
            ["ocr-old", "middlePanel_list_image", "ocr-baki", "ocr-copy", "ocr-tp732", "ocr-m880"]
        )
        XCTAssertEqual(result.history.last?.content, "m880可以打印卷子吗")
    }

    func testMergeAppendsNewIDsWithoutDuplicatingOrDeletingScrolledHistory() throws {
        let root = temporaryRoot("merge")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PerUserChatStore(rootDirectory: root)
        let m1 = message("1", .customer, "你好")
        let m2 = message("2", .service, "您好")
        let m3 = message("3", .customer, "再试试")

        let first = try store.merge(uid: "GZC-000001", messages: [m1, m2])
        let second = try store.merge(uid: "GZC-000001", messages: [m2, m3])
        let scrolled = try store.merge(uid: "GZC-000001", messages: [m3])

        XCTAssertEqual(first.insertedCount, 2)
        XCTAssertEqual(second.insertedCount, 1)
        XCTAssertEqual(scrolled.insertedCount, 0)
        XCTAssertEqual(scrolled.history.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(try store.load(uid: "GZC-000001"), [m1, m2, m3])
    }

    func testKeepsDifferentUsersIsolated() throws {
        let root = temporaryRoot("isolation")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PerUserChatStore(rootDirectory: root)

        _ = try store.merge(uid: "GZC-000001", messages: [message("1", .customer, "甲")])
        _ = try store.merge(uid: "GZC-000002", messages: [message("2", .customer, "乙")])

        XCTAssertEqual(try store.load(uid: "GZC-000001").map(\.content), ["甲"])
        XCTAssertEqual(try store.load(uid: "GZC-000002").map(\.content), ["乙"])
    }

    func testSameMessageIDRefreshesParsedFieldsButPreservesFirstCaptureTime() throws {
        let root = temporaryRoot("correction")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PerUserChatStore(rootDirectory: root)
        let original = PDDChatMessage(
            id: "same-id",
            sender: .service,
            content: "<AX error -25212>\n没有上线\n已读",
            displayTime: "<AX error -25212>",
            kind: .link,
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let corrected = PDDChatMessage(
            id: "same-id",
            sender: .service,
            content: "没有上线",
            displayTime: nil,
            kind: .text,
            capturedAt: Date(timeIntervalSince1970: 200)
        )
        _ = try store.merge(uid: "GZC-000001", messages: [original])

        let result = try store.merge(uid: "GZC-000001", messages: [corrected])

        XCTAssertEqual(result.insertedCount, 0)
        XCTAssertEqual(result.history[0].content, "没有上线")
        XCTAssertNil(result.history[0].displayTime)
        XCTAssertEqual(result.history[0].kind, .text)
        XCTAssertEqual(result.history[0].capturedAt, original.capturedAt)
    }

    func testSameStableMessageDoesNotBackfillDisplayTimeAndInvalidateCursor() throws {
        let root = temporaryRoot("stable-cursor")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PerUserChatStore(rootDirectory: root)
        let original = PDDChatMessage(
            id: "same-id", sender: .customer, content: "你好", displayTime: nil,
            kind: .text, capturedAt: Date(timeIntervalSince1970: 100)
        )
        let laterObservation = PDDChatMessage(
            id: "same-id", sender: .customer, content: "你好", displayTime: "09:31",
            kind: .text, capturedAt: Date(timeIntervalSince1970: 200)
        )
        _ = try store.merge(uid: "GZC-000001", messages: [original])

        let result = try store.merge(uid: "GZC-000001", messages: [laterObservation])

        XCTAssertNil(result.history[0].displayTime)
    }

    func testRejectsInvalidUID() throws {
        let root = temporaryRoot("invalid")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PerUserChatStore(rootDirectory: root)

        XCTAssertThrowsError(try store.merge(uid: "../escape", messages: []))
    }

    func testCorruptHistoryIsNotOverwritten() throws {
        let root = temporaryRoot("corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let userDirectory = root.appendingPathComponent("用户/GZC-000001", isDirectory: true)
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let historyURL = userDirectory.appendingPathComponent("history.jsonl")
        let corrupt = Data("{not-json}\n".utf8)
        try corrupt.write(to: historyURL)
        let store = PerUserChatStore(rootDirectory: root)

        XCTAssertThrowsError(
            try store.merge(uid: "GZC-000001", messages: [message("1", .customer, "不会写入")])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains(historyURL.path))
        }
        XCTAssertEqual(try Data(contentsOf: historyURL), corrupt)
    }

    private func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-chat-store-\(suffix)-\(UUID().uuidString)")
    }

    private func message(_ id: String, _ sender: ChatSender, _ content: String) -> PDDChatMessage {
        PDDChatMessage(
            id: id,
            sender: sender,
            content: content,
            displayTime: nil,
            kind: .text,
            capturedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
    }
}
