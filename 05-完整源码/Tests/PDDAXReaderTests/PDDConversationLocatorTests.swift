import XCTest
@testable import PDDAXReader

final class PDDConversationLocatorTests: XCTestCase {
    func testUniqueIdentifierProducesIdentifierKey() {
        let locator = PDDConversationLocator(domIdentifier: "buyer-row-123", nickname: "S***")
        XCTAssertEqual(PDDConversationKey.make(locator: locator), "PDD-ID-59251d3ab1e64445e8ddd85d")
    }

    func testMissingIdentifierProducesNicknameKeyFromTrimmedNickname() {
        let locator = PDDConversationLocator(domIdentifier: nil, nickname: "  S***  ")
        XCTAssertEqual(locator.normalizedNickname, "S***")
        XCTAssertEqual(PDDConversationKey.make(locator: locator), "PDD-NAME-a1366828d04c70214f9fcb06")
    }

    func testSameNicknameWithDifferentIdentifiersProducesDifferentKeys() {
        let first = PDDConversationKey.make(locator: .init(domIdentifier: "row-a", nickname: "S***"))
        let second = PDDConversationKey.make(locator: .init(domIdentifier: "row-b", nickname: "S***"))
        XCTAssertNotEqual(first, second)
    }

    func testResolvesCurrentMaskedNicknameFromActiveConversationRowWithoutLegacyUID() {
        let root = AXNodeSnapshot(role: "AXWindow", children: [
            AXNodeSnapshot(
                role: "AXGroup",
                attributes: [("AXDOMClassList", "[chat-item-box, active]")],
                children: [
                    AXNodeSnapshot(
                        role: "AXGroup",
                        attributes: [("AXDOMClassList", "[chat-nickname]")],
                        children: [
                            AXNodeSnapshot(role: "AXStaticText", attributes: [("AXValue", "山**川")]),
                            AXNodeSnapshot(role: "AXStaticText", attributes: [("AXValue", "下单数(1)")])
                        ]
                    ),
                    AXNodeSnapshot(
                        role: "AXGroup",
                        attributes: [("AXDOMClassList", "[chat-message-content]")],
                        children: [AXNodeSnapshot(role: "AXStaticText", attributes: [("AXValue", "消息预览")])]
                    )
                ]
            )
        ])

        XCTAssertEqual(
            PDDConversationSnapshotLocator.current(in: root),
            PDDConversationLocator(domIdentifier: nil, nickname: "山**川")
        )
    }
}
