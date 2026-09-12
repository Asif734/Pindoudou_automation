import XCTest
@testable import PDDAXReader

final class PDDAXVisibleMessageEvidenceTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_777_000_000)

    func testExtractsAllVisibleMessagesInAXOrder() {
        let root = AXNodeSnapshot(role: "AXWindow", children: [
            message(id: "middlePanel_list_1", senderClass: "[buyer-item]", text: "客户文字"),
            message(id: "middlePanel_list_2", senderClass: "[cs-item]", text: "客服回复"),
            message(
                id: "middlePanel_list_3",
                senderClass: "[buyer-item]",
                contentClass: "[msg-content, image-msg, buyer-img-st]",
                text: nil
            )
        ])

        let evidence = PDDAXVisibleMessageEvidence.extract(root: root, capturedAt: capturedAt)

        XCTAssertEqual(evidence.messageNodeCount, 3)
        XCTAssertEqual(evidence.messages.map(\.id), [
            "middlePanel_list_1", "middlePanel_list_2", "middlePanel_list_3"
        ])
        XCTAssertEqual(evidence.messages.map(\.sender), [.customer, .service, .customer])
        XCTAssertEqual(evidence.messages.map(\.kind), [.text, .text, .image])
        XCTAssertEqual(evidence.messages.map(\.content), ["客户文字", "客服回复", "[图片]"])
        XCTAssertTrue(evidence.isStructurallyValid)
        XCTAssertTrue(evidence.diagnostics.isEmpty)
        XCTAssertFalse(evidence.fingerprint.isEmpty)
    }

    func testFingerprintIsStableAcrossCaptureTimesAndChangesWithVisibleContent() {
        let original = AXNodeSnapshot(role: "AXWindow", children: [
            message(id: "middlePanel_list_1", senderClass: "[buyer-item]", text: "第一条")
        ])
        let changed = AXNodeSnapshot(role: "AXWindow", children: [
            message(id: "middlePanel_list_1", senderClass: "[buyer-item]", text: "第二条")
        ])

        let first = PDDAXVisibleMessageEvidence.extract(root: original, capturedAt: capturedAt)
        let second = PDDAXVisibleMessageEvidence.extract(
            root: original,
            capturedAt: capturedAt.addingTimeInterval(60)
        )
        let third = PDDAXVisibleMessageEvidence.extract(root: changed, capturedAt: capturedAt)

        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertNotEqual(first.fingerprint, third.fingerprint)
    }

    func testFingerprintIgnoresIncidentalWhitespaceChanges() {
        let spaces = AXNodeSnapshot(role: "AXWindow", children: [
            message(id: "middlePanel_list_1", senderClass: "[buyer-item]", text: "客户  问题")
        ])
        let lineBreak = AXNodeSnapshot(role: "AXWindow", children: [
            message(id: "middlePanel_list_1", senderClass: "[buyer-item]", text: "客户\n问题")
        ])

        let first = PDDAXVisibleMessageEvidence.extract(root: spaces, capturedAt: capturedAt)
        let second = PDDAXVisibleMessageEvidence.extract(root: lineBreak, capturedAt: capturedAt)

        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    func testRejectsMissingEmptyAndAmbiguousMessageStructures() {
        let missing = PDDAXVisibleMessageEvidence.extract(
            root: AXNodeSnapshot(role: "AXWindow"),
            capturedAt: capturedAt
        )
        let empty = PDDAXVisibleMessageEvidence.extract(
            root: message(id: "middlePanel_list_empty", senderClass: "[buyer-item]", text: nil),
            capturedAt: capturedAt
        )
        let ambiguousNode = AXNodeSnapshot(
            role: "AXGroup",
            attributes: [
                ("AXDOMClassList", "[clearfix, onemsg]"),
                ("AXDOMIdentifier", "middlePanel_list_ambiguous")
            ],
            children: [
                AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[buyer-item]")]),
                AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[cs-item]")]),
                AXNodeSnapshot(
                    role: "AXGroup",
                    attributes: [("AXDOMClassList", "[msg-content, msg-content-box]")],
                    children: [value("冲突")]
                )
            ]
        )
        let ambiguous = PDDAXVisibleMessageEvidence.extract(
            root: AXNodeSnapshot(role: "AXWindow", children: [ambiguousNode]),
            capturedAt: capturedAt
        )

        XCTAssertEqual(missing.messageNodeCount, 0)
        XCTAssertFalse(missing.isStructurallyValid)
        XCTAssertEqual(empty.messageNodeCount, 1)
        XCTAssertFalse(empty.isStructurallyValid)
        XCTAssertEqual(ambiguous.messageNodeCount, 1)
        XCTAssertFalse(ambiguous.isStructurallyValid)
        XCTAssertTrue(ambiguous.diagnostics.contains { $0.contains("同时存在客户和客服标记") })
    }

    private func message(
        id: String,
        senderClass: String,
        contentClass: String = "[msg-content, msg-content-box]",
        text: String?
    ) -> AXNodeSnapshot {
        var contentChildren: [AXNodeSnapshot] = []
        if let text { contentChildren = [value(text)] }
        return AXNodeSnapshot(
            role: "AXGroup",
            attributes: [
                ("AXDOMClassList", "[clearfix, onemsg]"),
                ("AXDOMIdentifier", id)
            ],
            children: [
                AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", senderClass)]),
                AXNodeSnapshot(
                    role: "AXGroup",
                    attributes: [("AXDOMClassList", contentClass)],
                    children: contentChildren
                )
            ]
        )
    }

    private func value(_ text: String) -> AXNodeSnapshot {
        AXNodeSnapshot(role: "AXStaticText", attributes: [("AXValue", text)])
    }
}
