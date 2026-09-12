import XCTest
@testable import PDDAXReader

final class PDDAXVideoPreviewTests: XCTestCase {
    func testRecognizesOnlyExplicitVideoPreviewMarkers() {
        XCTAssertTrue(PDDVideoPreviewElementPolicy.isPreviewMarker("视频预览"))
        XCTAssertTrue(PDDVideoPreviewElementPolicy.isPreviewMarker("客户视频播放"))
        XCTAssertFalse(PDDVideoPreviewElementPolicy.isPreviewMarker("拼多多商家工作台"))
        XCTAssertFalse(PDDVideoPreviewElementPolicy.isPreviewMarker("消息"))
        XCTAssertFalse(PDDVideoPreviewElementPolicy.isPreviewMarker("预览"))
    }

    func testRecognizesCloseButtonOnlyInsidePreviewSubtree() {
        XCTAssertTrue(PDDVideoPreviewElementPolicy.isCloseButton(role: "AXButton", labels: ["Close"]))
        XCTAssertTrue(PDDVideoPreviewElementPolicy.isCloseButton(role: "AXButton", labels: ["关闭"]))
        XCTAssertFalse(PDDVideoPreviewElementPolicy.isCloseButton(role: "AXButton", labels: ["Fullscreen"]))
        XCTAssertFalse(PDDVideoPreviewElementPolicy.isCloseButton(role: "AXWindow", labels: ["Close"]))
    }

    @MainActor
    func testLiveCloseOnlyWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PDD_LIVE_VIDEO_PREVIEW_CLOSE"] == "1" else {
            throw XCTSkip("set PDD_LIVE_VIDEO_PREVIEW_CLOSE=1 with a PDD video preview already open")
        }
        await PDDAXVideoPreviewOpener().close()
    }

    @MainActor
    func testLiveOpenCanConfirmAndCloseCurrentCustomerVideo() async throws {
        guard ProcessInfo.processInfo.environment["PDD_LIVE_VIDEO_PREVIEW_OPEN"] == "1" else {
            throw XCTSkip("set PDD_LIVE_VIDEO_PREVIEW_OPEN=1 with a customer video visible in PDD")
        }
        let backend = LivePDDAXBackend()
        let tree = try backend.readSemanticTree()
        let messageIDs = tree.nodes.compactMap(\.domIdentifier).filter {
            $0.hasPrefix("middlePanel_list_")
        }
        let candidate = try XCTUnwrap(PDDAXVideoSelection.customerVideos(
            in: tree.nodes, messageIDs: messageIDs
        ).last)
        let opener = PDDAXVideoPreviewOpener(backend: backend)

        try await opener.open(
            candidate,
            lease: UIOperationLeaseRegistry().acquire(uid: "PDD-live-video-test")
        )
        let confirmed = try await opener.waitUntilOpen()
        await opener.close()

        XCTAssertTrue(confirmed, "PDD accepted the click but preview-open evidence was not exposed")
    }

    @MainActor
    func testEveryOpenAttemptRefreshesTheVideoFrameByMessageID() async throws {
        let messageID = "middlePanel_list_123"
        let refreshedFrame = CGRect(x: 310, y: 220, width: 120, height: 90)
        let backend = PreviewBackendStub(tree: previewVideoTree(
            messageID: messageID, frame: refreshedFrame
        ))
        var clickedFrames: [CGRect] = []
        let opener = PDDAXVideoPreviewOpener(
            backend: backend,
            clickOverride: { clickedFrames.append($0.frame) },
            previewProbeOverride: { true },
            confirmationPause: {}
        )
        let staleCandidate = PDDCustomerVideoCandidate(
            messageID: messageID,
            frame: CGRect(x: 10, y: 20, width: 30, height: 30)
        )

        try await opener.open(
            staleCandidate,
            lease: UIOperationLeaseRegistry().acquire(uid: "PDD-one")
        )

        XCTAssertEqual(clickedFrames, [refreshedFrame])
        XCTAssertEqual(backend.readCount, 1)
    }

    private func previewVideoTree(messageID: String, frame: CGRect) -> PDDAXSemanticTree {
        PDDAXSemanticTree(rootSnapshot: AXNodeSnapshot(role: "AXWindow"), nodes: [
            PDDAXSemanticNode(
                id: AXElementToken(rawValue: 1), parentID: nil, role: "AXGroup",
                value: nil, title: nil, domIdentifier: "msgListContainer",
                domClasses: ["msg-list"], actionNames: [], isSettable: false,
                frame: CGRect(x: 0, y: 0, width: 800, height: 800)
            ),
            PDDAXSemanticNode(
                id: AXElementToken(rawValue: 2), parentID: AXElementToken(rawValue: 1),
                role: "AXGroup", value: nil, title: nil, domIdentifier: messageID,
                domClasses: ["onemsg", "buyer-item"], actionNames: [], isSettable: false
            ),
            PDDAXSemanticNode(
                id: AXElementToken(rawValue: 3), parentID: AXElementToken(rawValue: 2),
                role: "AXGroup", value: nil, title: nil, domIdentifier: nil,
                domClasses: ["video-msg"], actionNames: [], isSettable: false,
                frame: frame
            )
        ])
    }
}

@MainActor
private final class PreviewBackendStub: PDDAXBackend {
    let tree: PDDAXSemanticTree
    var readCount = 0

    init(tree: PDDAXSemanticTree) { self.tree = tree }

    func readSemanticTree() throws -> PDDAXSemanticTree {
        readCount += 1
        return tree
    }

    func performPress(_ id: AXElementToken) throws {}
    func setValue(_ text: String, on id: AXElementToken) throws {}
    func value(of id: AXElementToken) throws -> String { "" }
}
