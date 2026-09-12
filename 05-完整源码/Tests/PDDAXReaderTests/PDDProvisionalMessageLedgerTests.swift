import XCTest
@testable import PDDAXReader

final class PDDProvisionalMessageLedgerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_777_000_000)

    func testExactNormalizedContentWithinThirtySecondsIsAbsorbed() {
        var ledger = PDDProvisionalMessageLedger(receipts: [receipt(content: "客户  问题", answered: true)])
        let ax = message(id: "middlePanel_list_new", content: "客户 问题")

        let result = ledger.reconcile(axMessages: [ax], now: t0.addingTimeInterval(30))

        XCTAssertTrue(result.actionableAXMessages.isEmpty)
        XCTAssertEqual(result.absorbedAXMessageIDs, [ax.id])
        XCTAssertEqual(ledger.receipts[0].absorbedAXMessageID, ax.id)
    }

    func testMismatchAndMessageAfterWindowRemainActionable() {
        var mismatchLedger = PDDProvisionalMessageLedger(receipts: [receipt(content: "A", answered: true)])
        let mismatch = message(id: "middlePanel_list_b", content: "B")
        XCTAssertEqual(
            mismatchLedger.reconcile(axMessages: [mismatch], now: t0.addingTimeInterval(10))
                .actionableAXMessages,
            [mismatch]
        )

        var lateLedger = PDDProvisionalMessageLedger(receipts: [receipt(content: "A", answered: true)])
        let late = message(id: "middlePanel_list_late", content: "A")
        XCTAssertEqual(
            lateLedger.reconcile(axMessages: [late], now: t0.addingTimeInterval(30.001))
                .actionableAXMessages,
            [late]
        )
        XCTAssertNil(lateLedger.receipts[0].absorbedAXMessageID)
    }

    func testAbsorbsUnansweredReceiptSoExistingProvisionalWorkIsNotDuplicated() {
        var ledger = PDDProvisionalMessageLedger(receipts: [receipt(content: "同一条", answered: false)])

        let result = ledger.reconcile(
            axMessages: [message(id: "middlePanel_list_same", content: "同一条")],
            now: t0.addingTimeInterval(5)
        )

        XCTAssertTrue(result.actionableAXMessages.isEmpty)
    }

    func testRepeatedReconciliationIsIdempotent() {
        var ledger = PDDProvisionalMessageLedger(receipts: [receipt(content: "同一条", answered: true)])
        let ax = message(id: "middlePanel_list_same", content: "同一条")

        let first = ledger.reconcile(axMessages: [ax], now: t0.addingTimeInterval(5))
        let receiptsAfterFirst = ledger.receipts
        let second = ledger.reconcile(axMessages: [ax], now: t0.addingTimeInterval(6))

        XCTAssertEqual(first.absorbedAXMessageIDs, [ax.id])
        XCTAssertEqual(second.absorbedAXMessageIDs, [ax.id])
        XCTAssertTrue(second.actionableAXMessages.isEmpty)
        XCTAssertEqual(ledger.receipts, receiptsAfterFirst)
    }

    func testServiceMessagesAreNeverMatchedToCustomerReceipts() {
        var ledger = PDDProvisionalMessageLedger(receipts: [receipt(content: "相同正文", answered: true)])
        let service = PDDChatMessage(
            id: "middlePanel_list_service", sender: .service, content: "相同正文",
            displayTime: nil, kind: .text, capturedAt: t0
        )

        let result = ledger.reconcile(axMessages: [service], now: t0.addingTimeInterval(5))

        XCTAssertEqual(result.actionableAXMessages, [service])
        XCTAssertNil(ledger.receipts[0].absorbedAXMessageID)
    }

    private func receipt(content: String, answered: Bool) -> PDDProvisionalReceipt {
        PDDProvisionalReceipt(
            provisionalMessageID: "ocr-provisional-1",
            normalizedContent: PDDOCRNormalizer.normalize(content),
            firstObservedAt: t0,
            answered: answered,
            absorbedAXMessageID: nil
        )
    }

    private func message(id: String, content: String) -> PDDChatMessage {
        PDDChatMessage(
            id: id, sender: .customer, content: content,
            displayTime: nil, kind: .text, capturedAt: t0
        )
    }
}
