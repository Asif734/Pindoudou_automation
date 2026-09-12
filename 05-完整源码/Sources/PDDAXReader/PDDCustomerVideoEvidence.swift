import AVFoundation
import CryptoKit
import Foundation

struct PDDDownloadedCustomerVideo: Codable, Equatable, Sendable {
    let uid: String
    let messageID: String
    let key: PDDVideoTransferKey
    let fileURL: URL
    let summary: PDDVideoFileSummary
}

struct PDDCustomerVideoFrameManifest: Codable, Equatable, Sendable {
    let timestampSeconds: Double
    let fileName: String
    let sha256: String
}

struct PDDVideoTranscriptSegment: Codable, Equatable, Sendable {
    let startSeconds: Double
    let durationSeconds: Double
    let text: String
}

struct PDDCustomerVideoEvidenceManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let messageHash: String
    let durationSeconds: Double
    let width: Int
    let height: Int
    let frames: [PDDCustomerVideoFrameManifest]
    let audioFileName: String?
    let transcript: [PDDVideoTranscriptSegment]
}

protocol PDDVideoSpeechTranscribing: Sendable {
    func transcribe(_ mediaURL: URL) async -> [PDDVideoTranscriptSegment]
}

struct PDDNoVideoSpeechTranscriber: PDDVideoSpeechTranscribing {
    func transcribe(_ mediaURL: URL) async -> [PDDVideoTranscriptSegment] { [] }
}

protocol PDDCustomerVideoEvidencePreparing: Sendable {
    func prepare(download: PDDDownloadedCustomerVideo) async throws -> AutoReplyVideoAttachment
}

private struct PDDCustomerVideoAudioExporter: Sendable {
    func export(from asset: AVURLAsset, to outputURL: URL) async throws -> Bool {
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { return false }
        guard let exporter = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A
        ) else { return false }
        if #available(macOS 15.0, *) {
            try await exporter.export(to: outputURL, as: .m4a)
        } else {
            exporter.outputURL = outputURL
            exporter.outputFileType = .m4a
            await exporter.export()
            guard exporter.status == .completed else {
                throw exporter.error ?? PDDCustomerVideoError.invalidMedia
            }
        }
        return FileManager.default.fileExists(atPath: outputURL.path)
    }
}

struct PDDCustomerVideoEvidencePreparer: PDDCustomerVideoEvidencePreparing {
    let rootURL: URL
    let transcriber: any PDDVideoSpeechTranscribing
    let frameExtractor: any PDDVideoFrameExtracting

    init(
        rootURL: URL,
        transcriber: any PDDVideoSpeechTranscribing = PDDNoVideoSpeechTranscriber(),
        frameExtractor: any PDDVideoFrameExtracting = PDDVideoFrameExtractor(maximumFrames: 20)
    ) {
        self.rootURL = rootURL
        self.transcriber = transcriber
        self.frameExtractor = frameExtractor
    }

    static func transcriptionInputURL(
        stagingURL: URL,
        audioFileName: String?,
        fallbackVideoURL: URL
    ) -> URL {
        guard let audioFileName else { return fallbackVideoURL }
        return stagingURL.appendingPathComponent(audioFileName)
    }

    func prepare(download: PDDDownloadedCustomerVideo) async throws -> AutoReplyVideoAttachment {
        try Task.checkCancellation()
        let staging = rootURL.appendingPathComponent(
            ".\(download.key.messageHash).\(UUID().uuidString)", isDirectory: true
        )
        let final = rootURL.appendingPathComponent(download.key.messageHash, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let extracted = try await frameExtractor.extractFrames(
                from: download.fileURL,
                durationSeconds: download.summary.durationSeconds,
                destinationDirectory: staging
            )
            guard !extracted.isEmpty else { throw PDDCustomerVideoError.invalidMedia }
            let frames = try extracted.map { frame in
                PDDCustomerVideoFrameManifest(
                    timestampSeconds: frame.timestampSeconds,
                    fileName: frame.localURL.lastPathComponent,
                    sha256: try Self.digest(frame.localURL)
                )
            }.sorted { $0.timestampSeconds < $1.timestampSeconds }

            let asset = AVURLAsset(url: download.fileURL)
            let audioName = "audio.m4a"
            let audioSaved = (try? await PDDCustomerVideoAudioExporter().export(
                from: asset, to: staging.appendingPathComponent(audioName)
            )) == true
            let transcript = await transcriber.transcribe(Self.transcriptionInputURL(
                stagingURL: staging,
                audioFileName: audioSaved ? audioName : nil,
                fallbackVideoURL: download.fileURL
            )).sorted { lhs, rhs in lhs.startSeconds < rhs.startSeconds }
            let manifest = PDDCustomerVideoEvidenceManifest(
                schemaVersion: 2,
                messageHash: download.key.messageHash,
                durationSeconds: download.summary.durationSeconds,
                width: download.summary.width,
                height: download.summary.height,
                frames: frames,
                audioFileName: audioSaved ? audioName : nil,
                transcript: transcript
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(manifest).write(
                to: staging.appendingPathComponent("manifest.json"), options: .atomic
            )
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: final.path) {
                try FileManager.default.removeItem(at: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: final)
            }
            let finalFrames = frames.map {
                AutoReplyVideoFrame(
                    timestampSeconds: $0.timestampSeconds,
                    localURL: final.appendingPathComponent($0.fileName)
                )
            }
            let transcriptText = transcript.map {
                String(format: "%.2f–%.2f秒：%@", $0.startSeconds, $0.startSeconds + $0.durationSeconds, $0.text)
            }.joined(separator: "；")
            return AutoReplyVideoAttachment(
                messageID: download.messageID,
                localURL: download.fileURL,
                sha256: download.summary.sha256,
                byteCount: download.summary.byteCount,
                durationSeconds: download.summary.durationSeconds,
                width: download.summary.width,
                height: download.summary.height,
                videoCodec: download.summary.videoCodec,
                audioCodec: download.summary.audioCodec,
                frames: finalFrames,
                transcript: transcriptText.isEmpty ? nil : transcriptText,
                transcriptSegments: transcript,
                diagnostic: transcript.isEmpty ? "没有可靠语音转写" : nil,
                audioLocalURL: audioSaved ? final.appendingPathComponent(audioName) : nil,
                manifestLocalURL: final.appendingPathComponent("manifest.json")
            )
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
