import Foundation

/// Verified observations survive a chat switch or crash. This is capture evidence,
/// never an authorization to write to a customer or a Codex submission receipt.
struct PDDVerifiedCaptureInbox {
    struct Entry: Codable {
        let uid: String
        var locator: PDDConversationLocator
        var messages: [PDDChatMessage]
        var snapshot: PDDAXCaptureDiagnostic.Snapshot
        var unread: Bool
        var capturedAt: Date
        var acknowledged: Bool? = nil
    }
    let root: URL
    private var directory: URL { root.appendingPathComponent("capture-inbox", isDirectory: true) }
    private func url(_ uid: String) throws -> URL {
        guard PerUserAXStore.validUID(uid) else { throw PerUserAXStoreError.invalidUID }
        return directory.appendingPathComponent(uid + ".json")
    }
    func load(uid: String, includingAcknowledged: Bool = false) throws -> Entry? {
        let path = try url(uid)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: path))
        guard entry.uid == uid else { throw PerUserAXStoreError.invalidUID }
        return entry.acknowledged == true && !includingAcknowledged ? nil : entry
    }
    func entries(includingAcknowledged: Bool = false) throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { path -> Entry? in
                // A corrupt customer's inbox must not prevent scanning other customers.
                do { return try load(uid: path.deletingPathExtension().lastPathComponent, includingAcknowledged: includingAcknowledged) }
                catch {
                    AutomationStepLog.record(root: root, uid: nil, step: "capture-inbox-read-deferred", detail: "file=\(path.lastPathComponent) \(error.localizedDescription)")
                    return nil
                }
            }.sorted { $0.capturedAt < $1.capturedAt }
    }
    func stage(uid: String, locator: PDDConversationLocator, messages: [PDDChatMessage],
               snapshot: AXNodeSnapshot, unread: Bool, at date: Date) throws {
        let old = try load(uid: uid)
        let entry = Entry(uid: uid, locator: locator, messages: Self.merging(old?.messages ?? [], messages),
            snapshot: .init(snapshot), unread: unread || old?.unread == true, capturedAt: date)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: url(uid), options: .atomic)
    }
    func acknowledge(uid: String, capturedIDs: Set<String>) throws {
        guard var entry = try load(uid: uid), Set(entry.messages.map(\.id)).isSubset(of: capturedIDs) else { return }
        // Keep one bounded recovery copy per customer. It is hidden from discovery,
        // but can repair a crash between capture receipts and persisted job creation.
        entry.acknowledged = true
        try JSONEncoder().encode(entry).write(to: url(uid), options: .atomic)
    }
    static func merging(_ previous: [PDDChatMessage], _ observed: [PDDChatMessage]) -> [PDDChatMessage] {
        var result = previous
        var index = Dictionary(uniqueKeysWithValues: previous.enumerated().map { ($0.element.id, $0.offset) })
        for message in observed {
            if let slot = index[message.id] { result[slot] = message }
            else { index[message.id] = result.count; result.append(message) }
        }
        return result
    }
}
