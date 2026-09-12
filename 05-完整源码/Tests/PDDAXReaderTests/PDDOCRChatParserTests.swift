import CoreGraphics
import XCTest
@testable import PDDAXReader

final class PDDOCRChatParserTests: XCTestCase {
    func testParsesLeftCustomerAndRightServiceWithNearestPrecedingTime() {
        let lines = [
            line("2026年08月29日 09:31:52", 210, 10, 100, 14),
            line("你好", 18, 45, 42, 20),
            line("您好老板", 340, 90, 78, 20),
            line("已读", 335, 113, 30, 13)
        ]
        let parsed = PDDOCRChatParser.parse(
            uid: "GZC-000001", lines: lines, imageSize: CGSize(width: 440, height: 300)
        )
        XCTAssertEqual(parsed.map(\.sender), [.customer, .service])
        XCTAssertEqual(parsed.map(\.text), ["你好", "您好老板"])
        XCTAssertEqual(parsed.first?.timestamp, "2026-08-29 09:31:52")
    }

    func testRejectsCenteredSystemAndToolbarNoise() {
        let lines = [
            line("格志打印机小冯 将该会话转移给 格志打印机小甘", 90, 30, 260, 15),
            line("邀请关注", 180, 250, 70, 16),
            line("客户问题", 18, 100, 80, 20)
        ]
        let parsed = PDDOCRChatParser.parse(
            uid: "GZC-000001", lines: lines, imageSize: CGSize(width: 440, height: 300)
        )
        XCTAssertEqual(parsed.map(\.text), ["客户问题"])
    }

    func testRealPDDProbeKeepsOnlyBubbleTextAndDropsWatermarksAvatarsNamesAndWrappedTransferNotice() {
        let lines = [
            line("格志打印机小冯 将该会话转移给 格志打印机小甘，并留言：催售", 183, 56, 686, 23),
            line("后处理", 182, 91, 74, 24),
            PDDOCRLine(text: "信方旗舰店", box: CGRect(x: 0, y: 61, width: 143, height: 100), confidence: 0.92),
            line("格志打印机小甘", 769, 208, 169, 27),
            line("Grozziie", 957, 228, 82, 23),
            line("格志", 979, 244, 32, 18),
            line("1", 898, 278, 16, 25),
            line("已读", 815, 296, 51, 26),
            PDDOCRLine(text: "0", box: CGRect(x: 19, y: 364, width: 87, height: 90), confidence: 0.26),
            line("你好", 143, 393, 60, 34),
            line("格志官方旗舰店", 409, 380, 212, 128)
        ]
        let parsed = PDDOCRChatParser.parse(
            uid: "GZC-000001", lines: lines, imageSize: CGSize(width: 1076, height: 561)
        )
        XCTAssertEqual(parsed.map(\.sender), [.service, .customer])
        XCTAssertEqual(parsed.map(\.text), ["1", "你好"])
    }

    func testRightEdgeFlagshipWatermarkCannotMergeIntoServiceBubble() {
        let lines = [
            line("旗舰", 1004, 76, 70, 52),
            line("1", 899, 175, 15, 27),
            line("你好", 142, 289, 60, 34)
        ]

        let parsed = PDDOCRChatParser.parse(
            uid: "GZC-000001", lines: lines, imageSize: CGSize(width: 1076, height: 617)
        )

        XCTAssertEqual(parsed.map(\.sender), [.service, .customer])
        XCTAssertEqual(parsed.map(\.text), ["1", "你好"])
    }

    func testLongRightAnchoredServiceBubbleSurvivesCenterCrossingAndTallWatermarkNoise() {
        let lines = [
            line("志官方旗舰", 930, 70, 147, 102),
            line("您好，请问有什么可以帮您？如需咨询格志或加", 306, 211, 609, 32),
            line("普威产品，请告诉我产品型号和具体问题。", 309, 254, 514, 27),
            line("未读", 219, 278, 56, 30)
        ]

        let parsed = PDDOCRChatParser.parse(
            uid: "GZC-000001", lines: lines, imageSize: CGSize(width: 1076, height: 617)
        )

        XCTAssertEqual(parsed.map(\.sender), [.service])
        XCTAssertEqual(
            parsed.map(\.text),
            ["您好,请问有什么可以帮您?如需咨询格志或加普威产品,请告诉我产品型号和具体问题。"]
        )
    }

    func testBottomServiceBubbleIsKeptWhileToolbarBelowItIsExcluded() {
        let lines = [
            line("底部回复第一行", 306, 520, 500, 28),
            line("底部回复第二行", 309, 557, 514, 25),
            line("邀请下单", 776, 595, 106, 20)
        ]

        let parsed = PDDOCRChatParser.parse(
            uid: "GZC-000001", lines: lines, imageSize: CGSize(width: 1076, height: 617)
        )

        XCTAssertEqual(parsed.map(\.sender), [.service])
        XCTAssertEqual(parsed.map(\.text), ["底部回复第一行底部回复第二行"])
    }

    func testRealShortFinalServiceLineContinuesBubbleAndToolbarBadgesStayExcluded() {
        let lines = [
            line("您好，暂时无法理解您的具体需求。请您重新简", 305, 376, 609, 31),
            line("要说明需要咨询的问题；如为产品故障，请提供", 306, 417, 609, 31),
            line("产品型号和具体故障现象。", 305, 456, 322, 30),
            line("已读", 220, 476, 55, 31),
            line("新", 539, 550, 30, 28),
            line("新", 752, 546, 27, 29),
            line("邀请关注", 660, 558, 112, 32),
            line("邀请下单", 773, 558, 106, 32)
        ]

        let parsed = PDDOCRChatParser.parse(
            uid: "GZC-000001", lines: lines, imageSize: CGSize(width: 1077, height: 617)
        )

        XCTAssertEqual(parsed.map(\.sender), [.service])
        XCTAssertEqual(
            parsed.map(\.text),
            ["您好,暂时无法理解您的具体需求。请您重新简要说明需要咨询的问题;如为产品故障,请提供产品型号和具体故障现象。"]
        )
    }

    func testPlatformDisputeGuidanceOverlayCannotBecomeCustomerMessages() {
        let lines = [
            line("当交易双方产生分歧或争议时，商家需主动查明事实真相并予以说明。", 142, 40, 560, 30),
            line("1.主动调查：当消费者反馈商品与描述不符、存在瑕疵、发错货等争议问题时", 142, 78, 650, 30),
            line("2.结论告知：基于调查结果，商家应主动向消费者提供明确、负责任的答复。", 142, 116, 650, 30),
            line("真实客户问题", 142, 190, 180, 34)
        ]

        let parsed = PDDOCRChatParser.parse(
            uid: "GZC-000001", lines: lines, imageSize: CGSize(width: 1077, height: 617)
        )

        XCTAssertEqual(parsed.map(\.text), ["真实客户问题"])
    }

    func testCopyActionBesideCustomerBubbleIsNotParsedAsAnotherCustomerMessage() {
        let lines = [
            line("tp732", 70, 373, 37, 15),
            line("复制", 125, 377, 29, 15)
        ]

        let parsed = PDDOCRChatParser.parse(
            uid: "PDD-NAME-a1366828d04c70214f9fcb06",
            lines: lines,
            imageSize: CGSize(width: 1_156, height: 608)
        )

        XCTAssertEqual(parsed.map(\.sender), [.customer])
        XCTAssertEqual(parsed.map(\.text), ["tp732"])
    }

    func testTrailingCopyTextIsRemovedFromCustomerMessage() {
        let parsed = PDDOCRChatParser.parse(
            uid: "PDD-NAME-a1366828d04c70214f9fcb06",
            lines: [line("tp732复制", 70, 373, 95, 15)],
            imageSize: CGSize(width: 1_156, height: 608)
        )

        XCTAssertEqual(parsed.map(\.text), ["tp732"])
    }

    func testCopyTextInsideCustomerMessageIsPreserved() {
        let parsed = PDDOCRChatParser.parse(
            uid: "PDD-NAME-a1366828d04c70214f9fcb06",
            lines: [line("请复制驱动给我", 70, 373, 150, 15)],
            imageSize: CGSize(width: 1_156, height: 608)
        )

        XCTAssertEqual(parsed.map(\.text), ["请复制驱动给我"])
    }

    func testCustomerMessageContainingOnlyCopyTextIsDiscarded() {
        let parsed = PDDOCRChatParser.parse(
            uid: "PDD-NAME-a1366828d04c70214f9fcb06",
            lines: [line("复制", 70, 373, 29, 15)],
            imageSize: CGSize(width: 1_156, height: 608)
        )

        XCTAssertTrue(parsed.isEmpty)
    }

    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> PDDOCRLine {
        PDDOCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: height), confidence: 0.98)
    }
}
