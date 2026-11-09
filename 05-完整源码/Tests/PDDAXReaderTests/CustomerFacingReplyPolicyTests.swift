import XCTest
@testable import PDDAXReader

final class CustomerFacingReplyPolicyTests: XCTestCase {
    func testVideoProcessingStatusIsBlockedButSpecificEvidenceLimitsAndChineseHoldsAreAllowed() {
        for text in ["I can’t view the video here.", "Your video is still loading.", "我这边无法查看视频。", "您的视频还在加载。"] {
            XCTAssertEqual(CustomerFacingReplyPolicy.violation(in: text), "video processing status")
        }
        for text in PDDVideoHoldingNotice.messages + ["The guides are obscured by your hands.", "视频中看不清导纸器，请拍一下该部位。"] {
            XCTAssertNil(CustomerFacingReplyPolicy.violation(in: text))
        }
    }
    func testObservedAfterSalesTermsExplanationsAreAllowed() {
        for reply in [
            "Replacement eligibility depends on your order’s after-sales terms and confirmation of the fault. I can’t confirm those details yet.",
            "Replacement eligibility, deadlines, and any costs depend on your order’s after-sales terms and assessment of the fault. I can’t confirm a specific window.",
            "售后规则以订单为准，暂时无法确认换货资格。"
        ] { XCTAssertNil(CustomerFacingReplyPolicy.violation(in: reply), reply) }
        for reply in ["My colleague will verify your eligibility.", "A representative needs to review it.", "我会转接同事为您核实。"] {
            XCTAssertNotNil(CustomerFacingReplyPolicy.violation(in: reply), reply)
        }
    }

    func testFallbackHandoffUsesCustomerLanguageAndNeutralWording() {
        let history = [PDDChatMessage(id: "q", sender: .customer, content: "What is your replacement policy?",
            displayTime: nil, kind: .text, capturedAt: Date())]
        let reply = CustomerFacingFallback.handoff(history: history)
        XCTAssertEqual(reply, "I’ll transfer you to a colleague for further assistance.")
        XCTAssertNil(CustomerFacingReplyPolicy.violation(in: reply))
    }
    func testRejectsObservedIdentityAndVerificationPhrases() {
        let prohibited = [
            "A human after-sales agent needs to verify your order eligibility.",
            "A live agent will review this request.",
            "I am an AI assistant.",
            "我帮您转人工客服核实。",
            "这是自动客服回复。"
        ]
        for reply in prohibited {
            XCTAssertNotNil(CustomerFacingReplyPolicy.violation(in: reply), reply)
        }
    }

    func testAllowsNeutralStoreAndColleagueWording() {
        XCTAssertNil(CustomerFacingReplyPolicy.violation(
            in: "I’m a customer service assistant for the Grozziie store."
        ))
        XCTAssertNil(CustomerFacingReplyPolicy.violation(
            in: "I’ll transfer this conversation to my colleague, who will continue handling it."
        ))
        XCTAssertNil(CustomerFacingReplyPolicy.violation(
            in: "Please wait while I check the printer details."
        ))
        XCTAssertNil(CustomerFacingReplyPolicy.violation(
            in: "我为您转接同事继续协助。"
        ))
    }
}
