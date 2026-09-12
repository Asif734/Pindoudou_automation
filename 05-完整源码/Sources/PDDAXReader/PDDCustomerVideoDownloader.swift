import AVFoundation
import CryptoKit
import Foundation

enum PDDVideoDownloadPolicy {
    static func accepts(statusCode: Int, mimeType: String?) -> Bool {
        guard statusCode == 200 || statusCode == 206 else { return false }
        guard let mimeType = mimeType?.lowercased(), !mimeType.isEmpty else { return true }
        return mimeType == "video/mp4" || mimeType == "application/octet-stream"
    }
}

enum PDDVideoFileInspector {
    static func inspect(_ url: URL) async throws -> PDDVideoFileSummary {
        try Task.checkCancellation()
        guard try hasISOBaseMediaHeader(url) else { throw PDDCustomerVideoError.invalidMedia }
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            try Task.checkCancellation()
            let tracks = try await asset.loadTracks(withMediaType: .video)
            try Task.checkCancellation()
            guard let track = tracks.first, duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
                throw PDDCustomerVideoError.missingVideoTrack
            }
            async let naturalSize = track.load(.naturalSize)
            async let transform = track.load(.preferredTransform)
            async let formats = track.load(.formatDescriptions)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            try Task.checkCancellation()
            let audioFormats = try await audioTracks.first?.load(.formatDescriptions) ?? []
            let oriented = CGRect(origin: .zero, size: try await naturalSize)
                .applying(try await transform).standardized
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try Task.checkCancellation()
            return PDDVideoFileSummary(
                byteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                sha256: try digest(url), durationSeconds: duration.seconds,
                width: Int(oriented.width.rounded()), height: Int(oriented.height.rounded()),
                videoCodec: codecName((try await formats).first) ?? "unknown",
                audioCodec: codecName(audioFormats.first)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PDDCustomerVideoError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PDDCustomerVideoError.invalidMedia
        }
    }

    private static func hasISOBaseMediaHeader(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 12) ?? Data()
        return prefix.count >= 8 && String(decoding: prefix[4..<8], as: UTF8.self) == "ftyp"
    }

    private static func digest(_ url: URL) throws -> String {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        try Task.checkCancellation()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func codecName(_ value: CMFormatDescription?) -> String? {
        guard let value else { return nil }
        switch CMFormatDescriptionGetMediaSubType(value) {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kAudioFormatMPEG4AAC: return "AAC"
        default: return "unknown"
        }
    }
}

struct PDDCustomerVideoDownloader: PDDCustomerVideoDownloading, Sendable {
    let frameExtractor: any PDDVideoFrameExtracting
    let maximumBytes: Int64

    init(
        frameExtractor: any PDDVideoFrameExtracting = PDDVideoFrameExtractor(),
        maximumBytes: Int64 = 200 * 1024 * 1024
    ) {
        self.frameExtractor = frameExtractor
        self.maximumBytes = maximumBytes
    }

    func download(
        sourceURL: URL,
        destinationDirectory: URL,
        messageID: String
    ) async throws -> AutoReplyVideoAttachment {
        try Task.checkCancellation()
        guard sourceURL.scheme?.lowercased() == "https", PDDVideoHostPolicy.accepts(sourceURL.host) else {
            throw PDDCustomerVideoError.downloadRejected
        }
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await URLSession.shared.download(from: sourceURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PDDCustomerVideoError.downloadFailed
        }
        guard let http = response as? HTTPURLResponse,
              PDDVideoDownloadPolicy.accepts(statusCode: http.statusCode, mimeType: response.mimeType) else {
            throw PDDCustomerVideoError.downloadRejected
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0, bytes <= maximumBytes else { throw PDDCustomerVideoError.invalidMedia }
        let summary = try await PDDVideoFileInspector.inspect(temporary)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let videoURL = destinationDirectory.appendingPathComponent("\(summary.sha256).mp4")
        if !FileManager.default.fileExists(atPath: videoURL.path) {
            try Task.checkCancellation()
            do { try FileManager.default.copyItem(at: temporary, to: videoURL) }
            catch { throw PDDCustomerVideoError.downloadFailed }
        }
        try Task.checkCancellation()
        let frames = try await frameExtractor.extractFrames(
            from: videoURL,
            durationSeconds: summary.durationSeconds,
            destinationDirectory: destinationDirectory.appendingPathComponent("\(summary.sha256)-frames")
        )
        try Task.checkCancellation()
        return AutoReplyVideoAttachment(
            messageID: messageID, localURL: videoURL, sha256: summary.sha256,
            byteCount: summary.byteCount, durationSeconds: summary.durationSeconds,
            width: summary.width, height: summary.height, videoCodec: summary.videoCodec,
            audioCodec: summary.audioCodec, frames: frames, transcript: nil,
            diagnostic: summary.audioCodec == nil ? "无音轨" : "语音未转写"
        )
    }
}
