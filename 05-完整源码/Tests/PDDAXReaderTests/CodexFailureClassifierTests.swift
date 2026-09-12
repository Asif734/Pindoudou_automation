import XCTest
@testable import PDDAXReader

final class CodexFailureClassifierTests: XCTestCase {
    func testPermanentHTTPAuthenticationQuotaContextAndSafetyErrorsTransferImmediately() {
        let errors: [Error] = [
            AutoReplyCodexGeneratorError.commandFailed(1, "HTTP 401 Unauthorized"),
            AutoReplyCodexGeneratorError.commandFailed(1, "HTTP 403 forbidden"),
            AutoReplyCodexGeneratorError.commandFailed(1, "HTTP 429 rate limit exceeded"),
            AutoReplyCodexGeneratorError.commandFailed(1, "insufficient_quota usage limit reached"),
            AutoReplyCodexGeneratorError.commandFailed(1, "HTTP 413 context_length_exceeded"),
            AutoReplyCodexGeneratorError.commandFailed(1, "HTTP 422 invalid request"),
            AutoReplyCodexGeneratorError.commandFailed(1, "content safety refusal"),
            AutoReplyCodexGeneratorError.chatGPTLoginRequired
        ]

        for error in errors {
            guard case .transferImmediately = CodexFailureClassifier.classify(error) else {
                return XCTFail("expected immediate transfer for \(error)")
            }
        }
    }

    func testFreshSessionOrFreshProcessFailuresRetryOnceThenTransfer() {
        let errors: [Error] = [
            AutoReplyCodexGeneratorError.commandFailed(1, "HTTP 404 model not found"),
            AutoReplyCodexGeneratorError.commandFailed(1, "HTTP 500 internal server error"),
            AutoReplyCodexGeneratorError.commandFailed(137, "process crashed"),
            AutoReplyCodexGeneratorError.missingCompletion,
            AutoReplyCodexGeneratorError.missingThreadID,
            AutoReplyCodexGeneratorError.invalidReply("JSON malformed"),
            CodexProcessError.timeout(180),
            CodexProcessError.executableMissing("spawn failed"),
            URLError(.timedOut)
        ]

        for error in errors {
            guard case .retryOnceThenTransfer = CodexFailureClassifier.classify(error) else {
                return XCTFail("expected one retry for \(error)")
            }
        }
    }

    func testFailureAfterGeneratorAlreadyRetriedFreshSessionTransfersImmediately() {
        XCTAssertEqual(
            CodexFailureClassifier.classify(
                AutoReplyCodexGeneratorError.freshSessionRetryFailed("HTTP 404 model not found")
            ),
            .transferImmediately("Codex 新会话或新进程重试仍失败")
        )
    }

    func testStructuredSafetyRefusalTransfersWithoutRetry() {
        XCTAssertEqual(
            CodexFailureClassifier.classify(
                AutoReplyCodexGeneratorError.invalidReply(
                    "content safety refusal prevented a customer-service reply"
                )
            ),
            .transferImmediately("Codex 内容安全拒绝")
        )
    }

    func testDoesNotTreatUnrelatedErrorsOrCustomerLike404TextAsCodexHTTPFailure() {
        struct Unrelated: LocalizedError {
            var errorDescription: String? { "客户问型号404是什么意思" }
        }

        XCTAssertEqual(CodexFailureClassifier.classify(Unrelated()), .ordinaryRetry)
        XCTAssertEqual(
            CodexFailureClassifier.classify(
                AutoReplyCodexGeneratorError.invalidImageAttachment("/tmp/404.jpg")
            ),
            .ordinaryRetry
        )
        XCTAssertEqual(CodexFailureClassifier.classify(CancellationError()), .cancelled)
    }
}
