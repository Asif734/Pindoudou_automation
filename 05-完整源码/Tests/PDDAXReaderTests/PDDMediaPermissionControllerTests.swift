import Speech
import XCTest
@testable import PDDAXReader

@MainActor
final class PDDMediaPermissionControllerTests: XCTestCase {
    func testBothPermissionsRunSequentiallyAndLogEachStageWithoutStartingAutomation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = PermissionCallOrder()
        let controller = PDDMediaPermissionController(logRoot: root, requestFiles: {
            await calls.add("files")
            return .init(status: .authorized)
        }, requestSpeech: {
            await calls.add("speech")
            return .authorized
        })
        XCTAssertNil(controller.statusText)
        await controller.requestPermissions()
        let order = await calls.values
        XCTAssertEqual(order, ["files", "speech"])
        XCTAssertEqual(controller.fileStatus, .authorized)
        XCTAssertEqual(controller.speechStatus, .authorized)
        XCTAssertFalse(controller.isRequesting)
        XCTAssertTrue(controller.statusText?.contains("Downloads: Allowed") == true)
        let log = try String(contentsOf: root.appendingPathComponent("logs/automation-steps.jsonl"))
        for stage in ["media-permissions-started", "media-files-permission-requested", "media-files-permission-result",
                      "media-speech-permission-requested", "media-speech-permission-result", "media-permissions-completed"] {
            XCTAssertTrue(log.contains(stage))
        }
        XCTAssertFalse(log.contains("automation-started"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("run-intent.json").path))
    }

    func testFileDenialStillRequestsSpeechAndSettingsStayExplicit() async {
        var opened: [PDDMediaPermissionSettingsPage] = []
        let controller = PDDMediaPermissionController(logRoot: nil,
            requestFiles: { .init(status: .denied) }, requestSpeech: { .denied },
            settingsOpener: { opened.append($0); return true })
        await controller.requestPermissions()
        XCTAssertEqual(controller.fileStatus, .denied)
        XCTAssertEqual(controller.speechStatus, .denied)
        XCTAssertTrue(opened.isEmpty, "Do not silently redirect the user when macOS refuses access")
        controller.openSettings(.filesAndFolders)
        controller.openSettings(.speechRecognition)
        XCTAssertEqual(opened, [.filesAndFolders, .speechRecognition])
        XCTAssertTrue(PDDMediaPermissionSettingsPage.filesAndFolders.url.absoluteString.contains("Privacy_FilesAndFolders"))
        XCTAssertTrue(PDDMediaPermissionSettingsPage.speechRecognition.url.absoluteString.contains("Privacy_SpeechRecognition"))
    }

    func testDuplicateClickCannotStartSecondPermissionFlow() async {
        let gate = PermissionRequestGate()
        let controller = PDDMediaPermissionController(logRoot: nil, requestFiles: {
            await gate.wait()
            return .init(status: .authorized)
        }, requestSpeech: { .restricted })
        let first = Task { await controller.requestPermissions() }
        while await !gate.hasStarted { await Task.yield() }
        XCTAssertTrue(controller.isRequesting)
        await controller.requestPermissions()
        let count = await gate.calls
        XCTAssertEqual(count, 1)
        await gate.release()
        await first.value
        XCTAssertFalse(controller.isRequesting)
        XCTAssertEqual(controller.speechStatus, .restricted)
    }

    func testSpeechAuthorizationStatesAreNotReportedAsGrantedOnDenial() {
        XCTAssertEqual(PDDMediaPermissionStatus(speech: .authorized), .authorized)
        XCTAssertEqual(PDDMediaPermissionStatus(speech: .denied), .denied)
        XCTAssertEqual(PDDMediaPermissionStatus(speech: .restricted), .restricted)
        XCTAssertEqual(PDDMediaPermissionStatus(speech: .notDetermined), .notDetermined)
    }
}

private actor PermissionCallOrder {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

private actor PermissionRequestGate {
    var calls = 0
    var hasStarted: Bool { continuation != nil }
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
