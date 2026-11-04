import XCTest
@testable import PDDAXReader

final class PDDBackgroundVideoRecoveryTests: XCTestCase {
    func testResentVideoGetsTimestampedDistinctFileAndRecoveryReusesSameOccurrence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let morning = PDDVideoTransferKey(uid: "customer", messageID: "morning-message")
        let afternoon = PDDVideoTransferKey(uid: "customer", messageID: "afternoon-message")
        let morningTime = Date(timeIntervalSince1970: 1_793_779_200)
        let afternoonTime = morningTime.addingTimeInterval(6 * 3600)
        let first = PDDBackgroundVideoRecovery.savedVideoURL(root: root, key: morning, savedAt: morningTime)
        let second = PDDBackgroundVideoRecovery.savedVideoURL(root: root, key: afternoon, savedAt: afternoonTime)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("video_20261104T080000000Z_"))
        for file in [first, second] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("same exact video bytes".utf8).write(to: file)
        }
        XCTAssertEqual(PDDBackgroundVideoRecovery.savedVideoURL(root: root, key: morning, savedAt: afternoonTime), first,
            "Retrying the morning message must reuse its saved occurrence")
        XCTAssertEqual(PDDBackgroundVideoRecovery.action(root: root, uid: "customer", messageID: "afternoon-message"),
            .prepareEvidence(uid: "customer", messageID: "afternoon-message", stableURL: second))
    }
    func testPartialVideoURLKeepsMP4ExtensionForAVFoundationValidation() {
        let root = FileManager.default.temporaryDirectory
        let key = PDDVideoTransferKey(uid: "PDD-one", messageID: "v1")

        let partial = PDDBackgroundVideoRecovery.partialVideoURL(root: root, key: key)

        XCTAssertEqual(partial.lastPathComponent, "video.partial.mp4")
        XCTAssertEqual(partial.pathExtension, "mp4")
    }

    func testEvidenceFailureInvokesDurableRetryHandlerOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = PDDVideoTransferKey(uid: "PDD-one", messageID: "v1")
        let stable = PDDBackgroundVideoRecovery.stableVideoURL(root: root, key: key)
        try FileManager.default.createDirectory(
            at: stable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not-an-mp4".utf8).write(to: stable)
        let recorder = RecoveryFailureRecorder()

        await PDDBackgroundVideoRecovery.resumeStableVideo(
            root: root, uid: "PDD-one", messageID: "v1", stableURL: stable,
            analysisInbox: PDDVideoAnalysisInbox(
                stateURL: root.appendingPathComponent("claims.json")
            ),
            recovered: true,
            failureHandler: { _ in await recorder.record() },
            eventHandler: { _ in }
        )

        let failureCount = await recorder.count()
        XCTAssertEqual(failureCount, 1)
    }

    func testStableMP4ResumesEvidencePreparation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = PDDVideoTransferKey(uid: "PDD-one", messageID: "v1")
        let stable = PDDBackgroundVideoRecovery.stableVideoURL(root: root, key: key)
        try FileManager.default.createDirectory(
            at: stable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("stable".utf8).write(to: stable)

        XCTAssertEqual(
            PDDBackgroundVideoRecovery.action(root: root, uid: "PDD-one", messageID: "v1"),
            .prepareEvidence(uid: "PDD-one", messageID: "v1", stableURL: stable)
        )
    }

    func testPartialIsDeletedAndNeverTreatedAsSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = PDDVideoTransferKey(uid: "PDD-one", messageID: "v1")
        let partial = PDDBackgroundVideoRecovery.partialVideoURL(root: root, key: key)
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("partial".utf8).write(to: partial)

        XCTAssertEqual(
            PDDBackgroundVideoRecovery.action(root: root, uid: "PDD-one", messageID: "v1"),
            .reopen(uid: "PDD-one", messageID: "v1")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testMissingFileRequestsExactUIDReopen() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(
            PDDBackgroundVideoRecovery.action(root: root, uid: "PDD-exact", messageID: "v9"),
            .reopen(uid: "PDD-exact", messageID: "v9")
        )
    }
}

private actor RecoveryFailureRecorder {
    private var value = 0
    func record() { value += 1 }
    func count() -> Int { value }
}
