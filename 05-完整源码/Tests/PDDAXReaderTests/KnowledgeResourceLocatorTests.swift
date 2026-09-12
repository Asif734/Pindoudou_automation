import XCTest
@testable import PDDAXReader

final class KnowledgeResourceLocatorTests: XCTestCase {
    func testBundledResourcesWinOverConfiguredLegacyZIP() throws {
        let root = try makeResourceRoot(includeV2: true, includeZIP: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.deletingLastPathComponent().appendingPathComponent("legacy-\(UUID().uuidString).zip")
        try Data("legacy".utf8).write(to: legacy)
        defer { try? FileManager.default.removeItem(at: legacy) }

        let resources = KnowledgeResourceLocator.resolve(
            resourceRootURL: root,
            environment: ["PDD_KNOWLEDGE_ZIP": legacy.path],
            fileManager: .default
        )

        XCTAssertEqual(resources?.knowledgeBaseURL, root.appendingPathComponent("KnowledgeBase/Grozziie-China-KB-2026-08-24.zip"))
        XCTAssertEqual(resources?.scriptURL, root.appendingPathComponent("V2Knowledge/retrieve_top12.py"))
        XCTAssertEqual(resources?.workerScriptURL, root.appendingPathComponent("V2Knowledge/serve_top12.py"))
        XCTAssertEqual(resources?.knowledgeBaseSHA256.count, 64)
        XCTAssertNotEqual(resources?.knowledgeBaseSHA256, String(repeating: "0", count: 64))
        XCTAssertTrue(resources?.writableCacheURL.path.contains("PDDAutoReply/V2KnowledgeCache") == true)
    }

    func testConfiguredZIPIsUsedWhenBundleHasV2ButNoBundledZIP() throws {
        let root = try makeResourceRoot(includeV2: true, includeZIP: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let configured = root.appendingPathComponent("configured.zip")
        try Data("configured".utf8).write(to: configured)

        let resources = KnowledgeResourceLocator.resolve(
            resourceRootURL: root,
            environment: ["PDD_KNOWLEDGE_ZIP": configured.path],
            fileManager: .default
        )

        XCTAssertEqual(resources?.knowledgeBaseURL, configured)
    }

    func testMissingV2RuntimeReturnsNilEvenWhenZIPExists() throws {
        let root = try makeResourceRoot(includeV2: false, includeZIP: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(KnowledgeResourceLocator.resolve(
            resourceRootURL: root,
            environment: [:],
            fileManager: .default
        ))
    }

    func testMissingValidatedPythonReturnsNilBeforeWorkerCreation() throws {
        let root = try makeResourceRoot(includeV2: true, includeZIP: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNil(KnowledgeResourceLocator.resolve(
            resourceRootURL: root,
            environment: [:],
            fileManager: .default,
            pythonResolver: { _, _, _ in nil }
        ))
    }

    private func makeResourceRoot(includeV2: Bool, includeZIP: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        if includeV2 {
            for path in ["V2Knowledge/site-packages", "V2Knowledge/cache"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
            }
            try Data("print('ok')".utf8).write(to: root.appendingPathComponent("V2Knowledge/retrieve_top12.py"))
            try Data("print('ready')".utf8).write(to: root.appendingPathComponent("V2Knowledge/serve_top12.py"))
        }
        if includeZIP {
            let directory = root.appendingPathComponent("KnowledgeBase", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("zip".utf8).write(to: directory.appendingPathComponent("Grozziie-China-KB-2026-08-24.zip"))
        }
        return root
    }
}
