import XCTest
@testable import PDDAXReader

final class PDDVideoTransferRelayTests: XCTestCase {
    func testEventBeforeHandlerInstallationIsDeliveredExactlyOnce() async throws {
        let relay = PDDVideoTransferRelay()
        let received = EventCollector()
        let event = PDDVideoTransferEvent(
            uid: "PDD-one", messageID: "v1", phase: .downloading
        )

        await relay.send(event)
        await relay.install { await received.append($0) }
        try await Task.sleep(for: .milliseconds(20))

        let events = await received.snapshot()
        XCTAssertEqual(events, [event])
    }

    func testRegistryRejectsDuplicateAndCancelsWaitingTask() async throws {
        let registry = PDDVideoTransferRegistry()
        let key = PDDVideoTransferKey(uid: "PDD-one", messageID: "v1")
        let cancellation = AsyncFlag()
        let first = await registry.start(key: key) {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { await cancellation.set() }
        }
        let second = await registry.start(key: key) {}

        XCTAssertTrue(first)
        XCTAssertFalse(second)
        await registry.cancelAll()
        for _ in 0..<20 where !(await cancellation.value()) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let wasCancelled = await cancellation.value()
        let count = await registry.count
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(count, 0)
    }

    func testRegistryRejectsSameMessageWhileActiveUnderDifferentUID() async throws {
        let registry = PDDVideoTransferRegistry()
        let firstKey = PDDVideoTransferKey(uid: "PDD-one", messageID: "same-video")
        let aliasKey = PDDVideoTransferKey(uid: "PDD-alias", messageID: "same-video")
        let release = AsyncReleaseGateForRegistry()

        let first = await registry.start(key: firstKey) { await release.wait() }
        let alias = await registry.start(key: aliasKey) {}

        XCTAssertTrue(first)
        XCTAssertFalse(alias)
        await release.open()
    }

    func testRegistryIgnoresStaleStopAfterNewerRestart() async {
        let registry = PDDVideoTransferRegistry()
        await registry.setDesired(revision: 2, enabled: true)
        await registry.setDesired(revision: 1, enabled: false)

        let started = await registry.start(
            key: PDDVideoTransferKey(uid: "PDD-one", messageID: "v1")
        ) {}
        XCTAssertTrue(started)
    }
}

private actor EventCollector {
    private var events: [PDDVideoTransferEvent] = []
    func append(_ event: PDDVideoTransferEvent) { events.append(event) }
    func snapshot() -> [PDDVideoTransferEvent] { events }
}

private actor AsyncFlag {
    private var state = false
    func set() { state = true }
    func value() -> Bool { state }
}

private actor AsyncReleaseGateForRegistry {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
