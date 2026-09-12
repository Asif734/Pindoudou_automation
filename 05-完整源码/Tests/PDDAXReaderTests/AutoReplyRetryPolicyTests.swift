import XCTest
@testable import PDDAXReader

final class AutoReplyRetryPolicyTests: XCTestCase {
    func testSafeDeliveryFailuresUseCurrentQianniuBackoff() {
        let policy = AutoReplyRetryPolicy()

        XCTAssertEqual((1...6).map(policy.deliveryDelay), [2, 4, 8, 16, 30, 30])
    }
    private struct Failure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    func testOrdinaryAttemptsOneThroughTwentyRetryWithCappedExponentialDelay() {
        let policy = AutoReplyRetryPolicy()
        let now = Date(timeIntervalSince1970: 100)
        for attempt in 1...20 {
            guard case .retry(let date) = policy.decision(
                attempt: attempt, error: Failure(text: "temporary"), now: now
            ) else { return XCTFail("attempt \(attempt) should retry") }
            XCTAssertGreaterThan(date, now)
            XCTAssertLessThanOrEqual(date.timeIntervalSince(now), 60)
        }
        XCTAssertEqual(
            policy.decision(attempt: 21, error: Failure(text: "temporary"), now: now),
            .failRevision
        )
    }

    func testIdentityMismatchGetsOneRebuildAndThenFailsNormallyAtBudgetEnd() {
        let policy = AutoReplyRetryPolicy(maximumOrdinaryAttempts: 1)
        let now = Date(timeIntervalSince1970: 100)
        guard case .rebuildSessionAndRetry = policy.decision(
            attempt: 1, error: Failure(text: "wrong session identity"), now: now
        ) else { return XCTFail("first identity error should rebuild") }
        XCTAssertEqual(
            policy.decision(
                attempt: 2, error: Failure(text: "wrong session identity"), now: now
            ),
            .failRevision
        )
    }

    func testBackpressureClassificationIncludesRateAndAllocationFailures() {
        let policy = AutoReplyRetryPolicy()
        XCTAssertTrue(policy.isBackpressure(Failure(text: "HTTP 429 rate limit")))
        XCTAssertTrue(policy.isBackpressure(Failure(text: "allocation failed")))
        XCTAssertFalse(policy.isBackpressure(Failure(text: "ordinary timeout")))
    }
}
