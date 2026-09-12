import XCTest
@testable import PDDAXReader

final class PDDCompatibilityCheckerTests: XCTestCase {
    func testRequiredFailureWinsWhileOptionalSpeechFailureOnlyDegrades() {
        let speechOnly = PDDCompatibilityReport(items: [
            .init(kind: .speech, status: .degraded, detail: "语音不可用，视频仍使用画面")
        ])
        let missingAX = PDDCompatibilityReport(items: [
            .init(kind: .speech, status: .degraded, detail: "语音不可用"),
            .init(kind: .accessibility, status: .fail, detail: "辅助功能未授权"),
        ])

        XCTAssertEqual(speechOnly.overallStatus, .degraded)
        XCTAssertEqual(missingAX.overallStatus, .fail)
    }

    func testRedactedReportContainsNoSecretValuesOrChatContent() throws {
        let report = PDDCompatibilityReport(items: [
            .init(kind: .codex, status: .pass, detail: "Codex CLI 可用")
        ])
        let exported = String(decoding: try report.redactedJSON(), as: UTF8.self)

        XCTAssertFalse(exported.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(exported.contains("https://video"))
        XCTAssertFalse(exported.contains("客户消息"))
        XCTAssertTrue(exported.contains("Codex CLI 可用"))
    }
}
