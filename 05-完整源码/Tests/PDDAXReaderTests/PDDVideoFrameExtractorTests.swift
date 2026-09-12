import XCTest
@testable import PDDAXReader

final class PDDVideoFrameExtractorTests: XCTestCase {
    func testFrameScheduleUsesQianniuBuckets() {
        XCTAssertEqual(PDDVideoFrameSchedule.timestamps(durationSeconds: 1, maximumFrames: 20).count, 3)
        XCTAssertEqual(PDDVideoFrameSchedule.timestamps(durationSeconds: 8, maximumFrames: 20).count, 8)
        XCTAssertEqual(PDDVideoFrameSchedule.timestamps(durationSeconds: 20, maximumFrames: 20).count, 11)
        XCTAssertEqual(PDDVideoFrameSchedule.timestamps(durationSeconds: 31, maximumFrames: 20).count, 20)
    }

    func testEightSecondScheduleUsesQianniuInsets() {
        let values = PDDVideoFrameSchedule.timestamps(durationSeconds: 8, maximumFrames: 20)
        XCTAssertEqual(values.first!, 0.2, accuracy: 0.0001)
        XCTAssertEqual(values.last!, 7.8, accuracy: 0.0001)
    }

    func testCancelledExtractionStopsBeforeCreatingOutput() async throws {
        let video = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: output)
        }
        try Data().write(to: video)

        let task = Task {
            try await PDDVideoFrameExtractor().extractFrames(
                from: video, durationSeconds: 2, destinationDirectory: output
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled extraction must stop")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testLivePDDVideoProducesCodexReadableJPEGFramesWhenExplicitlyEnabled() async throws {
        guard let path = ProcessInfo.processInfo.environment["PDD_LIVE_VIDEO_FILE"] else {
            throw XCTSkip("set PDD_LIVE_VIDEO_FILE to a validated PDD MP4")
        }
        let video = URL(fileURLWithPath: path)
        let summary = try await PDDVideoFileInspector.inspect(video)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }

        let frames = try await PDDVideoFrameExtractor().extractFrames(
            from: video, durationSeconds: summary.durationSeconds, destinationDirectory: output
        )

        XCTAssertGreaterThanOrEqual(frames.count, 3)
        XCTAssertLessThanOrEqual(frames.count, 20)
        for frame in frames {
            let bytes = try Data(contentsOf: frame.localURL).prefix(3)
            XCTAssertEqual(Array(bytes), [0xff, 0xd8, 0xff])
        }
    }
}
