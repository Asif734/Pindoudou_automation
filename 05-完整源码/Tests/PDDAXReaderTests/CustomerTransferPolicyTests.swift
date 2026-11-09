import XCTest
@testable import PDDAXReader

final class CustomerTransferPolicyTests: XCTestCase {
    func testRefundOperationDoesNotRequireTechnicalTroubleshootingFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CustomerTransferPolicyStore(); let now = Date()
        let clarify = try await store.decide(root: root, uid: "A", messageIDs: ["request"], kind: .refundReturn,
            answerFound: true, issueHasNoSolution: false, proposedAction: .reply, proposedReason: .none, now: now)
        XCTAssertEqual(clarify.action, .reply)
        for (i, textID) in ["refund-confirmed", "return-product", "please-proceed"].enumerated() {
            let result = try await store.decide(root: root, uid: "A", messageIDs: [textID], kind: .refundReturn,
                answerFound: i != 0, issueHasNoSolution: false, proposedAction: .replyThenTransfer,
                proposedReason: .refundOperation, now: now)
            XCTAssertEqual(result.action, .replyThenTransfer)
            XCTAssertEqual(result.reason, .refundOperation)
            let retry = try await CustomerTransferPolicyStore().decide(root: root, uid: "A", messageIDs: [textID], kind: .refundReturn,
                answerFound: false, issueHasNoSolution: false, proposedAction: .replyThenTransfer, proposedReason: .refundOperation, now: now)
            XCTAssertEqual(retry, result)
        }
        let policyQuestion = try await store.decide(root: root, uid: "A", messageIDs: ["policy-only"], kind: .other,
            answerFound: false, issueHasNoSolution: false, proposedAction: .replyThenTransfer,
            proposedReason: .refundOperation, now: now)
        XCTAssertEqual(policyQuestion.action, .reply, "An unrelated current intent cannot inherit a refund handoff")
    }
    func testHumanRequestsArePerCustomerPersistentAndDeduplicated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CustomerTransferPolicyStore()
        let now = Date()
        let first = try await decide(store, root, "A", "1", .humanRequest, now)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.action, .reply)
        let retry = try await decide(CustomerTransferPolicyStore(), root, "A", "1", .humanRequest, now.addingTimeInterval(10))
        XCTAssertEqual(retry, first)
        let anotherCustomer = try await decide(store, root, "B", "2", .humanRequest, now.addingTimeInterval(20))
        XCTAssertEqual(anotherCustomer.count, 1)
        let second = try await decide(store, root, "A", "3", .humanRequest, now.addingTimeInterval(600))
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second.action, .replyThenTransfer)
        let expired = try await decide(store, root, "A", "4", .humanRequest, now.addingTimeInterval(601))
        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(expired.action, .reply)
    }

    func testRefundClarifiesThenTransfersAndTechnicalMissingSolutionTransfers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CustomerTransferPolicyStore()
        let now = Date()
        let first = try await decide(store, root, "A", "1", .refundReturn, now)
        XCTAssertEqual(first.action, .reply)
        let second = try await decide(store, root, "A", "2", .refundReturn, now.addingTimeInterval(5))
        XCTAssertEqual(second.action, .reply)
        XCTAssertEqual(second.count, 0)
        let missing = try await decide(store, root, "B", "3", .refundReturn, now, missing: true)
        XCTAssertEqual(missing.action, .replyThenTransfer)
        let technical = try await decide(store, root, "C", "4", .technical, now, missing: true)
        XCTAssertEqual(technical.reason, .troubleshootingExhausted)
        let unclear = try await store.decide(root: root, uid: "D", messageIDs: ["5"], kind: .technical,
            answerFound: false, issueHasNoSolution: false, proposedAction: .reply,
            proposedReason: .none, now: now)
        XCTAssertEqual(unclear.action, .reply)
    }

    func testIncomingHandoffResetsCounterOnceAndClosesPreBoundaryMessages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CustomerTransferPolicyStore()
        let now = Date()
        _ = try await decide(store, root, "A", "old-1", .humanRequest, now)
        let oldSecond = try await decide(
            store, root, "A", "old-2", .humanRequest, now.addingTimeInterval(5)
        )
        XCTAssertEqual(oldSecond.action, .replyThenTransfer)

        let began = try await store.beginIncomingHandoff(
            root: root,
            uid: "A",
            boundaryKey: "boundary-1",
            priorMessageIDs: ["old-1", "old-2"]
        )
        XCTAssertTrue(began)
        let repeated = try await store.beginIncomingHandoff(
            root: root,
            uid: "A",
            boundaryKey: "boundary-1",
            priorMessageIDs: ["old-1", "old-2"]
        )
        XCTAssertFalse(repeated)

        let stale = try await decide(
            store, root, "A", "old-2", .humanRequest, now.addingTimeInterval(10)
        )
        XCTAssertEqual(stale.action, .reply)
        let firstNew = try await decide(
            store, root, "A", "new-1", .humanRequest, now.addingTimeInterval(11)
        )
        XCTAssertEqual(firstNew.count, 1)
        XCTAssertEqual(firstNew.action, .reply)
        let secondNew = try await decide(
            store, root, "A", "new-2", .humanRequest, now.addingTimeInterval(12)
        )
        XCTAssertEqual(secondNew.count, 2)
        XCTAssertEqual(secondNew.action, .replyThenTransfer)
    }

    func testCompletedHandoffClosesOldMessagesAndResetsOnlyThatCustomer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CustomerTransferPolicyStore()
        let now = Date()
        _ = try await decide(store, root, "A", "1", .humanRequest, now)
        _ = try await decide(store, root, "A", "2", .humanRequest, now)
        _ = try await decide(store, root, "B", "3", .humanRequest, now)
        try await store.completeHandoff(root: root, uid: "A", messageIDs: ["1", "2"])
        let old = try await decide(store, root, "A", "2", .humanRequest, now)
        XCTAssertEqual(old.action, .reply)
        let returned = try await decide(store, root, "A", "4", .humanRequest, now)
        XCTAssertEqual(returned.count, 1)
        XCTAssertEqual(returned.action, .reply)
        let other = try await decide(store, root, "B", "5", .humanRequest, now)
        XCTAssertEqual(other.count, 2)
        let ordinary = try await store.decide(root: root, uid: "A", messageIDs: ["6"], kind: .other,
            answerFound: true, issueHasNoSolution: false, proposedAction: .replyThenTransfer,
            proposedReason: .customerExplicitlyRequestedHuman, now: now)
        XCTAssertEqual(ordinary.action, .reply)
    }

    private func decide(_ store: CustomerTransferPolicyStore, _ root: URL, _ uid: String,
                        _ id: String, _ kind: CustomerRequestKind, _ now: Date,
                        missing: Bool = false) async throws -> CustomerTransferDecision {
        try await store.decide(root: root, uid: uid, messageIDs: [id], kind: kind,
            answerFound: !missing, issueHasNoSolution: missing,
            proposedAction: .replyThenTransfer, proposedReason: .customerExplicitlyRequestedHuman,
            now: now)
    }
}
