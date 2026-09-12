import XCTest
@testable import PDDAXReader

final class V2KnowledgeRetrieverTests: XCTestCase {
    func testPersistentWorkerPreparesOnceAndServesMultipleQueries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-v2-persistent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let launches = root.appendingPathComponent("launches.txt")
        let script = root.appendingPathComponent("serve_top12.zsh")
        let packages = root.appendingPathComponent("site-packages", isDirectory: true)
        let seed = root.appendingPathComponent("seed", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let knowledge = root.appendingPathComponent("knowledge.zip")
        for directory in [packages, seed, cache] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("zip".utf8).write(to: knowledge)
        let shell = """
        #!/bin/zsh
        print started >> "\(launches.path)"
        print -r -- '{"type":"ready","version":"v2-top12"}'
        while IFS= read -r line; do
          id=$(/usr/bin/python3 -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$line")
          print -r -- '{"id":"'"$id"'","ok":true,"result":{"version":"v2-top12","documents":["tp732.md"],"context":"<retrieved_document_candidates>\\n- tp732.md\\n</retrieved_document_candidates>\\n\\n<most_relevant_original_sections>\\nTP732 不支持原生 macOS。\\n</most_relevant_original_sections>"}}'
        done
        """
        try Data(shell.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let retriever = V2KnowledgeRetriever(
            pythonURL: URL(fileURLWithPath: "/bin/zsh"),
            scriptURL: script,
            workerScriptURL: script,
            sitePackagesURL: packages,
            seedCacheURL: seed,
            writableCacheURL: cache,
            knowledgeBaseSHA256: String(repeating: "a", count: 64),
            indexRootURL: root.appendingPathComponent("indexes")
        )

        let preparation = try await retriever.prepare(knowledgeBaseURLs: [knowledge])
        let first = try await retriever.retrieve(
            historyJSONL: "{\"sender\":\"customer\",\"v\":\"tp732是否兼容mac\"}\n",
            knowledgeBaseURLs: [knowledge]
        )
        let second = try await retriever.retrieve(
            historyJSONL: "{\"sender\":\"customer\",\"v\":\"好的\"}\n",
            knowledgeBaseURLs: [knowledge]
        )
        await retriever.shutdown()

        XCTAssertEqual(preparation.version, "v2-top12")
        XCTAssertTrue(first.context.contains("TP732 不支持原生 macOS"))
        XCTAssertTrue(second.hasOriginalSections)
        XCTAssertEqual(try String(contentsOf: launches).split(separator: "\n").count, 1)
    }

    func testRetrieverWritesExpectedUTF8RequestAndValidatesV2Output() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let captured = root.appendingPathComponent("captured-request.json")
        let executable = root.appendingPathComponent("fake-python")
        let script = root.appendingPathComponent("retrieve_top12.py")
        let packages = root.appendingPathComponent("site-packages", isDirectory: true)
        let seed = root.appendingPathComponent("seed", isDirectory: true)
        let cache = root.appendingPathComponent("writable", isDirectory: true)
        let knowledge = root.appendingPathComponent("知识库.zip")
        for directory in [packages, seed, cache] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("# fixture".utf8).write(to: script)
        try Data("zip".utf8).write(to: knowledge)
        let shell = """
        #!/bin/zsh
        while IFS= read -r line; do
          /usr/bin/python3 - "\(captured.path)" "$line" <<'PY'
        import json, pathlib, sys
        envelope = json.loads(sys.argv[2])
        pathlib.Path(sys.argv[1]).write_text(
            json.dumps(envelope["request"], ensure_ascii=False), encoding="utf-8"
        )
        print(json.dumps({
            "id": envelope["id"],
            "result": {
                "version": "v2-top12",
                "documents": ["资料/M880.md"],
                "context": "<retrieved_document_candidates>\\n- M880.md\\n</retrieved_document_candidates>\\n\\n<most_relevant_original_sections>\\n原文：停电后检查电源。\\n</most_relevant_original_sections>",
            },
        }, ensure_ascii=False), flush=True)
        PY
        done
        """
        try Data(shell.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let retriever = V2KnowledgeRetriever(
            pythonURL: executable,
            scriptURL: script,
            sitePackagesURL: packages,
            seedCacheURL: seed,
            writableCacheURL: cache
        )

        let result = try await retriever.retrieve(
            historyJSONL: "{\"content\":\"停电后不开机\"}\n",
            knowledgeBaseURLs: [knowledge]
        )

        XCTAssertEqual(result.version, "v2-top12")
        XCTAssertEqual(result.documents, ["资料/M880.md"])
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: captured)) as? [String: String]
        )
        XCTAssertEqual(request["knowledge_base_path"], knowledge.path)
        XCTAssertEqual(request["history_jsonl"], "{\"content\":\"停电后不开机\"}\n")
        XCTAssertEqual(request["cache_directory"], cache.path)
        XCTAssertEqual(request["seed_cache_directory"], seed.path)
    }

    func testFocusedHistoryKeepsFrozenTargetAndDropsOldNoise() {
        let old = (1...40).map { "{\"id\":\"old-TP732-\($0)\",\"content\":\"TP732\"}" }
            .joined(separator: "\n")
        let target = "{\"messageID\":\"new\",\"content\":\"M880停电后不开机\"}\n"

        let focused = V2KnowledgeRetriever.focusedHistoryJSONL(
            fullHistoryJSONL: old + "\n" + target,
            targetCustomerJSONL: target,
            recentLineLimit: 24
        )

        XCTAssertTrue(focused.contains("M880停电后不开机"))
        XCTAssertFalse(focused.contains("old-TP732-1\""))
        XCTAssertEqual(focused.components(separatedBy: "M880停电后不开机").count - 1, 1)
    }
}
