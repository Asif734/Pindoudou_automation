import XCTest
@testable import PDDAXReader

final class CustomerReplyPromptBuilderTests: XCTestCase {
    func testManualSuggestionMatchesQuestionLanguage() {
        let prompt = CustomerReplyPromptBuilder.build(
            uid: "GZC-000001",
            history: [message("1", .customer, "How do I install the driver?")]
        )
        XCTAssertTrue(prompt.contains("English questions in English"))
        XCTAssertTrue(prompt.contains("How do I install the driver?"))
        XCTAssertFalse(prompt.contains("中文建议回复"))
    }

    func testPromptContainsBrandKnowledgeRulesHistoryAndUINotSendBoundary() {
        let history = [
            message("1", .customer, "打印机连不上"),
            message("2", .service, "请检查蓝牙"),
            message("3", .customer, "检查了还是不行")
        ]

        let prompt = CustomerReplyPromptBuilder.build(uid: "GZC-000001", history: history)

        XCTAssertTrue(prompt.contains("格志"))
        XCTAssertTrue(prompt.contains("品牌和平台事实以指定本地知识库为准"))
        XCTAssertTrue(prompt.contains("格志京东客服知识库-2026-10-04"))
        XCTAssertTrue(prompt.contains("客户：打印机连不上"))
        XCTAssertTrue(prompt.contains("客服：请检查蓝牙"))
        XCTAssertTrue(prompt.contains("客户：检查了还是不行"))
        XCTAssertTrue(prompt.contains("只生成一条"))
        XCTAssertTrue(prompt.contains("不得声称已经发送"))
        XCTAssertTrue(prompt.contains("只允许使用只读工具直接阅读知识库"))
        XCTAssertTrue(prompt.contains("禁止执行任何写入或外部动作"))
    }

    func testInvocationUsesReadOnlyStructuredStdinAndExactResumeID() {
        let schema = URL(fileURLWithPath: "/tmp/reply.schema.json")
        let result = URL(fileURLWithPath: "/tmp/reply.json")

        let create = CodexInvocation.arguments(sessionID: nil, schemaURL: schema, resultURL: result)
        let resume = CodexInvocation.arguments(
            sessionID: "thread-exact-123",
            schemaURL: schema,
            resultURL: result
        )

        XCTAssertEqual(Array(create.prefix(5)), ["-a", "never", "--enable", "shell_tool", "exec"])
        XCTAssertTrue(create.contains("--json"))
        XCTAssertTrue(create.contains("read-only"))
        XCTAssertTrue(create.contains("web_search=\"disabled\""))
        XCTAssertTrue(create.contains("--output-schema"))
        XCTAssertTrue(create.contains("gpt-5.6-sol"))
        XCTAssertTrue(create.contains("model_reasoning_effort=\"medium\""))
        XCTAssertEqual(create.last, "-")
        XCTAssertEqual(Array(resume.prefix(6)), ["-a", "never", "--enable", "shell_tool", "exec", "resume"])
        XCTAssertTrue(resume.contains("thread-exact-123"))
        XCTAssertFalse(resume.contains("--last"))
        XCTAssertFalse(resume.contains("read-only"), "exec resume 不接受 -s；它沿用新建会话的只读沙箱")
        XCTAssertEqual(resume.last, "-")
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
}
