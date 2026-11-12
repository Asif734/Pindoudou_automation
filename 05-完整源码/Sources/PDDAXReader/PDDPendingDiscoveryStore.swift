import Foundation

/// UI locators are retry hints, never proof of customer identity.
struct PDDPendingDiscovery: Codable, Equatable, Identifiable {
    let id: UUID
    var locator: PDDConversationLocator
    let occurrence: Int
    let firstSeenAt: Date
    var nextAttemptAt: Date
    var attempts: Int
    var requiresUnreadCapture: Bool
    var resolvedUID: String?
    var observedCustomerIDs: Set<String>
    var lastSelectionAt: Date?
    var lastRefreshAt: Date?
    var signalKey: String? = nil
    var signalSignature: String? = nil
    var transferOnly: Bool? = nil
    var previewTexts: [String]? = nil

    init(locator: PDDConversationLocator, occurrence: Int, unread: Bool, at date: Date) {
        id = UUID(); self.locator = locator; self.occurrence = occurrence
        firstSeenAt = date; nextAttemptAt = date; attempts = 0
        requiresUnreadCapture = unread; observedCustomerIDs = []
    }
}

/// A list signal authorizes inspection, never customer identity or a reply.
/// Keep its disposition across restarts so an unchanged notice cannot reopen a chat.
struct PDDDiscoverySignalStore {
    struct Observation: Codable, Equatable {
        var signature: String
        var active: Bool
        var handled: Bool
        var handledAt: Date? = nil
    }
    let root: URL
    private var url: URL { root.appendingPathComponent("discovery-signals.json") }
    func load() throws -> [String: Observation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: Observation].self, from: Data(contentsOf: url))
    }
    func save(_ state: [String: Observation]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }
    func finish(_ task: PDDPendingDiscovery, at date: Date = Date()) throws {
        guard let key = task.signalKey, let signature = task.signalSignature else { return }
        var state = try load()
        // Do not consume a newer signal that arrived during capture.
        guard state[key]?.signature == signature else { return }
        state[key]?.handled = true
        state[key]?.handledAt = date
        try save(state)
    }
}

struct PDDPendingDiscoveryStore {
    let root: URL
    private var url: URL { root.appendingPathComponent("pending-discovery.json") }

    func load() throws -> [PDDPendingDiscovery] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([PDDPendingDiscovery].self, from: Data(contentsOf: url))
    }

    func save(_ tasks: [PDDPendingDiscovery]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(tasks).write(to: url, options: .atomic)
    }

    @discardableResult
    static func retain(locator: PDDConversationLocator, occurrence: Int, unread: Bool,
                       at date: Date, in tasks: inout [PDDPendingDiscovery]) -> UUID {
        if let index = tasks.firstIndex(where: { task in
            if let id = locator.normalizedIdentifier, let old = task.locator.normalizedIdentifier {
                return id == old
            }
            return task.locator.normalizedNickname == locator.normalizedNickname && task.occurrence == occurrence
        }) {
            tasks[index].requiresUnreadCapture = tasks[index].requiresUnreadCapture || unread
            return tasks[index].id
        }
        let task = PDDPendingDiscovery(locator: locator, occurrence: occurrence, unread: unread, at: date)
        tasks.append(task)
        return task.id
    }
}
