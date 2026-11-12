import CryptoKit
import Foundation

/// Only exact platform evidence establishes ownership. Labels are never aliases.
struct PDDConversationIdentityStore {
    struct Entry: Codable, Equatable {
        var messageIDs: Set<String> = []
        var stableIDs: Set<String> = []
        var incomingBoundaries: Set<String> = []
        var provisional: Bool?
        var createdAt: Date?
    }
    private struct State: Codable {
        var owners: [String: Entry] = [:]
        var aliases: [String: String] = [:]
        var repairProofs: [String: Set<String>] = [:]
        init() {}
        enum CodingKeys: String, CodingKey { case owners, aliases, repairProofs }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            owners = try values.decodeIfPresent([String: Entry].self, forKey: .owners) ?? [:]
            aliases = try values.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
            repairProofs = try values.decodeIfPresent([String: Set<String>].self, forKey: .repairProofs) ?? [:]
        }
    }
    struct Repair {
        let canonicalUID: String
        let aliases: Set<String>
    }
    enum IdentityError: LocalizedError {
        case conflictingEvidence
        var errorDescription: String? { "会话身份依据互相冲突，保留待处理并继续其他客户" }
    }
    let root: URL
    private var url: URL { root.appendingPathComponent("conversation-identities.json") }
    private func load() throws -> State {
        guard FileManager.default.fileExists(atPath: url.path) else { return State() }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
    }
    private func matches(_ state: State, messageIDs: Set<String>, stableID: String?, boundary: String?) -> [String] {
        state.owners.filter { _, entry in
            !entry.messageIDs.isDisjoint(with: messageIDs)
                || stableID.map { entry.stableIDs.contains($0) } == true
                || boundary.map { entry.incomingBoundaries.contains($0) } == true
        }.map(\.key)
    }
    private func canonical(_ uid: String, in state: State) throws -> String {
        var current = uid; var visited = Set<String>()
        while let next = state.aliases[current] {
            guard visited.insert(current).inserted, PerUserAXStore.validUID(next) else { throw IdentityError.conflictingEvidence }
            current = next
        }
        return current
    }
    func canonicalUID(_ uid: String) throws -> String { try canonical(uid, in: load()) }
    func aliases() throws -> [String: String] { try load().aliases }
    func repairProof(uid: String) throws -> Set<String> { try load().repairProofs[uid] ?? [] }
    func evidenceOwners(messageIDs: Set<String>, stableID: String?, boundary: String?) throws -> Set<String> {
        let state = try load()
        return try Set(matches(state, messageIDs: messageIDs, stableID: stableID, boundary: boundary)
            .map { try canonical($0, in: state) })
    }
    func owner(messageIDs: Set<String> = [], stableID: String? = nil, boundary: String? = nil) throws -> String? {
        let state = try load()
        let owners = try Set(matches(state, messageIDs: messageIDs, stableID: stableID, boundary: boundary).map { try canonical($0, in: state) })
        guard owners.count <= 1 else { throw IdentityError.conflictingEvidence }
        return owners.first
    }
    func anchors(uid: String) throws -> Set<String> {
        let state = try load(); return state.owners[try canonical(uid, in: state)]?.messageIDs ?? []
    }
    func remember(uid: String, messageIDs: Set<String>, stableID: String?, boundary: String?, provisional: Bool = false, at date: Date = Date()) throws {
        guard !messageIDs.isEmpty || stableID != nil || boundary != nil else { return }
        guard PerUserAXStore.validUID(uid), !Self.isSharedVisitorUID(uid) else { throw IdentityError.conflictingEvidence }
        let uid = try canonicalUID(uid)
        if let existing = try owner(messageIDs: messageIDs, stableID: stableID, boundary: boundary), existing != uid {
            throw IdentityError.conflictingEvidence
        }
        var state = try load(); let old = state.owners[uid]
        var entry = old ?? Entry(); entry.messageIDs.formUnion(messageIDs)
        if old == nil { entry.provisional = provisional; entry.createdAt = date }
        if stableID != nil || boundary != nil { entry.provisional = false }
        if let stableID { entry.stableIDs.insert(stableID) }
        if let boundary { entry.incomingBoundaries.insert(boundary) }
        guard entry != old else { return }
        state.owners[uid] = entry
        try save(state)
    }

    /// Caller must independently verify one active chat surface. Every owner
    /// must contribute actual customer IDs in that same tree, not just a label
    /// or an old transfer notice. Only provisional CHAT records can be absorbed.
    func reconcileVerifiedThread(messageIDs: Set<String>, stableID: String?, boundary: String?) throws -> Repair? {
        var state = try load()
        let owners = matches(state, messageIDs: messageIDs, stableID: stableID, boundary: boundary)
        guard owners.count > 1 else { return nil }
        let entries = owners.compactMap { state.owners[$0] }
        guard entries.allSatisfy({ !$0.messageIDs.isDisjoint(with: messageIDs) }) else { throw IdentityError.conflictingEvidence }
        let stableIDs = entries.reduce(into: Set<String>()) { $0.formUnion($1.stableIDs) }
        guard stableIDs.count <= 1,
              stableID.map({ stableIDs.isEmpty || stableIDs == [$0] }) ?? true else { throw IdentityError.conflictingEvidence }
        func provisional(_ uid: String) -> Bool {
            guard uid.hasPrefix("PDD-CHAT-"), let entry = state.owners[uid],
                  entry.stableIDs.isEmpty, entry.incomingBoundaries.isEmpty else { return false }
            return entry.provisional == true || (entry.provisional == nil && entry.messageIDs.count == 1)
        }
        let established = owners.filter { !provisional($0) }
        guard established.count <= 1 else { throw IdentityError.conflictingEvidence }
        let canonicalUID = established.first ?? owners.sorted {
            if let left = state.owners[$0]?.createdAt, let right = state.owners[$1]?.createdAt, left != right { return left < right }
            let left = state.owners[$0]?.messageIDs.count ?? 0
            let right = state.owners[$1]?.messageIDs.count ?? 0
            return left == right ? $0 < $1 : left > right
        }[0]
        let aliases = Set(owners).subtracting([canonicalUID])
        guard aliases.allSatisfy({ provisional($0) && state.owners[$0]!.messageIDs.isSubset(of: messageIDs) }) else {
            throw IdentityError.conflictingEvidence
        }
        var combined = state.owners[canonicalUID]!
        for uid in aliases {
            let entry = state.owners.removeValue(forKey: uid)!
            combined.messageIDs.formUnion(entry.messageIDs)
            combined.stableIDs.formUnion(entry.stableIDs)
            combined.incomingBoundaries.formUnion(entry.incomingBoundaries)
            state.aliases[uid] = canonicalUID
        }
        for (uid, target) in state.aliases where aliases.contains(target) { state.aliases[uid] = canonicalUID }
        combined.provisional = false
        state.owners[canonicalUID] = combined
        state.repairProofs[canonicalUID] = messageIDs
        try save(state)
        AutomationStepLog.record(root: root, uid: canonicalUID, step: "conversation-identity-alias-reconciled",
            detail: "aliases=\(aliases.sorted().joined(separator: ",")) proof_message_ids=\(messageIDs.sorted().joined(separator: ",")); same active thread; no nickname merge")
        return .init(canonicalUID: canonicalUID, aliases: aliases)
    }
    private func save(_ state: State) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
    static func generic(_ name: String) -> Bool {
        ["", "游客", "访客", "visitor", "guest"].contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    static func isSharedVisitorUID(_ uid: String) -> Bool {
        ["游客", "访客", "visitor", "guest"].contains { PDDConversationKey.make(locator: .init(nickname: $0)) == uid }
    }
    static func anchoredUID(messageIDs: Set<String>, boundary: String? = nil) -> String {
        let material = boundary.map { "handoff:\($0)" } ?? "message:\(messageIDs.sorted().first ?? "")"
        return "PDD-CHAT-" + SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)
    }
}
