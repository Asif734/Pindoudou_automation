import XCTest
@testable import PDDAXReader

final class AXDumpFormatterTests: XCTestCase {
    func testFormatPreservesHierarchyAttributesActionsAndChineseText() {
        let root = AXNodeSnapshot(
            role: "AXWindow",
            attributes: [("AXTitle", "拼多多商家工作台")],
            actions: ["AXRaise"],
            children: [
                AXNodeSnapshot(
                    role: "AXGroup",
                    attributes: [("AXDescription", "聊天内容")],
                    children: [
                        AXNodeSnapshot(
                            role: "AXStaticText",
                            attributes: [("AXValue", "这不是上线了吗")]
                        )
                    ]
                )
            ]
        )

        XCTAssertEqual(
            AXDumpFormatter.format(root: root),
            """
            AXWindow
              @AXTitle: 拼多多商家工作台
              actions: AXRaise
              AXGroup
                @AXDescription: 聊天内容
                AXStaticText
                  @AXValue: 这不是上线了吗
            """
        )
    }

    func testFormatKeepsMultilineValuesReadable() {
        let root = AXNodeSnapshot(
            role: "AXStaticText",
            attributes: [("AXValue", "第一行\n第二行")]
        )

        XCTAssertEqual(
            AXDumpFormatter.format(root: root),
            """
            AXStaticText
              @AXValue: 第一行
                第二行
            """
        )
    }
}
