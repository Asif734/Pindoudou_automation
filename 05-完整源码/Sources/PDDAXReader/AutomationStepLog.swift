import Foundation

/// Append-only diagnostic evidence, independent of the bounded UI event list.
enum AutomationStepLog {
    private static let lock = NSLock()

    static func record(root: URL?, uid: String?, step: String, detail: String = "") {
        guard let root else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            let directory = root.appendingPathComponent("logs", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("automation-steps.jsonl")
            let event = AutoReplyEvent(id: UUID(), timestamp: Date(), uid: uid, kind: step, detail: detail)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(event)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            NSLog("Automation step log failed (%@): %@", step, error.localizedDescription)
        }
    }
}
