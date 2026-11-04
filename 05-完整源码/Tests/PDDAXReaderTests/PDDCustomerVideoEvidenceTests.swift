import XCTest
@testable import PDDAXReader

final class PDDCustomerVideoEvidenceTests: XCTestCase {
    func testIdenticalResendReusesEvidenceButDamagedFramesAreRegenerated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("video.mp4")
        try Data("video".utf8).write(to: source)
        let extractor = CountingFrameExtractor()
        let transcriber = CountingTranscriber()
        func receipt(_ id: String) -> PDDDownloadedCustomerVideo {
            .init(uid: "customer", messageID: id, key: .init(uid: "customer", messageID: id),
                fileURL: source, summary: .init(byteCount: 5, sha256: "same", durationSeconds: 8,
                    width: 720, height: 1280, videoCodec: "H.264", audioCodec: nil))
        }
        func preparer() -> PDDCustomerVideoEvidencePreparer {
            .init(rootURL: root.appendingPathComponent("evidence"), transcriber: transcriber, frameExtractor: extractor)
        }
        let first = try await preparer().prepare(download: receipt("morning"))
        let second = try await preparer().prepare(download: receipt("afternoon"))
        XCTAssertEqual(second.messageID, "afternoon")
        XCTAssertEqual(second.frames, first.frames)
        XCTAssertTrue(second.diagnostic?.contains("reused_verified_video_evidence") == true)
        let extracted = await extractor.count
        let transcribed = await transcriber.count
        XCTAssertEqual(extracted, 1)
        XCTAssertEqual(transcribed, 1)
        try Data("damaged".utf8).write(to: first.frames[0].localURL)
        _ = try await preparer().prepare(download: receipt("evening"))
        let regenerated = await extractor.count
        XCTAssertEqual(regenerated, 2)
    }

    func testNoAudioEvidenceKeepsRepeatedFramesAndWritesOrderedManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-video-evidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("video.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-a-real-video".utf8).write(to: video)
        let summary = PDDVideoFileSummary(
            byteCount: 16, sha256: "video-sha", durationSeconds: 8,
            width: 720, height: 1280, videoCodec: "H.264", audioCodec: nil
        )
        let download = PDDDownloadedCustomerVideo(
            uid: "PDD-one", messageID: "v1",
            key: PDDVideoTransferKey(uid: "PDD-one", messageID: "v1"),
            fileURL: video, summary: summary
        )
        let preparer = PDDCustomerVideoEvidencePreparer(
            rootURL: root.appendingPathComponent("evidence"),
            transcriber: TranscriptStub(),
            frameExtractor: RepeatedFrameExtractorStub()
        )

        let attachment = try await preparer.prepare(download: download)

        XCTAssertEqual(attachment.frames.map(\.timestampSeconds), [1, 7])
        XCTAssertEqual(attachment.frames.count, 2, "visually repeated frames must not be deduplicated")
        XCTAssertNil(attachment.audioLocalURL)
        XCTAssertEqual(attachment.transcriptSegments.map(\.text), ["先", "后"])
        let manifestData = try Data(contentsOf: XCTUnwrap(attachment.manifestLocalURL))
        let manifest = try JSONDecoder().decode(PDDCustomerVideoEvidenceManifest.self, from: manifestData)
        XCTAssertEqual(manifest.frames.map(\.timestampSeconds), [1, 7])
        XCTAssertEqual(manifest.transcript.map(\.startSeconds), [1, 5])
    }

    func testTranscriptionFallsBackToVideoWhenAudioWasNotSaved() {
        let staging = URL(fileURLWithPath: "/tmp/evidence")
        let video = URL(fileURLWithPath: "/tmp/video.mp4")
        XCTAssertEqual(
            PDDCustomerVideoEvidencePreparer.transcriptionInputURL(
                stagingURL: staging, audioFileName: nil, fallbackVideoURL: video
            ),
            video
        )
    }
}

private actor CountingFrameExtractor: PDDVideoFrameExtracting {
    var count = 0
    func extractFrames(from videoURL: URL, durationSeconds: Double, destinationDirectory: URL) async throws -> [AutoReplyVideoFrame] {
        count += 1
        return try await RepeatedFrameExtractorStub().extractFrames(from: videoURL,
            durationSeconds: durationSeconds, destinationDirectory: destinationDirectory)
    }
}

private actor CountingTranscriber: PDDVideoSpeechTranscribing {
    var count = 0
    func transcribe(_ mediaURL: URL) async -> [PDDVideoTranscriptSegment] {
        count += 1
        return [.init(startSeconds: 1, durationSeconds: 1, text: "test")]
    }
}

private struct RepeatedFrameExtractorStub: PDDVideoFrameExtracting {
    func extractFrames(
        from videoURL: URL, durationSeconds: Double, destinationDirectory: URL
    ) async throws -> [AutoReplyVideoFrame] {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let late = destinationDirectory.appendingPathComponent("late.jpg")
        let early = destinationDirectory.appendingPathComponent("early.jpg")
        let same = Data([0xff, 0xd8, 0xff])
        try same.write(to: late)
        try same.write(to: early)
        return [
            .init(timestampSeconds: 7, localURL: late),
            .init(timestampSeconds: 1, localURL: early)
        ]
    }
}

private struct TranscriptStub: PDDVideoSpeechTranscribing {
    func transcribe(_ mediaURL: URL) async -> [PDDVideoTranscriptSegment] {
        [
            .init(startSeconds: 5, durationSeconds: 1, text: "后"),
            .init(startSeconds: 1, durationSeconds: 1, text: "先")
        ]
    }
}
