import Foundation

enum PDDDurableVideoTransferPhase: String, Codable, Equatable, Sendable {
    case discovered
    case opening
    case addressCaptured
    case downloading
    case validating
    case downloaded
    case preparingEvidence
    case readyForGeneration
    case admitted
    case completed
    case waitingForRetry
    case terminalFailure
}

enum PDDVideoTransferFailureCategory: String, Codable, Equatable, Sendable {
    case addressUnavailable
    case dnsResolution
    case connectTimeout
    case tlsFailure
    case offline
    case connectionReset
    case httpRejected
    case redirectRejected
    case responseTimeout
    case invalidContent
    case invalidVideo
    case localFile
    case retryBudgetExhausted
    case legacyUnknown
}

struct PDDDurableVideoTransferRecord: Codable, Equatable, Sendable {
    let key: PDDVideoTransferKey
    let uid: String
    let messageID: String
    var phase: PDDDurableVideoTransferPhase
    var attemptCount: Int
    var retryIndex: Int
    var nextAttemptAt: Date?
    var needsFreshAddress: Bool
    var fallbackEmitted: Bool
    var fileName: String?
    var failure: PDDVideoTransferFailureCategory?
    var updatedAt: Date
}

enum PDDVideoRetryPolicy {
    private static let delays: [TimeInterval] = [60, 180, 600]

    static func delay(afterFailure index: Int) -> TimeInterval? {
        guard delays.indices.contains(index) else { return nil }
        return delays[index]
    }
}

enum PDDDurableVideoTransferStoreError: LocalizedError {
    case unsupportedSchema(Int)
    case identityMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "不支持的视频传输状态版本：\(version)"
        case .identityMismatch:
            return "视频传输客户身份不匹配"
        }
    }
}

actor PDDDurableVideoTransferStore {
    private struct Payload: Codable {
        var schemaVersion = 1
        var records: [PDDDurableVideoTransferRecord] = []
    }

    private let url: URL
    private let now: @Sendable () -> Date
    private var cached: Payload?

    init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    @discardableResult
    func begin(
        key: PDDVideoTransferKey, uid: String, messageID: String
    ) throws -> PDDDurableVideoTransferRecord {
        var payload = try load()
        if let index = payload.records.firstIndex(where: { $0.key == key }) {
            guard payload.records[index].uid == uid else {
                throw PDDDurableVideoTransferStoreError.identityMismatch
            }
            return payload.records[index]
        }
        let value = PDDDurableVideoTransferRecord(
            key: key, uid: uid, messageID: messageID, phase: .discovered, attemptCount: 0,
            retryIndex: 0, nextAttemptAt: nil, needsFreshAddress: false,
            fallbackEmitted: false, fileName: nil, failure: nil, updatedAt: now()
        )
        payload.records.append(value)
        try save(payload)
        return value
    }

    func record(_ key: PDDVideoTransferKey) throws -> PDDDurableVideoTransferRecord? {
        try load().records.first { $0.key == key }
    }

    func allRecords() throws -> [PDDDurableVideoTransferRecord] {
        try load().records
    }

    func dueRecords() throws -> [PDDDurableVideoTransferRecord] {
        let current = now()
        return try load().records.filter {
            $0.phase == .waitingForRetry && ($0.nextAttemptAt ?? .distantPast) <= current
        }.sorted { ($0.nextAttemptAt ?? .distantPast) < ($1.nextAttemptAt ?? .distantPast) }
    }

    func claimDueRecords() throws -> [PDDDurableVideoTransferRecord] {
        let current = now()
        var payload = try load()
        let indices = payload.records.indices.filter {
            payload.records[$0].phase == .waitingForRetry
                && (payload.records[$0].nextAttemptAt ?? .distantPast) <= current
        }.sorted {
            (payload.records[$0].nextAttemptAt ?? .distantPast)
                < (payload.records[$1].nextAttemptAt ?? .distantPast)
        }
        let claimed = indices.map { payload.records[$0] }
        guard !indices.isEmpty else { return [] }
        for index in indices {
            payload.records[index].phase = .opening
            payload.records[index].nextAttemptAt = nil
            payload.records[index].updatedAt = current
        }
        try save(payload)
        return claimed
    }

    func transition(
        key: PDDVideoTransferKey,
        to phase: PDDDurableVideoTransferPhase,
        failure: PDDVideoTransferFailureCategory? = nil,
        fileName: String? = nil
    ) throws {
        var payload = try load()
        guard let index = payload.records.firstIndex(where: { $0.key == key }) else { return }
        payload.records[index].phase = phase
        payload.records[index].failure = failure
        if let fileName { payload.records[index].fileName = fileName }
        if phase != .waitingForRetry { payload.records[index].nextAttemptAt = nil }
        if phase == .addressCaptured { payload.records[index].needsFreshAddress = false }
        payload.records[index].updatedAt = now()
        try save(payload)
    }

    func recordAttempt(key: PDDVideoTransferKey) throws {
        var payload = try load()
        guard let index = payload.records.firstIndex(where: { $0.key == key }) else { return }
        payload.records[index].attemptCount += 1
        payload.records[index].updatedAt = now()
        try save(payload)
    }

    func scheduleRetry(
        key: PDDVideoTransferKey,
        category: PDDVideoTransferFailureCategory,
        nextAttemptAt: Date
    ) throws {
        var payload = try load()
        guard let index = payload.records.firstIndex(where: { $0.key == key }) else { return }
        payload.records[index].phase = .waitingForRetry
        payload.records[index].failure = category
        payload.records[index].nextAttemptAt = nextAttemptAt
        payload.records[index].needsFreshAddress = true
        payload.records[index].retryIndex += 1
        payload.records[index].updatedAt = now()
        try save(payload)
    }

    func markFallbackEmitted(key: PDDVideoTransferKey) throws -> Bool {
        var payload = try load()
        guard let index = payload.records.firstIndex(where: { $0.key == key }) else { return false }
        guard !payload.records[index].fallbackEmitted else { return false }
        payload.records[index].fallbackEmitted = true
        payload.records[index].updatedAt = now()
        try save(payload)
        return true
    }

    private func load() throws -> Payload {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: url.path) else {
            let payload = Payload()
            cached = payload
            return payload
        }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        guard payload.schemaVersion == 1 else {
            throw PDDDurableVideoTransferStoreError.unsupportedSchema(payload.schemaVersion)
        }
        cached = payload
        return payload
    }

    private func save(_ payload: Payload) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(payload).write(to: url, options: .atomic)
        cached = payload
    }
}
