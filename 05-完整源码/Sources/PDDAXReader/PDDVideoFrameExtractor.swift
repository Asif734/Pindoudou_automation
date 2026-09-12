import AppKit
import AVFoundation
import Foundation

enum PDDVideoFrameSchedule {
    static func timestamps(durationSeconds: Double, maximumFrames: Int) -> [Double] {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return [] }
        let limit = max(1, min(20, maximumFrames))
        let count: Int
        if durationSeconds < 2 {
            count = min(3, limit)
        } else if durationSeconds <= 10 {
            count = min(limit, max(4, Int(ceil(durationSeconds))))
        } else if durationSeconds <= 30 {
            count = min(limit, max(4, Int(ceil(durationSeconds / 2)) + 1))
        } else {
            count = limit
        }
        if count == 1 { return [durationSeconds * 0.5] }
        let inset = min(0.20, durationSeconds * 0.1)
        let start = inset
        let end = max(start, durationSeconds - inset)
        return (0..<count).map { index in
            start + (end - start) * Double(index) / Double(count - 1)
        }.reduce(into: [Double]()) { values, value in
            if values.last.map({ abs($0 - value) >= 0.04 }) ?? true {
                values.append(value)
            }
        }
    }
}

protocol PDDVideoFrameExtracting: Sendable {
    func extractFrames(
        from videoURL: URL,
        durationSeconds: Double,
        destinationDirectory: URL
    ) async throws -> [AutoReplyVideoFrame]
}

struct PDDVideoFrameExtractor: PDDVideoFrameExtracting, Sendable {
    let maximumFrames: Int
    init(maximumFrames: Int = 20) { self.maximumFrames = max(1, min(20, maximumFrames)) }

    func extractFrames(
        from videoURL: URL,
        durationSeconds: Double,
        destinationDirectory: URL
    ) async throws -> [AutoReplyVideoFrame] {
        try Task.checkCancellation()
        let timestamps = PDDVideoFrameSchedule.timestamps(
            durationSeconds: durationSeconds, maximumFrames: maximumFrames
        )
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        var frames: [AutoReplyVideoFrame] = []
        for (index, seconds) in timestamps.enumerated() {
            try Task.checkCancellation()
            let image = try await generateImage(
                at: CMTime(seconds: seconds, preferredTimescale: 600),
                using: generator
            )
            try Task.checkCancellation()
            let representation = NSBitmapImageRep(cgImage: image)
            guard let data = representation.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
                throw PDDCustomerVideoError.invalidMedia
            }
            let destination = destinationDirectory.appendingPathComponent(
                String(format: "frame-%02d-%07.3f.jpg", index + 1, seconds)
            )
            try Task.checkCancellation()
            try data.write(to: destination, options: .atomic)
            try Task.checkCancellation()
            frames.append(.init(timestampSeconds: seconds, localURL: destination))
        }
        return frames
    }

    private func generateImage(
        at time: CMTime,
        using generator: AVAssetImageGenerator
    ) async throws -> CGImage {
        try await withTaskCancellationHandler {
            let (image, _) = try await generator.image(at: time)
            return image
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }
}
