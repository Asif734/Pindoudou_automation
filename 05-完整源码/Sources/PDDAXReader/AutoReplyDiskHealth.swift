import Foundation

enum AutoReplyDiskHealthError: Error, Equatable {
    case insufficientSpace
}

protocol AutoReplyDiskHealthChecking: Sendable {
    func check() throws
}

struct AutoReplyDiskHealthChecker: AutoReplyDiskHealthChecking, Sendable {
    let rootDirectory: URL
    let minimumFreeBytes: Int64
    let availableCapacity: @Sendable () throws -> Int64

    init(
        rootDirectory: URL,
        minimumFreeBytes: Int64 = 512 * 1024 * 1024,
        availableCapacity: (@Sendable () throws -> Int64)? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.minimumFreeBytes = minimumFreeBytes
        self.availableCapacity = availableCapacity ?? {
            let values = try rootDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage ?? 0
        }
    }

    func check() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        guard try availableCapacity() >= minimumFreeBytes else {
            throw AutoReplyDiskHealthError.insufficientSpace
        }
        let source = rootDirectory.appendingPathComponent(".disk-health-\(UUID().uuidString)")
        let destination = rootDirectory.appendingPathComponent(".disk-health-\(UUID().uuidString)-moved")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.write(contentsOf: Data("pdd-auto-reply-disk-health".utf8))
        try handle.synchronize()
        try handle.close()
        try FileManager.default.moveItem(at: source, to: destination)
    }
}
