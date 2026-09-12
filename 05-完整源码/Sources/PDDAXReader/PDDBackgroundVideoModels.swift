import CryptoKit
import Foundation

struct PDDVideoTransferKey: Codable, Equatable, Hashable, Sendable {
    let customerHash: String
    let messageHash: String

    init(uid: String, messageID: String) {
        customerHash = Self.hash(uid)
        messageHash = Self.hash(messageID)
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum PDDVideoTransferPhase: String, Codable, Equatable, Sendable {
    case armed
    case waitingForAddress
    case downloading
    case downloaded
    case preparingEvidence
    case readyForGeneration
    case admitted
    case completed
    case duplicate
    case failed
    case waitingForRetry
    case fallbackRequired
}

struct PDDPendingVideoBatch: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let uid: String
    let capture: AutoReplyCapture
    let expectedMessageIDs: [String]
    var completedAttachmentsByMessageID: [String: AutoReplyVideoAttachment]
    var failedMessageIDs: Set<String>
    var duplicateMessageIDs: Set<String>
    let createdAt: Date

    init(
        id: UUID = UUID(),
        uid: String,
        capture: AutoReplyCapture,
        expectedMessageIDs: [String],
        completedAttachmentsByMessageID: [String: AutoReplyVideoAttachment] = [:],
        failedMessageIDs: Set<String> = [],
        duplicateMessageIDs: Set<String> = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.uid = uid
        self.capture = capture
        self.expectedMessageIDs = expectedMessageIDs
        self.completedAttachmentsByMessageID = completedAttachmentsByMessageID
        self.failedMessageIDs = failedMessageIDs
        self.duplicateMessageIDs = duplicateMessageIDs
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, uid, capture, expectedMessageIDs, completedAttachmentsByMessageID
        case failedMessageIDs, duplicateMessageIDs, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        uid = try container.decode(String.self, forKey: .uid)
        capture = try container.decode(AutoReplyCapture.self, forKey: .capture)
        expectedMessageIDs = try container.decode([String].self, forKey: .expectedMessageIDs)
        completedAttachmentsByMessageID = try container.decodeIfPresent(
            [String: AutoReplyVideoAttachment].self,
            forKey: .completedAttachmentsByMessageID
        ) ?? [:]
        failedMessageIDs = try container.decodeIfPresent(
            Set<String>.self, forKey: .failedMessageIDs
        ) ?? []
        duplicateMessageIDs = try container.decodeIfPresent(
            Set<String>.self, forKey: .duplicateMessageIDs
        ) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct PDDVideoTransferEvent: Codable, Equatable, Sendable {
    let uid: String
    let messageID: String
    let phase: PDDVideoTransferPhase
    let attachment: AutoReplyVideoAttachment?
    let diagnostic: String?
    let timestamp: Date
    let recovered: Bool?

    init(
        uid: String,
        messageID: String,
        phase: PDDVideoTransferPhase,
        attachment: AutoReplyVideoAttachment? = nil,
        diagnostic: String? = nil,
        timestamp: Date = Date(),
        recovered: Bool = false
    ) {
        self.uid = uid
        self.messageID = messageID
        self.phase = phase
        self.attachment = attachment
        self.diagnostic = diagnostic
        self.timestamp = timestamp
        self.recovered = recovered ? true : nil
    }

    var key: PDDVideoTransferKey {
        PDDVideoTransferKey(uid: uid, messageID: messageID)
    }
}

struct PDDVideoProgressStatus: Codable, Equatable, Sendable {
    let uid: String
    let messageID: String
    let phase: PDDVideoTransferPhase
    let detail: String?
    let timestamp: Date

    init(event: PDDVideoTransferEvent) {
        uid = event.uid
        messageID = event.messageID
        phase = event.phase
        detail = event.diagnostic
        timestamp = event.timestamp
    }

    init(
        uid: String, messageID: String, phase: PDDVideoTransferPhase,
        detail: String?, timestamp: Date
    ) {
        self.uid = uid
        self.messageID = messageID
        self.phase = phase
        self.detail = detail
        self.timestamp = timestamp
    }
}
