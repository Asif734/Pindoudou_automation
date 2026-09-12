import Foundation
import XCTest
@testable import PDDAXReader

final class PDDCustomerImageDownloaderTests: XCTestCase {
    func testDownloadedLocalPNGIsValidatedAndCopiedIntoAttachmentStore() async throws {
        let root = temporaryRoot()
        let sourceRoot = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let source = sourceRoot.appendingPathComponent("pdd-download.png")
        try png.write(to: source)

        let attachment = try await PDDCustomerImageDownloader(maximumBytes: 1_000_000).download(
            sourceURL: source, destinationDirectory: root, messageID: "downloaded-message"
        )

        XCTAssertEqual(attachment.sourceURL, source)
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertEqual(try Data(contentsOf: attachment.localURL), png)
    }

    func testValidPNGIsVerifiedHashedAndAtomicallyStored() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let source = URL(string: "https://chat-img.pddugc.com/a.png")!
        let loader = ImageLoaderStub(response: PDDImageDataResponse(
            data: png, statusCode: 200, mimeType: "image/png", finalURL: source
        ))
        let downloader = PDDCustomerImageDownloader(loader: loader, maximumBytes: 1_000_000)

        let attachment = try await downloader.download(
            sourceURL: source, destinationDirectory: root, messageID: "middlePanel_list_100"
        )

        XCTAssertEqual(attachment.messageID, "middlePanel_list_100")
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertEqual(attachment.byteCount, png.count)
        XCTAssertEqual(attachment.sha256.count, 64)
        XCTAssertEqual(try Data(contentsOf: attachment.localURL), png)
        XCTAssertEqual(attachment.localURL.pathExtension, "png")
    }

    func testRejectsHTMLBodyAndOversizeDataWithoutWritingFile() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(string: "https://example.test/not-image")!
        let html = Data("<html>wrong</html>".utf8)
        let invalid = PDDCustomerImageDownloader(
            loader: ImageLoaderStub(response: PDDImageDataResponse(
                data: html, statusCode: 200, mimeType: "text/html", finalURL: source
            )),
            maximumBytes: 1_000
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await invalid.download(sourceURL: source, destinationDirectory: root, messageID: "m1")
        }

        let oversize = PDDCustomerImageDownloader(
            loader: ImageLoaderStub(response: PDDImageDataResponse(
                data: Data(repeating: 1, count: 10), statusCode: 200,
                mimeType: "image/jpeg", finalURL: source
            )),
            maximumBytes: 5
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await oversize.download(sourceURL: source, destinationDirectory: root, messageID: "m2")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("m1.png").path))
    }

    func testGIFIsDecodedAndNormalizedToCodexReadableJPEG() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")!
        let source = URL(string: "https://chat-img.pddugc.com/a.gif")!
        let downloader = PDDCustomerImageDownloader(
            loader: ImageLoaderStub(response: PDDImageDataResponse(
                data: gif, statusCode: 200, mimeType: "image/gif", finalURL: source
            )),
            maximumBytes: 1_000_000
        )

        let attachment = try await downloader.download(
            sourceURL: source, destinationDirectory: root, messageID: "gif-message"
        )

        XCTAssertEqual(attachment.mimeType, "image/jpeg")
        XCTAssertEqual(attachment.localURL.pathExtension, "jpg")
        XCTAssertEqual(Array(try Data(contentsOf: attachment.localURL).prefix(3)), [0xff, 0xd8, 0xff])
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-image-downloader-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private struct ImageLoaderStub: PDDImageDataLoading {
    let response: PDDImageDataResponse
    func load(_ url: URL, maximumBytes: Int) async throws -> PDDImageDataResponse { response }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
