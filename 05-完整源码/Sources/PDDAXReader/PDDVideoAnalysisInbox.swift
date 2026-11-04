import Foundation

/// Durable records of video occurrences. Separate chat messages remain separate
/// requests even when their downloaded MP4 bytes are identical.
actor PDDVideoAnalysisInbox {
    private struct Entry: Codable, Equatable, Sendable {
        let uid: String
        let messageID: String
        let contentSHA256: String
        let videoFilePath: String
        let claimedAt: Date
    }

    private struct Payload: Codable, Equatable, Sendable {
        var schemaVersion = 2
        var entries: [Entry] = []
    }

    private let stateURL: URL
    private let legacySchedulerRoot: URL?
    private var cached: Payload?

    init(stateURL: URL, legacySchedulerRoot: URL? = nil) {
        self.stateURL = stateURL
        self.legacySchedulerRoot = legacySchedulerRoot
    }

    /// Admit each distinct message and permit recovery of that exact message.
    /// Task/receipt tracking prevents duplicate work for a retry; content hashes
    /// are integrity metadata, never a reason to discard a later customer upload.
    func claim(_ receipt: PDDDownloadedCustomerVideo) throws -> Bool {
        var payload = try load()
        if payload.entries.contains(where: {
            $0.uid == receipt.uid && $0.messageID == receipt.messageID
        }) {
            return true
        }
        payload.schemaVersion = 2
        payload.entries.append(Entry(
            uid: receipt.uid,
            messageID: receipt.messageID,
            contentSHA256: receipt.summary.sha256,
            videoFilePath: receipt.fileURL.path,
            claimedAt: Date()
        ))
        try save(payload)
        return true
    }

    private func load() throws -> Payload {
        if let cached { return cached }
        let payload: Payload
        if FileManager.default.fileExists(atPath: stateURL.path) {
            payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: stateURL))
        } else {
            payload = hydrateLegacyEntries()
            if !payload.entries.isEmpty { try save(payload) }
        }
        cached = payload
        return payload
    }

    private func hydrateLegacyEntries() -> Payload {
        guard let root = legacySchedulerRoot else { return Payload() }
        var jobs: [AutoReplyJob] = []
        let stateURL = root.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: stateURL.path),
           let data = try? Data(contentsOf: stateURL),
           let state = try? JSONDecoder().decode(AutoReplyPersistentState.self, from: data) {
            jobs.append(contentsOf: state.jobs)
        }
        let archive = root.appendingPathComponent("archive/records", isDirectory: true)
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: archive, includingPropertiesForKeys: nil
        ) {
            for url in urls where url.pathExtension == "json" {
                if let data = try? Data(contentsOf: url),
                   let job = try? JSONDecoder().decode(AutoReplyJob.self, from: data) {
                    jobs.append(job)
                }
            }
        }
        var seen = Set<String>()
        let entries = jobs.flatMap { job in
            job.videoAttachments.compactMap { attachment -> Entry? in
                let key = "\(job.uid)|\(attachment.messageID)"
                guard !attachment.sha256.isEmpty, seen.insert(key).inserted else { return nil }
                return Entry(
                    uid: job.uid,
                    messageID: attachment.messageID,
                    contentSHA256: attachment.sha256,
                    videoFilePath: attachment.localURL.path,
                    claimedAt: Date()
                )
            }
        }
        return Payload(entries: entries)
    }

    private func save(_ payload: Payload) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(payload).write(to: stateURL, options: .atomic)
        cached = payload
    }
}
