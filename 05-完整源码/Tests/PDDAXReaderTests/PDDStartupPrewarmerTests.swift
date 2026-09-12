import XCTest
@testable import PDDAXReader

final class PDDStartupPrewarmerTests: XCTestCase {
    func testPrewarmRunsOCRKnowledgeSenseVoiceAndCodexInOrder() async throws {
        let log = PrewarmLog()
        let prewarmer = PDDStartupPrewarmer(
            warmOCR: { await log.append("ocr") },
            warmKnowledge: { await log.append("knowledge") },
            warmSenseVoice: { await log.append("sensevoice") },
            checkCodex: { await log.append("codex") }
        )

        try await prewarmer.prepare()

        let values = await log.snapshot()
        XCTAssertEqual(values, ["ocr", "knowledge", "sensevoice", "codex"])
    }
}

private actor PrewarmLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}
