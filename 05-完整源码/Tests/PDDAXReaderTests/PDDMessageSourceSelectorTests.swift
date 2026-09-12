import XCTest
@testable import PDDAXReader

final class PDDMessageSourceSelectorTests: XCTestCase {
    private let uid = "PDD-NAME-test"
    private let t0 = Date(timeIntervalSince1970: 1_777_000_000)

    func testValidFirstOrChangedAXUsesAXImmediately() {
        var selector = PDDMessageSourceSelector()

        XCTAssertEqual(selector.observe(uid: uid, unread: true, evidence: evidence("1"), now: t0), .useAX)
        XCTAssertEqual(
            selector.observe(uid: uid, unread: true, evidence: evidence("1", "2"), now: t0.addingTimeInterval(0.1)),
            .useAX
        )
    }

    func testMissingStructureUsesOCRImmediately() {
        var selector = PDDMessageSourceSelector()
        let missing = PDDAXVisibleMessageEvidence(
            messageNodeCount: 0,
            messages: [],
            diagnostics: [],
            fingerprint: "missing",
            isStructurallyValid: false
        )

        XCTAssertEqual(
            selector.observe(uid: uid, unread: true, evidence: missing, now: t0),
            .useOCR(reason: .missingStructure)
        )
    }

    func testUnreadUnchangedAXRequiresThreeSpacedSamplesBeforeOCR() {
        var selector = PDDMessageSourceSelector()
        let same = evidence("1")
        XCTAssertEqual(selector.observe(uid: uid, unread: false, evidence: same, now: t0), .useAX)

        XCTAssertEqual(
            selector.observe(uid: uid, unread: true, evidence: same, now: t0.addingTimeInterval(1)),
            .resampleAX(afterNanoseconds: 200_000_000)
        )
        XCTAssertEqual(
            selector.observe(uid: uid, unread: true, evidence: same, now: t0.addingTimeInterval(1.2)),
            .resampleAX(afterNanoseconds: 200_000_000)
        )
        XCTAssertEqual(
            selector.observe(uid: uid, unread: true, evidence: same, now: t0.addingTimeInterval(1.4)),
            .useOCR(reason: .unreadAXStale)
        )
    }

    func testElapsedDeadlineDoesNotReplaceRequiredThirdSample() {
        var selector = PDDMessageSourceSelector()
        let same = evidence("1")
        _ = selector.observe(uid: uid, unread: false, evidence: same, now: t0)

        XCTAssertEqual(
            selector.observe(uid: uid, unread: true, evidence: same, now: t0.addingTimeInterval(1)),
            .resampleAX(afterNanoseconds: 200_000_000)
        )
        XCTAssertEqual(
            selector.observe(uid: uid, unread: true, evidence: same, now: t0.addingTimeInterval(2.2)),
            .resampleAX(afterNanoseconds: 200_000_000)
        )
        XCTAssertEqual(
            selector.observe(uid: uid, unread: true, evidence: same, now: t0.addingTimeInterval(2.4)),
            .useOCR(reason: .unreadAXStale)
        )
    }

    func testTooEarlyObservationDoesNotCountAsAnotherSample() {
        var selector = PDDMessageSourceSelector()
        let same = evidence("1")
        _ = selector.observe(uid: uid, unread: false, evidence: same, now: t0)
        _ = selector.observe(uid: uid, unread: true, evidence: same, now: t0.addingTimeInterval(1))

        XCTAssertEqual(
            selector.observe(uid: uid, unread: true, evidence: same, now: t0.addingTimeInterval(1.05)),
            .resampleAX(afterNanoseconds: 150_000_000)
        )
        XCTAssertEqual(
            selector.observe(uid: uid, unread: true, evidence: same, now: t0.addingTimeInterval(1.2)),
            .resampleAX(afterNanoseconds: 200_000_000)
        )
    }

    func testNoUnreadWithUnchangedValidAXUsesAXWithoutProbe() {
        var selector = PDDMessageSourceSelector()
        let same = evidence("1")
        XCTAssertEqual(selector.observe(uid: uid, unread: false, evidence: same, now: t0), .useAX)
        XCTAssertEqual(
            selector.observe(uid: uid, unread: false, evidence: same, now: t0.addingTimeInterval(5)),
            .useAX
        )
    }

    func testReversedStableIDOrderUsesOCR() {
        var selector = PDDMessageSourceSelector()
        _ = selector.observe(uid: uid, unread: false, evidence: evidence("1", "2"), now: t0)

        XCTAssertEqual(
            selector.observe(
                uid: uid,
                unread: false,
                evidence: evidence("2", "1"),
                now: t0.addingTimeInterval(1)
            ),
            .useOCR(reason: .regressedStructure)
        )
    }

    func testChangedFingerprintCancelsAnUnreadStaleProbe() {
        var selector = PDDMessageSourceSelector()
        let same = evidence("1")
        _ = selector.observe(uid: uid, unread: false, evidence: same, now: t0)
        _ = selector.observe(uid: uid, unread: true, evidence: same, now: t0.addingTimeInterval(1))

        XCTAssertEqual(
            selector.observe(
                uid: uid,
                unread: true,
                evidence: evidence("1", "2"),
                now: t0.addingTimeInterval(1.2)
            ),
            .useAX
        )
        XCTAssertEqual(
            selector.observe(
                uid: uid,
                unread: true,
                evidence: evidence("1", "2"),
                now: t0.addingTimeInterval(1.4)
            ),
            .resampleAX(afterNanoseconds: 200_000_000)
        )
    }

    func testRestoredTrustedSnapshotStillProbesUnreadUnchangedAXAfterRestart() {
        var original = PDDMessageSourceSelector()
        let same = evidence("1")
        XCTAssertEqual(original.observe(uid: uid, unread: false, evidence: same, now: t0), .useAX)
        let persisted = original.snapshot()
        var restored = PDDMessageSourceSelector()
        restored.restore(persisted)

        XCTAssertEqual(
            restored.observe(
                uid: uid,
                unread: true,
                evidence: same,
                now: t0.addingTimeInterval(10)
            ),
            .resampleAX(afterNanoseconds: 200_000_000)
        )
    }

    private func evidence(_ ids: String...) -> PDDAXVisibleMessageEvidence {
        let messages = ids.map {
            PDDChatMessage(
                id: "middlePanel_list_\($0)",
                sender: .customer,
                content: "消息\($0)",
                displayTime: nil,
                kind: .text,
                capturedAt: t0
            )
        }
        return PDDAXVisibleMessageEvidence(
            messageNodeCount: messages.count,
            messages: messages,
            diagnostics: [],
            fingerprint: ids.joined(separator: "|"),
            isStructurallyValid: true
        )
    }
}
