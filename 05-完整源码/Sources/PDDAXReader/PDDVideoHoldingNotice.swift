import Foundation

/// A courtesy message is separate from capture/model/final-reply receipts.
struct PDDVideoHoldingNotice: Codable, Equatable, Sendable, Identifiable {
    static let messages = [
        "视频已收到，请稍等，我这边查看一下。",
        "收到您发的视频了，麻烦稍等片刻，我看一下具体情况。",
        "感谢您提供视频，请稍等，我查看后继续为您解答。",
        "请稍等一下，我这边正在查看您发的视频。",
        "您的视频已收到，请给我一点时间查看里面的细节。"
    ]
    let id: UUID
    let uid: String
    var messageIDs: Set<String>
    let capturedAt: Date
    let text: String
    var attemptedAt: Date?
    var finishedAt: Date?
    var outcome: String?
    var confirmedServiceMessageID: String?

    init(uid: String, messageIDs: Set<String>, capturedAt: Date) {
        id = UUID(); self.uid = uid; self.messageIDs = messageIDs
        self.capturedAt = capturedAt; text = Self.messages.randomElement()!
    }
}

/// Join only messages whose shared history actually contains every target ID.
/// Keeps the chronological customer intent and all original media attachments.
enum PDDVideoReplyBatch {
    static func joining(_ captures: [AutoReplyCapture]) -> AutoReplyCapture? {
        guard let first = captures.first, captures.allSatisfy({ $0.uid == first.uid && $0.batch?.incomingHandoffKey == nil }),
              let latest = captures.max(by: { $0.customerCursor.count < $1.customerCursor.count }) else { return nil }
        let ids = Set(captures.flatMap { $0.batch?.events.map(\.messageID) ?? [] })
        guard ids.isSubset(of: Set(latest.fullHistory.map(\.id))),
              let timeline = try? AutoReplyTimeline.make(messages: latest.fullHistory),
              let whole = try? timeline.freeze(after: .empty) else { return nil }
        let events = whole.events.filter { ids.contains($0.messageID) }
        guard events.count == ids.count else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let lines = try? events.map({ String(decoding: try encoder.encode($0), as: UTF8.self) }) else { return nil }
        func unique<T>(_ values: [T], key: (T) -> String) -> [T] {
            var seen = Set<String>(); return values.filter { seen.insert(key($0)).inserted }
        }
        return AutoReplyCapture(uid: first.uid, fullHistory: latest.fullHistory,
            batch: .init(startCursor: captures.compactMap { $0.batch?.startCursor }.min(by: { $0.count < $1.count }) ?? .empty,
                         endCursor: latest.customerCursor, events: events, targetCustomerJSONL: lines.joined(separator: "\n")),
            customerCursor: latest.customerCursor, unexpectedServiceMessageIDs: [],
            ocrDiagnostic: captures.compactMap(\.ocrDiagnostic).joined(separator: "; "),
            imageAttachments: unique(captures.flatMap(\.imageAttachments), key: { $0.messageID }),
            videoAttachments: unique(captures.flatMap(\.videoAttachments), key: { $0.messageID }),
            pendingVideoMessageIDs: Array(Set(captures.flatMap(\.pendingVideoMessageIDs))).sorted())
    }
}
