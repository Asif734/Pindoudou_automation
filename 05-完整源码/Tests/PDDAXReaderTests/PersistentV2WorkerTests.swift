import XCTest
@testable import PDDAXReader

final class PersistentV2WorkerTests: XCTestCase {
    func testTimeoutRestartsWorkerAndNextRequestSucceeds() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-v2-worker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("worker")
        let marker = root.appendingPathComponent("first-launch")
        let script = root.appendingPathComponent("ignored.py")
        try Data().write(to: script)
        let shell = """
        #!/bin/zsh
        if [[ ! -e "\(marker.path)" ]]; then
          /usr/bin/touch "\(marker.path)"
          /bin/sleep 5
          exit 0
        fi
        while IFS= read -r line; do
          /usr/bin/python3 - "$line" <<'PY'
        import json, sys
        e=json.loads(sys.argv[1])
        print(json.dumps({"id":e["id"],"result":{"version":"v2-top12","documents":["ok.md"],"context":"ok"}}),flush=True)
        PY
        done
        """
        try Data(shell.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path
        )
        let worker = PersistentV2Worker(
            pythonURL: executable,
            scriptURL: script,
            environment: ProcessInfo.processInfo.environment,
            hardTimeout: 2
        )
        let request = PersistentV2Request(
            knowledgeBasePath: "/tmp/kb.zip", historyJSONL: "{}\n",
            cacheDirectory: "/tmp/cache", seedCacheDirectory: "/tmp/seed"
        )

        do {
            _ = try await worker.retrieve(request)
            XCTFail("first request should time out")
        } catch {
            XCTAssertTrue(error is PersistentV2WorkerError)
        }
        let result = try await worker.retrieve(request)
        await worker.shutdown()

        XCTAssertEqual(result.documents, ["ok.md"])
        XCTAssertEqual(result.context, "ok")
    }
}
