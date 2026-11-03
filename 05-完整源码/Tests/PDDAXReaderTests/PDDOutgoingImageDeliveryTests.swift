import XCTest
@testable import PDDAXReader

@MainActor
final class PDDOutgoingImageDeliveryTests: XCTestCase {
    func testImageAndCaptionSendUsingUniqueAXChatWithoutOCRorTriggerBubble() async throws {
        let fixture = try ImageDeliveryFixture(timeout: 0.1)
        defer { fixture.clean() }
        fixture.backend.activeNickname = "~***"
        let uid = PDDConversationKey.make(locator: .init(nickname: "~***"))
        fixture.backend.uid = uid
        guard case .sent = try await fixture.send(uid: uid) else { return XCTFail("Expected AX-only image and caption delivery") }
        XCTAssertEqual(fixture.backend.textSendCount, 1)
        XCTAssertEqual(fixture.uploader.calls, 1)
        XCTAssertEqual(try PDDOutgoingImageReceiptStore(root: fixture.root).load(deliveryID: fixture.id, hash: fixture.image.sha256)?.uid, uid)
    }
    func testImageConfirmsBeforeTextAndRetrySkipsConfirmedUpload() async throws {
        let fixture = try ImageDeliveryFixture()
        defer { fixture.clean() }
        fixture.backend.failTextWrite = true
        let first = try await fixture.send()
        guard case .failedBeforeSend = first else { return XCTFail("Expected text retry: \(first)") }
        let receipt = try XCTUnwrap(PDDOutgoingImageReceiptStore(root: fixture.root)
            .load(deliveryID: fixture.id, hash: fixture.image.sha256))
        XCTAssertEqual(receipt.confirmedMessageID, "middlePanel_list_image1")
        fixture.backend.failTextWrite = false
        let retried = try await fixture.send()
        guard case .sent = retried else { return XCTFail("Expected sent: \(retried)") }
        XCTAssertEqual(fixture.uploader.calls, 1)
        XCTAssertEqual(fixture.backend.textSendCount, 1)
        let log = try String(contentsOf: fixture.root.appendingPathComponent("logs/automation-steps.jsonl"))
        XCTAssertTrue(log.contains("reply-image-confirmed"))
        XCTAssertTrue(log.contains("reply-image-duplicate-skipped"))
    }

    func testUploadInterruptedAfterCommitNeverUploadsAgainAndCanReconcile() async throws {
        let fixture = try ImageDeliveryFixture()
        defer { fixture.clean() }
        fixture.uploader.throwAfterCommit = true
        guard case .uncertain = try await fixture.send() else { return XCTFail("Expected uncertain upload") }
        XCTAssertEqual(fixture.backend.textSendCount, 0)
        fixture.uploader.throwAfterCommit = false
        guard case .uncertain = try await fixture.send() else { return XCTFail("Must not repeat an uncertain upload") }
        XCTAssertEqual(fixture.uploader.calls, 1)
        fixture.backend.imageVisible = true
        guard case .sent = try await fixture.send() else { return XCTFail("Expected read-only reconciliation then text") }
        XCTAssertEqual(fixture.uploader.calls, 1)
    }

    func testPastePreparationFailureBeforeCommitIsRetryableAndSendsNoText() async throws {
        let fixture = try ImageDeliveryFixture()
        defer { fixture.clean() }
        fixture.uploader.throwBeforeCommit = true
        guard case .failedBeforeSend = try await fixture.send() else { return XCTFail("Expected safe failure") }
        XCTAssertEqual(fixture.backend.textSendCount, 0)
        XCTAssertNil(try PDDOutgoingImageReceiptStore(root: fixture.root).load(deliveryID: fixture.id, hash: fixture.image.sha256))
        fixture.uploader.throwBeforeCommit = false
        guard case .sent = try await fixture.send() else { return XCTFail("Expected safe retry") }
        XCTAssertEqual(fixture.uploader.calls, 2)
    }

    func testCustomerSwitchBeforeUploadAndLeaseRevocationStopCommit() async throws {
        let fixture = try ImageDeliveryFixture()
        defer { fixture.clean() }
        fixture.uploader.beforeCommitHook = { fixture.backend.uid = "GZC-000002" }
        guard case .failedBeforeSend = try await fixture.send() else { return XCTFail("Wrong customer must block") }
        XCTAssertEqual(fixture.backend.textSendCount, 0)
        fixture.backend.uid = "GZC-000001"
        let registry = UIOperationLeaseRegistry()
        let lease = registry.acquire(uid: fixture.backend.uid)
        fixture.uploader.beforeCommitHook = { registry.revokeAll() }
        guard case .failedBeforeSend = try await fixture.send(lease: lease) else { return XCTFail("Revoked lease must block") }
        XCTAssertNil(try PDDOutgoingImageReceiptStore(root: fixture.root).load(deliveryID: fixture.id, hash: fixture.image.sha256))
    }

    func testSeparateImagePreviewIsSubmittedOnceAndConfirmed() async throws {
        let fixture = try ImageDeliveryFixture(timeout: 0.3)
        defer { fixture.clean() }
        fixture.uploader.usesPreview = true
        guard case .sent = try await fixture.send() else { return XCTFail("Expected preview image and text") }
        XCTAssertEqual(fixture.backend.previewSendCount, 1)
        let receipt = try XCTUnwrap(PDDOutgoingImageReceiptStore(root: fixture.root).load(deliveryID: fixture.id, hash: fixture.image.sha256))
        XCTAssertNotNil(receipt.previewSubmittedAt)
    }

    func testScreenshotConfirmationButtonIsClickedUsingItsFrameWhenAXPressIsUnavailable() async throws {
        let fixture = try ImageDeliveryFixture(timeout: 0.3)
        defer { fixture.clean() }
        fixture.uploader.usesPreview = true
        fixture.backend.previewUsesAXPress = false
        fixture.clicker.beforeClick = {
            let receipt = try XCTUnwrap(PDDOutgoingImageReceiptStore(root: fixture.root)
                .load(deliveryID: fixture.id, hash: fixture.image.sha256))
            XCTAssertNotNil(receipt.previewSubmittedAt, "Persist before sending")
        }
        guard case .sent = try await fixture.send() else { return XCTFail("Expected image confirmation click") }
        XCTAssertEqual(fixture.clicker.points, [CGPoint(x: 112.5, y: 112.5)])
        XCTAssertEqual(fixture.backend.previewSendCount, 1)
        XCTAssertEqual(fixture.backend.textSendCount, 1)
    }

    func testLiveCombinedSendCancelAXControlClicksLeftSendOnceAndConfirmsImage() async throws {
        let fixture = try ImageDeliveryFixture(timeout: 0.3)
        defer { fixture.clean() }
        fixture.uploader.usesPreview = true
        fixture.backend.previewUsesCombinedAXText = true
        let receiptStore = PDDOutgoingImageReceiptStore(root: fixture.root)
        fixture.clicker.beforeClick = {
            XCTAssertNotNil(try receiptStore.load(deliveryID: fixture.id, hash: fixture.image.sha256)?.previewSubmittedAt)
        }
        guard case .sent = try await fixture.send() else { return XCTFail("Expected live AX shape to send image and text") }
        XCTAssertEqual(fixture.clicker.points, [CGPoint(x: 150, y: 120)])
        XCTAssertEqual(fixture.backend.previewSendCount, 1)
        XCTAssertNotNil(try receiptStore.load(deliveryID: fixture.id, hash: fixture.image.sha256)?.confirmedMessageID)
        let log = try String(contentsOf: fixture.root.appendingPathComponent("logs/automation-steps.jsonl"))
        XCTAssertTrue(log.contains("发送 取消 (left Send)"))
        XCTAssertTrue(log.contains("reply-image-confirmed"))
    }

    func testStaticTextSendWithoutAXPressCanBeClickedInsideImageDialog() throws {
        let backend = ImageDeliveryBackend()
        backend.previewVisible = true
        backend.previewUsesAXPress = false
        let nodes = try backend.readSemanticTree().nodes.map { node in
            node.id.rawValue == 20 ? imageSemantic(20, parent: 24, role: "AXStaticText", value: "发送") : node
        }
        let target = try XCTUnwrap(PDDOutgoingImageControls.previewSendControl(in: nodes))
        XCTAssertFalse(target.allowsAXPress)
        XCTAssertEqual(target.point, CGPoint(x: 112.5, y: 112.5))
    }

    func testCombinedControlMustBeHorizontalAndSendingStatusCannotBeClickedAgain() throws {
        let backend = ImageDeliveryBackend()
        backend.previewVisible = true
        backend.previewUsesCombinedAXText = true
        let nodes = try backend.readSemanticTree().nodes
        let vertical = nodes.map { node in
            node.id.rawValue == 20 ? imageSemantic(20, parent: 19, role: "AXStaticText", value: "发送 取消",
                frame: CGRect(x: 100, y: 100, width: 200, height: 600)) : node
        }
        XCTAssertNil(PDDOutgoingImageControls.previewSendControl(in: vertical))
        let sending = nodes.map { node in
            node.id.rawValue == 20 ? imageSemantic(20, parent: 19, role: "AXStaticText", value: "发送中... 取消",
                frame: CGRect(x: 100, y: 100, width: 200, height: 40)) : node
        }
        XCTAssertNil(PDDOutgoingImageControls.previewSendControl(in: sending))
    }

    func testConfirmationThatDoesNotCloseIsNeverClickedTwice() async throws {
        let fixture = try ImageDeliveryFixture(timeout: 0.08)
        defer { fixture.clean() }
        fixture.uploader.usesPreview = true
        fixture.backend.previewPressLeavesOpen = true
        guard case .uncertain = try await fixture.send() else { return XCTFail("Expected uncertain confirmation") }
        XCTAssertEqual(fixture.backend.previewSendCount, 1)
        XCTAssertEqual(fixture.backend.textSendCount, 0)
        XCTAssertEqual(fixture.backend.previewCancelCount, 1)
        XCTAssertFalse(fixture.backend.previewVisible, "Failed image must not leave a modal over other customers")
        guard case .uncertain = try await fixture.send() else { return XCTFail("Uncertain confirmation must not be repeated") }
        XCTAssertEqual(fixture.backend.previewSendCount, 1)
        XCTAssertEqual(fixture.uploader.calls, 1)
    }

    func testCombinedImageConfirmationCleanupTargetsRightCancelWithoutSendingAgain() async throws {
        let fixture = try ImageDeliveryFixture(timeout: 0.05)
        defer { fixture.clean() }
        fixture.uploader.usesPreview = true
        fixture.backend.previewUsesCombinedAXText = true
        fixture.backend.previewPressLeavesOpen = true
        guard case .uncertain = try await fixture.send() else { return XCTFail("Expected uncertain confirmation") }
        XCTAssertEqual(fixture.clicker.points, [CGPoint(x: 150, y: 120), CGPoint(x: 250, y: 120)])
        XCTAssertEqual(fixture.backend.previewSendCount, 1)
        XCTAssertEqual(fixture.backend.previewCancelCount, 1)
        XCTAssertFalse(fixture.backend.previewVisible)
    }

    func testActualHeadingNestedInsideGenericDialogSelectsOnlyImageSendButton() throws {
        let backend = ImageDeliveryBackend()
        backend.previewVisible = true
        let nodes = try backend.readSemanticTree().nodes
        XCTAssertEqual(PDDOutgoingImageControls.previewSendControl(in: nodes)?.id.rawValue, 20)
        let ordinaryChatOnly = nodes.filter { $0.id.rawValue < 19 }
        XCTAssertNil(PDDOutgoingImageControls.previewSendControl(in: ordinaryChatOnly))
        let customerSpoof = [imageSemantic(1, classes: ["chat-panel"]),
            imageSemantic(19, parent: 1, classes: ["onemsg"]),
            imageSemantic(21, parent: 19, value: "是否发送图片"),
            imageSemantic(22, parent: 19, role: "AXImage"),
            imageSemantic(23, parent: 19, role: "AXButton", value: "取消"),
            imageSemantic(20, parent: 19, role: "AXButton", value: "发送", actions: ["AXPress"])]
        XCTAssertNil(PDDOutgoingImageControls.previewSendControl(in: customerSpoof))
    }

    func testMultipleImageConfirmationDialogsAndMissingCancelAreRejected() throws {
        let backend = ImageDeliveryBackend()
        backend.previewVisible = true
        let nodes = try backend.readSemanticTree().nodes
        XCTAssertNil(PDDOutgoingImageControls.previewSendControl(in: nodes.filter { $0.value != "取消" }))
        let secondDialog = nodes.filter { $0.id.rawValue >= 19 }.map { node in
            imageSemantic(node.id.rawValue + 100, parent: node.parentID.map { $0.rawValue + 100 },
                role: node.role, value: node.value, classes: node.domClasses, actions: node.actionNames)
        }
        XCTAssertNil(PDDOutgoingImageControls.previewSendControl(in: nodes + secondDialog))
    }

    func testFailedAndPendingBubblesCannotConfirmDelivery() throws {
        let backend = ImageDeliveryBackend()
        backend.imageVisible = true
        XCTAssertEqual(PDDOutgoingImageControls.confirmedImageMessageIDs(in: try backend.readSemanticTree()), ["middlePanel_list_image1"])
        backend.imageFailed = true
        XCTAssertTrue(PDDOutgoingImageControls.confirmedImageMessageIDs(in: try backend.readSemanticTree()).isEmpty)
    }

    func testImageDeliveryDoesNotRequireMediaToolbarOrFilePicker() async throws {
        let fixture = try ImageDeliveryFixture()
        defer { fixture.clean() }
        let nodes = try fixture.backend.readSemanticTree().nodes
        XCTAssertFalse(nodes.contains { $0.value == "" })
        guard case .sent = try await fixture.send() else { return XCTFail("Expected direct image paste without toolbar") }
        XCTAssertEqual(fixture.uploader.calls, 1)
        let log = try String(contentsOf: fixture.root.appendingPathComponent("logs/automation-steps.jsonl"))
        XCTAssertTrue(log.contains("reply-image-paste-started"))
        XCTAssertFalse(log.contains("picker"))
    }
}

@MainActor
private final class ImageDeliveryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let id = UUID()
    let image: DatasetReplyImage
    let backend = ImageDeliveryBackend()
    let uploader: ImageDeliveryUploader
    let clicker: ImagePreviewClicker
    let sender: PDDAXReplySender
    init(timeout: TimeInterval = 0) throws {
        image = try makeDatasetReplyImageFixture(root: root)
        uploader = ImageDeliveryUploader(backend: backend)
        clicker = ImagePreviewClicker(backend: backend)
        sender = PDDAXReplySender(backend: backend, opener: ImageDeliveryOpener(backend: backend),
            confirmationTimeout: 0, pollIntervalNanoseconds: 0, logRoot: root,
            imageUploader: uploader, imageConfirmationTimeout: timeout, imagePreviewClicker: clicker)
    }
    func send(uid: String = "GZC-000001", lease: UIOperationLease? = nil) async throws -> AutoReplyDeliveryResult {
        try await sender.send(uid: uid, text: "Here is the card sample.", outgoingImages: [image], deliveryID: id,
            expectedCustomerCursor: .empty, expectedCustomerMessageIDs: ["customer1"], lease: lease)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class ImageDeliveryUploader: PDDOutgoingImageUploading {
    let backend: ImageDeliveryBackend
    var calls = 0
    var throwBeforeCommit = false
    var throwAfterCommit = false
    var usesPreview = false
    var beforeCommitHook: (() -> Void)?
    init(backend: ImageDeliveryBackend) { self.backend = backend }
    func upload(file: URL, beforeCommit: () throws -> Void) async throws {
        calls += 1
        if throwBeforeCommit { throw CocoaError(.fileReadUnknown) }
        beforeCommitHook?()
        try beforeCommit()
        if throwAfterCommit { throw CocoaError(.fileReadUnknown) }
        backend.previewVisible = usesPreview
        backend.imageVisible = !usesPreview
    }
}

@MainActor
private final class ImageDeliveryOpener: PDDConversationOpening {
    let backend: ImageDeliveryBackend
    init(backend: ImageDeliveryBackend) { self.backend = backend }
    func openAndResolve(uid: String) async throws -> PDDAXSemanticTree { try backend.readSemanticTree() }
}

@MainActor
private final class ImageDeliveryBackend: PDDAXBackend {
    var uid = "GZC-000001"
    var activeNickname: String?
    var imageVisible = false
    var imageFailed = false
    var previewVisible = false
    var previewUsesAXPress = true
    var previewUsesCombinedAXText = false
    var previewPressLeavesOpen = false
    var failTextWrite = false
    var composer = ""
    var textSendCount = 0
    var previewSendCount = 0
    var previewCancelCount = 0
    func readSemanticTree() throws -> PDDAXSemanticTree {
        let image = AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMIdentifier", "middlePanel_list_image1"),
            ("AXDOMClassList", imageFailed ? "[onemsg, failed]" : "[onemsg]")], children: [
                AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[cs-item]")], children: [
                    AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[msg-content-box]")], children: [
                        AXNodeSnapshot(role: "AXImage", attributes: [("AXDOMClassList", "[image-msg]"),
                            ("AXURL", "https://img.example/card.png")])
                    ])
                ])
            ])
        var nodes = [imageSemantic(1, classes: ["chat-panel"]),
            imageSemantic(2, parent: 1, role: "AXTextArea", settable: true),
            imageSemantic(3, parent: 1, role: "AXButton", value: "发送", actions: ["AXPress"])]
        if previewVisible {
            // The actual merchant dialog has a nested title and separate image/footer containers.
            nodes += [imageSemantic(19), imageSemantic(21, parent: 19),
                imageSemantic(22, parent: 21, role: "AXStaticText", value: "是否发送图片"),
                imageSemantic(23, parent: 19, role: "AXImage")]
            if previewUsesCombinedAXText {
                nodes += [imageSemantic(20, parent: 19, role: "AXStaticText", value: "发送 取消",
                    frame: CGRect(x: 100, y: 100, width: 200, height: 40))]
            } else {
                nodes += [imageSemantic(24, parent: 19),
                    imageSemantic(25, parent: 24, role: "AXButton", value: "取消", actions: ["AXPress"],
                        frame: CGRect(x: 200, y: 100, width: 25, height: 25)),
                    imageSemantic(20, parent: 24, role: "AXButton", value: "发送", actions: previewUsesAXPress ? ["AXPress"] : [])]
            }
        }
        let rows = activeNickname.map { nickname in [AXNodeSnapshot(role: "AXGroup", attributes: [("AXDOMClassList", "[chat-item-box,active]")], children: [
            .init(role: "AXStaticText", attributes: [("AXDOMClassList", "[chat-nickname]"), ("AXValue", nickname)])])] } ?? []
        return PDDAXSemanticTree(rootSnapshot: AXNodeSnapshot(role: "AXWindow", attributes: [("AXValue", uid)],
            children: rows + (imageVisible ? [image] : [])), nodes: nodes)
    }
    func performPress(_ token: AXElementToken) throws {
        if token.rawValue == 25 { previewCancelCount += 1; previewVisible = false }
        else if token.rawValue == 20 {
            previewSendCount += 1
            if !previewPressLeavesOpen { previewVisible = false; imageVisible = true }
        }
        else { textSendCount += 1; composer = "" }
    }
    func setValue(_ text: String, on token: AXElementToken) throws {
        if failTextWrite { throw CocoaError(.fileWriteUnknown) }
        composer = text
    }
    func value(of token: AXElementToken) throws -> String { composer }
}

@MainActor
private final class ImagePreviewClicker: PDDTransferClicking {
    let backend: ImageDeliveryBackend
    var points: [CGPoint] = []
    var beforeClick: (() throws -> Void)?
    init(backend: ImageDeliveryBackend) { self.backend = backend }
    func click(at point: CGPoint) throws {
        try beforeClick?()
        points.append(point)
        try backend.performPress(.init(rawValue: point.x >= 200 ? 25 : 20))
    }
    func submitNoReasonTransfer(anchorFrame: CGRect) async throws { XCTFail("Unexpected transfer action") }
}

private func imageSemantic(_ id: Int, parent: Int? = nil, role: String = "AXGroup", value: String? = nil,
                           classes: Set<String> = [], actions: Set<String> = [], settable: Bool = false,
                           frame: CGRect = CGRect(x: 100, y: 100, width: 25, height: 25)) -> PDDAXSemanticNode<AXElementToken> {
    .init(id: .init(rawValue: id), parentID: parent.map { .init(rawValue: $0) }, role: role, value: value,
        title: nil, domIdentifier: nil, domClasses: classes, actionNames: actions, isSettable: settable,
        frame: frame)
}
