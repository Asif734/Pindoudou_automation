import Darwin
import Foundation

protocol AutoReplyLocking: AnyObject {
    func acquire() throws -> Bool
    func release()
}

final class AutoReplySessionLock: AutoReplyLocking {
    private let lockURLs: [URL]
    private var descriptors: [Int32] = []

    init(
        lockURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/拼多多AX记录/自动回复/session.lock")
    ) {
        self.lockURLs = [lockURL]
    }

    init(lockURLs: [URL]) {
        self.lockURLs = lockURLs
    }

    func acquire() throws -> Bool {
        if !descriptors.isEmpty { return true }
        var acquired: [Int32] = []
        do {
            for lockURL in lockURLs {
                try FileManager.default.createDirectory(
                    at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
                guard fd >= 0 else { throw POSIXError(.EIO) }
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                    Darwin.close(fd)
                    for held in acquired { _ = flock(held, LOCK_UN); Darwin.close(held) }
                    return false
                }
                acquired.append(fd)
            }
        } catch {
            for held in acquired { _ = flock(held, LOCK_UN); Darwin.close(held) }
            throw error
        }
        descriptors = acquired
        return true
    }

    func release() {
        for descriptor in descriptors {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
        descriptors.removeAll()
    }

    deinit { release() }
}
