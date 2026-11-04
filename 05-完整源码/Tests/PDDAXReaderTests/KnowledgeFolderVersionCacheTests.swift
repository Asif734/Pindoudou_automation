import CryptoKit
import XCTest
@testable import PDDAXReader

final class KnowledgeFolderVersionCacheTests: XCTestCase {
    func testWarmVersionSkipsFileBytesAndMatchesOriginalDigest() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("rules".utf8).write(to: root.appendingPathComponent("rules.md"))
        try Data(repeating: 0x4A, count: 4096).write(to: root.appendingPathComponent("media.jpg"))
        let cache = KnowledgeFolderVersionCache()
        let first = try await cache.version(folder: root)
        let warm = try await cache.version(folder: root)
        var original = SHA256()
        original.update(data: Data(root.path.utf8))
        let originalFiles = (FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])!.allObjects as! [URL])
            .sorted { $0.path < $1.path }
        for file in originalFiles {
            original.update(data: Data(file.path.utf8))
            original.update(data: try Data(contentsOf: file))
        }
        XCTAssertEqual(first.digest, original.finalize().map { String(format: "%02x", $0) }.joined())
        XCTAssertFalse(first.cacheHit)
        XCTAssertEqual(first.hashedByteCount, 4101)
        XCTAssertEqual(warm.digest, first.digest)
        XCTAssertTrue(warm.cacheHit)
        XCTAssertEqual(warm.hashedByteCount, 0)
    }

    func testSameSizeEditWithRestoredModificationDateInvalidatesCache() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rules.md")
        try Data("old".utf8).write(to: file)
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        let cache = KnowledgeFolderVersionCache()
        let first = try await cache.version(folder: root)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("new".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let changed = try await cache.version(folder: root)
        XCTAssertFalse(changed.cacheHit)
        XCTAssertNotEqual(changed.digest, first.digest)
    }

    func testAddingRenamingAndRemovingFilesInvalidatesCache() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = KnowledgeFolderVersionCache()
        let empty = try await cache.version(folder: root)
        let file = root.appendingPathComponent("a.md")
        try Data("facts".utf8).write(to: file)
        let added = try await cache.version(folder: root)
        let renamed = root.appendingPathComponent("b.md")
        try FileManager.default.moveItem(at: file, to: renamed)
        let moved = try await cache.version(folder: root)
        try FileManager.default.removeItem(at: renamed)
        let removed = try await cache.version(folder: root)
        XCTAssertFalse(added.cacheHit)
        XCTAssertNotEqual(empty.digest, added.digest)
        XCTAssertNotEqual(added.digest, moved.digest)
        XCTAssertEqual(removed.digest, empty.digest)
        XCTAssertFalse(removed.cacheHit)
    }

    func testConcurrentCustomersShareOneHashPass() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x1F, count: 4096).write(to: root.appendingPathComponent("facts.md"))
        let cache = KnowledgeFolderVersionCache()
        async let a = cache.version(folder: root)
        async let b = cache.version(folder: root)
        let versions = try await [a, b]
        XCTAssertEqual(versions[0].digest, versions[1].digest)
        XCTAssertEqual(versions.filter { $0.cacheHit }.count, 1)
        XCTAssertEqual(versions.map(\.hashedByteCount).reduce(0, +), 4096)
    }

    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
