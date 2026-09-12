import Foundation

struct CodexExecutionEvent: Codable, Equatable, Sendable {
    let type: String
    let threadID: String?
}

struct AutoReplyGenerationDiagnostic: Codable, Equatable, Sendable {
    let knowledge: KnowledgeRetrievalDiagnostic
    let codexDurationMilliseconds: Int
    let events: [CodexExecutionEvent]
}

struct FallbackKnowledgeEvidencePreparer: KnowledgeEvidencePreparing {
    func prepare(capture: AutoReplyCapture) async -> KnowledgeEvidence {
        KnowledgeEvidence(
            mode: .unavailable,
            version: KnowledgeRetrievalMode.unavailable.rawValue,
            documents: [],
            context: "",
            diagnostic: .emptyFallback
        )
    }
}
