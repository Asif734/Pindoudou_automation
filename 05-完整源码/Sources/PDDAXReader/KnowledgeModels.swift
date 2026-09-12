import Foundation

enum KnowledgeRetrievalMode: String, Codable, Equatable, Sendable {
    case v2Top12 = "v2-top12"
    case fullZipFallback = "full-zip-fallback"
    case unavailable = "unavailable"
}

struct RetrievedKnowledge: Codable, Equatable, Sendable {
    let version: String
    let documents: [String]
    let context: String

    var hasOriginalSections: Bool {
        let opening = "<most_relevant_original_sections>"
        let closing = "</most_relevant_original_sections>"
        guard let start = context.range(of: opening),
              let end = context.range(of: closing, range: start.upperBound..<context.endIndex),
              start.upperBound <= end.lowerBound else { return false }
        return !context[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct KnowledgeRetrievalDiagnostic: Codable, Equatable, Sendable {
    let mode: KnowledgeRetrievalMode
    let knowledgeBaseSHA256: String?
    let selectedDocuments: [String]
    let contextSHA256: String?
    let durationMilliseconds: Int
    let error: String?

    static let emptyFallback = KnowledgeRetrievalDiagnostic(
        mode: .unavailable,
        knowledgeBaseSHA256: nil,
        selectedDocuments: [],
        contextSHA256: nil,
        durationMilliseconds: 0,
        error: nil
    )
}

struct KnowledgeEvidence: Codable, Equatable, Sendable {
    let mode: KnowledgeRetrievalMode
    let version: String
    let documents: [String]
    let context: String
    let diagnostic: KnowledgeRetrievalDiagnostic
}
