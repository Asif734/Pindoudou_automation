import Foundation

enum AutoReplyRetryDecision: Equatable, Sendable {
    case retry(at: Date)
    case rebuildSessionAndRetry(at: Date)
    case failRevision
}

struct AutoReplyRetryPolicy: Sendable {
    let maximumOrdinaryAttempts: Int
    let maximumDelay: TimeInterval

    init(maximumOrdinaryAttempts: Int = 20, maximumDelay: TimeInterval = 60) {
        self.maximumOrdinaryAttempts = maximumOrdinaryAttempts
        self.maximumDelay = maximumDelay
    }

    func decision(attempt: Int, error: Error, now: Date) -> AutoReplyRetryDecision {
        if isSessionIdentityError(error), attempt <= 1 {
            return .rebuildSessionAndRetry(at: now.addingTimeInterval(delay(for: attempt)))
        }
        guard attempt <= maximumOrdinaryAttempts else { return .failRevision }
        return .retry(at: now.addingTimeInterval(delay(for: attempt)))
    }

    func isBackpressure(_ error: Error) -> Bool {
        let value = boundedDescription(error).lowercased()
        return value.contains("429") || value.contains("rate limit")
            || value.contains("resource exhausted") || value.contains("allocation")
            || value.contains("out of memory")
    }

    func boundedDescription(_ error: Error) -> String {
        String(error.localizedDescription.suffix(4_000))
    }

    func deliveryDelay(_ attempt: Int) -> TimeInterval {
        min(30, pow(2, Double(max(1, attempt))))
    }

    private func delay(for attempt: Int) -> TimeInterval {
        min(maximumDelay, pow(2, Double(max(0, attempt - 1))))
    }

    private func isSessionIdentityError(_ error: Error) -> Bool {
        let value = boundedDescription(error).lowercased()
        return value.contains("thread id") || value.contains("session identity")
            || value.contains("wrong session") || value.contains("resume mismatch")
    }
}
