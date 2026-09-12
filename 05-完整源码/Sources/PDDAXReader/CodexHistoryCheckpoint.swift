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

    init(
        historyByteCount: Int,
        prefixSHA256: String,
        attachmentSHA256: [String: String],
        requiresFullHistoryContinuation: Bool = false
    ) {
        self.historyByteCount = historyByteCount
        self.prefixSHA256 = prefixSHA256
        self.attachmentSHA256 = attachmentSHA256
        self.requiresFullHistoryContinuation = requiresFullHistoryContinuation
    }

    private enum CodingKeys: String, CodingKey {
        case historyByteCount, prefixSHA256, attachmentSHA256
        case messageDigests, submittedImageSHA256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
    }
}

struct HistorySubmission: Equatable, Sendable {
    let mode: HistorySubmissionMode
    let historyJSONL: String
    let imageAttachments: [AutoReplyImageAttachment]
    let videoAttachments: [AutoReplyVideoAttachment]
    let checkpoint: CodexHistoryCheckpoint
}

enum HistoryContinuation {
    static func plan(
        capture: AutoReplyCapture,
        after previous: CodexHistoryCheckpoint?
    ) throws -> HistorySubmission {
        let historyJSONL = AutoReplyPromptBuilder.historyJSONL(capture.fullHistory)
        let historyData = Data(historyJSONL.utf8)
        let attachmentDigests = Dictionary(uniqueKeysWithValues:
            capture.imageAttachments.map { ($0.localURL.path, $0.sha256) }
            + capture.videoAttachments.map { ($0.localURL.path, $0.sha256) }
        )
        let checkpoint = CodexHistoryCheckpoint(
            historyByteCount: historyData.count,
            prefixSHA256: sha256(historyData),
            attachmentSHA256: attachmentDigests
        )
        if let previous, previous.requiresFullHistoryContinuation {
            let knownDigests = Set(previous.attachmentSHA256.values)
            return HistorySubmission(
                mode: .incremental,
                historyJSONL: historyJSONL,
                imageAttachments: capture.imageAttachments.filter {
                    !knownDigests.contains($0.sha256)
                },
                videoAttachments: capture.videoAttachments.filter {
                    !knownDigests.contains($0.sha256)
                },
                checkpoint: checkpoint
            )
        }
        guard let previous,
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
            videoAttachments: capture.videoAttachments.filter { !knownDigests.contains($0.sha256) },
            checkpoint: checkpoint
        )
    }

    private static func sha256<D: DataProtocol>(_ data: D) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
