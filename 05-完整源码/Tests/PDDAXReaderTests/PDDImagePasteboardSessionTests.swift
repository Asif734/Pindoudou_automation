import AppKit
import XCTest
@testable import PDDAXReader

@MainActor
final class PDDImagePasteboardSessionTests: XCTestCase {
    func testWritesImageBytesOnlyAndRestoresPreviousClipboardAfterDelivery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try makeDatasetReplyImageFixture(root: root)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("previous clipboard", forType: .string)
        let session = PDDImagePasteboardSession(pasteboard: board)
        try session.writeImage(image.localURL)
        XCTAssertNotNil(board.data(forType: .png))
        XCTAssertNotNil(board.data(forType: .tiff))
        XCTAssertNil(board.string(forType: .fileURL))
        XCTAssertNil(board.string(forType: .string))
        session.restore()
        XCTAssertEqual(board.string(forType: .string), "previous clipboard")
        XCTAssertNil(board.data(forType: .png))
    }

    func testDoesNotOverwriteClipboardChangedByUserDuringUpload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try makeDatasetReplyImageFixture(root: root)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("old", forType: .string)
        let session = PDDImagePasteboardSession(pasteboard: board)
        try session.writeImage(image.localURL)
        board.clearContents()
        board.setString("new user copy", forType: .string)
        session.restore()
        XCTAssertEqual(board.string(forType: .string), "new user copy")
    }
}
