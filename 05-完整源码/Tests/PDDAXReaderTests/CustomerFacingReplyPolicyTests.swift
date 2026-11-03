import XCTest
@testable import PDDAXReader

final class CustomerFacingReplyPolicyTests: XCTestCase {
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
