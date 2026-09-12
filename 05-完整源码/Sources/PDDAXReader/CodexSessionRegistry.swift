import Foundation

struct CodexSessionBinding: Codable, Equatable {
    let uid: String
    let threadID: String
    let lastUsedAt: Date
    let historyCheckpoint: CodexHistoryCheckpoint?
    let promptSHA256: String?
    let knowledgeSHA256: String?
    let turnCount: Int
    let submittedBytes: Int
    let contaminated: Bool

    init(
        uid: String,
        threadID: String,
        lastUsedAt: Date,
        historyCheckpoint: CodexHistoryCheckpoint? = nil,
        promptSHA256: String? = nil,
        knowledgeSHA256: String? = nil,
        turnCount: Int = 0,
        submittedBytes: Int = 0,
        contaminated: Bool = false
    ) {
        self.uid = uid
        self.threadID = threadID
        self.lastUsedAt = lastUsedAt
        self.historyCheckpoint = historyCheckpoint
        self.promptSHA256 = promptSHA256
        self.knowledgeSHA256 = knowledgeSHA256
        self.turnCount = turnCount
        self.submittedBytes = submittedBytes
        self.contaminated = contaminated
    }

    private enum CodingKeys: String, CodingKey {
        case uid, threadID, lastUsedAt, historyCheckpoint, promptSHA256, knowledgeSHA256
        case turnCount, submittedBytes, contaminated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uid = try c.decode(String.self, forKey: .uid)
        threadID = try c.decode(String.self, forKey: .threadID)
        lastUsedAt = try c.decode(Date.self, forKey: .lastUsedAt)
        historyCheckpoint = try c.decodeIfPresent(
            CodexHistoryCheckpoint.self, forKey: .historyCheckpoint
        )
        promptSHA256 = try c.decodeIfPresent(String.self, forKey: .promptSHA256)
        knowledgeSHA256 = try c.decodeIfPresent(String.self, forKey: .knowledgeSHA256)
        turnCount = try c.decodeIfPresent(Int.self, forKey: .turnCount) ?? 0
        submittedBytes = try c.decodeIfPresent(Int.self, forKey: .submittedBytes) ?? 0
        contaminated = try c.decodeIfPresent(Bool.self, forKey: .contaminated) ?? false
    }
}

enum CodexSessionRegistryError: LocalizedError {
    case invalidUID
    case unsafeDestination
    case mismatchedUID(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidUID:
            return "Codex 会话的用户 ID 不安全。"
        case .unsafeDestination:
            return "Codex 会话路径超出本地隔离目录。"
        case .mismatchedUID(let expected, let actual):
            return "Codex 会话用户不匹配：目录为 \(expected)，文件为 \(actual)。"
        }
    }
}

struct CodexSessionRegistry {
    let rootDirectory: URL
    let leaseDuration: TimeInterval

    init(
        rootDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/拼多多AX记录", isDirectory: true),
        leaseDuration: TimeInterval = 3_600
    ) {
        self.rootDirectory = rootDirectory
        self.leaseDuration = leaseDuration
    }

    func activeBinding(uid: String, now: Date = Date()) throws -> CodexSessionBinding? {
        let url = try bindingURL(uid: uid, createDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let binding = try decoder.decode(CodexSessionBinding.self, from: Data(contentsOf: url))
        guard binding.uid == uid else {
            throw CodexSessionRegistryError.mismatchedUID(expected: uid, actual: binding.uid)
        }
        guard now.timeIntervalSince(binding.lastUsedAt) <= leaseDuration else { return nil }
        return binding
    }

    func save(_ binding: CodexSessionBinding) throws {
        guard !binding.threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let url = try bindingURL(uid: binding.uid, createDirectory: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(binding).write(to: url, options: .atomic)
    }

    func invalidate(uid: String) throws {
        let url = try bindingURL(uid: uid, createDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func bindingURL(uid: String, createDirectory: Bool) throws -> URL {
        guard PerUserAXStore.validUID(uid) else { throw CodexSessionRegistryError.invalidUID }
        let fileManager = FileManager.default
        let usersDirectory = rootDirectory.appendingPathComponent("用户", isDirectory: true)
        let userDirectory = usersDirectory.appendingPathComponent(uid, isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        }

        let canonicalUsers = usersDirectory.resolvingSymlinksInPath().standardizedFileURL
        let canonicalUser = userDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalUser.path.hasPrefix(canonicalUsers.path + "/") else {
            throw CodexSessionRegistryError.unsafeDestination
        }
        return canonicalUser.appendingPathComponent("codex-session.json")
    }
}
