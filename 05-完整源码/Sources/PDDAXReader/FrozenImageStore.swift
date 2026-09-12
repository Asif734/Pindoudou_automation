import CryptoKit
import Foundation

enum FrozenImageStoreError: Error, Equatable, LocalizedError {
    case sourceMissing
    case digestMismatch
    case unsupportedMIME
    case destinationConflict

    var errorDescription: String? {
        switch self {
        case .sourceMissing: return "待冻结图片不存在"
        case .digestMismatch: return "图片内容与声明 SHA-256 不一致"
        case .unsupportedMIME: return "图片 MIME 类型不受支持"
        case .destinationConflict: return "冻结图片目标存在不同内容"
        }
    }
}

final class FrozenImageStore: @unchecked Sendable {
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    func freeze(_ attachment: AutoReplyImageAttachment) throws -> AutoReplyImageAttachment {
        try locked {
            guard attachment.localURL.isFileURL,
                  fileManager.fileExists(atPath: attachment.localURL.path) else {
                throw FrozenImageStoreError.sourceMissing
            }
            let data = try Data(contentsOf: attachment.localURL, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == attachment.sha256 else { throw FrozenImageStoreError.digestMismatch }
            let ext: String
            switch attachment.mimeType.lowercased() {
            case "image/jpeg", "image/jpg": ext = "jpg"
            case "image/png": ext = "png"
            default: throw FrozenImageStoreError.unsupportedMIME
            }
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            let destination = rootDirectory.appendingPathComponent("\(digest).\(ext)")
            if fileManager.fileExists(atPath: destination.path) {
                guard try Data(contentsOf: destination) == data else {
                    throw FrozenImageStoreError.destinationConflict
                }
            } else {
                let temporary = rootDirectory.appendingPathComponent(".freeze-\(UUID().uuidString).tmp")
                defer { try? fileManager.removeItem(at: temporary) }
                try data.write(to: temporary)
                let handle = try FileHandle(forWritingTo: temporary)
                try handle.synchronize()
                try handle.close()
                try fileManager.moveItem(at: temporary, to: destination)
            }
            return AutoReplyImageAttachment(
                messageID: attachment.messageID,
                sourceURL: attachment.sourceURL,
                localURL: destination,
                mimeType: attachment.mimeType,
                byteCount: data.count,
                sha256: digest
            )
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
