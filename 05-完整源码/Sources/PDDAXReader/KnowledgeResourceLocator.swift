import CryptoKit
import Foundation

struct KnowledgeResources: Equatable, Sendable {
    let knowledgeBaseURL: URL
    let knowledgeBaseSHA256: String
    let scriptURL: URL
    let workerScriptURL: URL
    let pythonURL: URL
    let sitePackagesURL: URL
    let seedCacheURL: URL
    let writableCacheURL: URL
}

enum KnowledgeResourceLocator {
    typealias PythonResolver = (URL, [String: String], FileManager) -> PythonRuntimeResolution?

    static let knowledgeBaseName = "Grozziie-China-KB-2026-08-24.zip"
    static let legacyKnowledgeBasePath = "/Users/scy/Desktop/AI客服记录/知识库/Grozziie-China-KB-2026-08-24.zip"
    static let pythonPath = "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12"

    static func resolve(
        resourceRootURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        pythonResolver: PythonResolver = { root, environment, fileManager in
            PythonRuntimeResolver.resolve(
                resourceRootURL: root,
                environment: environment,
                fileManager: fileManager
            )
        }
    ) -> KnowledgeResources? {
        let folderConfig = resourceRootURL.appendingPathComponent("FolderKnowledge/config.json")
        if fileManager.fileExists(atPath: folderConfig.path) {
            // An explicitly configured primary folder must not silently fall back
            // to the stale legacy ZIP when configuration is invalid.
            return resolveFolder(configURL: folderConfig, resourceRoot: resourceRootURL,
                                 environment: environment, fileManager: fileManager)
        }
        let v2Root = resourceRootURL.appendingPathComponent("V2Knowledge", isDirectory: true)
        let script = v2Root.appendingPathComponent("retrieve_top12.py")
        let workerScript = v2Root.appendingPathComponent("serve_top12.py")
        let packages = v2Root.appendingPathComponent("site-packages", isDirectory: true)
        let seed = v2Root.appendingPathComponent("cache", isDirectory: true)
        guard fileManager.fileExists(atPath: script.path),
              fileManager.fileExists(atPath: workerScript.path),
              fileManager.fileExists(atPath: packages.path),
              fileManager.fileExists(atPath: seed.path) else { return nil }
        guard let python = pythonResolver(resourceRootURL, environment, fileManager) else {
            return nil
        }

        let bundled = resourceRootURL
            .appendingPathComponent("KnowledgeBase", isDirectory: true)
            .appendingPathComponent(knowledgeBaseName)
        let configured = environment["PDD_KNOWLEDGE_ZIP"].map(URL.init(fileURLWithPath:))
        let legacy = URL(fileURLWithPath: legacyKnowledgeBasePath)
        guard let knowledge = [bundled, configured, legacy]
            .compactMap({ $0 })
            .first(where: { fileManager.fileExists(atPath: $0.path) }) else { return nil }

        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDDAutoReply/V2KnowledgeCache", isDirectory: true)
        guard let knowledgeData = try? Data(contentsOf: knowledge) else { return nil }
        let knowledgeSHA256 = SHA256.hash(data: knowledgeData)
            .map { String(format: "%02x", $0) }
            .joined()
        return KnowledgeResources(
            knowledgeBaseURL: knowledge,
            knowledgeBaseSHA256: knowledgeSHA256,
            scriptURL: script,
            workerScriptURL: workerScript,
            pythonURL: python.executableURL,
            sitePackagesURL: packages,
            seedCacheURL: seed,
            writableCacheURL: support
        )
    }

    static func resolve(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> KnowledgeResources? {
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources", isDirectory: true)
        let root = bundle.resourceURL.flatMap { candidate in
            fileManager.fileExists(atPath: candidate.appendingPathComponent("FolderKnowledge/config.json").path)
                ? candidate : nil
        } ?? (fileManager.fileExists(atPath: development.appendingPathComponent("FolderKnowledge/config.json").path)
              ? development : bundle.resourceURL)
        guard let root else { return nil }
        return resolve(resourceRootURL: root, environment: environment, fileManager: fileManager)
    }

    private static func resolveFolder(configURL: URL, resourceRoot: URL,
                                      environment: [String: String], fileManager: FileManager) -> KnowledgeResources? {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let configuredFolder = environment["PDD_KNOWLEDGE_FOLDER"] ?? config["primary_data_folder"],
              let pythonPath = environment["PDD_KNOWLEDGE_PYTHON"] ?? config["python_path"],
              let modelPath = environment["PDD_SEMANTIC_MODEL_PATH"] ?? config["model_path"] else { return nil }
        let folder = URL(fileURLWithPath: configuredFolder, isDirectory: true)
        let cards = folder.appendingPathComponent("rag_cards/customer_service_rag_cards.jsonl")
        let script = resourceRoot.appendingPathComponent("FolderKnowledge/serve_folder.py")
        guard fileManager.fileExists(atPath: cards.path),
              fileManager.fileExists(atPath: script.path),
              fileManager.fileExists(atPath: modelPath),
              fileManager.isExecutableFile(atPath: pythonPath),
              let cardsData = try? Data(contentsOf: cards) else { return nil }
        let cache = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDDAutoReply/FolderKnowledgeCache", isDirectory: true)
        return KnowledgeResources(
            knowledgeBaseURL: folder,
            knowledgeBaseSHA256: SHA256.hash(data: cardsData).map { String(format: "%02x", $0) }.joined(),
            scriptURL: script, workerScriptURL: script,
            pythonURL: URL(fileURLWithPath: pythonPath),
            sitePackagesURL: URL(fileURLWithPath: pythonPath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("lib/python3.12/site-packages"),
            seedCacheURL: URL(fileURLWithPath: modelPath, isDirectory: true),
            writableCacheURL: cache
        )
    }
}
