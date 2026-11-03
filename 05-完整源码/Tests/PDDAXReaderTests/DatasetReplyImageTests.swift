import AppKit
import XCTest
@testable import PDDAXReader

final class DatasetReplyImageTests: XCTestCase {
    func testValidatedImageIsFrozenDeduplicatedAndTamperingIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try makeDatasetReplyImageFixture(root: root)
        let resolver = DatasetReplyImageResolver(datasetRoot: root, outputRoot: root)
        let copies = try resolver.resolve([image.datasetRelativePath, image.datasetRelativePath])
        XCTAssertEqual(copies, [image])
        try Data("changed source".utf8).write(to: root.appendingPathComponent(image.datasetRelativePath))
        XCTAssertNoThrow(try image.verify(in: root))
        try Data("tampered copy".utf8).write(to: image.localURL)
        XCTAssertThrowsError(try image.verify(in: root))
    }

    func testTraversalAbsoluteURLsSymlinksAndNonImagesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try makeDatasetReplyImageFixture(root: root)
        let resolver = DatasetReplyImageResolver(datasetRoot: root, outputRoot: root)
        for path in ["/etc/passwd", "assets/../secrets.png", "https://example.com/a.png", "notes/a.png", "assets/./sample.png", "assets//sample.png"] {
            XCTAssertThrowsError(try resolver.resolve([path]), path)
        }
        let link = root.appendingPathComponent("assets/link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image.localURL)
        XCTAssertThrowsError(try resolver.resolve(["assets/link.png"]))
        try Data("not an image".utf8).write(to: root.appendingPathComponent("assets/fake.png"))
        XCTAssertThrowsError(try resolver.resolve(["assets/fake.png"]))
        XCTAssertThrowsError(try resolver.resolve(Array(repeating: image.datasetRelativePath, count: 4)))
    }

    func testGeneratorDecodesAndFreezesImageSelectionAndRejectsUnsafePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try makeDatasetReplyImageFixture(root: root)
        let message = PDDChatMessage(id: "m1", sender: .customer, content: "Can you show me a card sample?",
            displayTime: nil, kind: .text, capturedAt: Date())
        let timeline = try AutoReplyTimeline.make(messages: [message])
        let capture = try AutoReplyCapture(uid: "GZC-000001", fullHistory: [message], batch: timeline.freeze(after: .empty),
            customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
        let generator = AutoReplyCodexGenerator(runner: ImageDocumentRunner(path: image.datasetRelativePath),
            sessionRegistry: CodexSessionRegistry(rootDirectory: root), evidencePreparer: FallbackKnowledgeEvidencePreparer(),
            outgoingImageDatasetRoot: root)
        let result = try await generator.generate(capture)
        XCTAssertEqual(result.outgoingImages, [image])
        XCTAssertEqual(result.reply, "Here is the attendance card layout.")
        let unsafe = AutoReplyCodexGenerator(runner: ImageDocumentRunner(path: "assets/../private.png"),
            sessionRegistry: CodexSessionRegistry(rootDirectory: root.appendingPathComponent("unsafe-session")),
            evidencePreparer: FallbackKnowledgeEvidencePreparer(), outgoingImageDatasetRoot: root)
        do { _ = try await unsafe.generate(capture); XCTFail("Unsafe image must reject the reply") }
        catch is DatasetReplyImageError { }
    }
}

func makeDatasetReplyImageFixture(root: URL) throws -> DatasetReplyImage {
    try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: root.appendingPathComponent("assets/sample.png"))
    return try XCTUnwrap(DatasetReplyImageResolver(datasetRoot: root, outputRoot: root).resolve(["assets/sample.png"]).first)
}

private struct ImageDocumentRunner: CodexProcessRunning {
    let path: String
    func run(executable: URL, arguments: [String], stdin: String, timeout: TimeInterval) async throws -> CodexProcessResult {
        XCTAssertTrue(stdin.contains("image_paths"))
        let index = try XCTUnwrap(arguments.firstIndex(of: "-o"))
        let result: [String: Any] = ["action": "reply", "reply_text": "Here is the attendance card layout.",
            "transfer_reason": "none", "image_paths": [path]]
        try JSONSerialization.data(withJSONObject: result).write(to: URL(fileURLWithPath: arguments[index + 1]))
        return CodexProcessResult(exitCode: 0,
            stdout: "{\"type\":\"thread.started\",\"thread_id\":\"image-thread\"}\n{\"type\":\"turn.completed\"}\n", stderr: "")
    }
}
