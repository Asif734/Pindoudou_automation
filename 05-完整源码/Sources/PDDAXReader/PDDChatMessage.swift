import Foundation

enum ChatSender: String, Codable, Equatable, Sendable {
    case customer
    case service
}

enum ChatContentKind: String, Codable, Equatable, Sendable {
    case text
    case image
    case video
    case link
}

struct PDDChatMessage: Codable, Equatable, Sendable {
    let id: String
    let sender: ChatSender
    let content: String
    let displayTime: String?
    let kind: ChatContentKind
    let capturedAt: Date
}

struct PDDChatParseResult: Equatable {
    let messages: [PDDChatMessage]
    let diagnostics: [String]
}
