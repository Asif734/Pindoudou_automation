import Foundation

/// Connects cancellation of a generation to its detached CLI task, including
/// cancellation that arrives before the continuation/task is installed.
final class CodexTurnCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: Task<Void, Never>?
    private var finish: (@Sendable () -> Void)?

    func install(_ task: Task<Void, Never>, finish: @escaping @Sendable () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
            finish()
        } else {
            self.task = task
            self.finish = finish
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        let finish = self.finish
        self.task = nil
        self.finish = nil
        lock.unlock()
        task?.cancel()
        finish?()
    }
}
