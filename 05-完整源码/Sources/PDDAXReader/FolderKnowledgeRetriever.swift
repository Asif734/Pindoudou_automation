import Foundation

protocol SemanticKnowledgeRetrieving: KnowledgeContextRetrieving {
    func retrieveSemantic(query: String) async throws -> RetrievedKnowledge
    func retrieveSemantic(queries: [String]) async throws -> RetrievedKnowledge
}

extension SemanticKnowledgeRetrieving {
    func retrieveSemantic(queries: [String]) async throws -> RetrievedKnowledge {
        try await retrieveSemantic(query: queries.joined(separator: "\n\n"))
    }
}

actor FolderKnowledgeRetriever: SemanticKnowledgeRetrieving, KnowledgePrewarming {
    private let worker: PersistentJSONLWorker
    private var preparation: Task<KnowledgePreparation, Error>?

    init(resources: KnowledgeResources) {
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        environment["HF_HUB_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        worker = PersistentJSONLWorker(
            executable: resources.pythonURL,
            arguments: [resources.workerScriptURL.path,
                        "--folder", resources.knowledgeBaseURL.path,
                        "--model-path", resources.seedCacheURL.path,
                        "--cache", resources.writableCacheURL.path],
            environment: environment,
            startupDeadline: .seconds(180), queryDeadline: .seconds(30)
        )
    }

    func prepare(knowledgeBaseURLs: [URL]) async throws -> KnowledgePreparation {
        if let preparation { return try await preparation.value }
        let worker = self.worker
        let task = Task<KnowledgePreparation, Error> {
            let data = try await worker.start()
            let message = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard message?["type"] as? String == "ready" else { throw PersistentWorkerError.invalidLine("folder worker not ready") }
            return KnowledgePreparation(version: "folder-hybrid")
        }
        preparation = task
        do { return try await task.value }
        catch { preparation = nil; await worker.stop(); throw error }
    }

    func retrieve(historyJSONL: String, knowledgeBaseURLs: [URL]) async throws -> RetrievedKnowledge {
        try await request(query: Self.firstQuery(historyJSONL: historyJSONL), semantic: false)
    }

    static func firstQuery(historyJSONL: String) -> String {
        let messages = historyJSONL.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let query = messages.filter { $0["sender"] as? String == "customer" }
            .suffix(4).compactMap { $0["v"] as? String }.joined(separator: "\n")
        return query
    }

    func retrieveSemantic(query: String) async throws -> RetrievedKnowledge {
        try await request(query: query, semantic: true)
    }

    func retrieveSemantic(queries: [String]) async throws -> RetrievedKnowledge {
        try await request(query: queries.first ?? "", semantic: true, queries: queries)
    }

    private func request(query: String, semantic: Bool, queries: [String]? = nil) async throws -> RetrievedKnowledge {
        do {
            _ = try await prepare(knowledgeBaseURLs: [])
            let id = UUID().uuidString
            var body: [String: Any] = ["id": id, "query": query, "semantic_only": semantic]
            if let queries { body["queries"] = queries }
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = try JSONDecoder().decode(Response.self, from: await worker.request(data))
            guard response.id == id, response.ok, let result = response.result else {
                throw PersistentWorkerError.invalidLine(response.error ?? "folder response ID mismatch")
            }
            return result
        } catch {
            await worker.stop()
            preparation = nil
            throw error
        }
    }

    func shutdown() async { preparation?.cancel(); await worker.stop(); preparation = nil }

    private struct Response: Decodable {
        let id: String?
        let ok: Bool
        let result: RetrievedKnowledge?
        let error: String?
    }
}
