import Foundation

enum TaskFailureDecision: Equatable, Sendable {
    case requeueAtTail
    case parkRevision
}

enum TaskFailurePolicy {
    static let firstRetryDelay: TimeInterval = 1

    static func uiDecision(previousFailures: Int) -> TaskFailureDecision {
        previousFailures <= 0 ? .requeueAtTail : .parkRevision
    }
}
