import XCTest
@testable import PDDAXReader

final class SingleAXParseWorkflowTests: XCTestCase {
    func testMaskedActiveConversationParsesWithoutGZCLegacyValue() throws {
        let root = AXNodeSnapshot(role: "AXWindow", children: [
            AXNodeSnapshot(
                role: "AXGroup",
                attributes: [("AXDOMClassList", "[chat-item-box, active]")],
                children: [
                    AXNodeSnapshot(
                        role: "AXGroup",
                        attributes: [("AXDOMClassList", "[chat-nickname]")],
                        children: [AXNodeSnapshot(role: "AXStaticText", attributes: [("AXValue", "S***")])]
                    )
                ]
            )
        ])
        let workflow = SingleAXParseWorkflow(readAX: {
            AXReadResult(root: root, nodeCount: 5, elapsedSeconds: 0, applicationName: "拼多多")
        })

        XCTAssertEqual(try workflow.run().uid, "PDD-NAME-a1366828d04c70214f9fcb06")
    }
    func testOneButtonRunReadsExactlyOneAXSnapshotAndReportsLatestParsedMessage() throws {
        let counter = ReadCounter()
        let capturedAt = Date(timeIntervalSince1970: 1_777_000_000)
        let root = AXNodeSnapshot(
            role: "AXWindow",
            attributes: [("AXValue", "GZC-000001")],
            children: [
                message(id: "middlePanel_list_300", senderClass: "[buyer-item]", text: "刚到的客户消息"),
                message(id: "middlePanel_list_301", senderClass: "[cs-item, isread]", text: "稍后的客服回复")
            ]
        )
        let workflow = SingleAXParseWorkflow(readAX: {
            counter.increment()
            return AXReadResult(
                root: root,
                nodeCount: 123,
                elapsedSeconds: 0.456,
                applicationName: "拼多多商家版"
            )
        })

        let report = try workflow.run(capturedAt: capturedAt)

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(report.uid, "GZC-000001")
        XCTAssertEqual(report.newestRawMessageID, "middlePanel_list_301")
        XCTAssertEqual(report.messages.count, 2)
        XCTAssertEqual(report.latestMessage?.sender, .customer)
        XCTAssertEqual(report.latestMessage?.content, "刚到的客户消息")
        XCTAssertTrue(report.formatted.contains("用户：GZC-000001"))
        XCTAssertTrue(report.formatted.contains("时间："))
        XCTAssertFalse(report.formatted.contains("AX 未提供"))
        XCTAssertTrue(report.formatted.contains("客户：刚到的客户消息"))
        XCTAssertTrue(report.formatted.contains("Customer: 刚到的客户消息"))
        XCTAssertFalse(report.formatted.contains("稍后的客服回复"))
        XCTAssertFalse(report.formatted.contains("节点数"))
        XCTAssertFalse(report.formatted.contains("消息 ID"))
        XCTAssertFalse(report.formatted.contains("解析诊断"))
    }

    func testReportShowsRawNewestIDEvenWhenNewestNodeIsSystemMessage() throws {
        let root = AXNodeSnapshot(
            role: "AXWindow",
            attributes: [("AXValue", "GZC-000001")],
            children: [
                message(id: "middlePanel_list_100", senderClass: "[buyer-item]", text: "客户消息"),
                AXNodeSnapshot(
                    role: "AXGroup",
                    attributes: [
                        ("AXDOMClassList", "[clearfix, onemsg]"),
                        ("AXDOMIdentifier", "middlePanel_list_200")
                    ],
                    children: [
                        AXNodeSnapshot(
                            role: "AXGroup",
                            attributes: [("AXDOMClassList", "[msg-system]")],
                            children: [AXNodeSnapshot(role: "AXStaticText", attributes: [("AXValue", "转移会话")])]
                        )
                    ]
                )
            ]
        )
        let workflow = SingleAXParseWorkflow(readAX: {
            AXReadResult(root: root, nodeCount: 10, elapsedSeconds: 0.1, applicationName: "拼多多")
        })

        let report = try workflow.run()

        XCTAssertEqual(report.newestRawMessageID, "middlePanel_list_200")
        XCTAssertEqual(report.latestMessage?.content, "客户消息")
        XCTAssertEqual(report.diagnostics.count, 1)
    }

    private func message(id: String, senderClass: String, text: String) -> AXNodeSnapshot {
        AXNodeSnapshot(
            role: "AXGroup",
            attributes: [
                ("AXDOMClassList", "[clearfix, onemsg]"),
                ("AXDOMIdentifier", id)
            ],
            children: [
                AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", senderClass)]),
                AXNodeSnapshot(
                    role: "AXGroup",
                    attributes: [("AXDOMClassList", "[msg-content-box]")],
                    children: [AXNodeSnapshot(role: "AXStaticText", attributes: [("AXValue", text)])]
                )
            ]
        )
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
