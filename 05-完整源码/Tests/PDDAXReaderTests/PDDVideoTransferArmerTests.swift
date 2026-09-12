import XCTest
@testable import PDDAXReader

@MainActor
final class PDDVideoTransferArmerTests: XCTestCase {
    func testForegroundOrderIsArmOpenStartClose() async throws {
        let recorder = VideoOrderRecorder()
        let armer = VideoArmerSpy(recorder: recorder)
        let opener = VideoPreviewOpenerSpy(recorder: recorder)
        let coordinator = PDDVideoForegroundCoordinator(armer: armer, opener: opener)
        let candidate = PDDCustomerVideoCandidate(
            messageID: "v1", frame: CGRect(x: 10, y: 10, width: 80, height: 60)
        )

        let pending = try await coordinator.begin(
            uid: "PDD-one",
            candidates: [candidate],
            lease: UIOperationLeaseRegistry().acquire(uid: "PDD-one")
        )

        XCTAssertEqual(pending, ["v1"])
        XCTAssertEqual(recorder.values, ["arm", "open", "start", "close"])
    }

    func testPreviewRemainsOpenUntilDownloadFinishesThenClosesOnce() async throws {
        let recorder = VideoOrderRecorder()
        let started = expectation(description: "download started")
        let release = AsyncReleaseGate()
        let armer = WaitingVideoArmerSpy(
            recorder: recorder, started: started, release: release
        )
        let opener = VideoPreviewOpenerSpy(recorder: recorder)
        let coordinator = PDDVideoForegroundCoordinator(armer: armer, opener: opener)
        let candidate = PDDCustomerVideoCandidate(
            messageID: "v1", frame: CGRect(x: 10, y: 10, width: 80, height: 60)
        )

        let operation = Task { @MainActor in
            try await coordinator.begin(
                uid: "PDD-one", candidates: [candidate],
                lease: UIOperationLeaseRegistry().acquire(uid: "PDD-one")
            )
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(recorder.values, ["arm", "open", "start"])

        await release.open()
        _ = try await operation.value
        XCTAssertEqual(recorder.values, ["arm", "open", "start", "close"])
    }

    func testStartReturnsWhileBackgroundOperationWaits() async throws {
        let started = expectation(description: "background started")
        let release = AsyncReleaseGate()
        let transfer = ArmedPDDVideoTransfer {
            started.fulfill()
            await release.wait()
        }

        transfer.start()
        await fulfillment(of: [started], timeout: 1)
        await release.open()
    }

    func testStartIsIdempotent() async throws {
        let counter = AsyncCounter()
        let transfer = ArmedPDDVideoTransfer { await counter.increment() }

        transfer.start()
        transfer.start()
        try await Task.sleep(for: .milliseconds(30))

        let value = await counter.currentValue()
        XCTAssertEqual(value, 1)
    }

    func testLaterOpenFailureKeepsEveryVideoPendingAndReportsOnlyFailedVideo() async throws {
        let recorder = VideoOrderRecorder()
        let armer = VideoArmerSpy(recorder: recorder)
        let opener = VideoPreviewOpenerSpy(recorder: recorder, failingMessageID: "v2")
        let coordinator = PDDVideoForegroundCoordinator(armer: armer, opener: opener)
        let candidates = ["v1", "v2"].map {
            PDDCustomerVideoCandidate(messageID: $0, frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        }

        let pending = try await coordinator.begin(
            uid: "PDD-one", candidates: candidates,
            lease: UIOperationLeaseRegistry().acquire(uid: "PDD-one")
        )

        XCTAssertEqual(pending, ["v1", "v2"])
        XCTAssertEqual(armer.failedMessageIDs, ["v2"])
    }

    func testRetriesPreviewOpenAtMostThreeTimesUntilItIsConfirmed() async throws {
        let recorder = VideoOrderRecorder()
        let armer = VideoArmerSpy(recorder: recorder)
        let opener = ConfirmingVideoPreviewOpenerSpy(
            recorder: recorder, confirmations: [false, false, true]
        )
        let coordinator = PDDVideoForegroundCoordinator(armer: armer, opener: opener)
        let candidate = PDDCustomerVideoCandidate(
            messageID: "v1", frame: CGRect(x: 10, y: 10, width: 80, height: 60)
        )

        _ = try await coordinator.begin(
            uid: "PDD-one", candidates: [candidate],
            lease: UIOperationLeaseRegistry().acquire(uid: "PDD-one")
        )

        XCTAssertEqual(opener.openCount, 3)
        XCTAssertEqual(recorder.values, [
            "arm", "open", "confirm-false", "open", "confirm-false",
            "open", "confirm-true", "start", "close"
        ])
        XCTAssertTrue(armer.failedMessageIDs.isEmpty)
    }

    func testConfirmedPreviewIsNeverClickedASecondTime() async throws {
        let recorder = VideoOrderRecorder()
        let armer = VideoArmerSpy(recorder: recorder)
        let opener = ConfirmingVideoPreviewOpenerSpy(
            recorder: recorder, confirmations: [true, false, false]
        )
        let coordinator = PDDVideoForegroundCoordinator(armer: armer, opener: opener)
        let candidate = PDDCustomerVideoCandidate(
            messageID: "v1", frame: CGRect(x: 10, y: 10, width: 80, height: 60)
        )

        _ = try await coordinator.begin(
            uid: "PDD-one", candidates: [candidate],
            lease: UIOperationLeaseRegistry().acquire(uid: "PDD-one")
        )

        XCTAssertEqual(opener.openCount, 1)
        XCTAssertEqual(recorder.values, ["arm", "open", "confirm-true", "start", "close"])
    }

    func testThreeUnconfirmedClicksFallBackWithoutStartingAddressWait() async throws {
        let recorder = VideoOrderRecorder()
        let armer = VideoArmerSpy(recorder: recorder)
        let opener = ConfirmingVideoPreviewOpenerSpy(
            recorder: recorder, confirmations: [false, false, false]
        )
        let coordinator = PDDVideoForegroundCoordinator(armer: armer, opener: opener)
        let candidate = PDDCustomerVideoCandidate(
            messageID: "v1", frame: CGRect(x: 10, y: 10, width: 80, height: 60)
        )

        let pending = try await coordinator.begin(
            uid: "PDD-one", candidates: [candidate],
            lease: UIOperationLeaseRegistry().acquire(uid: "PDD-one")
        )

        XCTAssertEqual(pending, ["v1"], "the empty video must remain in the Codex batch")
        XCTAssertEqual(opener.openCount, 3)
        XCTAssertFalse(recorder.values.contains("start"), "link waiting must not start before preview confirmation")
        XCTAssertEqual(armer.failedMessageIDs, ["v1"], "existing fallback path must receive the empty video")
    }
}

private final class VideoOrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

@MainActor
private final class VideoArmerSpy: PDDVideoTransferArming {
    let recorder: VideoOrderRecorder
    var failedMessageIDs: [String] = []
    init(recorder: VideoOrderRecorder) { self.recorder = recorder }
    func arm(
        uid: String, messageID: String, candidate: PDDCustomerVideoCandidate
    ) async throws -> ArmedPDDVideoTransfer? {
        recorder.append("arm")
        return ArmedPDDVideoTransfer(
            onStart: { [recorder] in recorder.append("start") },
            operation: {}
        )
    }
    func reportFailure(uid: String, messageID: String, error: Error) async {
        failedMessageIDs.append(messageID)
    }
}

@MainActor
private final class WaitingVideoArmerSpy: PDDVideoTransferArming {
    let recorder: VideoOrderRecorder
    let started: XCTestExpectation
    let release: AsyncReleaseGate

    init(
        recorder: VideoOrderRecorder,
        started: XCTestExpectation,
        release: AsyncReleaseGate
    ) {
        self.recorder = recorder
        self.started = started
        self.release = release
    }

    func arm(
        uid: String, messageID: String, candidate: PDDCustomerVideoCandidate
    ) async throws -> ArmedPDDVideoTransfer? {
        recorder.append("arm")
        return ArmedPDDVideoTransfer(
            onStart: { [recorder, started] in
                recorder.append("start")
                started.fulfill()
            },
            operation: { [release] in await release.wait() }
        )
    }
}

@MainActor
private final class VideoPreviewOpenerSpy: PDDVideoPreviewOpening {
    let recorder: VideoOrderRecorder
    let failingMessageID: String?
    init(recorder: VideoOrderRecorder, failingMessageID: String? = nil) {
        self.recorder = recorder
        self.failingMessageID = failingMessageID
    }
    func open(_ candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws {
        recorder.append("open")
        if candidate.messageID == failingMessageID { throw VideoFixtureError.openFailed }
    }
    func close() async { recorder.append("close") }
}

@MainActor
private final class ConfirmingVideoPreviewOpenerSpy: PDDVideoPreviewOpening {
    let recorder: VideoOrderRecorder
    var confirmations: [Bool]
    var openCount = 0

    init(recorder: VideoOrderRecorder, confirmations: [Bool]) {
        self.recorder = recorder
        self.confirmations = confirmations
    }

    func open(_ candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws {
        openCount += 1
        recorder.append("open")
    }

    func waitUntilOpen() async throws -> Bool {
        let result = confirmations.isEmpty ? false : confirmations.removeFirst()
        recorder.append("confirm-\(result)")
        return result
    }

    func close() async { recorder.append("close") }
}

private enum VideoFixtureError: Error { case openFailed }

private actor AsyncCounter {
    var value = 0
    func increment() { value += 1 }
    func currentValue() -> Int { value }
}

private actor AsyncReleaseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
