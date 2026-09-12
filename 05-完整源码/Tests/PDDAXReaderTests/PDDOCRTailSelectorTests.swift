import CoreGraphics
import XCTest
@testable import PDDAXReader

final class PDDOCRTailSelectorTests: XCTestCase {
    private let uid = "PDD-NAME-tail"
    private let capturedAt = Date(timeIntervalSince1970: 1_777_000_000)

    func testSelectsOnlyBottomCustomerTailAfterLastAXAnchor() {
        let ax = [
            axMessage("ax-1", .customer, "旧客户问题"),
            axMessage("ax-2", .service, "已经回复"),
            axMessage("ax-3", .customer, "锚点")
        ]
        let ocr = [
            ocrMessage("ocr-old", .customer, "旧客户问题", y: 10),
            ocrMessage("ocr-fake-service", .customer, "已经回复", y: 30),
            ocrMessage("ocr-watermark", .customer, "格志官方旗舰店", y: 50),
            ocrMessage("ocr-anchor", .customer, "锚点", y: 70),
            ocrMessage("ocr-new-1", .customer, "较早的新问题", y: 90),
            ocrMessage("ocr-new-2", .customer, "唯一最末问题", y: 110)
        ]

        let selected = PDDOCRTailSelector.select(
            uid: uid,
            ocrMessages: ocr,
            axMessages: ax,
            hasUnreadEvidence: true,
            capturedAt: capturedAt
        )

        XCTAssertEqual(selected?.content, "唯一最末问题")
        XCTAssertEqual(selected?.sender, .customer)
        XCTAssertEqual(selected?.kind, .text)
        XCTAssertEqual(selected?.capturedAt, capturedAt)
        XCTAssertTrue(selected?.id.hasPrefix("ocr-provisional-") == true)
    }

    func testReturnsNilWhenAXAnchorIsNotVisibleInOCR() {
        let selected = PDDOCRTailSelector.select(
            uid: uid,
            ocrMessages: [ocrMessage("ocr-new", .customer, "新问题", y: 100)],
            axMessages: [axMessage("ax-anchor", .service, "未出现在截图里的锚点")],
            hasUnreadEvidence: true,
            capturedAt: capturedAt
        )

        XCTAssertNil(selected)
    }

    func testWithoutAXAnchorRequiresUnreadAndSelectsOnlyBottomCustomer() {
        let ocr = [
            ocrMessage("ocr-1", .customer, "上面", y: 20),
            ocrMessage("ocr-2", .service, "客服", y: 40),
            ocrMessage("ocr-3", .customer, "最下面", y: 60)
        ]

        XCTAssertNil(PDDOCRTailSelector.select(
            uid: uid,
            ocrMessages: ocr,
            axMessages: [],
            hasUnreadEvidence: false,
            capturedAt: capturedAt
        ))
        XCTAssertEqual(PDDOCRTailSelector.select(
            uid: uid,
            ocrMessages: ocr,
            axMessages: [],
            hasUnreadEvidence: true,
            capturedAt: capturedAt
        )?.content, "最下面")
    }

    func testRejectsAXServiceDuplicateAndKnownPlatformNoise() {
        let service = axMessage("ax-service", .service, "自动客服刚刚的回复")
        let selected = PDDOCRTailSelector.select(
            uid: uid,
            ocrMessages: [
                ocrMessage("ocr-1", .customer, "自动客服刚刚的回复", y: 70),
                ocrMessage("ocr-2", .customer, "货物打包视频", y: 90)
            ],
            axMessages: [service],
            hasUnreadEvidence: true,
            capturedAt: capturedAt
        )

        XCTAssertNil(selected)
    }

    func testDoesNotReachPastBottomServiceMessageToReplyToOlderCustomer() {
        let anchor = axMessage("ax-anchor", .service, "锚点客服")
        let selected = PDDOCRTailSelector.select(
            uid: uid,
            ocrMessages: [
                ocrMessage("ocr-anchor", .service, "锚点客服", y: 20),
                ocrMessage("ocr-customer", .customer, "已经被回复的问题", y: 60),
                ocrMessage("ocr-service", .service, "后续客服已经回复", y: 100)
            ],
            axMessages: [anchor],
            hasUnreadEvidence: true,
            capturedAt: capturedAt
        )

        XCTAssertNil(selected)
    }

    func testProvisionalIDIsStableForSameOCRMessage() {
        let ocr = [ocrMessage("ocr-same", .customer, "同一条", y: 100)]
        let first = PDDOCRTailSelector.select(
            uid: uid, ocrMessages: ocr, axMessages: [],
            hasUnreadEvidence: true, capturedAt: capturedAt
        )
        let second = PDDOCRTailSelector.select(
            uid: uid, ocrMessages: ocr, axMessages: [],
            hasUnreadEvidence: true, capturedAt: capturedAt.addingTimeInterval(10)
        )

        XCTAssertEqual(first?.id, second?.id)
    }

    func testRejectsExactVideoDurationButKeepsOrdinaryTextContainingTime() {
        XCTAssertNil(PDDOCRTailSelector.select(
            uid: uid,
            ocrMessages: [ocrMessage("ocr-duration", .customer, "00:04", y: 100)],
            axMessages: [],
            hasUnreadEvidence: true,
            capturedAt: capturedAt
        ))

        XCTAssertEqual(PDDOCRTailSelector.select(
            uid: uid,
            ocrMessages: [ocrMessage("ocr-question", .customer, "00:04这里是什么", y: 100)],
            axMessages: [],
            hasUnreadEvidence: true,
            capturedAt: capturedAt
        )?.content, "00:04这里是什么")
    }

    private func axMessage(_ id: String, _ sender: ChatSender, _ content: String) -> PDDChatMessage {
        PDDChatMessage(
            id: id, sender: sender, content: content,
            displayTime: nil, kind: .text, capturedAt: capturedAt
        )
    }

    private func ocrMessage(
        _ id: String,
        _ sender: ChatSender,
        _ text: String,
        y: CGFloat
    ) -> PDDOCRMessage {
        PDDOCRMessage(
            id: id, sender: sender, text: text, timestamp: nil,
            box: CGRect(x: sender == .customer ? 20 : 300, y: y, width: 100, height: 20)
        )
    }
}
