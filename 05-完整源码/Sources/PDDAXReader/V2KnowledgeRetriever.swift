import Foundation

protocol KnowledgeContextRetrieving: Sendable {
    func retrieve(historyJSONL: String, knowledgeBaseURLs: [URL]) async throws -> RetrievedKnowledge
}

struct KnowledgePreparation: Sendable, Equatable {
    let version: String
}

protocol KnowledgePrewarming: Sendable {
    func prepare(knowledgeBaseURLs: [URL]) async throws -> KnowledgePreparation
    func shutdown() async
}

enum V2KnowledgeRetrieverError: LocalizedError {
    case knowledgeBaseMissing
    case processFailed(Int32, String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .knowledgeBaseMissing: return "未找到知识库 ZIP"
        case .processFailed(let code, let detail): return "V2 检索失败（\(code)）：\(detail)"
        case .invalidOutput(let detail): return "V2 检索输出无效：\(detail)"
        }
    }
}

actor V2KnowledgeRetriever: KnowledgeContextRetrieving, KnowledgePrewarming {
    let pythonURL: URL
    let scriptURL: URL
    let workerScriptURL: URL?
    let sitePackagesURL: URL
    let seedCacheURL: URL
    let writableCacheURL: URL
    let knowledgeBaseSHA256: String
    let indexRootURL: URL
    let indexAlgorithmVersion: String
    private let startupDeadline: Duration
    private let queryDeadline: Duration
    private let oneShotWorker: PersistentV2Worker
    private var worker: PersistentJSONLWorker?
    private var workerVersion: String?

    init(
        pythonURL: URL,
        scriptURL: URL,
        workerScriptURL: URL? = nil,
        sitePackagesURL: URL,
        seedCacheURL: URL,
        writableCacheURL: URL,
        knowledgeBaseSHA256: String = String(repeating: "0", count: 64),
        indexRootURL: URL? = nil,
        indexAlgorithmVersion: String = "v2-index-1",
        startupDeadline: Duration = .seconds(120),
        queryDeadline: Duration = .seconds(5)
    ) {
        self.pythonURL = pythonURL
        self.scriptURL = scriptURL
        self.workerScriptURL = workerScriptURL
        self.sitePackagesURL = sitePackagesURL
        self.seedCacheURL = seedCacheURL
        self.writableCacheURL = writableCacheURL
        self.knowledgeBaseSHA256 = knowledgeBaseSHA256
        self.indexRootURL = indexRootURL ?? writableCacheURL.appendingPathComponent("indexes")
        self.indexAlgorithmVersion = indexAlgorithmVersion
        self.startupDeadline = startupDeadline
        self.queryDeadline = queryDeadline
        oneShotWorker = PersistentV2Worker(
            pythonURL: pythonURL,
            scriptURL: scriptURL,
            environment: Self.pythonEnvironment(
                base: ProcessInfo.processInfo.environment,
                sitePackagesURL: sitePackagesURL
            )
        )
    }

    func retrieve(historyJSONL: String, knowledgeBaseURLs: [URL]) async throws -> RetrievedKnowledge {
        guard let knowledgeBase = knowledgeBaseURLs.first(where: {
            $0.pathExtension.lowercased() == "zip" && FileManager.default.fileExists(atPath: $0.path)
        }) else { throw V2KnowledgeRetrieverError.knowledgeBaseMissing }
        try FileManager.default.createDirectory(at: writableCacheURL, withIntermediateDirectories: true)
        guard let workerScriptURL else {
            let result = try await oneShotWorker.retrieve(PersistentV2Request(
                knowledgeBasePath: knowledgeBase.path,
                historyJSONL: historyJSONL,
                cacheDirectory: writableCacheURL.path,
                seedCacheDirectory: seedCacheURL.path
            ))
            return try validated(result)
        }
        var lastError: Error = PersistentWorkerError.closed
        for attempt in 0...1 {
            do {
                let active = try await prepareWorker(
                    script: workerScriptURL,
                    knowledgeBasePath: knowledgeBase.path
                )
                let requestID = UUID().uuidString
                let request = try JSONSerialization.data(withJSONObject: [
                    "id": requestID,
                    "history_jsonl": historyJSONL,
                ])
                let data = try await active.request(request)
                let response = try JSONDecoder().decode(WorkerResponse.self, from: data)
                guard response.id == requestID, response.ok, let result = response.result else {
                    throw V2KnowledgeRetrieverError.invalidOutput(response.error ?? "响应 ID 不匹配")
                }
                return try validated(result)
            } catch {
                lastError = error
                if let worker { await worker.stop() }
                worker = nil
                workerVersion = nil
                if attempt == 1 { break }
            }
        }
        throw lastError
    }

    func prepare(knowledgeBaseURLs: [URL]) async throws -> KnowledgePreparation {
        guard let workerScriptURL else {
            throw V2KnowledgeRetrieverError.invalidOutput("未配置常驻 V2 worker")
        }
        guard let knowledgeBase = knowledgeBaseURLs.first(where: {
            $0.pathExtension.lowercased() == "zip" && FileManager.default.fileExists(atPath: $0.path)
        }) else { throw V2KnowledgeRetrieverError.knowledgeBaseMissing }
        _ = try await prepareWorker(script: workerScriptURL, knowledgeBasePath: knowledgeBase.path)
        guard let workerVersion else {
            throw V2KnowledgeRetrieverError.invalidOutput("常驻 worker 未报告版本")
        }
        return KnowledgePreparation(version: workerVersion)
    }

    func shutdown() async {
        if let worker { await worker.stop() }
        worker = nil
        workerVersion = nil
        await oneShotWorker.shutdown()
    }

    static func pythonEnvironment(
        base: [String: String],
        sitePackagesURL: URL
    ) -> [String: String] {
        var environment = base
        environment["PYTHONPATH"] = sitePackagesURL.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        return environment
    }

    private func prepareWorker(script: URL, knowledgeBasePath: String) async throws -> PersistentJSONLWorker {
        if let worker { return worker }
        try FileManager.default.createDirectory(at: writableCacheURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: indexRootURL, withIntermediateDirectories: true)
        let candidate = PersistentJSONLWorker(
            executable: pythonURL,
            arguments: [
                script.path,
                "--knowledge-base", knowledgeBasePath,
                "--knowledge-sha256", knowledgeBaseSHA256,
                "--cache-directory", writableCacheURL.path,
                "--seed-cache-directory", seedCacheURL.path,
                "--index-root", indexRootURL.path,
                "--index-algorithm-version", indexAlgorithmVersion,
            ],
            environment: Self.pythonEnvironment(
                base: ProcessInfo.processInfo.environment,
                sitePackagesURL: sitePackagesURL
            ),
            startupDeadline: startupDeadline,
            queryDeadline: queryDeadline
        )
        let ready: WorkerReady
        do {
            ready = try JSONDecoder().decode(WorkerReady.self, from: await candidate.start())
        } catch {
            await candidate.stop()
            throw error
        }
        guard ready.type == "ready", ["v2-top12", "v2-lexical-only"].contains(ready.version) else {
            await candidate.stop()
            throw V2KnowledgeRetrieverError.invalidOutput("常驻 worker 未返回 ready")
        }
        worker = candidate
        workerVersion = ready.version
        return candidate
    }

    private func validated(_ result: RetrievedKnowledge) throws -> RetrievedKnowledge {
        guard [KnowledgeRetrievalMode.v2Top12.rawValue, "v2-lexical-only"].contains(result.version),
              result.hasOriginalSections else {
            throw V2KnowledgeRetrieverError.invalidOutput("常驻工作进程返回结果缺少原文章节")
        }
        return result
    }

    static func focusedHistoryJSONL(
        fullHistoryJSONL: String,
        targetCustomerJSONL: String,
        recentLineLimit: Int = 24
    ) -> String {
        let recent = fullHistoryJSONL.split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(max(1, recentLineLimit)).map(String.init)
        let target = targetCustomerJSONL.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let alreadyEndsWithTarget = recent.count >= target.count
            && Array(recent.suffix(target.count)) == target
        let lines = alreadyEndsWithTarget ? recent : recent + target
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }
}

private struct WorkerReady: Decodable {
    let type: String
    let version: String
}

private struct WorkerResponse: Decodable {
    let id: String?
    let ok: Bool
    let result: RetrievedKnowledge?
    let error: String?
}
