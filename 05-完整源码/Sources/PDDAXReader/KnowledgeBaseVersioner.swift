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
