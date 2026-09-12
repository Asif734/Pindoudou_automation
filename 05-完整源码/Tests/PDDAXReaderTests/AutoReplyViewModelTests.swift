import XCTest
@testable import PDDAXReader

@MainActor
final class AutoReplyViewModelTests: XCTestCase {
    func testLiveStartWaitsForStartupPrewarmBeforeRuntimeBegins() async {
        let runtime = FakeAutoReplyRuntime()
        let gate = AsyncPrewarmGate()
        let model = AutoReplyViewModel(
            runtime: runtime,
            sessionLock: FakeAutoReplyLock(acquireResult: true),
            permissionCheck: { true },
            screenRecordingPermissionCheck: { true },
            startupPrewarm: { try await gate.wait() }
        )

        model.start()
        await Task.yield()
        XCTAssertEqual(runtime.startCount, 0)
        XCTAssertTrue(model.status.contains("预热"))

        await gate.release()
        for _ in 0..<20 where runtime.startCount == 0 { await Task.yield() }
        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertTrue(model.isRunning)
    }

    func testCompatibilityCheckPublishesStructuredSummaryWithoutStartingRuntime() async {
        let runtime = FakeAutoReplyRuntime()
        let report = PDDCompatibilityReport(items: [
            .init(kind: .speech, status: .degraded, detail: "语音不可用时仍处理视频画面"),
            .init(kind: .codex, status: .pass, detail: "Codex CLI 可用"),
        ])
        let model = AutoReplyViewModel(
            runtime: runtime,
            sessionLock: FakeAutoReplyLock(acquireResult: true),
            permissionCheck: { true },
            compatibilityCheck: { report }
        )

        await model.runCompatibilityCheck()

        XCTAssertEqual(model.compatibilityReport, report)
        XCTAssertEqual(model.status, BilingualText.lines("兼容性：通过 1 · 降级 1 · 失败 0", "Compatibility: 1 passed · 1 degraded · 0 failed"))
        XCTAssertEqual(runtime.startCount, 0)
    }

    func testFailedCompatibilityReportBlocksStartUntilRechecked() async {
        let runtime = FakeAutoReplyRuntime()
        let report = PDDCompatibilityReport(items: [
            .init(kind: .architecture, status: .fail, detail: "仅支持 Apple Silicon")
        ])
        let model = AutoReplyViewModel(
            runtime: runtime,
            sessionLock: FakeAutoReplyLock(acquireResult: true),
            permissionCheck: { true },
            screenRecordingPermissionCheck: { true },
            compatibilityCheck: { report }
        )

        await model.runCompatibilityCheck()
        model.start()

        XCTAssertFalse(model.canStart)
        XCTAssertEqual(runtime.startCount, 0)
        XCTAssertTrue(model.status.contains("兼容性检查未通过"))
    }

    func testCompatibilityReportCanBeExportedAsRedactedJSON() async throws {
        let runtime = FakeAutoReplyRuntime()
        let report = PDDCompatibilityReport(items: [
            .init(kind: .codex, status: .pass, detail: "Codex CLI 已登录 ChatGPT")
        ])
        let model = AutoReplyViewModel(
            runtime: runtime,
            sessionLock: FakeAutoReplyLock(acquireResult: true),
            permissionCheck: { true },
            compatibilityCheck: { report }
        )
        await model.runCompatibilityCheck()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-compatibility-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: destination) }

        try model.exportCompatibilityReport(to: destination)

        let text = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(text.contains("Codex CLI 已登录 ChatGPT"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("token"))
    }

    func testOpenRequiredPermissionSettingsRoutesToAccessibilityWhenAXIsMissing() {
        let runtime = FakeAutoReplyRuntime()
        var openedPages: [PDDPermissionSettingsPage] = []
        let model = AutoReplyViewModel(
            runtime: runtime,
            sessionLock: FakeAutoReplyLock(acquireResult: true),
            permissionCheck: { false },
            screenRecordingPermissionCheck: { false },
            permissionSettingsOpener: { openedPages.append($0); return true }
        )

        model.openRequiredPermissionSettings()

        XCTAssertEqual(openedPages, [.accessibility])
        XCTAssertTrue(model.status.contains("辅助功能"))
    }

    func testOpenRequiredPermissionSettingsRoutesToScreenRecordingWhenOnlyThatPermissionIsMissing() {
        let runtime = FakeAutoReplyRuntime()
        var openedPages: [PDDPermissionSettingsPage] = []
        let model = AutoReplyViewModel(
            runtime: runtime,
            sessionLock: FakeAutoReplyLock(acquireResult: true),
            permissionCheck: { true },
            screenRecordingPermissionCheck: { false },
            permissionSettingsOpener: { openedPages.append($0); return true }
        )

        model.openRequiredPermissionSettings()

        XCTAssertEqual(openedPages, [.screenRecording])
        XCTAssertTrue(model.status.contains("录屏"))
    }

    func testOpenRequiredPermissionSettingsDoesNotOpenSystemSettingsWhenPermissionsAreReady() {
        let runtime = FakeAutoReplyRuntime()
        var openedPages: [PDDPermissionSettingsPage] = []
        let model = AutoReplyViewModel(
            runtime: runtime,
            sessionLock: FakeAutoReplyLock(acquireResult: true),
            permissionCheck: { true },
            screenRecordingPermissionCheck: { true },
            permissionSettingsOpener: { openedPages.append($0); return true }
        )

        model.openRequiredPermissionSettings()

        XCTAssertTrue(openedPages.isEmpty)
        XCTAssertTrue(model.status.contains("所需权限已开启"))
    }

    func testAutoReplyModelDefaultsToLiveDeliveryForAutonomousLaunch() {
        let runtime = FakeAutoReplyRuntime()
        let model = AutoReplyViewModel(
            runtime: runtime,
            sessionLock: FakeAutoReplyLock(acquireResult: true),
            permissionCheck: { true }
        )

        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.scope, .allUsers)
        XCTAssertFalse(model.isDryRun)
        XCTAssertEqual(runtime.startCount, 0)
    }

    func testPermissionFailureDoesNotAcquireLockOrStartRuntime() {
        let runtime = FakeAutoReplyRuntime()
        let lock = FakeAutoReplyLock(acquireResult: true)
        let promptCount = SendableCounter()
        let model = AutoReplyViewModel(
            runtime: runtime,
            sessionLock: lock,
            permissionCheck: { false },
            permissionPrompt: { promptCount.increment(); return false }
        )

        model.start()

        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(lock.acquireCount, 0)
        XCTAssertEqual(runtime.startCount, 0)
        XCTAssertEqual(promptCount.value, 1)
        XCTAssertTrue(model.status.contains("辅助功能权限"))
    }

    func testLockConflictPreventsSecondRuntime() {
        let runtime = FakeAutoReplyRuntime()
        let model = AutoReplyViewModel(
            runtime: runtime,
            sessionLock: FakeAutoReplyLock(acquireResult: false),
            permissionCheck: { true }
        )

        model.start()

        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(runtime.startCount, 0)
        XCTAssertTrue(model.status.contains("另一个"))
    }

    func testStartPassesLiveDeliverySettingAndStopReleasesLock() {
        let runtime = FakeAutoReplyRuntime()
        let lock = FakeAutoReplyLock(acquireResult: true)
        let model = AutoReplyViewModel(
            runtime: runtime, sessionLock: lock, permissionCheck: { true }
        )

        model.start()
        model.stop()

        XCTAssertEqual(runtime.deliveryEnabledValues.first, true)
        XCTAssertEqual(runtime.startCount, 1)
        XCTAssertEqual(runtime.stopCount, 1)
        XCTAssertEqual(lock.releaseCount, 1)
    }

    func testViewAppearanceStartsLiveRuntimeAutomatically() {
        let runtime = FakeAutoReplyRuntime()
        let model = AutoReplyViewModel(
            runtime: runtime,
            sessionLock: FakeAutoReplyLock(acquireResult: true),
            permissionCheck: { true }
        )

        model.viewAppeared()

        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(runtime.deliveryEnabledValues.first, true)
        XCTAssertEqual(runtime.startCount, 1)
    }

    func testCandidateViewAppearanceRemainsStoppedUntilExplicitStart() {
        let runtime = FakeAutoReplyRuntime()
        let model = AutoReplyViewModel(
            runtime: runtime,
            identity: .taskIsolationCandidate(
                homeDirectory: URL(fileURLWithPath: "/tmp/pdd-candidate-home", isDirectory: true)
            ),
            sessionLock: FakeAutoReplyLock(acquireResult: true),
            permissionCheck: { true }
        )

        model.viewAppeared()

        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(runtime.startCount, 0)
        XCTAssertTrue(model.status.contains("已停止"))
    }

    func testTransientViewDisappearanceDoesNotStopAutonomousRuntime() {
        let runtime = FakeAutoReplyRuntime()
        let lock = FakeAutoReplyLock(acquireResult: true)
        let model = AutoReplyViewModel(
            runtime: runtime,
            sessionLock: lock,
            permissionCheck: { true }
        )
        model.viewAppeared()

        model.viewDisappeared()

        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(runtime.stopCount, 0)
        XCTAssertEqual(lock.releaseCount, 0)
    }

    func testStartListensForAXChangesAndStopReleasesObserver() {
        let runtime = FakeAutoReplyRuntime()
        let observer = FakeAXNotificationListener()
        let model = AutoReplyViewModel(
            runtime: runtime,
            sessionLock: FakeAutoReplyLock(acquireResult: true),
            permissionCheck: { true },
            axNotificationListener: observer
        )

        model.start()
        observer.trigger()
        model.stop()

        XCTAssertEqual(observer.startCount, 1)
        XCTAssertEqual(runtime.axRefreshRequestCount, 1)
        XCTAssertEqual(observer.stopCount, 1)
    }

    func testModelPublishesCodexKnowledgeAndRuntimeHealthWithoutExtraAXWork() {
        let runtime = FakeAutoReplyRuntime()
        runtime.codexExecutablePath = "/Applications/ChatGPT.app/Contents/Resources/codex"
        runtime.latestKnowledgeDiagnostic = KnowledgeRetrievalDiagnostic(
            mode: .v2Top12, knowledgeBaseSHA256: "abcdef123456", selectedDocuments: ["m880.md"],
            contextSHA256: "ctx", durationMilliseconds: 88, error: nil
        )
        runtime.latestResourceSnapshot = RuntimeResourceSnapshot(
            date: Date(timeIntervalSince1970: 1), availableMemoryBytes: 8 << 30,
            activeCLI: 2, queueDepth: 3, lastLatencyMilliseconds: 900
        )
        runtime.lastRuntimeIssue = "上次 AX 读取失败，正在继续"
        let model = AutoReplyViewModel(
            runtime: runtime,
            sessionLock: FakeAutoReplyLock(acquireResult: true),
            permissionCheck: { true }
        )

        model.viewAppeared()

        XCTAssertEqual(model.codexExecutablePath, runtime.codexExecutablePath)
        XCTAssertEqual(model.latestKnowledgeDiagnostic, runtime.latestKnowledgeDiagnostic)
        XCTAssertEqual(model.latestResourceSnapshot, runtime.latestResourceSnapshot)
        XCTAssertEqual(model.lastRuntimeIssue, runtime.lastRuntimeIssue)
        XCTAssertEqual(runtime.axRefreshRequestCount, 0)
    }

    func testRuntimeStageChangeReachesProgressUIBeforeLongTickCompletes() {
        let runtime = FakeAutoReplyRuntime()
        let model = AutoReplyViewModel(
            runtime: runtime,
            sessionLock: FakeAutoReplyLock(acquireResult: true),
            permissionCheck: { true }
        )

        runtime.currentUIOwner = "capture:GZC-000001"
        runtime.onStateChange?()

        XCTAssertEqual(model.currentUIOwner, "capture:GZC-000001")
    }

    func testExplicitStartAndStopPersistRunIntent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-view-model-intent", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let intent = AutoReplyRunIntentStore(rootDirectory: root)
        let model = AutoReplyViewModel(
            runtime: FakeAutoReplyRuntime(),
            sessionLock: FakeAutoReplyLock(acquireResult: true),
            permissionCheck: { true },
            runIntentStore: intent
        )

        model.start()
        XCTAssertTrue(try intent.load())
        model.stop()
        XCTAssertFalse(try intent.load())
    }

    func testCandidateRestartsWhenPersistedIntentIsRunning() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-view-model-resume", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let identity = PDDRuntimeIdentity.taskIsolationCandidate(homeDirectory: home)
        let intent = AutoReplyRunIntentStore(rootDirectory: identity.dataRoot)
        try intent.save(desiredRunning: true)
        let runtime = FakeAutoReplyRuntime()
        let model = AutoReplyViewModel(
            runtime: runtime,
            identity: identity,
            sessionLock: FakeAutoReplyLock(acquireResult: true),
            permissionCheck: { true },
            runIntentStore: intent
        )

        model.viewAppeared()

        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(runtime.startCount, 1)
    }
}

private final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func increment() { lock.lock(); storage += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
}

private actor AsyncPrewarmGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var released = false

    func wait() async throws {
        if released { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class FakeAutoReplyRuntime: AutoReplyRunning {
    var onStateChange: (@MainActor () -> Void)?
    var jobs: [AutoReplyJob] = []
    var currentUIOwner: String?
    var latestCapture: AutoReplyCapture?
    var liveGenerationCount = 0
    var lastAXWakeAt: Date?
    var codexExecutablePath: String?
    var latestKnowledgeDiagnostic: KnowledgeRetrievalDiagnostic?
    var latestResourceSnapshot: RuntimeResourceSnapshot?
    var lastRuntimeIssue: String?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var deliveryEnabledValues: [Bool] = []
    private(set) var axRefreshRequestCount = 0
    func setDeliveryEnabled(_ enabled: Bool) { deliveryEnabledValues.append(enabled) }
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func tick() async {}
    func requestAXRefresh() { axRefreshRequestCount += 1 }
}

@MainActor
private final class FakeAXNotificationListener: AXNotificationListening {
    var callback: (@MainActor () -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func trigger() { callback?() }
}

private final class FakeAutoReplyLock: AutoReplyLocking {
    let acquireResult: Bool
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    init(acquireResult: Bool) { self.acquireResult = acquireResult }
    func acquire() throws -> Bool { acquireCount += 1; return acquireResult }
    func release() { releaseCount += 1 }
}
