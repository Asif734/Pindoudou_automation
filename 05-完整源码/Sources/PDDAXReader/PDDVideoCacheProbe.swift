import Foundation

enum PDDVideoCacheLocator {
    static func findCacheDataDirectories(inCEFRoot root: URL) throws -> [URL] {
        let manager = FileManager.default
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = canonicalRoot.pathComponents.count
        guard let enumerator = manager.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { throw PDDCustomerVideoError.cacheUnavailable }
        var matches = Set<URL>()
        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - rootComponents
            if depth >= 4 { enumerator.skipDescendants() }
            guard depth <= 4,
                  url.lastPathComponent == "Cache_Data",
                  url.deletingLastPathComponent().lastPathComponent == "Cache",
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            guard canonical.path.hasPrefix(canonicalRoot.path + "/") else { continue }
            matches.insert(URL(fileURLWithPath: canonical.path))
        }
        let result = matches.sorted { $0.path < $1.path }
        guard !result.isEmpty else { throw PDDCustomerVideoError.cacheUnavailable }
        return result
    }
}

enum PDDVideoCacheMetadata {
    private static let expression = try! NSRegularExpression(
        pattern: #"https://[^\s\x00]+\.mp4(?:\?[^\s\x00]*)?"#,
        options: [.caseInsensitive]
    )

    static func extractCandidate(from data: Data) -> URL? {
        let text = String(decoding: data, as: UTF8.self)
        guard text.range(of: #"content-type:\s*video/mp4"#, options: [.caseInsensitive, .regularExpression]) != nil else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text),
                  let url = URL(string: String(text[swiftRange])),
                  url.scheme?.lowercased() == "https",
                  url.pathExtension.lowercased() == "mp4",
                  PDDVideoHostPolicy.accepts(url.host) else { continue }
            return url
        }
        return nil
    }
}

enum PDDVideoHostPolicy {
    static func accepts(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let labels = host.split(separator: ".")
        return labels.count >= 3 && labels[0].hasPrefix("video")
            && (host.hasSuffix(".yangkeduo.com") || host.hasSuffix(".pddcdn.com"))
    }
}

struct PDDVideoCacheSnapshot: Sendable {
    fileprivate struct Fingerprint: Equatable, Sendable {
        let size: UInt64
        let modificationTime: TimeInterval
    }
    fileprivate let files: [String: Fingerprint]

    static func capture(directory: URL) throws -> Self {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { throw PDDCustomerVideoError.cacheUnavailable }
        var files: [String: Fingerprint] = [:]
        for case let url as URL in enumerator
        where url.lastPathComponent.hasSuffix("_0") || url.lastPathComponent.hasSuffix("_s") {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            files[url.path] = Fingerprint(
                size: UInt64(values.fileSize ?? 0),
                modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            )
        }
        return Self(files: files)
    }
}

struct PDDVideoCacheBaseline: Sendable {
    fileprivate let directory: URL
    fileprivate let snapshot: PDDVideoCacheSnapshot

    static func capture(directories: [URL]) throws -> [Self] {
        try directories.map { Self(directory: $0, snapshot: try .capture(directory: $0)) }
    }
}

struct PDDVideoCacheWatcher: Sendable {
    let pollInterval: Duration
    init(pollInterval: Duration = .milliseconds(200)) { self.pollInterval = pollInterval }

    func waitForNewCandidate(in baselines: [PDDVideoCacheBaseline], timeout: Duration) async throws -> URL {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        return try await wait(in: baselines, deadline: deadline, accept: { _ in true })
    }

    func wait(in baselines: [PDDVideoCacheBaseline]) async throws -> URL {
        try await wait(in: baselines, deadline: nil, accept: { _ in true })
    }

    func wait(
        in baselines: [PDDVideoCacheBaseline],
        preloadedWindow: ClosedRange<Date>? = nil,
        accept: @escaping @Sendable (URL) async -> Bool
    ) async throws -> URL {
        if let preloadedWindow,
           let candidate = uniquePreloadedCandidate(
               in: baselines, window: preloadedWindow
           ),
           await accept(candidate) {
            return candidate
        }
        return try await wait(in: baselines, deadline: nil, accept: accept)
    }

    private func wait(
        in baselines: [PDDVideoCacheBaseline],
        deadline: ContinuousClock.Instant?,
        accept: @escaping @Sendable (URL) async -> Bool
    ) async throws -> URL {
        guard !baselines.isEmpty else { throw PDDCustomerVideoError.cacheUnavailable }
        let clock = ContinuousClock()
        var changed = Set<String>()
        var metadataPathsToRecheck: [String: Set<String>] = [:]
        var pendingMetadata: [String: [String: (url: URL, modificationTime: TimeInterval)]] = [:]
        var observed = Dictionary(uniqueKeysWithValues: baselines.map { ($0.directory.path, $0.snapshot) })
        while deadline.map({ clock.now < $0 }) ?? true {
            try Task.checkCancellation()
            var matches: [(URL, TimeInterval, String)] = []
            for baseline in baselines {
                guard let current = try? PDDVideoCacheSnapshot.capture(directory: baseline.directory) else { continue }
                let previous = observed[baseline.directory.path] ?? baseline.snapshot
                for (path, fingerprint) in current.files where previous.files[path] != fingerprint {
                    changed.insert(path)
                    if path.hasSuffix("_0") {
                        metadataPathsToRecheck[baseline.directory.path, default: []].insert(path)
                    }
                }
                for path in metadataPathsToRecheck[baseline.directory.path] ?? [] {
                    guard pendingMetadata[baseline.directory.path]?[path] == nil,
                          let fingerprint = current.files[path],
                          let data = try? metadataPrefix(at: URL(fileURLWithPath: path)),
                          let candidate = PDDVideoCacheMetadata.extractCandidate(from: data) else { continue }
                    pendingMetadata[baseline.directory.path, default: [:]][path] = (
                        candidate, fingerprint.modificationTime
                    )
                }
                for (path, candidate) in pendingMetadata[baseline.directory.path] ?? [:]
                where matchingVideoBodyStarted(
                        metadataPath: path,
                        baseline: baseline.snapshot,
                        current: current
                    ) {
                    matches.append((candidate.url, candidate.modificationTime, path))
                }
                observed[baseline.directory.path] = current
            }
            let newestFirst = matches.sorted {
                $0.1 == $1.1 ? $0.2 > $1.2 : $0.1 > $1.1
            }
            for match in newestFirst where await accept(match.0) { return match.0 }
            try await Task.sleep(for: pollInterval)
        }
        if changed.isEmpty { throw PDDCustomerVideoError.timedOutNoCacheChange }
        throw PDDCustomerVideoError.timedOutWithoutVideoMarker(changedFiles: changed.count)
    }

    private func matchingVideoBodyStarted(
        metadataPath: String,
        baseline: PDDVideoCacheSnapshot,
        current: PDDVideoCacheSnapshot
    ) -> Bool {
        guard metadataPath.hasSuffix("_0") else { return false }
        let bodyPath = String(metadataPath.dropLast(2)) + "_s"
        guard let body = current.files[bodyPath], body.size > 0 else { return false }
        return baseline.files[bodyPath] != body
    }

    private func metadataPrefix(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 1_048_576) ?? Data()
    }

    private func uniquePreloadedCandidate(
        in baselines: [PDDVideoCacheBaseline],
        window: ClosedRange<Date>
    ) -> URL? {
        var candidates = Set<URL>()
        for baseline in baselines {
            for (metadataPath, fingerprint) in baseline.snapshot.files
            where metadataPath.hasSuffix("_0")
                && window.contains(Date(timeIntervalSince1970: fingerprint.modificationTime)) {
                let bodyPath = String(metadataPath.dropLast(2)) + "_s"
                guard let body = baseline.snapshot.files[bodyPath], body.size > 0,
                      let data = try? metadataPrefix(at: URL(fileURLWithPath: metadataPath)),
                      let candidate = PDDVideoCacheMetadata.extractCandidate(from: data)
                else { continue }
                candidates.insert(candidate)
            }
        }
        guard candidates.count == 1 else { return nil }
        return candidates.first
    }
}
