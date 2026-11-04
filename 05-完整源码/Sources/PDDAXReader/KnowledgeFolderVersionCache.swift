import CryptoKit
import Darwin
import Foundation

/// Caches only a version digest and filesystem metadata, never document/media
/// contents. Every call checks the complete file inventory before reusing it.
actor KnowledgeFolderVersionCache {
    static let shared = KnowledgeFolderVersionCache()

    struct Version: Sendable {
        let digest: String
        let cacheHit: Bool
        let hashedByteCount: Int64
    }

    private struct Fingerprint: Equatable {
        let path: String
        let size: Int64
        let device: Int32
        let inode: UInt64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    private struct Entry {
        let fingerprints: [Fingerprint]
        let digest: String
    }

    private var entries: [String: Entry] = [:]

    func version(folder: URL) throws -> Version {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let files = try inventory(folder)
            if let cached = entries[folder.path], cached.fingerprints == files {
                return Version(digest: cached.digest, cacheHit: true, hashedByteCount: 0)
            }
            var hash = SHA256()
            var bytes: Int64 = 0
            hash.update(data: Data(folder.path.utf8))
            for file in files {
                try Task.checkCancellation()
                hash.update(data: Data(file.path.utf8))
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file.path))
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    try Task.checkCancellation()
                    hash.update(data: chunk)
                    bytes += Int64(chunk.count)
                }
            }
            // Never cache a digest computed while files were being replaced.
            guard try inventory(folder) == files else {
                if attempt == 0 { continue }
                throw CocoaError(.fileReadUnknown)
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            entries[folder.path] = Entry(fingerprints: files, digest: digest)
            return Version(digest: digest, cacheHit: false, hashedByteCount: bytes)
        }
        throw CocoaError(.fileReadUnknown)
    }

    private func inventory(_ folder: URL) throws -> [Fingerprint] {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var files: [Fingerprint] = []
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            var metadata = stat()
            guard file.path.withCString({ Darwin.fstatat(AT_FDCWD, $0, &metadata, 0) }) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            files.append(Fingerprint(path: file.path, size: metadata.st_size,
                device: metadata.st_dev, inode: metadata.st_ino,
                modifiedSeconds: metadata.st_mtimespec.tv_sec, modifiedNanoseconds: metadata.st_mtimespec.tv_nsec,
                changedSeconds: metadata.st_ctimespec.tv_sec, changedNanoseconds: metadata.st_ctimespec.tv_nsec))
        }
        if let enumerationError { throw enumerationError }
        return files.sorted { $0.path < $1.path }
    }
}
