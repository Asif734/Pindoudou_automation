import XCTest
@testable import PDDAXReader

final class PDDVideoTransferStateTests: XCTestCase {
    func testRetryScheduleMatchesCurrentQianniu() {
        XCTAssertEqual(PDDVideoRetryPolicy.delay(afterFailure: 0), 60)
        XCTAssertEqual(PDDVideoRetryPolicy.delay(afterFailure: 1), 180)
        XCTAssertEqual(PDDVideoRetryPolicy.delay(afterFailure: 2), 600)
        XCTAssertNil(PDDVideoRetryPolicy.delay(afterFailure: 3))
    }

    func testDurableStatePersistsRetryWithoutSignedAddress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-video-v2-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        let key = PDDVideoTransferKey(uid: "PDD-one", messageID: "video-1")
        let now = Date(timeIntervalSince1970: 100)
        let store = PDDDurableVideoTransferStore(url: url, now: { now })

        _ = try await store.begin(key: key, uid: "PDD-one", messageID: "video-1")
        try await store.scheduleRetry(
            key: key, category: .connectTimeout,
            nextAttemptAt: Date(timeIntervalSince1970: 160)
        )

        let restored = PDDDurableVideoTransferStore(url: url, now: { now })
        let record = try await restored.record(key)
        XCTAssertEqual(record?.phase, .waitingForRetry)
        XCTAssertEqual(record?.retryIndex, 1)
        XCTAssertEqual(record?.nextAttemptAt, Date(timeIntervalSince1970: 160))
        let persisted = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(persisted.contains("https://"))
        XCTAssertFalse(persisted.contains("sign="))
    }

    func testDueRetryRequiresFreshAddressAndCanRecoverAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-video-v2-due-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = VideoStateClock(Date(timeIntervalSince1970: 100))
        let url = root.appendingPathComponent("state.json")
        let key = PDDVideoTransferKey(uid: "PDD-one", messageID: "video-1")
        let first = PDDDurableVideoTransferStore(url: url, now: { clock.value })
        _ = try await first.begin(key: key, uid: "PDD-one", messageID: "video-1")
        try await first.scheduleRetry(
            key: key, category: .responseTimeout,
            nextAttemptAt: Date(timeIntervalSince1970: 160)
        )

        let restarted = PDDDurableVideoTransferStore(url: url, now: { clock.value })
        let notDue = try await restarted.dueRecords()
        XCTAssertTrue(notDue.isEmpty)
        clock.value = Date(timeIntervalSince1970: 160)
        let due = try await restarted.dueRecords()
        XCTAssertEqual(due.map(\.key), [key])
        XCTAssertTrue(due[0].needsFreshAddress)
    }

    func testClaimingDueRetryMakesItUnavailableToTheNextPollingCycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-video-v2-claim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        let key = PDDVideoTransferKey(uid: "PDD-one", messageID: "video-1")
        let now = Date(timeIntervalSince1970: 200)
        let store = PDDDurableVideoTransferStore(url: url, now: { now })
        _ = try await store.begin(key: key, uid: "PDD-one", messageID: "video-1")
        try await store.scheduleRetry(
            key: key, category: .responseTimeout,
            nextAttemptAt: Date(timeIntervalSince1970: 199)
        )

        let firstClaim = try await store.claimDueRecords()
        let secondClaim = try await store.claimDueRecords()
        let claimedRecord = try await store.record(key)

        XCTAssertEqual(firstClaim.map(\.key), [key])
        XCTAssertTrue(secondClaim.isEmpty)
        XCTAssertEqual(claimedRecord?.phase, .opening)
        XCTAssertNil(claimedRecord?.nextAttemptAt)
    }

    func testFallbackAdmissionIsDurablyExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-video-v2-fallback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        let key = PDDVideoTransferKey(uid: "PDD-one", messageID: "video-1")
        let store = PDDDurableVideoTransferStore(url: url)
        _ = try await store.begin(key: key, uid: "PDD-one", messageID: "video-1")

        let first = try await store.markFallbackEmitted(key: key)
        let second = try await store.markFallbackEmitted(key: key)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let restarted = PDDDurableVideoTransferStore(url: url)
        let afterRestart = try await restarted.markFallbackEmitted(key: key)
        XCTAssertFalse(afterRestart)
    }
}

private final class VideoStateClock: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}
