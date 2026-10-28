import Foundation

struct StreamingReplyCandidate: Sendable {
    var answerFound = true
    let reply: String
    let action: CodexReplyAction
    let transferReason: CodexTransferReason
    let threadID: String?
    let events: [CodexExecutionEvent]
}

/// Incrementally validates Codex JSONL. A reply is eligible for early handoff
/// only after a completed final agent message and `turn.completed`.
final class AutoReplyCLIStream: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var eligible = true
    private var started = false
    private var ended = false
    private var candidate: String?
    private var candidateAction: CodexReplyAction?
    private var candidateTransferReason: CodexTransferReason?
    private var candidateAnswerFound = true
    private var runningItems = Set<String>()
    private var threadID: String?
    private var events: [CodexExecutionEvent] = []

    func consume(_ data: Data) -> StreamingReplyCandidate? {
        lock.lock()
        defer { lock.unlock() }
        var ready: StreamingReplyCandidate?
        for (index, part) in data.split(separator: 0x0A, omittingEmptySubsequences: false).enumerated() {
            if index > 0 {
                if !pending.isEmpty { ready = event(pending) ?? ready }
                pending.removeAll(keepingCapacity: true)
            }
            if pending.count + part.count > 4 * 1_024 * 1_024 {
                pending.removeAll(keepingCapacity: true)
                eligible = false
            } else {
                pending.append(contentsOf: part)
            }
        }
        return ready
    }

    func finish() {
        lock.lock()
        if !pending.isEmpty { _ = event(pending) }
        pending.removeAll()
        lock.unlock()
    }

    private func event(_ data: Data) -> StreamingReplyCandidate? {
        guard !ended,
              let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = row["type"] as? String else {
            eligible = false
            return nil
        }
        events.append(CodexExecutionEvent(type: type, threadID: row["thread_id"] as? String))
        switch type {
        case "thread.started":
            if let value = row["thread_id"] as? String, !value.isEmpty {
                if let threadID, threadID != value { eligible = false }
                else { threadID = value }
            }
        case "turn.started":
            if started { eligible = false }
            started = true
            candidate = nil
            candidateAction = nil
            candidateTransferReason = nil
        case "turn.failed":
            ended = true
            candidate = nil
            candidateAction = nil
            candidateTransferReason = nil
        case "error":
            eligible = false
            candidate = nil
            candidateAction = nil
            candidateTransferReason = nil
        case "item.started", "item.updated", "item.completed":
            guard let item = row["item"] as? [String: Any] else {
                eligible = false
                return nil
            }
            let id = item["id"] as? String
            if type == "item.started" {
                candidate = nil
                if let id { runningItems.insert(id) } else { eligible = false }
            }
            if type == "item.completed", let id { runningItems.remove(id) }
            guard type == "item.completed", item["type"] as? String == "agent_message",
                  item["phase"] == nil || item["phase"] as? String == "final_answer",
                  let text = item["text"] as? String,
                  let body = text.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  Set(object.keys) == Set(["action", "reply_text", "transfer_reason"]),
                  let actionValue = object["action"] as? String,
                  let action = CodexReplyAction(rawValue: actionValue),
                  let reasonValue = object["transfer_reason"] as? String,
                  let transferReason = CodexTransferReason(rawValue: reasonValue),
                  ((action == .reply && transferReason == .none)
                    || (action == .replyThenTransfer && transferReason != .none)),
                  let reply = object["reply_text"] as? String,
                  !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            candidate = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            candidateAnswerFound = object["answer_found"] as? Bool ?? true
            candidateAction = action
            candidateTransferReason = transferReason
        case "turn.completed":
            ended = true
            guard started, eligible, runningItems.isEmpty, let candidate,
                  let candidateAction, let candidateTransferReason else { return nil }
            return StreamingReplyCandidate(
                answerFound: candidateAnswerFound,
                reply: candidate, action: candidateAction,
                transferReason: candidateTransferReason,
                threadID: threadID, events: events
            )
        default:
            eligible = false
        }
        return nil
    }
}

final class CodexTurnHandoff<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var inputFinished = false
    private var pending: Value?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func offer(_ value: Value) {
        lock.lock()
        if inputFinished {
            let target = continuation
            continuation = nil
            lock.unlock()
            target?.resume(returning: value)
        } else {
            pending = value
            lock.unlock()
        }
    }

    func didWriteInput() {
        lock.lock()
        inputFinished = true
        let value = pending
        pending = nil
        let target = value == nil ? nil : continuation
        if value != nil { continuation = nil }
        lock.unlock()
        if let value { target?.resume(returning: value) }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let target = continuation
        continuation = nil
        pending = nil
        lock.unlock()
        target?.resume(with: result)
    }
}
