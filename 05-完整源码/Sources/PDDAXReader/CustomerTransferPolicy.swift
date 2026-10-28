import CryptoKit
import Foundation

// Intent is supplied by Codex. This layer never inspects customer text for keywords.
enum CustomerRequestKind: String, Codable, Sendable {
    case other
    case humanRequest = "human_request"
    case refundReturn = "refund_return"
    case technical
}

struct CustomerTransferDecision: Codable, Equatable, Sendable {
    let count: Int
    let action: CodexReplyAction
    let reason: CodexTransferReason
}

actor CustomerTransferPolicyStore {
    static let shared = CustomerTransferPolicyStore()
    private struct Window: Codable {
        var firstAt: Date
        var count: Int
    }
    private struct Customer: Codable {
        var closedMessageIDs: Set<String> = []
        var windows: [String: Window] = [:]
        var decisions: [String: CustomerTransferDecision] = [:]
    }
    private struct State: Codable {
        var customers: [String: Customer] = [:]
    }

    private func load(root: URL) throws -> State {
        let url = root.appendingPathComponent("customer-transfer-policy.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return State() }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
    }

    func closedMessageIDs(root: URL, uid: String) throws -> Set<String> {
        try load(root: root).customers[uid]?.closedMessageIDs ?? []
    }

    func completeHandoff(root: URL, uid: String, messageIDs: Set<String>) throws {
        var state = try load(root: root)
        var customer = state.customers[uid] ?? Customer()
        customer.windows.removeAll()
        customer.decisions.removeAll()
        customer.closedMessageIDs.formUnion(messageIDs)
        state.customers[uid] = customer
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("customer-transfer-policy.json"), options: .atomic)
    }

    func context(root: URL, uid: String, now: Date) throws -> String {
        let customer = try load(root: root).customers[uid] ?? Customer()
        func count(_ kind: CustomerRequestKind) -> Int {
            guard let window = customer.windows[kind.rawValue],
                  now >= window.firstAt, now.timeIntervalSince(window.firstAt) <= 600 else { return 0 }
            return window.count
        }
        return "本客户此前10分钟窗口内的已记录请求：human_request=\(count(.humanRequest))，refund_return=\(count(.refundReturn))。本轮请求尚未计入；重复执行同一批次不增加计数。计数与最终动作由应用持久化执行。"
    }

    func decide(root: URL, uid: String, messageIDs: [String], kind: CustomerRequestKind,
                answerFound: Bool, issueHasNoSolution: Bool,
                proposedAction: CodexReplyAction, proposedReason: CodexTransferReason,
                now: Date) throws -> CustomerTransferDecision {
        // Batch identity excludes model classification so a retry cannot count a message twice.
        let key = SHA256.hash(data: Data(messageIDs.sorted().joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        var state = try load(root: root)
        var customer = state.customers[uid] ?? Customer()
        if Set(messageIDs).isSubset(of: customer.closedMessageIDs) {
            return .init(count: 0, action: .reply, reason: .none)
        }
        if let recorded = customer.decisions[key] { return recorded }
        var count = 0
        if kind == .humanRequest || kind == .refundReturn {
            var window = customer.windows[kind.rawValue] ?? Window(firstAt: now, count: 0)
            if now < window.firstAt || now.timeIntervalSince(window.firstAt) > 600 {
                window = Window(firstAt: now, count: 0)
            }
            window.count += 1
            customer.windows[kind.rawValue] = window
            count = window.count
        }
        let decision: CustomerTransferDecision
        switch kind {
        case .humanRequest:
            decision = .init(count: count, action: count >= 2 ? .replyThenTransfer : .reply,
                             reason: count >= 2 ? .customerExplicitlyRequestedHuman : .none)
        case .refundReturn:
            let transfer = count >= 2 || issueHasNoSolution
            decision = .init(count: count, action: transfer ? .replyThenTransfer : .reply,
                             reason: transfer ? .explicitReturnRefund : .none)
        case .technical where issueHasNoSolution:
            decision = .init(count: 0, action: .replyThenTransfer, reason: .troubleshootingExhausted)
        default:
            // A historical request cannot create a new handoff in an unrelated batch.
            let staleRequest = proposedReason == .customerExplicitlyRequestedHuman
                || proposedReason == .explicitReturnRefund
            decision = .init(count: 0, action: staleRequest ? .reply : proposedAction,
                             reason: staleRequest ? .none : proposedReason)
        }
        customer.decisions[key] = decision
        state.customers[uid] = customer
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("customer-transfer-policy.json"), options: .atomic)
        return decision
    }
}
