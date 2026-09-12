import CryptoKit
import XCTest
@testable import PDDAXReader

final class FrozenImageStoreTests: XCTestCase {
    func testFreezeUsesContentAddressAndSurvivesOriginalDeletion() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("download.png")
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
        try bytes.write(to: source)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let store = FrozenImageStore(rootDirectory: root.appendingPathComponent("frozen"))

        let frozen = try store.freeze(attachment(source: source, digest: digest))
        try FileManager.default.removeItem(at: source)

        XCTAssertEqual(frozen.localURL.lastPathComponent, "\(digest).png")
        XCTAssertEqual(try Data(contentsOf: frozen.localURL), bytes)
        XCTAssertEqual(try store.freeze(frozen), frozen)
    }

    func testFreezeRejectsChangedSourceBytes() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("download.png")
        try Data([1, 2, 3]).write(to: source)
        let store = FrozenImageStore(rootDirectory: root.appendingPathComponent("frozen"))

        XCTAssertThrowsError(try store.freeze(
            attachment(source: source, digest: String(repeating: "a", count: 64))
        )) { error in
            XCTAssertEqual(error as? FrozenImageStoreError, .digestMismatch)
        }
    }

    private func attachment(source: URL, digest: String) -> AutoReplyImageAttachment {
        AutoReplyImageAttachment(
            messageID: "image-1", sourceURL: URL(string: "https://example.com/a.png")!,
            localURL: source, mimeType: "image/png", byteCount: 3, sha256: digest
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-frozen-images-\(UUID().uuidString)")
    }
}
