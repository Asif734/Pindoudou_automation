import CryptoKit
import Foundation

protocol KnowledgeEvidencePreparing: Sendable {
    func prepare(capture: AutoReplyCapture) async -> KnowledgeEvidence
}

struct KnowledgeEvidenceService: KnowledgeEvidencePreparing, Sendable {
    let retriever: any KnowledgeContextRetrieving
    let versioner: KnowledgeBaseVersioner
    let knowledgeBaseURL: URL
    let now: @Sendable () -> Date

    init(
        retriever: any KnowledgeContextRetrieving,
        versioner: KnowledgeBaseVersioner,
        knowledgeBaseURL: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.retriever = retriever
        self.versioner = versioner
        self.knowledgeBaseURL = knowledgeBaseURL
        self.now = now
    }

    func prepare(capture: AutoReplyCapture) async -> KnowledgeEvidence {
        let started = now()
        let knowledgeHash = try? await versioner.version(url: knowledgeBaseURL)
        do {
            let fullHistory = Self.historyJSONL(capture.fullHistory)
            let targetHistory = Self.targetHistoryJSONL(capture.batch?.events ?? [])
            let focused = V2KnowledgeRetriever.focusedHistoryJSONL(
                fullHistoryJSONL: fullHistory,
                targetCustomerJSONL: targetHistory
            )
            let result = try await retriever.retrieve(
                historyJSONL: focused,
                knowledgeBaseURLs: [knowledgeBaseURL]
            )
            guard [KnowledgeRetrievalMode.v2Top12.rawValue, "v2-lexical-only"].contains(result.version),
                  result.hasOriginalSections else {
                throw V2KnowledgeRetrieverError.invalidOutput("缺少原文章节")
            }
            let diagnostic = KnowledgeRetrievalDiagnostic(
                mode: .v2Top12,
                knowledgeBaseSHA256: knowledgeHash,
                selectedDocuments: result.documents,
                contextSHA256: Self.sha256(result.context),
                durationMilliseconds: Self.milliseconds(from: started, to: now()),
                error: nil
            )
            return KnowledgeEvidence(
                mode: .v2Top12,
                version: result.version,
                documents: result.documents,
                context: result.context,
                diagnostic: diagnostic
            )
        } catch {
            let diagnostic = KnowledgeRetrievalDiagnostic(
                mode: .unavailable,
                knowledgeBaseSHA256: knowledgeHash,
                selectedDocuments: [],
                contextSHA256: nil,
                durationMilliseconds: Self.milliseconds(from: started, to: now()),
                error: error.localizedDescription
            )
            return KnowledgeEvidence(
                mode: .unavailable,
                version: KnowledgeRetrievalMode.unavailable.rawValue,
                documents: [],
                context: "",
                diagnostic: diagnostic
            )
        }
    }

    private struct V2Message: Encodable {
        let sender: String
        let v: String
        let kind: String
        let id: String
    }

    private static func historyJSONL(_ messages: [PDDChatMessage]) -> String {
        encodeJSONL(messages.map {
            V2Message(
                sender: $0.sender == .customer ? "customer" : "service",
                v: $0.content,
                kind: $0.kind.rawValue,
                id: $0.id
            )
        })
    }

    private static func targetHistoryJSONL(_ events: [ActionableCustomerEvent]) -> String {
        encodeJSONL(events.map {
            V2Message(
                sender: "customer",
                v: $0.content,
                kind: $0.kind.rawValue,
                id: $0.messageID
            )
        })
    }

    private static func encodeJSONL(_ messages: [V2Message]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return messages.compactMap { message in
            guard let data = try? encoder.encode(message) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + (messages.isEmpty ? "" : "\n")
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) * 1_000))
    }
}
