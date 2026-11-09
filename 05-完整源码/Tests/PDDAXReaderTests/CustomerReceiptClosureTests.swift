import XCTest
@testable import PDDAXReader

final class CustomerReceiptClosureTests: XCTestCase {
    func testLegacySkipReconciliationClosesOnlyProvenUnsubmittedUntrackedMessages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("logs"), withIntermediateDirectories: true)
        let date = "2026-11-04T09:09:29Z"
        var messages: [String: [String: Any]] = [:]
        for id in ["old-skipped-video", "active-video", "already-submitted", "unrelated", "already-sent"] {
            messages[id] = ["messageID": id, "capturedAt": date, "requiresSubmission": true]
        }
        messages["already-submitted"]?["submittedAt"] = date
        messages["already-sent"]?["replySentAt"] = date
        try JSONSerialization.data(withJSONObject: ["customers": ["customer": messages]])
            .write(to: root.appendingPathComponent("message-receipts.json"))
        let events: [[String: Any]] = [
            ["kind": "video-content-duplicate", "uid": "customer", "detail": "old-skipped-video,active-video,already-submitted,already-sent"],
            ["kind": "customer-message", "uid": "customer", "detail": "video-content-duplicate unrelated"],
            ["kind": "video-content-duplicate", "uid": "other-customer", "detail": "unrelated"]
        ]
        let jsonl = try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        try Data(jsonl.utf8).write(to: root.appendingPathComponent("logs/automation-steps.jsonl"))
        let receipts = CustomerMessageReceipts(root: root)
        XCTAssertEqual(try receipts.reconcileLegacyVideoSkips(excluding: ["customer": ["active-video"]]), 1)
        let restored = CustomerMessageReceipts(root: root)
        let closed = try XCTUnwrap(restored.receipts(uid: "customer")["old-skipped-video"])
        XCTAssertNotNil(closed.closedAt)
        XCTAssertEqual(closed.closureReason, "legacy-video-content-duplicate")
        XCTAssertNil(closed.submittedAt)
        XCTAssertNil(closed.completedAt)
        XCTAssertNil(closed.replySentAt)
        XCTAssertEqual(try restored.awaitingSubmission()["customer"], ["active-video", "unrelated"])
        XCTAssertEqual(try restored.reconcileLegacyVideoSkips(excluding: ["customer": ["active-video"]]), 0)
        try restored.observe(uid: "customer", messages: [.init(id: "old-skipped-video", sender: .customer,
            content: "[视频]", displayTime: nil, kind: .video, capturedAt: Date())], actionableIDs: ["old-skipped-video"])
        XCTAssertFalse(try restored.awaitingSubmission()["customer"]!.contains("old-skipped-video"))
    }
}
