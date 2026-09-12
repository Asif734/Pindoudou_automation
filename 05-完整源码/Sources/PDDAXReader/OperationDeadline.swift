import Foundation

struct OperationTimeout: Error, Equatable, LocalizedError, Sendable {
    let stage: String

    var errorDescription: String? {
        "操作超时：\(stage)"
    }
}

private final class OperationDeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []
    private var resolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func register(_ task: Task<Void, Never>) {
        lock.lock()
        if resolved {
            lock.unlock()
            task.cancel()
        } else {
            tasks.append(task)
            lock.unlock()
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        let tasks = self.tasks
        self.tasks.removeAll()
        lock.unlock()

        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

func withOperationDeadline<Value: Sendable>(
    _ duration: Duration,
    stage: String,
    shouldDeferTimeout: @escaping @Sendable () -> Bool = { false },
    operation: @escaping @MainActor @Sendable () async throws -> Value
) async throws -> Value {
    let race = OperationDeadlineRace<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)

            let operationTask = Task {
                do {
                    race.resolve(.success(try await operation()))
                } catch {
                    race.resolve(.failure(error))
                }
            }
            race.register(operationTask)

            let deadlineTask = Task {
                while true {
                    do {
                        try await Task.sleep(for: duration)
                        if shouldDeferTimeout() { continue }
                        race.resolve(.failure(OperationTimeout(stage: stage)))
                        return
                    } catch {
                        return
                    }
                }
            }
            race.register(deadlineTask)
        }
    } onCancel: {
        race.resolve(.failure(CancellationError()))
    }
}
