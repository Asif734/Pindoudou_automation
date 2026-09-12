import Foundation

enum PDDAppMode: Equatable {
    case reader
    case singleParse
    case autoReply
    case taskIsolationCandidate

    init(bundleIdentifier: String?) {
        switch bundleIdentifier {
        case "com.scy.pdd-ax-single-parse-probe": self = .singleParse
        case "com.scy.pdd-auto-reply": self = .autoReply
        case "com.scy.pdd-auto-reply.task-isolation-candidate": self = .taskIsolationCandidate
        default: self = .reader
        }
    }
}
