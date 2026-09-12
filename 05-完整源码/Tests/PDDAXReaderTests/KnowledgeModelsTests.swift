import XCTest
@testable import PDDAXReader

final class KnowledgeModelsTests: XCTestCase {
    func testRetrievalModesUseStablePersistenceValues() throws {
        let encoder = JSONEncoder()

        XCTAssertEqual(String(decoding: try encoder.encode(KnowledgeRetrievalMode.v2Top12), as: UTF8.self), "\"v2-top12\"")
        XCTAssertEqual(String(decoding: try encoder.encode(KnowledgeRetrievalMode.fullZipFallback), as: UTF8.self), "\"full-zip-fallback\"")
    }

    func testLegacyCaptureWithoutKnowledgeEvidenceStillDecodes() throws {
        let json = """
        {
          "uid": "GZC-000001",
          "fullHistory": [],
          "customerCursor": {"count": 0, "digest": ""},
          "unexpectedServiceMessageIDs": []
        }
        """

        let capture = try JSONDecoder().decode(AutoReplyCapture.self, from: Data(json.utf8))

        XCTAssertNil(capture.knowledgeEvidence)
    }

    func testCustomerServicePromptLoadsUTF8ResourceBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("customer-reply-prompt.md")
        try Data("格志客服规则：一次只推进一个排障步骤。".utf8).write(to: url)

        let prompt = try CustomerServicePrompt.load(from: url)

        XCTAssertEqual(prompt, "格志客服规则：一次只推进一个排障步骤。")
    }

    func testCustomerServicePromptRejectsWhitespaceOnlyResource() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-prompt-\(UUID().uuidString).md")
        try Data(" \n\t".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try CustomerServicePrompt.load(from: url))
    }
}
