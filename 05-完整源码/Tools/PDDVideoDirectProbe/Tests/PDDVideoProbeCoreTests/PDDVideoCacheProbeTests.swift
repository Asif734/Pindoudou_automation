import Foundation
import XCTest
@testable import PDDVideoProbeCore

final class PDDVideoCacheProbeTests: XCTestCase {
    func testLocatorFindsNumericCEFProfileCacheDataDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = root.appendingPathComponent("188145238/Cache/Cache_Data", isDirectory: true)
        try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("cef_default/Cache/Cache_Data", isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertEqual(
            try PDDVideoCacheLocator.findCacheDataDirectory(inCEFRoot: root).resolvingSymlinksInPath(),
            expected.resolvingSymlinksInPath()
        )
    }

    func testLocatorFindsEveryCEFProfileCacheDataDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let numeric = root.appendingPathComponent("188145238/Cache/Cache_Data", isDirectory: true)
        let secondNumeric = root.appendingPathComponent("90591271/Cache/Cache_Data", isDirectory: true)
        let defaultProfile = root.appendingPathComponent("cef_default/Cache/Cache_Data", isDirectory: true)
        for directory in [numeric, secondNumeric, defaultProfile] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("not-a-profile", isDirectory: true),
            withIntermediateDirectories: true
        )

        let results = try PDDVideoCacheLocator.findCacheDataDirectories(inCEFRoot: root)
            .map { $0.resolvingSymlinksInPath() }

        XCTAssertEqual(Set(results), Set([numeric, secondNumeric, defaultProfile].map { $0.resolvingSymlinksInPath() }))
    }

    func testExtractsOnlyPDDHTTPSMP4WithVideoContentType() throws {
        let valid = Data("""
        1/0/https://video3.yangkeduo.com/idaho-api-video/2026-09-02/sample.mp4
        content-type:video/mp4
        content-range:bytes 0-99/100
        """.utf8)

        let candidate = try XCTUnwrap(PDDVideoCacheMetadata.extractCandidate(from: valid))

        XCTAssertEqual(candidate.host, "video3.yangkeduo.com")
        XCTAssertEqual(candidate.path, "/idaho-api-video/2026-09-02/sample.mp4")
        XCTAssertNil(PDDVideoCacheMetadata.extractCandidate(from: Data("1/0/http://video3.yangkeduo.com/a.mp4\ncontent-type:video/mp4".utf8)))
        XCTAssertNil(PDDVideoCacheMetadata.extractCandidate(from: Data("1/0/https://evil.example/a.mp4\ncontent-type:video/mp4".utf8)))
        XCTAssertNil(PDDVideoCacheMetadata.extractCandidate(from: Data("1/0/https://video3.yangkeduo.com/a.jpg\ncontent-type:image/jpeg".utf8)))
    }

    func testMetadataAcceptsWhitespaceAfterContentTypeColon() throws {
        let data = Data("1/0/https://video3.yangkeduo.com/a.mp4\nContent-Type: video/mp4".utf8)

        XCTAssertEqual(PDDVideoCacheMetadata.extractCandidate(from: data)?.path, "/a.mp4")
    }

    func testWatcherIgnoresBaselineAndReturnsNewCacheMetadata() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("1/0/https://video3.yangkeduo.com/old.mp4\ncontent-type:video/mp4".utf8)
            .write(to: root.appendingPathComponent("old_0"))
        let baseline = try PDDVideoCacheSnapshot.capture(directory: root)
        let watcher = PDDVideoCacheWatcher(pollInterval: .milliseconds(10))

        let task = Task {
            try await watcher.waitForNewCandidate(in: root, baseline: baseline, timeout: .seconds(1))
        }
        try await Task.sleep(for: .milliseconds(50))
        try Data("1/0/https://video3.yangkeduo.com/new.mp4\ncontent-type:video/mp4".utf8)
            .write(to: root.appendingPathComponent("new_0"))

        let result = try await task.value
        XCTAssertEqual(result.path, "/new.mp4")
    }

    func testWatcherAcceptsMetadataFileChangedAfterBaseline() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("entry_0")
        try Data("not video yet".utf8).write(to: metadata)
        let baseline = try PDDVideoCacheSnapshot.capture(directory: root)
        let watcher = PDDVideoCacheWatcher(pollInterval: .milliseconds(10))

        let task = Task {
            try await watcher.waitForNewCandidate(in: root, baseline: baseline, timeout: .seconds(1))
        }
        try await Task.sleep(for: .milliseconds(50))
        try Data("1/0/https://video4.pddcdn.com/new.mp4\ncontent-type:video/mp4\nextra".utf8)
            .write(to: metadata)

        let result = try await task.value
        XCTAssertEqual(result.host, "video4.pddcdn.com")
    }

    func testWatcherFindsCandidateInSecondCEFProfile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let baselines = try PDDVideoCacheBaseline.capture(directories: [first, second])
        let watcher = PDDVideoCacheWatcher(pollInterval: .milliseconds(10))

        let task = Task {
            try await watcher.waitForNewCandidate(in: baselines, timeout: .seconds(1))
        }
        try await Task.sleep(for: .milliseconds(50))
        try Data("1/0/https://video4.pddcdn.com/from-second.mp4\ncontent-type:video/mp4".utf8)
            .write(to: second.appendingPathComponent("new_0"))

        let result = try await task.value
        XCTAssertEqual(result.path, "/from-second.mp4")
    }

    func testWatcherContinuesWhenAnotherProfileDisappears() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let disappearing = root.appendingPathComponent("disappearing", isDirectory: true)
        let active = root.appendingPathComponent("active", isDirectory: true)
        try FileManager.default.createDirectory(at: disappearing, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        let baselines = try PDDVideoCacheBaseline.capture(directories: [disappearing, active])
        try FileManager.default.removeItem(at: disappearing)
        let watcher = PDDVideoCacheWatcher(pollInterval: .milliseconds(10))

        let task = Task {
            try await watcher.waitForNewCandidate(in: baselines, timeout: .seconds(1))
        }
        try await Task.sleep(for: .milliseconds(50))
        try Data("1/0/https://video4.pddcdn.com/active.mp4\ncontent-type:video/mp4".utf8)
            .write(to: active.appendingPathComponent("new_0"))

        let result = try await task.value
        XCTAssertEqual(result.path, "/active.mp4")
    }

    func testWatcherChoosesNewestCandidateAcrossProfiles() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let baselines = try PDDVideoCacheBaseline.capture(directories: [first, second])
        let oldCandidate = first.appendingPathComponent("old_0")
        let newCandidate = second.appendingPathComponent("new_0")
        try Data("https://video4.pddcdn.com/older.mp4\ncontent-type:video/mp4".utf8).write(to: oldCandidate)
        try Data("https://video4.pddcdn.com/newer.mp4\ncontent-type:video/mp4".utf8).write(to: newCandidate)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: oldCandidate.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: newCandidate.path)

        let result = try await PDDVideoCacheWatcher(pollInterval: .milliseconds(10))
            .waitForNewCandidate(in: baselines, timeout: .seconds(1))

        XCTAssertEqual(result.path, "/newer.mp4")
    }

    func testWatcherDetectsStreamMetadataFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = try PDDVideoCacheSnapshot.capture(directory: root)
        let watcher = PDDVideoCacheWatcher(pollInterval: .milliseconds(10))

        let task = Task {
            try await watcher.waitForNewCandidate(in: root, baseline: baseline, timeout: .seconds(1))
        }
        try await Task.sleep(for: .milliseconds(50))
        try Data("1/0/https://video4.pddcdn.com/stream.mp4\ncontent-type: video/mp4".utf8)
            .write(to: root.appendingPathComponent("new_s"))

        let result = try await task.value
        XCTAssertEqual(result.path, "/stream.mp4")
    }

    func testWatcherTimesOutWithoutNewVideoCacheEntry() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = try PDDVideoCacheSnapshot.capture(directory: root)

        do {
            _ = try await PDDVideoCacheWatcher(pollInterval: .milliseconds(5))
                .waitForNewCandidate(in: root, baseline: baseline, timeout: .milliseconds(30))
            XCTFail("a silent cache must time out")
        } catch let error as PDDVideoProbeError {
            XCTAssertEqual(error, .timedOutNoCacheChange)
        }
    }

    func testWatcherReportsChangedCacheWithoutVideoMarker() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = try PDDVideoCacheSnapshot.capture(directory: root)
        let watcher = PDDVideoCacheWatcher(pollInterval: .milliseconds(5))

        let task = Task {
            try await watcher.waitForNewCandidate(in: root, baseline: baseline, timeout: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(20))
        try Data("a new non-video cache record".utf8).write(to: root.appendingPathComponent("new_0"))

        do {
            _ = try await task.value
            XCTFail("a changed non-video cache must have a distinct timeout")
        } catch let error as PDDVideoProbeError {
            XCTAssertEqual(error, .timedOutWithoutVideoMarker(changedFiles: 1))
        }
    }

    func testEncodedReportCannotContainMediaURLOrCredentials() throws {
        let report = SanitizedPDDVideoProbeReport(
            machine: .init(macOS: "26.4.1", architecture: "arm64", pddVersion: "1.0.19"),
            result: .passed,
            discoveryMilliseconds: 500,
            downloadMilliseconds: 800,
            httpStatus: 200,
            file: .init(
                name: "下载的视频.mp4", bytes: 773_171, sha256: "abc123",
                durationSeconds: 4.3667, width: 720, height: 1280,
                videoCodec: "H.264", audioCodec: "AAC"
            ),
            failure: nil
        )

        let text = try XCTUnwrap(String(data: JSONEncoder().encode(report), encoding: .utf8))

        XCTAssertFalse(text.contains("https://"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("cookie"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("access_token"))
        XCTAssertTrue(text.contains("773171"))
    }

    func testDownloadPolicyRejectsHTMLAndAcceptsMP4() {
        XCTAssertTrue(PDDVideoDownloadPolicy.accepts(statusCode: 200, mimeType: "video/mp4"))
        XCTAssertTrue(PDDVideoDownloadPolicy.accepts(statusCode: 206, mimeType: "application/octet-stream"))
        XCTAssertFalse(PDDVideoDownloadPolicy.accepts(statusCode: 403, mimeType: "video/mp4"))
        XCTAssertFalse(PDDVideoDownloadPolicy.accepts(statusCode: 200, mimeType: "text/html"))
    }

    func testInspectorRejectsTextSavedAsMP4() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("bad.mp4")
        try Data("not an mp4".utf8).write(to: file)

        do {
            _ = try await PDDVideoFileInspector.inspect(file)
            XCTFail("invalid media must be rejected")
        } catch let error as PDDVideoProbeError {
            XCTAssertEqual(error, .invalidMedia)
        }
    }

    func testMarkdownReportContainsEvidenceWithoutInternalAddress() {
        let report = SanitizedPDDVideoProbeReport(
            machine: .init(macOS: "26.4.1", architecture: "arm64", pddVersion: "1.0.19"),
            result: .passed,
            discoveryMilliseconds: 500,
            downloadMilliseconds: 800,
            httpStatus: 200,
            file: .init(
                name: "下载的视频.mp4", bytes: 773_171, sha256: "abc123",
                durationSeconds: 4.3667, width: 720, height: 1280,
                videoCodec: "H.264", audioCodec: "AAC"
            ),
            failure: nil
        )

        let markdown = PDDVideoProbeReportMarkdown.render(report)

        XCTAssertTrue(markdown.contains("PASS"))
        XCTAssertTrue(markdown.contains("4.367"))
        XCTAssertTrue(markdown.contains("720 × 1280"))
        XCTAssertFalse(markdown.contains("https://"))
        XCTAssertFalse(markdown.localizedCaseInsensitiveContains("cookie"))
    }

    func testLiveCachedPDDVideoDownloadsAndValidatesWhenExplicitlyEnabled() async throws {
        guard let metadataPath = ProcessInfo.processInfo.environment["PDD_LIVE_CACHE_METADATA"] else {
            throw XCTSkip("set PDD_LIVE_CACHE_METADATA to a confirmed PDD video cache metadata file")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: metadataPath))
        let mediaURL = try XCTUnwrap(PDDVideoCacheMetadata.extractCandidate(from: data))
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = try await PDDVideoDownloadClient()
            .download(from: mediaURL, to: root.appendingPathComponent("live.mp4"))
        let summary = try await PDDVideoFileInspector.inspect(receipt.fileURL)

        XCTAssertTrue(receipt.statusCode == 200 || receipt.statusCode == 206)
        XCTAssertGreaterThan(summary.bytes, 0)
        XCTAssertGreaterThan(summary.durationSeconds, 0)
        XCTAssertGreaterThan(summary.width, 0)
        XCTAssertGreaterThan(summary.height, 0)
        print("LIVE_PDD_VIDEO status=\(receipt.statusCode) bytes=\(summary.bytes) duration=\(summary.durationSeconds) size=\(summary.width)x\(summary.height) video=\(summary.videoCodec) audio=\(summary.audioCodec ?? "none")")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
