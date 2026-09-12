import Foundation

actor PDDVideoTransferRegistry {
    private var tasks: [PDDVideoTransferKey: Task<Void, Never>] = [:]
    private var latestLifecycleRevision = 0
    private var enabled = true
    private var claimedSourceHashes: [String: PDDVideoTransferKey] = [:]

    var count: Int { tasks.count }

    func contains(_ key: PDDVideoTransferKey) -> Bool {
        tasks.keys.contains { $0.messageHash == key.messageHash }
    }

    @discardableResult
    func start(
        key: PDDVideoTransferKey,
        operation: @escaping @Sendable () async -> Void
    ) -> Bool {
        guard enabled, !tasks.keys.contains(where: { $0.messageHash == key.messageHash }) else {
            return false
        }
        let task = Task(priority: .utility) { [weak self] in
            await operation()
            await self?.finish(key)
        }
        tasks[key] = task
        return true
    }

    func finish(_ key: PDDVideoTransferKey) {
        tasks[key] = nil
    }

    func cancelAll() {
        let active = Array(tasks.values)
        tasks.removeAll()
        active.forEach { $0.cancel() }
    }

    @discardableResult
    func setDesired(revision: Int, enabled: Bool) -> Bool {
        guard revision >= latestLifecycleRevision else { return false }
        latestLifecycleRevision = revision
        self.enabled = enabled
        if !enabled { cancelAll() }
        return true
    }

    func claimSource(_ url: URL, for key: PDDVideoTransferKey) -> Bool {
        let hash = PDDVideoTransferKey(uid: "source", messageID: url.absoluteString).messageHash
        if let owner = claimedSourceHashes[hash] { return owner == key }
        claimedSourceHashes[hash] = key
        return true
    }

    func isEnabled(for revision: Int) -> Bool {
        enabled && revision == latestLifecycleRevision
    }
}
