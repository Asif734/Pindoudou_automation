import XCTest
@testable import PDDAXReader

final class ReaderWorkflowTests: XCTestCase {
    func testMaskedActiveConversationUsesNicknameKeyWithoutGZCLegacyValue() async throws {
        let root = activeConversationRoot(nickname: "S***")
        let dependencies = ReaderWorkflowDependencies(
            readAX: { AXReadResult(root: root, nodeCount: 5, elapsedSeconds: 0, applicationName: "拼多多") },
            saveAX: { _, _ in URL(fileURLWithPath: "/tmp/ax.txt") },
            parseChat: { _, _ in PDDChatParseResult(messages: [], diagnostics: []) },
            mergeHistory: { _, messages in
                ChatMergeResult(history: messages, insertedCount: 0, fileURL: URL(fileURLWithPath: "/tmp/history.jsonl"))
            },
            generateReply: { _, _ in CodexReplyResult(reply: "unused", threadID: "unused") }
        )

        let result = try await ReaderWorkflow(dependencies: dependencies).run()

        XCTAssertEqual(result.uid, "PDD-NAME-a1366828d04c70214f9fcb06")
    }
    func testRunsReadSaveParseMergeCodexInStrictOrder() async throws {
        let recorder = EventRecorder()
        let root = AXNodeSnapshot(role: "AXWindow", attributes: [("AXValue", "GZC-000001")])
        let customer = message("1", .customer, "客户问题")
        let dependencies = ReaderWorkflowDependencies(
            readAX: {
                recorder.append("read")
                return AXReadResult(root: root, nodeCount: 1, elapsedSeconds: 0.1, applicationName: "拼多多")
            },
            saveAX: { _, _ in
                recorder.append("save")
                return URL(fileURLWithPath: "/tmp/ax.txt")
            },
            parseChat: { _, _ in
                recorder.append("parse")
                return PDDChatParseResult(messages: [customer], diagnostics: [])
            },
            mergeHistory: { _, messages in
                recorder.append("merge")
                return ChatMergeResult(
                    history: messages,
                    insertedCount: messages.count,
                    fileURL: URL(fileURLWithPath: "/tmp/history.jsonl")
                )
            },
            generateReply: { _, history in
                recorder.append("codex")
                XCTAssertEqual(history, [customer])
                return CodexReplyResult(reply: "检查建议", threadID: "thread-1")
            }
        )

        let result = try await ReaderWorkflow(dependencies: dependencies).run()

        XCTAssertEqual(recorder.events, ["read", "save", "parse", "merge", "codex"])
        XCTAssertEqual(result.uid, "GZC-000001")
        XCTAssertTrue(result.fullAXOutput.contains("GZC-000001"))
        XCTAssertTrue(result.parsedChatOutput.contains("客户：客户问题"))
        XCTAssertEqual(result.replyOutput, "检查建议")
    }

    func testAXSaveFailureStopsParsingAndCodexButCarriesFullAXForUI() async {
        let recorder = EventRecorder()
        let root = AXNodeSnapshot(role: "AXWindow", attributes: [("AXValue", "GZC-000001")])
        let dependencies = ReaderWorkflowDependencies(
            readAX: {
                recorder.append("read")
                return AXReadResult(root: root, nodeCount: 1, elapsedSeconds: 0, applicationName: "拼多多")
            },
            saveAX: { _, _ in
                recorder.append("save")
                throw CocoaError(.fileWriteUnknown)
            },
            parseChat: { _, _ in
                recorder.append("parse")
                return PDDChatParseResult(messages: [], diagnostics: [])
            },
            mergeHistory: { _, _ in
                recorder.append("merge")
                throw CocoaError(.fileWriteUnknown)
            },
            generateReply: { _, _ in
                recorder.append("codex")
                throw CocoaError(.fileWriteUnknown)
            }
        )

        do {
            _ = try await ReaderWorkflow(dependencies: dependencies).run()
            XCTFail("保存失败必须终止")
        } catch let error as ReaderWorkflowError {
            XCTAssertEqual(error.stage, .saveAX)
            XCTAssertTrue(error.fullAXOutput?.contains("GZC-000001") == true)
        } catch {
            XCTFail("错误类型不正确：\(error)")
        }
        XCTAssertEqual(recorder.events, ["read", "save"])
    }

    func testLatestServiceMessageSkipsCodex() async throws {
        let recorder = EventRecorder()
        let root = AXNodeSnapshot(role: "AXWindow", attributes: [("AXValue", "GZC-000001")])
        let history = [message("1", .customer, "问题"), message("2", .service, "已回答")]
        let dependencies = ReaderWorkflowDependencies(
            readAX: { AXReadResult(root: root, nodeCount: 1, elapsedSeconds: 0, applicationName: "拼多多") },
            saveAX: { _, _ in URL(fileURLWithPath: "/tmp/ax.txt") },
            parseChat: { _, _ in PDDChatParseResult(messages: history, diagnostics: []) },
            mergeHistory: { _, _ in
                ChatMergeResult(history: history, insertedCount: 2, fileURL: URL(fileURLWithPath: "/tmp/history.jsonl"))
            },
            generateReply: { _, _ in
                recorder.append("codex")
                return CodexReplyResult(reply: "不应生成", threadID: "x")
            }
        )

        let result = try await ReaderWorkflow(dependencies: dependencies).run()

        XCTAssertEqual(result.replyOutput, "当前无需回复：最后一条有效消息来自客服。")
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testNewestMessageIDWinsEvenWhenHistoryDiscoveryOrderEndsWithOlderServiceMessage() async throws {
        let recorder = EventRecorder()
        let root = AXNodeSnapshot(role: "AXWindow", attributes: [("AXValue", "GZC-000001")])
        let newestCustomer = message("middlePanel_list_200", .customer, "刚到的客户消息")
        let olderService = message("middlePanel_list_100", .service, "较早客服消息")
        let discoveryOrder = [newestCustomer, olderService]
        let dependencies = ReaderWorkflowDependencies(
            readAX: { AXReadResult(root: root, nodeCount: 1, elapsedSeconds: 0, applicationName: "拼多多") },
            saveAX: { _, _ in URL(fileURLWithPath: "/tmp/ax.txt") },
            parseChat: { _, _ in PDDChatParseResult(messages: discoveryOrder, diagnostics: []) },
            mergeHistory: { _, _ in
                ChatMergeResult(history: discoveryOrder, insertedCount: 2, fileURL: URL(fileURLWithPath: "/tmp/history.jsonl"))
            },
            generateReply: { _, _ in
                recorder.append("codex")
                return CodexReplyResult(reply: "已生成", threadID: "thread")
            }
        )

        let result = try await ReaderWorkflow(dependencies: dependencies).run()

        XCTAssertEqual(result.replyOutput, "已生成")
        XCTAssertEqual(recorder.events, ["codex"])
    }

    private func message(_ id: String, _ sender: ChatSender, _ content: String) -> PDDChatMessage {
        PDDChatMessage(
            id: id,
            sender: sender,
            content: content,
            displayTime: "20:00",
            kind: .text,
            capturedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
    }

    private func activeConversationRoot(nickname: String) -> AXNodeSnapshot {
        AXNodeSnapshot(role: "AXWindow", children: [
            AXNodeSnapshot(
                role: "AXGroup",
                attributes: [("AXDOMClassList", "[chat-item-box, active]")],
                children: [
                    AXNodeSnapshot(
                        role: "AXGroup",
                        attributes: [("AXDOMClassList", "[chat-nickname]")],
                        children: [AXNodeSnapshot(role: "AXStaticText", attributes: [("AXValue", nickname)])]
                    )
                ]
            )
        ])
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
