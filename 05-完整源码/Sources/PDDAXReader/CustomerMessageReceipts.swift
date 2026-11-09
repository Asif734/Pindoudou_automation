import CryptoKit
import Foundation

/// Local evidence for capture, CLI input delivery, completed turns, and replies.
/// Writing stdin is deliberately distinct from a successful Codex turn.
struct CustomerMessageReceipts: Sendable {
    struct Receipt: Codable, Equatable, Sendable {
        let messageID: String
        let capturedAt: Date
        var requiresSubmission = false
        var submittedAt: Date?
        var completedAt: Date?
        var replySentAt: Date?
        var batchKey: String?
        var promptSHA256: String?
        var submissionID: UUID?
        var closedAt: Date?
        var closureReason: String?
    }

    private struct State: Codable {
        var customers: [String: [String: Receipt]] = [:]
    }

    enum ReceiptError: LocalizedError {
        case targetDoesNotMatchBatch
        case inputNotConfirmed

        var errorDescription: String? {
            switch self {
            case .targetDoesNotMatchBatch: return "Codex 目标消息与冻结批次不一致，拒绝提交"
            case .inputNotConfirmed: return "未确认全部客户消息已完整写入本次 Codex 请求"
            }
        }
    }

    private static let lock = NSLock()
    let root: URL
    private var url: URL { root.appendingPathComponent("message-receipts.json") }

    func prepare() throws { try update { _ in } }

    func receipts(uid: String) throws -> [String: Receipt] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try load().customers[uid] ?? [:]
    }

    func awaitingSubmission() throws -> [String: Set<String>] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try load().customers.mapValues { messages in
            Set(messages.values.filter {
                $0.requiresSubmission && $0.submittedAt == nil && $0.replySentAt == nil && $0.closedAt == nil
            }.map(\.messageID))
        }.filter { !$0.value.isEmpty }
    }

    func closedMessageIDs(uid: String) throws -> Set<String> {
        Set(try receipts(uid: uid).values.filter { $0.closedAt != nil }.map(\.messageID))
    }

    /// Closing known skipped work is not a model completion or a send receipt.
    @discardableResult
    func closeUnsubmitted(uid: String, messageIDs: Set<String>, reason: String, at date: Date = Date()) throws -> Int {
        var count = 0
        try update { state in
            for id in messageIDs {
                guard var receipt = state.customers[uid]?[id], receipt.requiresSubmission,
                      receipt.closedAt == nil, receipt.submittedAt == nil, receipt.replySentAt == nil else { continue }
                receipt.closedAt = date; receipt.closureReason = reason
                state.customers[uid, default: [:]][id] = receipt
                count += 1
            }
        }
        if count > 0 {
            AutomationStepLog.record(root: root, uid: uid, step: "message-receipt-intentionally-closed",
                detail: "reason=\(reason) message_ids=\(messageIDs.sorted().joined(separator: ",")) count=\(count); not submitted or sent")
        }
        return count
    }

    /// One startup pass over durable legacy skip events; never infer closure from age or a missing red dot.
    @discardableResult
    func reconcileLegacyVideoSkips(excluding activeIDs: [String: Set<String>] = [:], at date: Date = Date()) throws -> Int {
        let pending = try awaitingSubmission()
        guard !pending.isEmpty else { return 0 }
        let logURL = root.appendingPathComponent("logs/automation-steps.jsonl")
        guard FileManager.default.fileExists(atPath: logURL.path) else { return 0 }
        let handle = try FileHandle(forReadingFrom: logURL)
        defer { try? handle.close() }
        // Stream old logs instead of loading the whole history into memory.
        var buffer = Data(); var skipped: [String: Set<String>] = [:]
        func consume(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8), text.contains("video-content-duplicate"),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["kind"] as? String == "video-content-duplicate",
                  let uid = object["uid"] as? String, let wanted = pending[uid],
                  let detail = object["detail"] as? String else { return }
            let ids = Set(detail.split(separator: ",").map(String.init)).intersection(wanted)
                .subtracting(activeIDs[uid] ?? [])
            skipped[uid, default: []].formUnion(ids)
        }
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                consume(Data(buffer[..<newline]))
                buffer.removeSubrange(...newline)
            }
            if buffer.count > 4 * 1024 * 1024 { buffer.removeAll() }
        }
        if !buffer.isEmpty { consume(buffer) }
        var count = 0
        for (uid, ids) in skipped where !ids.isEmpty {
            count += try closeUnsubmitted(uid: uid, messageIDs: ids, reason: "legacy-video-content-duplicate", at: date)
        }
        return count
    }

    func observe(uid: String, messages: [PDDChatMessage], actionableIDs: Set<String> = [], at date: Date = Date()) throws {
        try update { state in
            for message in messages where message.sender == .customer {
                var receipt = state.customers[uid]?[message.id]
                    ?? Receipt(messageID: message.id, capturedAt: date)
                receipt.requiresSubmission = receipt.requiresSubmission || actionableIDs.contains(message.id)
                state.customers[uid, default: [:]][message.id] = receipt
            }
        }
    }

    func capture(_ capture: AutoReplyCapture, at date: Date = Date()) throws {
        try observe(uid: capture.uid, messages: capture.fullHistory,
            actionableIDs: capture.batch?.customerMessageIDs ?? [], at: date)
        // OCR/media placeholders can occur in a batch before full-history enrichment.
        let events = capture.batch?.events.filter { capture.batch?.customerMessageIDs.contains($0.messageID) == true } ?? []
        try observe(uid: capture.uid, messages: events.map {
            PDDChatMessage(id: $0.messageID, sender: .customer, content: $0.content,
                displayTime: $0.displayTime, kind: $0.kind, capturedAt: date)
        }, actionableIDs: Set(events.map(\.messageID)), at: date)
    }

    func begin(_ capture: AutoReplyCapture, submissionID: UUID) throws {
        try update { state in
            for id in capture.batch?.customerMessageIDs ?? [] {
                guard var receipt = state.customers[capture.uid]?[id], receipt.closedAt == nil else { throw ReceiptError.inputNotConfirmed }
                receipt.submissionID = submissionID
                receipt.submittedAt = nil
                receipt.completedAt = nil
                state.customers[capture.uid, default: [:]][id] = receipt
            }
        }
    }

    func submitted(_ capture: AutoReplyCapture, prompt: String, submissionID: UUID, at date: Date = Date()) throws {
        guard let batch = capture.batch else { throw ReceiptError.targetDoesNotMatchBatch }
        let expected = batch.events.filter { batch.customerMessageIDs.contains($0.messageID) }
        let decoded = try batch.targetCustomerJSONL.split(separator: "\n").map {
            try JSONDecoder().decode(ActionableCustomerEvent.self, from: Data($0.utf8))
        }
        let containsTarget = batch.targetCustomerJSONL.isEmpty
            ? batch.incomingHandoffKey != nil : prompt.contains(batch.targetCustomerJSONL)
        guard decoded == expected, containsTarget else {
            throw ReceiptError.targetDoesNotMatchBatch
        }
        let key = batchKey(batch)
        try update { state in
            for id in batch.customerMessageIDs {
                guard var receipt = state.customers[capture.uid]?[id], receipt.submissionID == submissionID
                else { throw ReceiptError.inputNotConfirmed }
                receipt.submittedAt = date
                receipt.completedAt = nil
                receipt.batchKey = key
                receipt.promptSHA256 = sha256(prompt)
                state.customers[capture.uid, default: [:]][id] = receipt
            }
        }
        AutomationStepLog.record(root: root, uid: capture.uid, step: "codex-input-confirmed",
            detail: "batch=\(key) message_ids=\(batch.customerMessageIDs.sorted().joined(separator: ","))")
    }

    func completed(_ capture: AutoReplyCapture, submissionID: UUID?, at date: Date = Date()) throws {
        guard let batch = capture.batch else { throw ReceiptError.inputNotConfirmed }
        let key = batchKey(batch)
        try update { state in
            for id in batch.customerMessageIDs {
                guard var receipt = state.customers[capture.uid]?[id], receipt.submittedAt != nil,
                      receipt.batchKey == key, submissionID != nil, receipt.submissionID == submissionID
                else { throw ReceiptError.inputNotConfirmed }
                receipt.completedAt = date
                state.customers[capture.uid, default: [:]][id] = receipt
            }
        }
        AutomationStepLog.record(root: root, uid: capture.uid, step: "codex-batch-completed",
            detail: "batch=\(key) message_ids=\(batch.customerMessageIDs.sorted().joined(separator: ","))")
    }

    func replied(_ capture: AutoReplyCapture, at date: Date = Date()) throws {
        try update { state in
            for id in capture.batch?.customerMessageIDs ?? [] {
                guard var receipt = state.customers[capture.uid]?[id] else { continue }
                receipt.replySentAt = date
                state.customers[capture.uid, default: [:]][id] = receipt
            }
        }
    }

    private func batchKey(_ batch: FrozenCustomerBatch) -> String {
        sha256(batch.targetCustomerJSONL + "\n" + (batch.incomingHandoffKey ?? ""))
    }

    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func load() throws -> State {
        guard FileManager.default.fileExists(atPath: url.path) else { return State() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(State.self, from: Data(contentsOf: url))
    }

    private func update(_ mutation: (inout State) throws -> Void) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var state = try load()
        try mutation(&state)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
