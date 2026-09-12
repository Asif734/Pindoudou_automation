import Foundation

struct ChatMergeResult: Equatable {
    let history: [PDDChatMessage]
    let insertedCount: Int
    let fileURL: URL
}

enum PerUserChatStoreError: LocalizedError {
    case invalidUID
    case unsafeDestination
    case corruptHistory(URL, Int)

    var errorDescription: String? {
        switch self {
        case .invalidUID:
            return "聊天历史的用户 ID 不安全。"
        case .unsafeDestination:
            return "聊天历史路径超出本地隔离目录，已拒绝写入。"
        case .corruptHistory(let url, let line):
            return "聊天历史文件损坏：\(url.path)（第 \(line) 行）。原文件未被覆盖。"
        }
    }
}

struct PerUserChatStore {
    let rootDirectory: URL

    init(
        rootDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/拼多多AX记录", isDirectory: true)
    ) {
        self.rootDirectory = rootDirectory
    }

    func load(uid: String) throws -> [PDDChatMessage] {
        try load(uid: uid, fileName: "history.jsonl")
    }

    func loadAXFirst(uid: String) throws -> [PDDChatMessage] {
        try load(uid: uid, fileName: "history-ax-first.jsonl")
    }

    private func load(uid: String, fileName: String) throws -> [PDDChatMessage] {
        guard PerUserAXStore.validUID(uid) else { throw PerUserChatStoreError.invalidUID }
        let candidate = rootDirectory
            .appendingPathComponent("用户", isDirectory: true)
            .appendingPathComponent(uid, isDirectory: true)
            .appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return [] }
        let url = try historyURL(uid: uid, fileName: fileName, createDirectory: false)
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw PerUserChatStoreError.corruptHistory(url, 1)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var messages: [PDDChatMessage] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            do {
                messages.append(try decoder.decode(PDDChatMessage.self, from: Data(line.utf8)))
            } catch {
                throw PerUserChatStoreError.corruptHistory(url, offset + 1)
            }
        }
        return messages
    }

    func merge(uid: String, messages: [PDDChatMessage]) throws -> ChatMergeResult {
        let existing = try load(uid: uid)
        return try merge(uid: uid, existing: existing, messages: messages)
    }

    func mergeAXFirst(uid: String, messages: [PDDChatMessage]) throws -> ChatMergeResult {
        let existing = try loadAXFirst(uid: uid)
        return try merge(
            uid: uid,
            existing: existing,
            messages: messages,
            fileName: "history-ax-first.jsonl"
        )
    }

    func mergeOCRAuthoritative(uid: String, messages: [PDDChatMessage]) throws -> ChatMergeResult {
        let existingOCR = try load(uid: uid).filter {
            ($0.id.hasPrefix("ocr-") && !PDDOCRChatParser.isKnownPlatformNoiseText($0.content))
                || ($0.kind == .image && $0.sender == .customer)
        }
        let visibleIDs = Set(messages.map(\.id))
        let overlap = existingOCR.indices.filter { visibleIDs.contains(existingOCR[$0].id) }
        guard !overlap.isEmpty else {
            return try merge(uid: uid, existing: existingOCR, messages: messages)
        }

        let existingIndexes = Dictionary(
            uniqueKeysWithValues: existingOCR.enumerated().map { ($0.element.id, $0.offset) }
        )
        let visibleAnchorIndexes = messages.compactMap { existingIndexes[$0.id] }
        let anchorsAreMonotonic = zip(
            visibleAnchorIndexes, visibleAnchorIndexes.dropFirst()
        ).allSatisfy(<)
        guard anchorsAreMonotonic else {
            return try merge(uid: uid, existing: existingOCR, messages: messages)
        }

        let existingByID = Dictionary(uniqueKeysWithValues: existingOCR.map { ($0.id, $0) })
        let orderedVisible = messages.map { message in
            guard let previous = existingByID[message.id] else { return message }
            return PDDChatMessage(
                id: message.id,
                sender: message.sender,
                content: message.content,
                displayTime: message.displayTime,
                kind: message.kind,
                capturedAt: previous.capturedAt
            )
        }
        let visibleIndexes = Dictionary(
            uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) }
        )
        var previousVisible: [Int?] = Array(repeating: nil, count: existingOCR.count)
        var previous: Int?
        for index in existingOCR.indices {
            previousVisible[index] = previous
            if let visibleIndex = visibleIndexes[existingOCR[index].id] {
                previous = visibleIndex
            }
        }
        var nextVisible: [Int?] = Array(repeating: nil, count: existingOCR.count)
        var next: Int?
        for index in existingOCR.indices.reversed() {
            nextVisible[index] = next
            if let visibleIndex = visibleIndexes[existingOCR[index].id] {
                next = visibleIndex
            }
        }
        var retainedBySlot = Array(repeating: [PDDChatMessage](), count: messages.count + 1)
        for index in existingOCR.indices where !visibleIDs.contains(existingOCR[index].id) {
            let slot: Int
            switch (previousVisible[index], nextVisible[index]) {
            case let (previous?, next?) where previous < next:
                slot = previous + 1
            case let (previous?, nil):
                slot = previous + 1
            case let (nil, next?):
                slot = next
            case let (previous?, next?):
                slot = min(previous, next) + 1
            case (nil, nil):
                slot = messages.count
            }
            retainedBySlot[slot].append(existingOCR[index])
        }
        var history: [PDDChatMessage] = []
        for slot in 0...messages.count {
            history.append(contentsOf: retainedBySlot[slot])
            if slot < orderedVisible.count { history.append(orderedVisible[slot]) }
        }
        let insertedCount = messages.filter { existingByID[$0.id] == nil }.count
        return try persist(uid: uid, history: history, insertedCount: insertedCount)
    }

    private func merge(
        uid: String,
        existing: [PDDChatMessage],
        messages: [PDDChatMessage],
        fileName: String = "history.jsonl"
    ) throws -> ChatMergeResult {
        var merged = existing
        var indexes = Dictionary(uniqueKeysWithValues: existing.enumerated().map { ($0.element.id, $0.offset) })
        var insertedCount = 0
        for message in messages {
            if let index = indexes[message.id] {
                let previous = merged[index]
                if previous.sender != message.sender
                    || previous.content != message.content
                    || previous.kind != message.kind {
                    merged[index] = PDDChatMessage(
                        id: message.id,
                        sender: message.sender,
                        content: message.content,
                        displayTime: message.displayTime,
                        kind: message.kind,
                        capturedAt: previous.capturedAt
                    )
                }
            } else {
                indexes[message.id] = merged.count
                merged.append(message)
                insertedCount += 1
            }
        }

        return try persist(
            uid: uid,
            history: merged,
            insertedCount: insertedCount,
            fileName: fileName
        )
    }

    private func persist(
        uid: String,
        history: [PDDChatMessage],
        insertedCount: Int,
        fileName: String = "history.jsonl"
    ) throws -> ChatMergeResult {
        let destination = try historyURL(uid: uid, fileName: fileName, createDirectory: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let lines = try history.map { message -> String in
            let data = try encoder.encode(message)
            guard let line = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            return line
        }
        let contents = lines.isEmpty ? Data() : Data((lines.joined(separator: "\n") + "\n").utf8)
        try contents.write(to: destination, options: .atomic)

        return ChatMergeResult(history: history, insertedCount: insertedCount, fileURL: destination)
    }

    private func historyURL(
        uid: String,
        fileName: String = "history.jsonl",
        createDirectory: Bool
    ) throws -> URL {
        guard PerUserAXStore.validUID(uid) else { throw PerUserChatStoreError.invalidUID }
        let fileManager = FileManager.default
        let usersDirectory = rootDirectory.appendingPathComponent("用户", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: usersDirectory, withIntermediateDirectories: true)
        }
        let userDirectory = usersDirectory.appendingPathComponent(uid, isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        }

        let canonicalUsers = usersDirectory.resolvingSymlinksInPath().standardizedFileURL
        let canonicalUser = userDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalUser.path.hasPrefix(canonicalUsers.path + "/") else {
            throw PerUserChatStoreError.unsafeDestination
        }
        return canonicalUser.appendingPathComponent(fileName)
    }
}
