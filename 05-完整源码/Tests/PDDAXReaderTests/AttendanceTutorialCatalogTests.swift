import XCTest
@testable import PDDAXReader

final class AttendanceTutorialCatalogTests: XCTestCase {
    func testGeneralCatalogRetainsEveryApprovedJDAttendanceTutorial() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("格志京东客服知识库-2026-10-04")
        let detailed = try document(root.appendingPathComponent("rag_cards/attendance_video_materials.json"))
        let catalog = try document(root.appendingPathComponent("rag_cards/china_market_video_catalog.json"))
        let entries = try XCTUnwrap(catalog["entries"] as? [[String: Any]])
        let ids = entries.compactMap { $0["content_id"] as? String }
        XCTAssertEqual(Set(ids).count, ids.count, "Duplicate tutorial IDs create ambiguous selection")
        for source in try XCTUnwrap(detailed["contents"] as? [[String: Any]]) {
            guard let url = (source["platform_urls"] as? [String: String])?["JD"] else { continue }
            let id = try XCTUnwrap(source["content_id"] as? String)
            let entry = try XCTUnwrap(entries.first { $0["content_id"] as? String == id }, "Missing \(id)")
            XCTAssertEqual((entry["platform_urls"] as? [String: String])?["JD"], url)
            XCTAssertEqual(entry["models"] as? [String], source["models"] as? [String])
            XCTAssertEqual(entry["source_manifest"] as? String, "rag_cards/attendance_video_materials.json")
        }
        XCTAssertTrue((catalog["detailed_manifests"] as? [String] ?? [])
            .contains("rag_cards/attendance_video_materials.json"))
        let rules = try String(contentsOf: root.appendingPathComponent("jd_customer_service_rules.md"))
        XCTAssertTrue(rules.contains("rag_cards/attendance_video_materials.json"))
    }

    private func document(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}
