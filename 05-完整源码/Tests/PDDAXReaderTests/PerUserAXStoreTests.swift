import XCTest
@testable import PDDAXReader

final class PerUserAXStoreTests: XCTestCase {
    func testAcceptsLegacyAndConversationKeys() {
        XCTAssertTrue(PerUserAXStore.validUID("GZC-000001"))
        XCTAssertTrue(PerUserAXStore.validUID("PDD-ID-0123456789abcdef01234567"))
        XCTAssertTrue(PerUserAXStore.validUID("PDD-NAME-0123456789abcdef01234567"))
    }

    func testSaveWritesOneAtomicAXFileInsideUsersOwnDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-ax-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PerUserAXStore(rootDirectory: root)

        let saved = try store.save(uid: "GZC-000001", contents: "AXWindow\n  客户消息：1")

        XCTAssertEqual(
            saved.standardizedFileURL,
            root.appendingPathComponent("用户/GZC-000001/ax.txt").standardizedFileURL
        )
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "AXWindow\n  客户消息：1")
    }

    func testSaveOverwritesOnlyThatUsersSingleAXFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-ax-overwrite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PerUserAXStore(rootDirectory: root)

        let first = try store.save(uid: "GZC-000001", contents: "旧 AX")
        let second = try store.save(uid: "GZC-000001", contents: "新 AX")

        XCTAssertEqual(first, second)
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "新 AX")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: second.deletingLastPathComponent().path), ["ax.txt"])
    }

    func testRejectsUnsafeOrIncompleteUIDs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-ax-reject-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PerUserAXStore(rootDirectory: root)

        for uid in ["", "../escape", "GZC/000001", "GZC\\000001", "GZC-..."] {
            XCTAssertThrowsError(try store.save(uid: uid, contents: "AX"), "必须拒绝：\(uid)")
        }
    }
}
