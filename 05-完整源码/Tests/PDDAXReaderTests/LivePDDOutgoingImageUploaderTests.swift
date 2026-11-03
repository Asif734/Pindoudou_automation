import AppKit
import XCTest
@testable import PDDAXReader

@MainActor
final class LivePDDOutgoingImageUploaderTests: XCTestCase {
    func testPastesActualImageBytesIntoFocusedChatAfterCommitAndRestoresClipboard() async throws {
        let fixture = try ImagePasteFixture()
        defer { fixture.clean() }
        var committed = false
        fixture.target.onPaste = {
            XCTAssertTrue(committed)
            XCTAssertNotNil(fixture.board.data(forType: .png))
            XCTAssertNotNil(fixture.board.data(forType: .tiff))
            XCTAssertNil(fixture.board.string(forType: .fileURL))
            XCTAssertNil(fixture.board.string(forType: .string))
        }
        try await fixture.uploader.upload(file: fixture.image.localURL) {
            XCTAssertEqual(fixture.target.events, ["focus-chatbox"])
            committed = true
        }
        XCTAssertEqual(fixture.target.events, ["focus-chatbox", "paste-image"])
        fixture.uploader.finish()
        XCTAssertEqual(fixture.board.string(forType: .string), "original clipboard")
        let log = try String(contentsOf: fixture.root.appendingPathComponent("logs/automation-steps.jsonl"))
        XCTAssertTrue(log.contains("image-chatbox-focused"))
        XCTAssertTrue(log.contains("image-copied-to-clipboard"))
        XCTAssertTrue(log.contains("image-paste-submitted"))
        XCTAssertFalse(log.contains("picker"))
    }

    func testFocusFailureDoesNotTouchClipboardOrCommitDelivery() async throws {
        let fixture = try ImagePasteFixture()
        defer { fixture.clean() }
        fixture.target.failFocus = true
        do {
            try await fixture.uploader.upload(file: fixture.image.localURL) { XCTFail("Focus must be verified first") }
            XCTFail("Expected focus failure")
        } catch { }
        XCTAssertEqual(fixture.target.events, ["focus-chatbox"])
        XCTAssertEqual(fixture.board.string(forType: .string), "original clipboard")
    }

    func testCustomerVerificationFailureBlocksPasteAndRestoresClipboard() async throws {
        let fixture = try ImagePasteFixture()
        defer { fixture.clean() }
        do {
            try await fixture.uploader.upload(file: fixture.image.localURL) { throw UIOperationLeaseError.revoked }
            XCTFail("Expected revoked delivery")
        } catch { }
        XCTAssertEqual(fixture.target.events, ["focus-chatbox"])
        fixture.uploader.finish()
        XCTAssertEqual(fixture.board.string(forType: .string), "original clipboard")
    }

    func testConcurrentUserClipboardChangeBlocksPasteAndPreservesNewCopy() async throws {
        let fixture = try ImagePasteFixture()
        defer { fixture.clean() }
        do {
            try await fixture.uploader.upload(file: fixture.image.localURL) {
                fixture.board.clearContents()
                fixture.board.setString("new user clipboard", forType: .string)
            }
            XCTFail("Must not paste a changed clipboard")
        } catch { }
        XCTAssertEqual(fixture.target.events, ["focus-chatbox"])
        fixture.uploader.finish()
        XCTAssertEqual(fixture.board.string(forType: .string), "new user clipboard")
    }
}

@MainActor
private final class ImagePasteFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let board = NSPasteboard.withUniqueName()
    let image: DatasetReplyImage
    let target = ImagePasteTargetSpy()
    let uploader: LivePDDOutgoingImageUploader
    init() throws {
        image = try makeDatasetReplyImageFixture(root: root)
        board.setString("original clipboard", forType: .string)
        uploader = LivePDDOutgoingImageUploader(logRoot: root,
            pasteboardSession: PDDImagePasteboardSession(pasteboard: board), target: target)
    }
    func clean() {
        uploader.finish()
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class ImagePasteTargetSpy: PDDChatImagePasteTarget {
    var events: [String] = []
    var failFocus = false
    var onPaste: (() -> Void)?
    func focusComposer() async throws {
        events.append("focus-chatbox")
        if failFocus { throw CocoaError(.featureUnsupported) }
    }
    func pasteImage() throws {
        events.append("paste-image")
        onPaste?()
    }
}
