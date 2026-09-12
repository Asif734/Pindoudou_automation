import Foundation

private struct AutoReplyRunIntentDocument: Codable {
    let desiredRunning: Bool
}

protocol AutoReplyRunIntentStoring: Sendable {
    func load() throws -> Bool
    func save(desiredRunning: Bool) throws
}

struct AutoReplyRunIntentStore: AutoReplyRunIntentStoring, Sendable {
    let rootDirectory: URL

    func load() throws -> Bool {
        let url = rootDirectory.appendingPathComponent("run-intent.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return try JSONDecoder().decode(
            AutoReplyRunIntentDocument.self, from: Data(contentsOf: url)
        ).desiredRunning
    }

    func save(desiredRunning: Bool) throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(AutoReplyRunIntentDocument(desiredRunning: desiredRunning)).write(
            to: rootDirectory.appendingPathComponent("run-intent.json"), options: .atomic
        )
    }
}

struct VolatileAutoReplyRunIntentStore: AutoReplyRunIntentStoring {
    func load() throws -> Bool { false }
    func save(desiredRunning: Bool) throws {}
}
