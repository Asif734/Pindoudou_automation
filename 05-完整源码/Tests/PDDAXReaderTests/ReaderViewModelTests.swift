import XCTest
@testable import PDDAXReader

@MainActor
final class ReaderViewModelTests: XCTestCase {
    func testSuccessfulWorkflowPublishesAllThreePanels() async {
        let result = ReaderWorkflowResult(
            uid: "GZC-000001",
            fullAXOutput: "完整 AX",
            parsedChatOutput: "客户：你好",
            replyOutput: "您好，请问有什么可以帮您？",
            savedAXURL: URL(fileURLWithPath: "/tmp/ax.txt"),
            historyCount: 1
        )
        let model = ReaderViewModel(
            runWorkflow: { result },
            permissionCheck: { true },
            permissionPrompt: { true }
        )

        await model.performRead()

        XCTAssertEqual(model.fullAXOutput, "完整 AX")
        XCTAssertEqual(model.parsedChatOutput, "客户：你好")
        XCTAssertEqual(model.replyOutput, "您好，请问有什么可以帮您？")
        XCTAssertEqual(model.selectedTab, .reply)
        XCTAssertTrue(model.status.contains("GZC-000001"))
        XCTAssertFalse(model.isReading)
    }

    func testWorkflowFailureStillPublishesCapturedAX() async {
        let model = ReaderViewModel(
            runWorkflow: {
                throw ReaderWorkflowError(
                    stage: .codex,
                    detail: "CLI 未登录",
                    fullAXOutput: "已保存的完整 AX"
                )
            },
            permissionCheck: { true },
            permissionPrompt: { true }
        )

        await model.performRead()

        XCTAssertEqual(model.fullAXOutput, "已保存的完整 AX")
        XCTAssertTrue(model.replyOutput.contains("CLI 未登录"))
        XCTAssertEqual(model.selectedTab, .reply)
        XCTAssertFalse(model.isReading)
    }
}
