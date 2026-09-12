import XCTest
@testable import PDDAXReader

final class PDDChatParserTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_777_000_000)

    func testParsesCustomerTextAndTimestampFromOnemsg() {
        let root = message(
            id: "middlePanel_list_1756348090123",
            senderClass: "[buyer-item]",
            contentChildren: [value("这不是上线了吗")],
            time: "20:08"
        )

        let result = PDDChatParser.parse(root: root, capturedAt: capturedAt)

        XCTAssertEqual(result.diagnostics, [])
        XCTAssertEqual(result.messages, [
            PDDChatMessage(
                id: "middlePanel_list_1756348090123",
                sender: .customer,
                content: "这不是上线了吗",
                displayTime: "20:08",
                kind: .text,
                capturedAt: capturedAt
            )
        ])
    }

    func testParsesServiceMessageAndIgnoresAvatarAndSidebarURLs() {
        let chat = message(
            id: "middlePanel_list_1756348090999",
            senderClass: "[cs-item, isread]",
            contentChildren: [
                AXNodeSnapshot(role: "AXLink", attributes: [("AXValue", "https://support.example/answer")]),
                value("请再试一次")
            ],
            extraChildren: [
                AXNodeSnapshot(
                    role: "AXImage",
                    attributes: [
                        ("AXDOMClassList", "[avatar]"),
                        ("AXURL", "https://avatar.example/user.png")
                    ]
                )
            ]
        )
        let root = AXNodeSnapshot(
            role: "AXWindow",
            children: [
                AXNodeSnapshot(
                    role: "AXGroup",
                    attributes: [("AXDOMClassList", "[product-sidebar]")],
                    children: [value("https://shop.example/product")]
                ),
                chat
            ]
        )

        let result = PDDChatParser.parse(root: root, capturedAt: capturedAt)

        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].sender, .service)
        XCTAssertEqual(result.messages[0].kind, .link)
        XCTAssertEqual(result.messages[0].content, "https://support.example/answer\n请再试一次")
        XCTAssertFalse(result.messages[0].content.contains("avatar.example"))
        XCTAssertFalse(result.messages[0].content.contains("shop.example"))
    }

    func testRepresentsImageWithoutReadingItsBytes() {
        let root = message(
            id: "middlePanel_list_1756348091111",
            senderClass: "[buyer-item]",
            contentClass: "[msg-content, image-msg, buyer-img-st]",
            contentChildren: [
                AXNodeSnapshot(role: "AXImage", attributes: [("AXURL", "https://image.example/original.png")])
            ]
        )

        let result = PDDChatParser.parse(root: root, capturedAt: capturedAt)

        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].kind, .image)
        XCTAssertEqual(result.messages[0].content, "[图片]")
    }

    func testRepresentsExplicitCustomerVideoWithoutReadingItsBytes() {
        let root = message(
            id: "middlePanel_list_1756348092222",
            senderClass: "[buyer-item]",
            contentClass: "[msg-content, image-msg, video-msg]",
            contentChildren: [value("00:08")]
        )

        let parsed = PDDChatParser.parse(root: root, capturedAt: capturedAt).messages

        XCTAssertEqual(parsed.first?.kind, .video)
        XCTAssertEqual(parsed.first?.content, "[视频]")
    }

    func testRepresentsVideoNestedDirectlyUnderSenderWhenContentWrapperIsMissing() {
        func directVideo(id: String, senderClass: String) -> AXNodeSnapshot {
            AXNodeSnapshot(
                role: "AXGroup",
                attributes: [
                    ("AXDOMClassList", "[clearfix, onemsg]"),
                    ("AXDOMIdentifier", id)
                ],
                children: [
                    AXNodeSnapshot(
                        role: "AXGroup",
                        attributes: [("AXDOMClassList", senderClass)],
                        children: [
                            AXNodeSnapshot(
                                role: "AXGroup",
                                attributes: [("AXDOMClassList", "[video-content]")],
                                children: [
                                    AXNodeSnapshot(
                                        role: "AXGroup",
                                        attributes: [("AXDOMClassList", "[video-box]")],
                                        children: [value("00:08")]
                                    )
                                ]
                            )
                        ]
                    )
                ]
            )
        }
        let root = AXNodeSnapshot(role: "AXWindow", children: [
            directVideo(id: "middlePanel_list_1788365091920", senderClass: "[buyer-item]"),
            directVideo(id: "middlePanel_list_1788365091921", senderClass: "[cs-item]")
        ])

        let parsed = PDDChatParser.parse(root: root, capturedAt: capturedAt).messages

        XCTAssertEqual(parsed.map(\.id), [
            "middlePanel_list_1788365091920",
            "middlePanel_list_1788365091921"
        ])
        XCTAssertEqual(parsed.map(\.sender), [.customer, .service])
        XCTAssertEqual(parsed.map(\.kind), [.video, .video])
        XCTAssertEqual(parsed.map(\.content), ["[视频]", "[视频]"])
    }

    func testRepresentsDurationOverThumbnailAsVideoButKeepsPlainThumbnailAsImage() {
        let video = message(
            id: "middlePanel_list_1756348093333",
            senderClass: "[buyer-item]",
            contentClass: "[msg-content, image-msg]",
            contentChildren: [
                AXNodeSnapshot(role: "AXImage", attributes: [("AXURL", "/thumb.jpeg")]),
                value("0:08")
            ]
        )
        let image = message(
            id: "middlePanel_list_1756348094444",
            senderClass: "[buyer-item]",
            contentClass: "[msg-content, image-msg]",
            contentChildren: [AXNodeSnapshot(role: "AXImage", attributes: [("AXURL", "/plain.jpeg")])]
        )

        let parsed = PDDChatParser.parse(
            root: AXNodeSnapshot(role: "AXWindow", children: [video, image]),
            capturedAt: capturedAt
        ).messages

        XCTAssertEqual(parsed.map(\.kind), [.video, .image])
        XCTAssertEqual(parsed.map(\.content), ["[视频]", "[图片]"])
    }

    func testFiltersAXErrorsAndReadStatusOutsideMessageContentBox() {
        let root = AXNodeSnapshot(
            role: "AXGroup",
            attributes: [
                ("AXDOMClassList", "[clearfix, onemsg]"),
                ("AXDOMIdentifier", "middlePanel_list_clean")
            ],
            children: [
                AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[cs-item, isread]")]),
                AXNodeSnapshot(
                    role: "AXGroup",
                    attributes: [
                        ("AXDOMClassList", "[msg-content]"),
                        ("AXURL", "<AX error -25212>"),
                        ("AXValue", "")
                    ],
                    children: [
                        AXNodeSnapshot(
                            role: "AXGroup",
                            attributes: [
                                ("AXDOMClassList", "[msg-content-box]"),
                                ("AXURL", "<AX error -25212>")
                            ],
                            children: [value("没有上线")]
                        ),
                        value("已读")
                    ]
                ),
                AXNodeSnapshot(
                    role: "AXGroup",
                    attributes: [("AXDOMClassList", "[message-time]")],
                    children: [value("<AX error -25212>")]
                )
            ]
        )

        let result = PDDChatParser.parse(root: root, capturedAt: capturedAt)

        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].content, "没有上线")
        XCTAssertEqual(result.messages[0].kind, .text)
        XCTAssertNil(result.messages[0].displayTime)
    }

    func testSkipsAmbiguousSenderAndEmptyMessageWithDiagnostics() {
        let ambiguous = AXNodeSnapshot(
            role: "AXGroup",
            attributes: [
                ("AXDOMClassList", "[clearfix, onemsg]"),
                ("AXDOMIdentifier", "middlePanel_list_bad-sender")
            ],
            children: [
                AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[buyer-item]")]),
                AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[cs-item]")]),
                AXNodeSnapshot(
                    role: "AXGroup",
                    attributes: [("AXDOMClassList", "[msg-content]")],
                    children: [value("冲突")]
                )
            ]
        )
        let empty = message(
            id: "middlePanel_list_empty",
            senderClass: "[buyer-item]",
            contentChildren: []
        )
        let root = AXNodeSnapshot(role: "AXWindow", children: [ambiguous, empty])

        let result = PDDChatParser.parse(root: root, capturedAt: capturedAt)

        XCTAssertTrue(result.messages.isEmpty)
        XCTAssertEqual(result.diagnostics.count, 2)
    }

    func testMissingDOMIdentifierUsesStableFallbackID() {
        let root = message(
            id: nil,
            senderClass: "[buyer-item]",
            contentChildren: [value("稳定消息")],
            time: "昨天 18:00"
        )

        let first = PDDChatParser.parse(root: root, capturedAt: capturedAt).messages.first
        let second = PDDChatParser.parse(
            root: root,
            capturedAt: capturedAt.addingTimeInterval(60)
        ).messages.first

        XCTAssertNotNil(first)
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertTrue(first?.id.hasPrefix("fallback-") == true)
        XCTAssertEqual(first?.capturedAt, capturedAt)
        XCTAssertEqual(second?.capturedAt, capturedAt.addingTimeInterval(60))
    }

    private func message(
        id: String?,
        senderClass: String,
        contentClass: String = "[msg-content, msg-content-box]",
        contentChildren: [AXNodeSnapshot],
        time: String? = nil,
        extraChildren: [AXNodeSnapshot] = []
    ) -> AXNodeSnapshot {
        var attributes = [("AXDOMClassList", "[clearfix, onemsg]")]
        if let id { attributes.append(("AXDOMIdentifier", id)) }

        var children = [
            AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", senderClass)]),
            AXNodeSnapshot(
                role: "AXGroup",
                attributes: [("AXDOMClassList", contentClass)],
                children: contentChildren
            )
        ]
        if let time {
            children.append(
                AXNodeSnapshot(
                    role: "AXGroup",
                    attributes: [("AXDOMClassList", "[message-time]")],
                    children: [value(time)]
                )
            )
        }
        children.append(contentsOf: extraChildren)
        return AXNodeSnapshot(role: "AXGroup", attributes: attributes, children: children)
    }

    private func value(_ text: String) -> AXNodeSnapshot {
        AXNodeSnapshot(role: "AXStaticText", attributes: [("AXValue", text)])
    }
}
