import XCTest
@testable import PDDAXReader

final class AutomationStepLogTests: XCTestCase {
    func testConcurrentStepsAppendCompleteRecordsAndPreserveEarlierLogs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        AutomationStepLog.record(root: root, uid: "customer", step: "initial")
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            AutomationStepLog.record(root: root, uid: "customer", step: "step-\(index)", detail: "line\n\(index)")
        }
        let text = try String(contentsOf: root.appendingPathComponent("logs/automation-steps.jsonl"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try text.split(separator: "\n").map { try decoder.decode(AutoReplyEvent.self, from: Data($0.utf8)) }
        XCTAssertEqual(events.count, 21)
        XCTAssertEqual(events.first?.kind, "initial")
        XCTAssertEqual(Set(events.map(\.kind)).count, 21)
        XCTAssertTrue(events.allSatisfy { $0.uid == "customer" })
    }
}
