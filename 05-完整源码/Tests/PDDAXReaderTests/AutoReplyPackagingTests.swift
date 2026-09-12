import XCTest

final class AutoReplyPackagingTests: XCTestCase {
    func testAutoReplyInfoHasIndependentBundleAndExecutable() throws {
        let plist = try loadPlist("Resources/AutoReplyInfo.plist")

        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.scy.pdd-auto-reply")
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "PDDAutoReply")
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, "拼多多全自动客服")
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertNotNil(plist["NSScreenCaptureUsageDescription"] as? String)
        XCTAssertFalse((plist["NSSpeechRecognitionUsageDescription"] as? String ?? "").isEmpty)
    }

    func testCandidateInfoHasDistinctBundleExecutableAndDisplayName() throws {
        let current = try loadPlist("Resources/AutoReplyInfo.plist")
        let candidate = try loadPlist("Resources/TaskIsolationCandidateInfo.plist")

        XCTAssertEqual(
            candidate["CFBundleIdentifier"] as? String,
            "com.scy.pdd-auto-reply.task-isolation-candidate"
        )
        XCTAssertEqual(candidate["CFBundleExecutable"] as? String, "PDDTaskIsolationCandidate")
        XCTAssertEqual(candidate["CFBundleDisplayName"] as? String, "pinduodou_automation")
        XCTAssertEqual(candidate["CFBundleIconFile"] as? String, "PDDLatest.icns")
        XCTAssertFalse((candidate["NSSpeechRecognitionUsageDescription"] as? String ?? "").isEmpty)
        XCTAssertNotEqual(candidate["CFBundleIdentifier"] as? String, current["CFBundleIdentifier"] as? String)
        XCTAssertNotEqual(candidate["CFBundleExecutable"] as? String, current["CFBundleExecutable"] as? String)
    }

    func testBuildScriptSupportsCandidateOnlyBuildWithBackup() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/build_app.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("--task-isolation-candidate"))
        XCTAssertTrue(script.contains("pinduodou_automation.app"))
        XCTAssertTrue(script.contains("outputs/backups"))
        XCTAssertTrue(script.contains("TaskIsolationCandidateInfo.plist"))
        XCTAssertTrue(script.contains("PDDLatest.icns"))
    }

    private func loadPlist(_ relativePath: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }
}
