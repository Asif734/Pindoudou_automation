import XCTest
@testable import PDDAXReader

final class PDDVideoCacheProbeTests: XCTestCase {
    func testFindsCacheDataInsideNamedCEFProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("account-main/Cache/Cache_Data")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        XCTAssertEqual(
            try PDDVideoCacheLocator.findCacheDataDirectories(inCEFRoot: root).map(\.path),
            [cache.path]
        )
    }

    func testExtractsOnlySignedPDDHTTPSMP4WithVideoMIME() throws {
        let valid = Data("https://video3.yangkeduo.com/path/a.mp4?sign=secret\ncontent-type: video/mp4".utf8)
        let invalidHost = Data("https://evil.example/a.mp4\ncontent-type: video/mp4".utf8)
        let invalidMIME = Data("https://video3.yangkeduo.com/a.mp4\ncontent-type: text/html".utf8)

        XCTAssertEqual(PDDVideoCacheMetadata.extractCandidate(from: valid)?.host, "video3.yangkeduo.com")
        XCTAssertNil(PDDVideoCacheMetadata.extractCandidate(from: invalidHost))
        XCTAssertNil(PDDVideoCacheMetadata.extractCandidate(from: invalidMIME))
    }

    func testWatcherFindsChangedEntryAcrossProfiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let baselines = try PDDVideoCacheBaseline.capture(directories: [first, second])

        Task {
            try await Task.sleep(for: .milliseconds(30))
            try Data("https://video1.pddcdn.com/new.mp4?token=x\ncontent-type:video/mp4".utf8)
                .write(to: second.appendingPathComponent("entry_0"))
            try Data([0, 1, 2, 3]).write(to: second.appendingPathComponent("entry_s"))
        }
        let result = try await PDDVideoCacheWatcher(pollInterval: .milliseconds(5))
            .waitForNewCandidate(in: baselines, timeout: .seconds(1))

        XCTAssertEqual(result.host, "video1.pddcdn.com")
        XCTAssertEqual(result.path, "/new.mp4")
    }

    func testWatcherUsesUniquePreloadedCandidateCreatedJustAfterMessage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let messageDate = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = root.appendingPathComponent("preloaded_0")
        let body = root.appendingPathComponent("preloaded_s")
        try Data("https://video1.pddcdn.com/preloaded.mp4?token=x\ncontent-type:video/mp4".utf8)
            .write(to: metadata)
        try Data([0, 1, 2, 3]).write(to: body)
        let cacheDate = messageDate.addingTimeInterval(3)
        try FileManager.default.setAttributes(
            [.modificationDate: cacheDate], ofItemAtPath: metadata.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: cacheDate], ofItemAtPath: body.path
        )
        let baselines = try PDDVideoCacheBaseline.capture(directories: [root])

        let result = try await PDDVideoCacheWatcher(pollInterval: .milliseconds(5)).wait(
            in: baselines,
            preloadedWindow: messageDate...messageDate.addingTimeInterval(20),
            accept: { _ in true }
        )

        XCTAssertEqual(result.path, "/preloaded.mp4")
    }

    func testWatcherDoesNotReturnMetadataBeforeMatchingVideoBodyStarts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let baselines = try PDDVideoCacheBaseline.capture(directories: [root])

        Task {
            try await Task.sleep(for: .milliseconds(20))
            try Data("https://video1.pddcdn.com/new.mp4?token=x\ncontent-type:video/mp4".utf8)
                .write(to: root.appendingPathComponent("entry_0"))
        }

        do {
            _ = try await PDDVideoCacheWatcher(pollInterval: .milliseconds(5))
                .waitForNewCandidate(in: baselines, timeout: .milliseconds(100))
            XCTFail("metadata alone must not be treated as an active video download")
        } catch let error as PDDCustomerVideoError {
            XCTAssertEqual(error, .timedOutWithoutVideoMarker(changedFiles: 1))
        }
    }

    func testWatcherRechecksNewMetadataUntilPartiallyWrittenEntryBecomesComplete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let baselines = try PDDVideoCacheBaseline.capture(directories: [root])
        let metadata = root.appendingPathComponent("entry_0")
        let body = root.appendingPathComponent("entry_s")
        let complete = "https://video1.pddcdn.com/new.mp4?token=x\ncontent-type:video/mp4"
        let partial = complete.replacingOccurrences(of: "https", with: "xxxxx")
        XCTAssertEqual(partial.utf8.count, complete.utf8.count)
        let stableDate = Date(timeIntervalSince1970: 1_700_000_000)

        Task {
            try await Task.sleep(for: .milliseconds(20))
            try Data(partial.utf8).write(to: metadata)
            try FileManager.default.setAttributes(
                [.modificationDate: stableDate], ofItemAtPath: metadata.path
            )
            try Data([0, 1, 2, 3]).write(to: body)

            // Let one polling pass observe the incomplete entry. The completed
            // write deliberately preserves size and mtime, matching CEF's race.
            try await Task.sleep(for: .milliseconds(130))
            try Data(complete.utf8).write(to: metadata)
            try FileManager.default.setAttributes(
                [.modificationDate: stableDate], ofItemAtPath: metadata.path
            )
        }

        let result = try await PDDVideoCacheWatcher(pollInterval: .milliseconds(100))
            .waitForNewCandidate(in: baselines, timeout: .milliseconds(500))

        XCTAssertEqual(result.host, "video1.pddcdn.com")
        XCTAssertEqual(result.path, "/new.mp4")
    }

    func testIndefiniteWatcherKeepsRecheckingIncompleteMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let baselines = try PDDVideoCacheBaseline.capture(directories: [root])
        let metadata = root.appendingPathComponent("late_0")
        let body = root.appendingPathComponent("late_s")

        Task {
            try await Task.sleep(for: .milliseconds(20))
            try Data("incomplete".utf8).write(to: metadata)
            try Data([1]).write(to: body)
            try await Task.sleep(for: .milliseconds(180))
            try Data("https://video1.pddcdn.com/late.mp4?token=x\ncontent-type:video/mp4".utf8)
                .write(to: metadata)
        }

        let result = try await PDDVideoCacheWatcher(pollInterval: .milliseconds(20))
            .wait(in: baselines)

        XCTAssertEqual(result.path, "/late.mp4")
    }
}
