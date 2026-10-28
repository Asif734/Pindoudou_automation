import CryptoKit
import Foundation

actor KnowledgeBaseVersioner {
    private struct CacheEntry {
        let size: UInt64
        let modificationDate: Date
        let digest: String
    }

    private var cache: [String: CacheEntry] = [:]

    func version(url: URL) throws -> String {
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
            // Hash every retrieval input, so in-place edits invalidate sessions.
            let paths = ["rag_cards/customer_service_rag_cards.jsonl", "rag_cards/source_chunks.jsonl",
                         "rag_cards/high_frequency_queries.json"]
            var hasher = SHA256()
            for path in paths {
                hasher.update(data: Data(path.utf8))
                hasher.update(data: try Data(contentsOf: url.appendingPathComponent(path)))
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let date = (attributes[.modificationDate] as? Date) ?? .distantPast
        if let cached = cache[url.path], cached.size == size, cached.modificationDate == date {
            return cached.digest
        }
        let digest = SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
        cache[url.path] = CacheEntry(size: size, modificationDate: date, digest: digest)
        return digest
    }
}
