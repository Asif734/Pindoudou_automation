import CryptoKit
import Foundation

struct AutoReplyCheckpointToken: Codable, Equatable, Sendable {
    let hash: String
    let schemaVersion: Int
}

struct AutoReplyCheckpoint: Equatable, Sendable {
    let state: AutoReplyPersistentState
    let token: AutoReplyCheckpointToken
}

enum AutoReplyTransactionalStoreError: Error, Equatable, LocalizedError {
    case checkpointChanged
    case cursorRegression(String)
    case archiveManifestConflict(String)

    var errorDescription: String? {
        switch self {
        case .checkpointChanged:
            return "state checkpoint 已被外部修改，拒绝静默覆盖"
        case .cursorRegression(let uid):
            return "客户游标禁止倒退：\(uid)"
        case .archiveManifestConflict(let id):
            return "终态归档清单冲突：\(id)"
        }
    }
}

final class AutoReplyTransactionalStore: @unchecked Sendable {
    private let rootDirectory: URL
    private let base: AutoReplyStore
    private let lock = NSLock()

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        base = AutoReplyStore(rootDirectory: rootDirectory)
    }

    func loadCheckpoint() throws -> AutoReplyCheckpoint {
        try locked {
            let state = try base.load()
            return AutoReplyCheckpoint(state: state, token: try currentToken(state: state))
        }
    }

    @discardableResult
    func commit(
        expected: AutoReplyCheckpointToken?,
        mutation: (inout AutoReplyPersistentState) throws -> Void
    ) throws -> AutoReplyCheckpointToken {
        try locked {
            let old = try base.load()
            let actual = try currentToken(state: old)
            if let expected, expected != actual {
                throw AutoReplyTransactionalStoreError.checkpointChanged
            }
            var updated = old
            try mutation(&updated)
            updated.repairOverlappingExecutions(at: Date())
            for (uid, oldCursor) in old.answeredCursors {
                if let newCursor = updated.answeredCursors[uid], newCursor.count < oldCursor.count {
                    throw AutoReplyTransactionalStoreError.cursorRegression(uid)
                }
            }
            if updated.events.count > 100 {
                updated.events = Array(updated.events.suffix(100))
            }
            let active = updated.jobs.filter {
                [.discovered, .capturing, .queued, .generating, .ready, .sending]
                    .contains($0.state)
            }
            let terminal = updated.jobs.filter {
                ![.discovered, .capturing, .queued, .generating, .ready, .sending]
                    .contains($0.state)
            }.suffix(200)
            updated.jobs = (active + terminal).sorted { $0.sequence < $1.sequence }
            try base.save(updated)
            return try currentToken(state: updated)
        }
    }

    func archiveTerminal(_ job: AutoReplyJob) throws {
        try locked {
            try base.archive(job)
            let recordURL = rootDirectory.appendingPathComponent(
                "archive/records/\(job.id.uuidString).json"
            )
            let replyURL = rootDirectory.appendingPathComponent(
                "archive/replies/\(job.id.uuidString).txt"
            )
            let record = try Data(contentsOf: recordURL)
            let reply = try Data(contentsOf: replyURL)
            let manifest = ArchiveManifest(
                jobID: job.id,
                recordBytes: record.count,
                recordSHA256: Self.sha256(record),
                replyBytes: reply.count,
                replySHA256: Self.sha256(reply)
            )
            let manifests = rootDirectory.appendingPathComponent(
                "archive/manifests", isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: manifests, withIntermediateDirectories: true
            )
            let url = manifests.appendingPathComponent("\(job.id.uuidString).json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(manifest)
            if FileManager.default.fileExists(atPath: url.path) {
                guard try Data(contentsOf: url) == data else {
                    throw AutoReplyTransactionalStoreError.archiveManifestConflict(
                        job.id.uuidString
                    )
                }
                return
            }
            let temporary = manifests.appendingPathComponent(".manifest-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private struct ArchiveManifest: Codable, Equatable {
        let jobID: UUID
        let recordBytes: Int
        let recordSHA256: String
        let replyBytes: Int
        let replySHA256: String
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func currentToken(state: AutoReplyPersistentState) throws -> AutoReplyCheckpointToken {
        let stateURL = rootDirectory.appendingPathComponent("state.json")
        let data: Data
        if FileManager.default.fileExists(atPath: stateURL.path) {
            data = try Data(contentsOf: stateURL)
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(state)
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return AutoReplyCheckpointToken(hash: hash, schemaVersion: state.schemaVersion)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
