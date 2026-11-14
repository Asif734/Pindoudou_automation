import CryptoKit
import Foundation

enum HistorySubmissionMode: String, Codable, Equatable, Sendable {
    case full
    case incremental
}

struct CodexHistoryCheckpoint: Codable, Equatable, Sendable {
    let historyByteCount: Int
    let prefixSHA256: String
    let attachmentSHA256: [String: String]
    let requiresFullHistoryContinuation: Bool
    let videoSHA256ByMessageID: [String: String]?
    let historyMessageLimit: Int?
    let contextImages: [AutoReplyImageAttachment]?
    let contextVideos: [AutoReplyVideoAttachment]?

    init(
        historyByteCount: Int,
        prefixSHA256: String,
        attachmentSHA256: [String: String],
        requiresFullHistoryContinuation: Bool = false,
        videoSHA256ByMessageID: [String: String]? = nil,
        historyMessageLimit: Int? = nil,
        contextImages: [AutoReplyImageAttachment]? = nil,
        contextVideos: [AutoReplyVideoAttachment]? = nil
    ) {
        self.historyByteCount = historyByteCount
        self.prefixSHA256 = prefixSHA256
        self.attachmentSHA256 = attachmentSHA256
        self.requiresFullHistoryContinuation = requiresFullHistoryContinuation
        self.videoSHA256ByMessageID = videoSHA256ByMessageID
        self.historyMessageLimit = historyMessageLimit
        self.contextImages = contextImages
        self.contextVideos = contextVideos
    }

    private enum CodingKeys: String, CodingKey {
        case historyByteCount, prefixSHA256, attachmentSHA256
        case messageDigests, submittedImageSHA256, videoSHA256ByMessageID, historyMessageLimit
        case contextImages, contextVideos
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videoSHA256ByMessageID = try container.decodeIfPresent([String: String].self, forKey: .videoSHA256ByMessageID)
        historyMessageLimit = try container.decodeIfPresent(Int.self, forKey: .historyMessageLimit)
        contextImages = try container.decodeIfPresent([AutoReplyImageAttachment].self, forKey: .contextImages)
        contextVideos = try container.decodeIfPresent([AutoReplyVideoAttachment].self, forKey: .contextVideos)
        if container.contains(.historyByteCount) {
            historyByteCount = try container.decode(Int.self, forKey: .historyByteCount)
            prefixSHA256 = try container.decode(String.self, forKey: .prefixSHA256)
            attachmentSHA256 = try container.decode(
                [String: String].self, forKey: .attachmentSHA256
            )
            requiresFullHistoryContinuation = false
            return
        }

        _ = try container.decode([String].self, forKey: .messageDigests)
        let legacyImageDigests = try container.decodeIfPresent(
            [String].self, forKey: .submittedImageSHA256
        ) ?? []
        historyByteCount = 0
        prefixSHA256 = ""
        attachmentSHA256 = Dictionary(uniqueKeysWithValues: legacyImageDigests.enumerated().map {
            ("legacy-\($0.offset)", $0.element)
        })
        requiresFullHistoryContinuation = true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(historyByteCount, forKey: .historyByteCount)
        try container.encode(prefixSHA256, forKey: .prefixSHA256)
        try container.encode(attachmentSHA256, forKey: .attachmentSHA256)
        try container.encodeIfPresent(videoSHA256ByMessageID, forKey: .videoSHA256ByMessageID)
        try container.encodeIfPresent(historyMessageLimit, forKey: .historyMessageLimit)
        try container.encodeIfPresent(contextImages, forKey: .contextImages)
        try container.encodeIfPresent(contextVideos, forKey: .contextVideos)
    }
}

struct HistorySubmission: Equatable, Sendable {
    let mode: HistorySubmissionMode
    let historyJSONL: String
    let imageAttachments: [AutoReplyImageAttachment]
    var videoAttachments: [AutoReplyVideoAttachment]
    let checkpoint: CodexHistoryCheckpoint
    var reusedVideoAnalyses: [PDDReusedVideoAnalysis] = []
}

enum HistoryContinuation {
    static let maximumHistoryMessages = 50

    static func retainingRecentMedia(
        in capture: AutoReplyCapture,
        images: [AutoReplyImageAttachment],
        videos: [AutoReplyVideoAttachment]
    ) -> AutoReplyCapture {
        let contextIDs = Set(capture.fullHistory.suffix(maximumHistoryMessages).map(\.id))
        let imageIDs = Set(capture.imageAttachments.map(\.messageID))
        let videoIDs = Set(capture.videoAttachments.map(\.messageID))
        func available(_ url: URL) -> Bool {
            var directory: ObjCBool = false
            return url.isFileURL && FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
        }
        var restored = capture
        var restoredImages = imageIDs
        for image in images where contextIDs.contains(image.messageID) && !restoredImages.contains(image.messageID) {
            guard available(image.localURL) else { continue }
            restored.imageAttachments.append(image)
            restoredImages.insert(image.messageID)
        }
        var restoredVideos = videoIDs
        for video in videos where contextIDs.contains(video.messageID) && !restoredVideos.contains(video.messageID) {
            guard available(video.localURL), video.frames.allSatisfy({ available($0.localURL) }),
                  video.audioLocalURL.map(available) ?? true,
                  video.manifestLocalURL.map(available) ?? true else { continue }
            restored.videoAttachments.append(video)
            restoredVideos.insert(video.messageID)
        }
        return restored
    }

    static func plan(
        capture original: AutoReplyCapture,
        after previous: CodexHistoryCheckpoint?
    ) throws -> HistorySubmission {
        let capture = retainingRecentMedia(in: original, images: previous?.contextImages ?? [], videos: previous?.contextVideos ?? [])
        // Only model context is bounded. Durable history, cursors and the frozen
        // target batch remain intact, including batches larger than this window.
        let historyJSONL = AutoReplyPromptBuilder.historyJSONL(Array(capture.fullHistory.suffix(maximumHistoryMessages)))
        let historyData = Data(historyJSONL.utf8)
        // An older thread may already contain unlimited history. Never resume it.
        let prior = previous?.historyMessageLimit == maximumHistoryMessages ? previous : nil
        let attachmentDigests = Dictionary(
            capture.imageAttachments.map { ($0.localURL.path, $0.sha256) }
            + capture.videoAttachments.map { ($0.localURL.path, $0.sha256) },
            uniquingKeysWith: { _, current in current }
        )
        let continuesHistory = prior.map {
            $0.requiresFullHistoryContinuation || ($0.historyByteCount <= historyData.count
                && sha256(historyData.prefix($0.historyByteCount)) == $0.prefixSHA256)
        } ?? false
        let knownVideos = continuesHistory ? prior?.videoSHA256ByMessageID ?? [:] : [:]
        let currentVideos = Dictionary(capture.videoAttachments.map { ($0.messageID, $0.sha256) },
            uniquingKeysWith: { _, current in current })
        let submittedVideos = capture.videoAttachments.filter { knownVideos[$0.messageID] != $0.sha256 }
        let checkpoint = CodexHistoryCheckpoint(
            historyByteCount: historyData.count,
            prefixSHA256: sha256(historyData),
            attachmentSHA256: attachmentDigests,
            videoSHA256ByMessageID: knownVideos.merging(currentVideos) { _, current in current },
            historyMessageLimit: maximumHistoryMessages,
            contextImages: capture.imageAttachments.filter { image in capture.fullHistory.suffix(maximumHistoryMessages).contains { $0.id == image.messageID } },
            contextVideos: capture.videoAttachments.filter { video in capture.fullHistory.suffix(maximumHistoryMessages).contains { $0.id == video.messageID } }
        )
        if let previous = prior, previous.requiresFullHistoryContinuation {
            let knownDigests = Set(previous.attachmentSHA256.values)
            return HistorySubmission(
                mode: .incremental,
                historyJSONL: historyJSONL,
                imageAttachments: capture.imageAttachments.filter {
                    !knownDigests.contains($0.sha256)
                },
                videoAttachments: submittedVideos,
                checkpoint: checkpoint
            )
        }
        guard let previous = prior,
              previous.historyByteCount <= historyData.count,
              sha256(historyData.prefix(previous.historyByteCount)) == previous.prefixSHA256 else {
            return HistorySubmission(
                mode: .full,
                historyJSONL: historyJSONL,
                imageAttachments: capture.imageAttachments,
                videoAttachments: capture.videoAttachments,
                checkpoint: checkpoint
            )
        }
        let knownDigests = Set(previous.attachmentSHA256.values)
        let suffix = String(decoding: historyData.dropFirst(previous.historyByteCount), as: UTF8.self)
        return HistorySubmission(
            mode: .incremental,
            historyJSONL: suffix,
            imageAttachments: capture.imageAttachments.filter { !knownDigests.contains($0.sha256) },
            videoAttachments: submittedVideos,
            checkpoint: checkpoint
        )
    }

    private static func sha256<D: DataProtocol>(_ data: D) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
