import XCTest
@testable import PDDAXReader

final class AutoReplyTransactionalStoreTests: XCTestCase {
    func testCommitRejectsExternallyModifiedCheckpoint() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let loaded = try fixture.store.loadCheckpoint()
        var external = loaded.state
        external.nextSequence = 99
        try AutoReplyStore(rootDirectory: fixture.root).save(external)

        XCTAssertThrowsError(try fixture.store.commit(expected: loaded.token) { state in
            state.nextSequence = 1
        }) { error in
            XCTAssertEqual(error as? AutoReplyTransactionalStoreError, .checkpointChanged)
        }
        XCTAssertEqual(try AutoReplyStore(rootDirectory: fixture.root).load().nextSequence, 99)
    }

    func testCheckpointTokenChangesWhenExistingStateFileIsDeleted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try AutoReplyStore(rootDirectory: fixture.root).save(.empty)
        let present = try fixture.store.loadCheckpoint()

        try FileManager.default.removeItem(
            at: fixture.root.appendingPathComponent("state.json")
        )
        let missing = try fixture.store.loadCheckpoint()

        XCTAssertNotEqual(present.token, missing.token)
    }

    func testCommitRejectsAnsweredCursorRegression() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var initial = AutoReplyPersistentState.empty
        initial.answeredCursors[fixture.uid] = AutoReplyCursor(
            count: 2, digest: String(repeating: "a", count: 64)
        )
        try AutoReplyStore(rootDirectory: fixture.root).save(initial)
        let loaded = try fixture.store.loadCheckpoint()

        XCTAssertThrowsError(try fixture.store.commit(expected: loaded.token) { state in
            state.answeredCursors[fixture.uid] = AutoReplyCursor(
                count: 1, digest: String(repeating: "b", count: 64)
            )
        }) { error in
            XCTAssertEqual(error as? AutoReplyTransactionalStoreError, .cursorRegression(fixture.uid))
        }
    }

    func testCommitKeepsOnlyNewestOneHundredCheckpointEvents() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var initial = AutoReplyPersistentState.empty
        initial.events = (0..<105).map { index in
            AutoReplyEvent(
                id: UUID(), timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                uid: fixture.uid, kind: "event", detail: "\(index)"
            )
        }
        try AutoReplyStore(rootDirectory: fixture.root).save(initial)
        let loaded = try fixture.store.loadCheckpoint()

        _ = try fixture.store.commit(expected: loaded.token) { $0.nextSequence = 1 }

        let saved = try AutoReplyStore(rootDirectory: fixture.root).load()
        XCTAssertEqual(saved.events.count, 100)
        XCTAssertEqual(saved.events.first?.detail, "5")
        XCTAssertEqual(saved.events.last?.detail, "104")
    }

    func testCommitRepairsOverlappingExecutionForSameUIDInsteadOfStopping() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var initial = AutoReplyPersistentState.empty
        initial.nextSequence = 2
        initial.jobs = [
            fixture.job(sequence: 1, state: .generating),
            fixture.job(sequence: 2, state: .sending)
        ]
        try AutoReplyStore(rootDirectory: fixture.root).save(initial)
        let loaded = try fixture.store.loadCheckpoint()

        _ = try fixture.store.commit(expected: loaded.token) { _ in }

        let saved = try AutoReplyStore(rootDirectory: fixture.root).load()
        XCTAssertEqual(saved.jobs.first(where: { $0.id == initial.jobs[1].id })?.state, .sending)
        let deferred = try XCTUnwrap(saved.jobs.first(where: { $0.id == initial.jobs[0].id }))
        XCTAssertEqual(deferred.state, .queued)
        XCTAssertEqual(deferred.sequence, 3)
        XCTAssertTrue(saved.events.contains {
            $0.uid == fixture.uid && $0.kind == "execution-conflict-repaired"
        })
    }

    func testCommitNeverRequeuesAnOverlappingInvokedSend() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var invoked = fixture.job(sequence: 1, state: .sending)
        invoked.sendWasInvoked = true
        var initial = AutoReplyPersistentState.empty
        initial.nextSequence = 2
        initial.jobs = [invoked, fixture.job(sequence: 2, state: .generating)]
        try AutoReplyStore(rootDirectory: fixture.root).save(initial)
        let loaded = try fixture.store.loadCheckpoint()

        _ = try fixture.store.commit(expected: loaded.token) { _ in }

        let saved = try AutoReplyStore(rootDirectory: fixture.root).load()
        let finished = try XCTUnwrap(saved.jobs.first(where: { $0.id == invoked.id }))
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.deliveryOutcome, .uncertain)
        XCTAssertTrue(finished.sendWasInvoked)
        XCTAssertEqual(saved.jobs.first(where: { $0.id != invoked.id })?.state, .generating)
    }
}

private extension AutoReplyTransactionalStoreTests {
    struct Fixture {
        let root: URL
        let store: AutoReplyTransactionalStore
        let uid = "GZC-000001"

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdd-transaction-store-tests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            store = AutoReplyTransactionalStore(rootDirectory: root)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func job(sequence: Int, state: AutoReplyJobState) -> AutoReplyJob {
            let digest = String(repeating: String(sequence), count: 64)
            let event = ActionableCustomerEvent(
                messageID: "m-\(sequence)", kind: .text,
                content: "消息\(sequence)", displayTime: nil
            )
            let batch = FrozenCustomerBatch(
                startCursor: .empty,
                endCursor: AutoReplyCursor(count: sequence, digest: digest),
                events: [event],
                targetCustomerJSONL: ""
            )
            let capture = AutoReplyCapture(
                uid: uid, fullHistory: [], batch: batch,
                customerCursor: batch.endCursor, unexpectedServiceMessageIDs: []
            )
            return AutoReplyJob(
                id: UUID(), uid: uid, sequence: sequence, state: state,
                capture: capture, reply: state == .sending ? "回复" : nil,
                deliveryOutcome: .notSent, confirmedServiceMessageID: nil,
                retries: 0, nextAttemptAt: nil, lastError: nil
            )
        }
    }
}
