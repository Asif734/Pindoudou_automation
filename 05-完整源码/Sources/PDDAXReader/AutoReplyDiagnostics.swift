import Foundation

struct CodexExecutionEvent: Codable, Equatable, Sendable {
    let type: String
    let threadID: String?
}

struct AutoReplyGenerationDiagnostic: Codable, Equatable, Sendable {
    let knowledge: KnowledgeRetrievalDiagnostic
    let codexDurationMilliseconds: Int
    let events: [CodexExecutionEvent]
    var model: String? = nil
    var reasoningEffort: String? = nil
    var tokenUsage: CodexTokenUsage? = nil
    var tokenUsageScope: String? = nil
}

struct CodexTokenUsage: Codable, Equatable, Sendable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int

    var totalTokens: Int { inputTokens + outputTokens }

    init(inputTokens: Int, cachedInputTokens: Int, outputTokens: Int, reasoningOutputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }

    func subtracting(_ previous: CodexTokenUsage) -> CodexTokenUsage? {
        guard inputTokens >= previous.inputTokens, cachedInputTokens >= previous.cachedInputTokens,
              outputTokens >= previous.outputTokens, reasoningOutputTokens >= previous.reasoningOutputTokens else { return nil }
        return CodexTokenUsage(inputTokens: inputTokens - previous.inputTokens,
            cachedInputTokens: cachedInputTokens - previous.cachedInputTokens,
            outputTokens: outputTokens - previous.outputTokens,
            reasoningOutputTokens: reasoningOutputTokens - previous.reasoningOutputTokens)
    }

    init?(json: [String: Any]?) {
        guard let json, let input = json["input_tokens"] as? Int,
              let output = json["output_tokens"] as? Int else { return nil }
        inputTokens = input
        cachedInputTokens = json["cached_input_tokens"] as? Int ?? 0
        outputTokens = output
        reasoningOutputTokens = json["reasoning_output_tokens"] as? Int ?? 0
    }
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
