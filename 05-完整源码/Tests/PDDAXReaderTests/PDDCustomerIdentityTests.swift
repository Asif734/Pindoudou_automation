import XCTest
@testable import PDDAXReader

final class PDDCustomerIdentityTests: XCTestCase {
    func testFindsCanonicalGZCIdentifierAnywhereInAXTree() {
        let root = AXNodeSnapshot(
            role: "AXApplication",
            children: [
                AXNodeSnapshot(
                    role: "AXGroup",
                    attributes: [("AXValue", "c*** 女 已关注本店 GZC-000001")]
                )
            ]
        )

        XCTAssertEqual(PDDCustomerIdentity.resolve(from: root), "GZC-000001")
    }

    func testReturnsNilWhenAXTreeHasNoCanonicalCustomerIdentifier() {
        let root = AXNodeSnapshot(
            role: "AXWindow",
            attributes: [("AXTitle", "拼多多商家工作台")]
        )

        XCTAssertNil(PDDCustomerIdentity.resolve(from: root))
    }

    func testRejectsAmbiguousDifferentCustomerIdentifiers() {
        let root = AXNodeSnapshot(
            role: "AXWindow",
            attributes: [("AXValue", "GZC-000001 和 GZC-000002")]
        )

        XCTAssertNil(PDDCustomerIdentity.resolve(from: root))
    }
}
