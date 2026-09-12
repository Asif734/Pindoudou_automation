import Foundation

enum AutoReplyStoreError: Error, LocalizedError {
    case unsupportedSchema(Int)
    case missingReply
    case archiveConflict(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "不支持的自动回复状态版本：\(version)"
        case .missingReply: return "归档任务没有回复文本"
        case .archiveConflict(let id): return "归档证据冲突，拒绝覆盖：\(id)"
        }
    }
}

final class AutoReplyStore: @unchecked Sendable {
    let rootDirectory: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    init(
        rootDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/拼多多AX记录/自动回复", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    func load() throws -> AutoReplyPersistentState {
        try locked {
            let url = stateURL
            guard fileManager.fileExists(atPath: url.path) else { return .empty }
            let originalData = try Data(contentsOf: url)
            var state = try decoder.decode(AutoReplyPersistentState.self, from: originalData)
            let originalSchema = state.schemaVersion
            if (1...4).contains(state.schemaVersion) {
                let droppedUIDs = Set(state.pendingCaptureRequests.compactMap { request in
                    request.uid.hasPrefix("GZC-")
                        && state.conversationLocatorsByUID[request.uid] == nil
                        ? request.uid : nil
                })
                state.pendingCaptureRequests.removeAll { request in
                    droppedUIDs.contains(request.uid)
                }
                for uid in droppedUIDs.sorted() {
                    state.events.append(AutoReplyEvent(
                        id: UUID(),
                        timestamp: Date(),
                        uid: uid,
                        kind: "legacy-locator-dropped",
                        detail: "旧版待采集任务没有可恢复的会话 locator，已移出活跃队列"
                    ))
                }
                if state.events.count > 100 {
                    state.events = Array(state.events.suffix(100))
                }
                state.schemaVersion = 5
            }
            if state.schemaVersion == 5 {
                migrateSchemaFiveToAXFirst(&state)
            }
            guard state.schemaVersion == 6 else {
                throw AutoReplyStoreError.unsupportedSchema(state.schemaVersion)
            }
            if originalSchema != state.schemaVersion {
                let stamp = Int(Date().timeIntervalSince1970 * 1_000)
                let backup = rootDirectory.appendingPathComponent(
                    "state.schema\(originalSchema)-backup-\(stamp).json"
                )
                try originalData.write(to: backup, options: .atomic)
                try encoder.encode(state).write(to: url, options: .atomic)
            }
            return state
        }
    }

    private func migrateSchemaFiveToAXFirst(_ state: inout AutoReplyPersistentState) {
        let reason = "AX-first 迁移丢弃旧 OCR 待处理任务"
        for index in state.jobs.indices {
            if [.completed, .failed, .uncertain, .quarantined].contains(state.jobs[index].state) {
                continue
            }
            if state.jobs[index].state == .sending, state.jobs[index].sendWasInvoked {
                state.jobs[index].state = .completed
                state.jobs[index].deliveryOutcome = .uncertain
                state.jobs[index].lastError = "\(reason)；发送调用已经发生，按结果不确定完成"
            } else {
                state.jobs[index].state = .failed
                state.jobs[index].deliveryOutcome = .notSent
                state.jobs[index].lastError = reason
            }
            state.jobs[index].pendingSupplement = nil
            state.jobs[index].supplementCapturePending = false
            state.jobs[index].nextAttemptAt = nil
        }
        state.pendingCaptureRequests = []
        state.answeredCursors = [:]
        state.baselinedUIDs = []
        state.axFirstBaselinedUIDs = []
        state.provisionalReceiptsByUID = [:]
        state.messageSourceSelectorStatesByUID = [:]
        state.events.append(AutoReplyEvent(
            id: UUID(),
            timestamp: Date(),
            uid: nil,
            kind: "ax-first-migration",
            detail: reason
        ))
        if state.events.count > 100 {
            state.events = Array(state.events.suffix(100))
        }
        state.schemaVersion = 6
    }

    func loadRecoveringInterruptedWork(now: Date) throws -> AutoReplyPersistentState {
        var state = try load()
        var changed = false
        for index in state.jobs.indices {
            switch state.jobs[index].state {
            case .sending:
                if state.jobs[index].sendWasInvoked {
                    state.jobs[index].state = .completed
                    state.jobs[index].deliveryOutcome = .uncertain
                    state.jobs[index].lastError = "应用在发送调用后中断；为避免重复发送，按结果不确定完成 @ \(now.timeIntervalSince1970)"
                    _ = state.advanceSourceAndPromoteSupplement(at: index)
                } else {
                    state.jobs[index].state = .ready
                    state.jobs[index].deliveryOutcome = .notSent
                    state.jobs[index].lastError = "应用在调用发送前中断；已安全重新排队 @ \(now.timeIntervalSince1970)"
                    state.jobs[index].durableAttemptOperationID = nil
                }
                changed = true
            case .generating:
                state.jobs[index].state = .queued
                changed = true
            case .capturing:
                state.jobs[index].state = .discovered
                changed = true
            default:
                break
            }
        }
        if changed { try save(state) }
        return state
    }

    func save(_ state: AutoReplyPersistentState) throws {
        try locked {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            try encoder.encode(state).write(to: stateURL, options: .atomic)
        }
    }

    func archive(_ job: AutoReplyJob) throws {
        guard let reply = job.reply else { throw AutoReplyStoreError.missingReply }
        try locked {
            let records = rootDirectory.appendingPathComponent("archive/records", isDirectory: true)
            let replies = rootDirectory.appendingPathComponent("archive/replies", isDirectory: true)
            try fileManager.createDirectory(at: records, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: replies, withIntermediateDirectories: true)
            let recordURL = records.appendingPathComponent("\(job.id.uuidString).json")
            let replyURL = replies.appendingPathComponent("\(job.id.uuidString).txt")
            let recordData = try encoder.encode(job)
            let replyData = Data(reply.utf8)
            if fileManager.fileExists(atPath: recordURL.path),
               try Data(contentsOf: recordURL) != recordData {
                throw AutoReplyStoreError.archiveConflict(job.id.uuidString)
            }
            if fileManager.fileExists(atPath: replyURL.path),
               try Data(contentsOf: replyURL) != replyData {
                throw AutoReplyStoreError.archiveConflict(job.id.uuidString)
            }
            if !fileManager.fileExists(atPath: recordURL.path) {
                try recordData.write(to: recordURL, options: .atomic)
            }
            if !fileManager.fileExists(atPath: replyURL.path) {
                try replyData.write(to: replyURL, options: .atomic)
            }
        }
    }

    private var stateURL: URL {
        rootDirectory.appendingPathComponent("state.json")
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
