import CryptoKit
import Foundation

/// Commit intent is durable BEFORE AXPress. A crash at that boundary is
/// ambiguous, so recovery observes the chat and never blindly presses again.
struct PDDTextDeliveryAttempt: Codable, Equatable {
    enum Stage: String, Codable { case prepared, composerVerified, commitIntent, confirmed }
    let uid: String
    let replySHA256: String
    var stage: Stage
    var baselineServiceIDs: Set<String> = []
    var confirmedMessageID: String? = nil
    var updatedAt: Date
    var mayHaveSent: Bool { stage == .commitIntent || stage == .confirmed }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct PDDTextDeliveryAttemptStore {
    let root: URL
    private func url(_ id: UUID) -> URL {
        root.appendingPathComponent("text-delivery-attempts").appendingPathComponent(id.uuidString + ".json")
    }
    func load(_ id: UUID) throws -> PDDTextDeliveryAttempt? {
        guard FileManager.default.fileExists(atPath: url(id).path) else { return nil }
        return try JSONDecoder().decode(PDDTextDeliveryAttempt.self, from: Data(contentsOf: url(id)))
    }
    func save(_ attempt: PDDTextDeliveryAttempt, id: UUID) throws {
        let path = url(id)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(attempt).write(to: path, options: .atomic)
    }
}
