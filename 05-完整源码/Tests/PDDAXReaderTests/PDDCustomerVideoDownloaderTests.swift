import XCTest
@testable import PDDAXReader

final class PDDCustomerVideoDownloaderTests: XCTestCase {
    func testDownloadPolicyAcceptsOnlySuccessfulVideoResponses() {
        XCTAssertTrue(PDDVideoDownloadPolicy.accepts(statusCode: 200, mimeType: "video/mp4"))
        XCTAssertTrue(PDDVideoDownloadPolicy.accepts(statusCode: 206, mimeType: "application/octet-stream"))
        XCTAssertFalse(PDDVideoDownloadPolicy.accepts(statusCode: 403, mimeType: "video/mp4"))
        XCTAssertFalse(PDDVideoDownloadPolicy.accepts(statusCode: 200, mimeType: "text/html"))
    }

    func testInspectorRejectsTextRenamedAsMP4() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("not video".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        do {
            _ = try await PDDVideoFileInspector.inspect(file)
            XCTFail("invalid data must be rejected")
        } catch let error as PDDCustomerVideoError {
            XCTAssertEqual(error, .invalidMedia)
        }
    }

    func testInspectorPreservesCancellation() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try Data([0, 0, 0, 12] + Array("ftypisom".utf8)).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let task = Task {
            try await PDDVideoFileInspector.inspect(file)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled inspection must not become invalidMedia")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
