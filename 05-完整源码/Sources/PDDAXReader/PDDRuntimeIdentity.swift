import Foundation

struct PDDRuntimeIdentity: Equatable, Sendable {
    let mode: PDDAppMode
    let bundleIdentifier: String
    let executableName: String
    let displayName: String
    let dataRoot: URL
    let sharedSessionLockURL: URL
    let legacySessionLockURL: URL?
    let startsAutomatically: Bool

    var sessionLockURLs: [URL] {
        [sharedSessionLockURL, legacySessionLockURL].compactMap { $0 }
    }

    static func forMode(
        _ mode: PDDAppMode,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> PDDRuntimeIdentity {
        switch mode {
        case .taskIsolationCandidate:
            return .taskIsolationCandidate(homeDirectory: homeDirectory)
        case .autoReply, .reader, .singleParse:
            return .currentAutoReply(homeDirectory: homeDirectory)
        }
    }

    static func currentAutoReply(homeDirectory: URL) -> PDDRuntimeIdentity {
        let legacyRoot = homeDirectory.appendingPathComponent(
            "Desktop/拼多多AX记录/自动回复", isDirectory: true
        )
        return PDDRuntimeIdentity(
            mode: .autoReply,
            bundleIdentifier: "com.scy.pdd-auto-reply",
            executableName: "PDDAutoReply",
            displayName: "拼多多全自动客服",
            dataRoot: legacyRoot,
            sharedSessionLockURL: homeDirectory.appendingPathComponent(
                "Library/Application Support/PDDAutoReplyShared/session.lock"
            ),
            legacySessionLockURL: legacyRoot.appendingPathComponent("session.lock"),
            startsAutomatically: true
        )
    }

    static func taskIsolationCandidate(homeDirectory: URL) -> PDDRuntimeIdentity {
        PDDRuntimeIdentity(
            mode: .taskIsolationCandidate,
            bundleIdentifier: "com.scy.pdd-auto-reply.task-isolation-candidate",
            executableName: "PDDTaskIsolationCandidate",
            displayName: "pinduodou_automation",
            dataRoot: homeDirectory.appendingPathComponent(
                "Library/Application Support/PDDAutoReplyTaskIsolationCandidate/拼多多AX记录-任务隔离候选版",
                isDirectory: true
            ),
            sharedSessionLockURL: homeDirectory.appendingPathComponent(
                "Library/Application Support/PDDAutoReplyShared/session.lock"
            ),
            legacySessionLockURL: homeDirectory.appendingPathComponent(
                "Desktop/拼多多AX记录/自动回复/session.lock"
            ),
            startsAutomatically: false
        )
    }
}
