import AppKit
import XCTest
@testable import PDDAXReader

@MainActor
final class PDDTransferMenuControlsTests: XCTestCase {
    private let anchor = CGRect(x: 900, y: 350, width: 40, height: 20)

    func testAXSubmissionReReadsTheSendControlAfterReasonChangesTree() async throws {
        let reason = node(10, label: "无原因直接转移", frame: .init(x: 850, y: 600, width: 140, height: 20))
        let backend = MenuBackend(nodes: dialog + [reason])
        backend.onPress = { id in
            if id.rawValue == 10 {
                backend.nodes = self.dialog + [self.node(51, label: "发送", frame: .init(x: 1040, y: 600, width: 35, height: 20))]
            }
        }
        let reader = MenuReader()
        let clicker = MenuClicker()
        let submitter = PDDTransferMenuSubmitter(backend: backend, clicker: clicker, reader: reader, sleep: { _ in })
        try await submitter.submit(uid: "customer", anchor: anchor, lease: lease())
        XCTAssertEqual(backend.pressed.map(\.rawValue), [10, 51])
        XCTAssertEqual(reader.calls, 0)
        XCTAssertTrue(clicker.points.isEmpty)
    }

    func testHiddenAXMenuUsesFreshTextBoundsAndNeverClicksComposerSend() async throws {
        let backend = MenuBackend(nodes: dialog + [node(99, label: "发送", frame: .init(x: 1100, y: 850, width: 30, height: 20))])
        let reader = MenuReader()
        reader.results = [menu(y: 600), menu(y: 620) + [line("发送", x: 1070, y: 620), line("发送", x: 1100, y: 850)]]
        let clicker = MenuClicker()
        let submitter = PDDTransferMenuSubmitter(backend: backend, clicker: clicker, reader: reader, sleep: { _ in })
        try await submitter.submit(uid: "customer", anchor: anchor, lease: lease())
        XCTAssertEqual(clicker.points, [.init(x: 920, y: 610), .init(x: 1085, y: 630)])
        XCTAssertTrue(backend.pressed.isEmpty)
        XCTAssertEqual(reader.calls, 2)
    }

    func testUnknownOrAmbiguousMenuDoesNotUseOldOffsets() async throws {
        let backend = MenuBackend(nodes: dialog)
        let reader = MenuReader()
        reader.results = [menu(y: 600), menu(y: 600) + [line("发送", x: 1040, y: 600), line("发送", x: 1080, y: 600)]]
        let clicker = MenuClicker()
        let submitter = PDDTransferMenuSubmitter(backend: backend, clicker: clicker, reader: reader, sleep: { _ in })
        do { try await submitter.submit(uid: "customer", anchor: anchor, lease: lease()); XCTFail("ambiguous send must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("发送按钮")) }
        XCTAssertEqual(clicker.points.count, 1, "Only the verified reason was clicked")
    }

    func testDirectSubmissionAfterReasonDoesNotClickAgain() async throws {
        let backend = MenuBackend(nodes: dialog)
        let reader = MenuReader(); reader.results = [menu(y: 600)]
        let clicker = MenuClicker(); clicker.onClick = { backend.nodes = [] }
        let submitter = PDDTransferMenuSubmitter(backend: backend, clicker: clicker, reader: reader, sleep: { _ in })
        try await submitter.submit(uid: "customer", anchor: anchor, lease: lease())
        XCTAssertEqual(clicker.points.count, 1)
        XCTAssertEqual(reader.calls, 1)
    }

    func testLiveCombinedAXRowUsesOnlyItsOCRSendEvenWhenOtherReasonsAreNotRecognized() async throws {
        let backend = MenuBackend(nodes: dialog + combinedMenu())
        let reader = MenuReader()
        // The disabled custom-reason footer and chat composer are also visible.
        reader.results = [[line("发送", x: 1070, y: 600), line("发送", x: 1070, y: 680),
                           line("发送", x: 1100, y: 850)]]
        let clicker = MenuClicker()
        let submitter = PDDTransferMenuSubmitter(backend: backend, clicker: clicker, reader: reader, sleep: { _ in })
        try await submitter.submit(uid: "customer", anchor: anchor, lease: lease())
        XCTAssertEqual(clicker.points, [.init(x: 1085, y: 610)])
        XCTAssertTrue(backend.pressed.isEmpty, "Never press the combined text as if it were Send")
        XCTAssertEqual(reader.calls, 1)
    }

    func testCombinedAXDescriptionWithSeparateSendChildUsesAXWithoutOCR() async throws {
        let backend = MenuBackend(nodes: dialog + combinedMenu(descriptionOnly: true, childSend: true))
        let reader = MenuReader(); let clicker = MenuClicker()
        let submitter = PDDTransferMenuSubmitter(backend: backend, clicker: clicker, reader: reader, sleep: { _ in })
        try await submitter.submit(uid: "customer", anchor: anchor, lease: lease())
        XCTAssertEqual(backend.pressed.map(\.rawValue), [205])
        XCTAssertTrue(clicker.points.isEmpty)
        XCTAssertEqual(reader.calls, 0)
    }

    func testSeparateReasonCanBecomeCombinedAndMoveBeforeSend() async throws {
        let reason = node(10, label: "无原因直接转移", frame: .init(x: 850, y: 580, width: 140, height: 20))
        let backend = MenuBackend(nodes: dialog + [reason])
        backend.onPress = { _ in backend.nodes = self.dialog + self.combinedMenu(rowY: 620) }
        let reader = MenuReader(); reader.results = [[line("发送", x: 1070, y: 620)]]
        let clicker = MenuClicker()
        let submitter = PDDTransferMenuSubmitter(backend: backend, clicker: clicker, reader: reader, sleep: { _ in })
        try await submitter.submit(uid: "customer", anchor: anchor, lease: lease())
        XCTAssertEqual(backend.pressed.map(\.rawValue), [10])
        XCTAssertEqual(clicker.points, [.init(x: 1085, y: 630)])
    }

    func testCombinedAXRowRejectsFooterOnlyAndSavesFailureCandidates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = MenuBackend(nodes: dialog + combinedMenu())
        let reader = MenuReader(); reader.results = [[line("发送", x: 1070, y: 680)]]
        let clicker = MenuClicker()
        let submitter = PDDTransferMenuSubmitter(backend: backend, clicker: clicker, reader: reader,
            logRoot: root, sleep: { _ in })
        do { try await submitter.submit(uid: "customer", anchor: anchor, lease: lease()); XCTFail("footer is not the transfer Send") }
        catch { XCTAssertTrue(error.localizedDescription.contains("发送按钮")) }
        XCTAssertTrue(clicker.points.isEmpty)
        XCTAssertTrue(backend.pressed.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("logs/transfer-diagnostics"),
            includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 4)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: files[0])) as? [String: Any])
        XCTAssertEqual(record["phase"] as? String, "send")
        XCTAssertFalse(try XCTUnwrap(record["axCandidates"] as? [[String: Any]]).isEmpty)
        XCTAssertEqual((record["ocrCandidates"] as? [[String: Any]])?.count, 1)
    }

    func testCombinedLabelInChatOrTooltipDoesNotEstablishASelectedMenuRow() {
        let combined = node(10, label: "无原因直接转移 发送", frame: .init(x: 850, y: 600, width: 250, height: 20))
        XCTAssertNil(PDDTransferMenuControls.combinedReasonRow(in: dialog + [combined], anchor: anchor))
        let tooltip = node(11, label: "催发货 发送 换货问题 发送 无原因直接转移 发送", frame: combined.frame)
        XCTAssertNil(PDDTransferMenuControls.combinedReasonRow(in: dialog + [tooltip], anchor: anchor))
    }

    func testCombinedMenuRejectsAmbiguousSendAndLowConfidence() {
        let row = CGRect(x: 850, y: 600, width: 250, height: 20)
        XCTAssertNil(PDDTransferMenuControls.combinedRowSend(in: [line("发送", x: 1040, y: 600),
            line("发送", x: 1070, y: 600)], row: row))
        XCTAssertNil(PDDTransferMenuControls.combinedRowSend(in: [.init(text: "发送",
            box: .init(x: 1070, y: 600, width: 30, height: 20), confidence: 0.3)], row: row))
    }

    func testCombinedRowMovingDuringOCRWaitsForFreshMatchingBounds() async throws {
        let backend = MenuBackend(nodes: dialog + combinedMenu())
        let reader = MenuReader()
        reader.results = [menu(y: 600) + [line("发送", x: 1070, y: 600)],
                          menu(y: 620) + [line("发送", x: 1070, y: 620)]]
        reader.onRead = { backend.nodes = self.dialog + self.combinedMenu(rowY: 620) }
        let clicker = MenuClicker()
        let submitter = PDDTransferMenuSubmitter(backend: backend, clicker: clicker, reader: reader, sleep: { _ in })
        try await submitter.submit(uid: "customer", anchor: anchor, lease: lease())
        XCTAssertEqual(reader.calls, 2)
        XCTAssertEqual(clicker.points, [.init(x: 1085, y: 630)])
    }

    func testRevokedLeaseDuringCombinedRowOCRPreventsSend() async throws {
        let registry = UIOperationLeaseRegistry(); let operation = registry.acquire(uid: "customer")
        let backend = MenuBackend(nodes: dialog + combinedMenu())
        let reader = MenuReader(); reader.results = [[line("发送", x: 1070, y: 600)]]
        reader.onRead = { registry.revoke(operationID: operation.operationID) }
        let clicker = MenuClicker()
        let submitter = PDDTransferMenuSubmitter(backend: backend, clicker: clicker, reader: reader, sleep: { _ in })
        do { try await submitter.submit(uid: "customer", anchor: anchor, lease: operation); XCTFail("revoked operation") } catch {}
        XCTAssertTrue(clicker.points.isEmpty)
        XCTAssertTrue(backend.pressed.isEmpty)
    }

    func testRecordedHiddenMenuRearmsHoverBeforeAcceptingSameRowSend() async throws {
        // 2026-11-12 live failure: reason at y=645; only footer/composer Send
        // at y=692.5/864. Neither is authorized by the selected reason.
        let backend = MenuBackend(nodes: dialog)
        let reason = PDDOCRLine(text: "无原因直接转移", box: .init(x: 889, y: 645, width: 100, height: 16.3), confidence: 1)
        let observed = [reason, line("催发货", x: 889, y: 444.5), line("换货问题", x: 889, y: 604.8),
            line("发送", x: 1039, y: 692.5), line("发送", x: 1031.5, y: 864)]
        XCTAssertNil(PDDTransferMenuControls.sendControl(in: observed, reason: reason.box))
        let reader = MenuReader(); reader.results = [observed, observed]
        let clicker = MenuClicker()
        clicker.onHover = { reader.results = [observed + [self.line("发送", x: 1039, y: 645)]] }
        let submitter = PDDTransferMenuSubmitter(backend: backend, clicker: clicker, reader: reader, sleep: { _ in })
        try await submitter.submit(uid: "customer", anchor: .init(x: 967, y: 401, width: 24, height: 18), lease: lease())
        XCTAssertEqual(clicker.hovers, [.init(x: 939, y: 653.15)])
        XCTAssertEqual(clicker.points.count, 2)
        XCTAssertEqual(clicker.points.last, .init(x: 1054, y: 655))
        XCTAssertFalse(clicker.points.contains(.init(x: 1054, y: 702.5)))
    }

    func testRecordedMenuWithOnlyLowerSendNeverCommitsDespiteHoverRetries() async throws {
        let backend = MenuBackend(nodes: dialog)
        let reader = MenuReader(); reader.results = [menu(y: 645) + [line("发送", x: 1040, y: 692.5)]]
        let clicker = MenuClicker()
        let submitter = PDDTransferMenuSubmitter(backend: backend, clicker: clicker, reader: reader, sleep: { _ in })
        do { try await submitter.submit(uid: "customer", anchor: anchor, lease: lease()); XCTFail("Lower Send remains unverified") } catch {}
        XCTAssertEqual(clicker.points.count, 1)
        XCTAssertEqual(clicker.hovers.count, 4)
    }

    private func combinedMenu(rowY: CGFloat = 600, descriptionOnly: Bool = false,
                              childSend: Bool = false) -> [PDDAXSemanticNode<AXElementToken>] {
        // Real Chromium layout: a portal menu, other reasons, one merged text
        // row and a different custom-reason footer Send.
        func item(_ id: Int, parent: Int?, role: String = "AXStaticText", value: String?,
                  frame: CGRect, description: String? = nil, press: Bool = false) -> PDDAXSemanticNode<AXElementToken> {
            .init(id: .init(rawValue: id), parentID: parent.map { .init(rawValue: $0) }, role: role,
                value: value, title: nil, domIdentifier: nil, domClasses: [],
                actionNames: press ? ["AXPress"] : [], isSettable: false, frame: frame,
                accessibilityDescription: description)
        }
        var nodes = [
            item(200, parent: nil, role: "AXGroup", value: nil,
                frame: .init(x: 830, y: 300, width: 300, height: 420)),
            item(201, parent: 200, value: "催发货", frame: .init(x: 850, y: 400, width: 80, height: 20)),
            item(202, parent: 200, value: "换货问题", frame: .init(x: 850, y: 500, width: 80, height: 20)),
            item(203, parent: 200, role: "AXGroup", value: nil,
                frame: .init(x: 840, y: rowY - 10, width: 270, height: 40)),
            item(204, parent: 203, value: descriptionOnly ? nil : "无原因直接转移 发送",
                frame: .init(x: 850, y: rowY, width: 250, height: 20),
                description: descriptionOnly ? "无原因直接转移 发送" : nil),
            item(206, parent: 200, value: "发送", frame: .init(x: 1070, y: 680, width: 30, height: 20), press: true)
        ]
        if childSend { nodes.append(item(205, parent: 203, value: "发送",
            frame: .init(x: 1070, y: rowY, width: 30, height: 20), press: true)) }
        return nodes
    }

    func testRevokedLeaseDuringRecognitionPreventsAnyClick() async throws {
        let registry = UIOperationLeaseRegistry(); let lease = registry.acquire(uid: "customer")
        let backend = MenuBackend(nodes: dialog)
        let reader = MenuReader(); reader.results = [menu(y: 600)]
        reader.onRead = { registry.revoke(operationID: lease.operationID) }
        let clicker = MenuClicker()
        let submitter = PDDTransferMenuSubmitter(backend: backend, clicker: clicker, reader: reader, sleep: { _ in })
        do { try await submitter.submit(uid: "customer", anchor: anchor, lease: lease); XCTFail("expected revocation") } catch {}
        XCTAssertTrue(clicker.points.isEmpty)
    }

    func testReasonRequiresMenuEvidenceAndRejectsLowConfidenceOrDuplicateMenus() {
        XCTAssertNil(PDDTransferMenuControls.reasonControl(in: [menu(y: 600)[0]], anchor: anchor))
        var lines = menu(y: 600)
        lines[0] = .init(text: "无原因直接转移", box: lines[0].box, confidence: 0.3)
        XCTAssertNil(PDDTransferMenuControls.reasonControl(in: lines, anchor: anchor))
        XCTAssertNil(PDDTransferMenuControls.reasonControl(in: menu(y: 600) + menu(y: 700), anchor: anchor))
    }

    func testRetinaCaptureAtMovedWindowConvertsToGlobalScreenPoints() async throws {
        let image = bitmap(width: 2400, height: 1800)
        let capture = MenuCapture(frame: .init(image: image, fullWindowImage: image,
            windowFrame: .init(x: 100, y: 50, width: 1200, height: 900)))
        let recognizer = MenuRecognizer(lines: [.init(text: "发送", box: .init(x: 200, y: 400, width: 100, height: 30), confidence: 1)])
        let reader = PDDLiveTransferMenuReader(capture: capture, recognizer: recognizer)
        let result = try await reader.controls(anchor: .init(x: 900, y: 500, width: 40, height: 20))
        XCTAssertEqual(result.first?.box, .init(x: 720, y: 250, width: 50, height: 15))
    }

    func testNativeVisionSeparatesReasonAndSendOnTheSameTextLine() async throws {
        let image = NSImage(size: .init(width: 1000, height: 400))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 400).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black]
        ("催发货" as NSString).draw(at: .init(x: 40, y: 300), withAttributes: attrs)
        ("换货问题" as NSString).draw(at: .init(x: 40, y: 230), withAttributes: attrs)
        ("无原因直接转移     发送" as NSString).draw(at: .init(x: 40, y: 140), withAttributes: attrs)
        image.unlockFocus()
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let lines = try await PDDTransferMenuVisionRecognizer().recognize(cg)
        let reason = try XCTUnwrap(lines.first { $0.text == "无原因直接转移" })
        let send = try XCTUnwrap(lines.first { $0.text == "发送" })
        XCTAssertGreaterThan(send.box.minX, reason.box.maxX)
        XCTAssertLessThan(abs(send.box.midY - reason.box.midY), 15)
    }

    private func lease() -> UIOperationLease { UIOperationLeaseRegistry().acquire(uid: "customer") }
    private var dialog: [PDDAXSemanticNode<AXElementToken>] {
        [node(1, label: "转移会话", frame: .init(x: 400, y: 100, width: 800, height: 700)),
         .init(id: .init(rawValue: 2), parentID: .init(rawValue: 1), role: "AXTextField", value: "请输入内容", title: nil,
            domIdentifier: nil, domClasses: [], actionNames: [], isSettable: true)]
    }
    private func node(_ id: Int, label: String, frame: CGRect) -> PDDAXSemanticNode<AXElementToken> {
        .init(id: .init(rawValue: id), parentID: id == 1 ? nil : .init(rawValue: 1), role: "AXButton",
            value: label, title: nil, domIdentifier: nil, domClasses: [], actionNames: ["AXPress"], isSettable: false, frame: frame)
    }
    private func menu(y: CGFloat) -> [PDDOCRLine] {
        [.init(text: "无原因直接转移", box: .init(x: 850, y: y, width: 140, height: 20), confidence: 1),
         line("催发货", x: 850, y: y - 150), line("换货问题", x: 850, y: y - 40)]
    }
    private func line(_ text: String, x: CGFloat, y: CGFloat) -> PDDOCRLine {
        .init(text: text, box: .init(x: x, y: y, width: 30, height: 20), confidence: 1)
    }
    private func bitmap(width: Int, height: Int) -> CGImage {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
}

@MainActor private final class MenuBackend: PDDAXBackend {
    var nodes: [PDDAXSemanticNode<AXElementToken>]
    var pressed: [AXElementToken] = []
    var onPress: ((AXElementToken) -> Void)?
    init(nodes: [PDDAXSemanticNode<AXElementToken>]) { self.nodes = nodes }
    func readSemanticTree() throws -> PDDAXSemanticTree { .init(rootSnapshot: .init(role: "AXWindow"), nodes: nodes) }
    func performPress(_ id: AXElementToken) throws { pressed.append(id); onPress?(id) }
    func setValue(_ text: String, on id: AXElementToken) throws {}
    func value(of id: AXElementToken) throws -> String { "" }
}
@MainActor private final class MenuClicker: PDDTransferClicking {
    var points: [CGPoint] = []; var onClick: (() -> Void)?
    var hovers: [CGPoint] = []; var onHover: (() -> Void)?
    func hover(at point: CGPoint) throws { hovers.append(point); onHover?() }
    func click(at point: CGPoint) throws { points.append(point); onClick?() }
}
@MainActor private final class MenuReader: PDDTransferMenuReading {
    var results: [[PDDOCRLine]] = []; var calls = 0; var onRead: (() -> Void)?
    func controls(anchor: CGRect) async throws -> [PDDOCRLine] {
        defer { calls += 1 }; onRead?()
        return results.isEmpty ? [] : results[min(calls, results.count - 1)]
    }
}
@MainActor private final class MenuCapture: PDDOCRCapturing {
    let frame: PDDOCRFrame
    init(frame: PDDOCRFrame) { self.frame = frame }
    func capture() async throws -> PDDOCRFrame { frame }
}
@MainActor private final class MenuRecognizer: PDDOCRRecognizing {
    let lines: [PDDOCRLine]
    init(lines: [PDDOCRLine]) { self.lines = lines }
    func recognize(_ image: CGImage) async throws -> [PDDOCRLine] { lines }
}
