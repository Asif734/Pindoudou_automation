import CryptoKit
import Foundation

struct ActionableCustomerEvent: Codable, Equatable, Sendable {
    let messageID: String
    let kind: ChatContentKind
    let content: String
    let displayTime: String?
}

struct AutoReplyCursor: Codable, Equatable, Hashable, Sendable {
    let count: Int
    let digest: String

    static let empty = AutoReplyCursor(count: 0, digest: String(repeating: "0", count: 64))
}

struct FrozenCustomerBatch: Codable, Equatable, Sendable {
    let startCursor: AutoReplyCursor
    let endCursor: AutoReplyCursor
    let events: [ActionableCustomerEvent]
    let targetCustomerJSONL: String
}

enum AutoReplyTimelineError: Error, Equatable {
    case invalidPrefix
    case encodingFailed
}

struct AutoReplyTimeline: Equatable, Sendable {
    let events: [ActionableCustomerEvent]
    let cursor: AutoReplyCursor

    private let prefixCursors: [AutoReplyCursor]
    private let canonicalJSON: [String]

    static func make(messages: [PDDChatMessage]) throws -> AutoReplyTimeline {
        let events = messages.compactMap { message -> ActionableCustomerEvent? in
            guard message.sender == .customer else { return nil }
            return ActionableCustomerEvent(
                messageID: message.id,
                kind: message.kind,
                content: message.content,
                displayTime: message.displayTime
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var cursors = [AutoReplyCursor.empty]
        var lines: [String] = []
        var previous = AutoReplyCursor.empty.digest

        for (index, event) in events.enumerated() {
            guard
                let data = try? encoder.encode(event),
                let line = String(data: data, encoding: .utf8)
            else { throw AutoReplyTimelineError.encodingFailed }
            lines.append(line)
            var chained = Data(previous.utf8)
            chained.append(data)
            previous = SHA256.hash(data: chained).map { String(format: "%02x", $0) }.joined()
            cursors.append(AutoReplyCursor(count: index + 1, digest: previous))
        }

        return AutoReplyTimeline(
            events: events,
            cursor: cursors.last ?? .empty,
            prefixCursors: cursors,
            canonicalJSON: lines
        )
    }

    func freeze(after start: AutoReplyCursor) throws -> FrozenCustomerBatch? {
        guard start.count >= 0,
              start.count < prefixCursors.count,
              prefixCursors[start.count] == start
        else { throw AutoReplyTimelineError.invalidPrefix }

        guard start.count < events.count else { return nil }
        return FrozenCustomerBatch(
            startCursor: start,
            endCursor: cursor,
            events: Array(events.dropFirst(start.count)),
            targetCustomerJSONL: canonicalJSON.dropFirst(start.count).joined(separator: "\n")
        )
    }

    func validatesPrefix(_ prefix: AutoReplyCursor) -> Bool {
        guard prefix.count >= 0, prefix.count < prefixCursors.count else { return false }
        return prefixCursors[prefix.count] == prefix
    }

    func prefixCursor(at count: Int) -> AutoReplyCursor? {
        guard count >= 0, count < prefixCursors.count else { return nil }
        return prefixCursors[count]
    }
}
