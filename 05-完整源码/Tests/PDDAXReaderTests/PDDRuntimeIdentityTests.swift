import Foundation
import XCTest
@testable import PDDAXReader

final class PDDRuntimeIdentityTests: XCTestCase {
    func testCandidateUsesIndependentIdentityAndDataRootAndStartsStopped() {
        let home = URL(fileURLWithPath: "/tmp/pdd-candidate-home", isDirectory: true)

        let identity = PDDRuntimeIdentity.taskIsolationCandidate(homeDirectory: home)

        XCTAssertEqual(identity.mode, .taskIsolationCandidate)
        XCTAssertEqual(identity.bundleIdentifier, "com.scy.pdd-auto-reply.task-isolation-candidate")
        XCTAssertEqual(identity.executableName, "PDDTaskIsolationCandidate")
        XCTAssertEqual(identity.displayName, "pinduodou_automation")
        XCTAssertEqual(
            identity.dataRoot,
            home.appendingPathComponent(
                "Library/Application Support/PDDAutoReplyTaskIsolationCandidate/拼多多AX记录-任务隔离候选版",
                isDirectory: true
            )
        )
        XCTAssertFalse(identity.startsAutomatically)
    }

    func testCandidateLockPathsIncludeSharedAndLegacyLocks() {
        let home = URL(fileURLWithPath: "/tmp/pdd-candidate-home", isDirectory: true)

        let identity = PDDRuntimeIdentity.taskIsolationCandidate(homeDirectory: home)

        XCTAssertEqual(
            identity.sharedSessionLockURL,
            home.appendingPathComponent(
                "Library/Application Support/PDDAutoReplyShared/session.lock"
            )
        )
        XCTAssertEqual(
            identity.legacySessionLockURL,
            home.appendingPathComponent("Desktop/拼多多AX记录/自动回复/session.lock")
        )
    }
}
