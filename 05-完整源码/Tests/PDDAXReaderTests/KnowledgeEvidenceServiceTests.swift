import XCTest
@testable import PDDAXReader

final class KnowledgeEvidenceServiceTests: XCTestCase {
    func testPreparationUsesQianniuSenderValueProtocol() async throws {
        let knowledge = try makeKnowledgeFile("knowledge-v1")
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let context = """
        <retrieved_document_candidates>
        - m880.md
        </retrieved_document_candidates>

        <most_relevant_original_sections>
        SOURCE: m880.md
        M880 停电后请检查电源。
        </most_relevant_original_sections>
        """
        let retriever = RecordingKnowledgeRetriever(result: .success(RetrievedKnowledge(
            version: "v2-top12", documents: ["m880.md"], context: context
        )))
        let service = KnowledgeEvidenceService(
            retriever: retriever,
            versioner: KnowledgeBaseVersioner(),
            knowledgeBaseURL: knowledge
        )

        _ = await service.prepare(capture: try makeCapture())

        let recordedHistory = await retriever.recordedHistoryJSONL
        let history = try XCTUnwrap(recordedHistory)
        let objects = try history.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let customer = try XCTUnwrap(objects.last { $0["v"] as? String == "M880停电后不开机" })
        XCTAssertEqual(customer["sender"] as? String, "customer")
        XCTAssertEqual(customer["kind"] as? String, "text")
        XCTAssertEqual(customer["id"] as? String, "new")
        XCTAssertNil(customer["content"])
    }

    func testCandidateNamesWithoutOriginalSectionsAreUnavailable() async throws {
        let knowledge = try makeKnowledgeFile("knowledge-v1")
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let retriever = RecordingKnowledgeRetriever(result: .success(RetrievedKnowledge(
            version: "v2-top12",
            documents: ["a.md"],
            context: "<retrieved_document_candidates>\n- a.md\n</retrieved_document_candidates>"
        )))
        let service = KnowledgeEvidenceService(
            retriever: retriever,
            versioner: KnowledgeBaseVersioner(),
            knowledgeBaseURL: knowledge
        )

        let evidence = await service.prepare(capture: try makeCapture())

        XCTAssertEqual(evidence.mode, .unavailable)
        XCTAssertTrue(evidence.diagnostic.error?.contains("缺少原文章节") == true)
    }

    func testLexicalOnlyOriginalEvidenceRemainsUsableInsteadOfGoingSilent() async throws {
        let context = """
        <retrieved_document_candidates>
        - tp732.md
        </retrieved_document_candidates>
        <most_relevant_original_sections>
        TP732 不支持原生 macOS。
        </most_relevant_original_sections>
        """
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-lexical-evidence-\(UUID().uuidString)")
        try Data("kb".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = KnowledgeEvidenceService(
            retriever: RecordingKnowledgeRetriever(result: .success(RetrievedKnowledge(
                version: "v2-lexical-only", documents: ["tp732.md"], context: context
            ))),
            versioner: KnowledgeBaseVersioner(),
            knowledgeBaseURL: root
        )

        let evidence = await service.prepare(capture: try makeCapture())

        XCTAssertEqual(evidence.mode, .v2Top12)
        XCTAssertEqual(evidence.version, "v2-lexical-only")
        XCTAssertTrue(evidence.context.contains("TP732 不支持原生 macOS"))
    }

    func testSuccessfulPreparationReturnsV2EvidenceAndHashes() async throws {
        let knowledge = try makeKnowledgeFile("knowledge-v1")
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let context = """
        <retrieved_document_candidates>
        - m880.md
        </retrieved_document_candidates>

        <most_relevant_original_sections>
        可信原文
        </most_relevant_original_sections>
        """
        let retriever = RecordingKnowledgeRetriever(result: .success(RetrievedKnowledge(
            version: "v2-top12",
            documents: ["m880.md"],
            context: context
        )))
        let service = KnowledgeEvidenceService(
            retriever: retriever,
            versioner: KnowledgeBaseVersioner(),
            knowledgeBaseURL: knowledge,
            now: { Date(timeIntervalSince1970: 100) }
        )

        let evidence = await service.prepare(capture: try makeCapture())

        XCTAssertEqual(evidence.mode, .v2Top12)
        XCTAssertEqual(evidence.context, context)
        XCTAssertEqual(evidence.documents, ["m880.md"])
        XCTAssertEqual(evidence.diagnostic.knowledgeBaseSHA256, "77bc1e8765bbb92abc4a5fb144f7382ada7aa492eebbc1e057adaa11f978287c")
        XCTAssertEqual(evidence.diagnostic.contextSHA256, "6b020612a389dc33a07a866ca680c6d3638a34c970ae8ee43fd1be7bbc4aff62")
        XCTAssertNil(evidence.diagnostic.error)
    }

    func testRetrieverFailureReturnsNonThrowingUnavailableEvidenceWithoutZipFallback() async throws {
        let knowledge = try makeKnowledgeFile("knowledge-v1")
        defer { try? FileManager.default.removeItem(at: knowledge) }
        let retriever = RecordingKnowledgeRetriever(result: .failure(FixtureError.broken))
        let service = KnowledgeEvidenceService(
            retriever: retriever,
            versioner: KnowledgeBaseVersioner(),
            knowledgeBaseURL: knowledge
        )

        let evidence = await service.prepare(capture: try makeCapture())

        XCTAssertEqual(evidence.mode, .unavailable)
        XCTAssertEqual(evidence.context, "")
        XCTAssertEqual(evidence.version, "unavailable")
        XCTAssertTrue(evidence.diagnostic.error?.contains("fixture retrieval failed") == true)
        XCTAssertNotNil(evidence.diagnostic.knowledgeBaseSHA256)
    }

    private func makeKnowledgeFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kb-\(UUID().uuidString).zip")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeCapture() throws -> AutoReplyCapture {
        let message = PDDChatMessage(
            id: "new", sender: .customer, content: "M880停电后不开机", displayTime: "10:00",
            kind: .text, capturedAt: Date(timeIntervalSince1970: 1)
        )
        let timeline = try AutoReplyTimeline.make(messages: [message])
        return AutoReplyCapture(
            uid: "GZC-000001", fullHistory: [message], batch: try timeline.freeze(after: .empty),
            customerCursor: timeline.cursor, unexpectedServiceMessageIDs: []
        )
    }
}

private actor RecordingKnowledgeRetriever: KnowledgeContextRetrieving {
    let result: Result<RetrievedKnowledge, Error>
    private(set) var recordedHistoryJSONL: String?
    init(result: Result<RetrievedKnowledge, Error>) { self.result = result }
    func retrieve(historyJSONL: String, knowledgeBaseURLs: [URL]) async throws -> RetrievedKnowledge {
        recordedHistoryJSONL = historyJSONL
        return try result.get()
    }
}

private enum FixtureError: LocalizedError {
    case broken
    var errorDescription: String? { "fixture retrieval failed" }
}
