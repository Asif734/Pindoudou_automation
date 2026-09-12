import Foundation

enum PersistentWorkerError: LocalizedError {
    case closed
    case invalidLine(String)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .closed: return "V2 常驻 worker 已退出"
        case .invalidLine(let value): return "V2 常驻 worker 返回无效：\(value)"
        case .timeout(let operation): return "V2 常驻 worker \(operation)超时"
        }
    }
}

private final class WorkerTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func mark() { lock.lock(); value = true; lock.unlock() }
    func read() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

final class PersistentJSONLWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pdd.v2-persistent-worker")
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let startupDeadline: Duration
    private let queryDeadline: Duration
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        startupDeadline: Duration,
        queryDeadline: Duration
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.startupDeadline = startupDeadline
        self.queryDeadline = queryDeadline
    }

    func start() async throws -> Data {
        try await perform {
            if self.process == nil {
                let process = Process()
                let stdin = Pipe()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = self.executable
                process.arguments = self.arguments
                process.environment = self.environment
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = stderr
                try process.run()
                self.process = process
                self.input = stdin.fileHandleForWriting
                self.output = stdout.fileHandleForReading
                self.errorOutput = stderr.fileHandleForReading
                self.errorOutput?.readabilityHandler = { handle in _ = handle.availableData }
            }
            guard let process = self.process else { throw PersistentWorkerError.closed }
            return try self.readLine(process: process, deadline: self.startupDeadline, operation: "启动")
        }
    }

    func request(_ data: Data) async throws -> Data {
        try await perform {
            guard let process = self.process, process.isRunning, let input = self.input else {
                throw PersistentWorkerError.closed
            }
            try input.write(contentsOf: data + Data([0x0A]))
            return try self.readLine(process: process, deadline: self.queryDeadline, operation: "查询")
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                try? self.input?.close()
                if let process = self.process, process.isRunning { process.terminate() }
                self.errorOutput?.readabilityHandler = nil
                try? self.output?.close()
                try? self.errorOutput?.close()
                self.process = nil
                self.input = nil
                self.output = nil
                self.errorOutput = nil
                continuation.resume()
            }
        }
    }

    private func readLine(process: Process, deadline: Duration, operation: String) throws -> Data {
        guard let output else { throw PersistentWorkerError.closed }
        let timeout = WorkerTimeoutFlag()
        let timeoutWork = DispatchWorkItem {
            timeout.mark()
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.seconds(deadline),
            execute: timeoutWork
        )
        defer { timeoutWork.cancel() }
        var data = Data()
        while true {
            let byte = output.readData(ofLength: 1)
            guard !byte.isEmpty else {
                if timeout.read() { throw PersistentWorkerError.timeout(operation) }
                throw PersistentWorkerError.closed
            }
            if byte[0] == 0x0A { return data }
            data.append(byte)
            if data.count > 2_000_000 {
                throw PersistentWorkerError.invalidLine("单行超过 2 MB")
            }
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return max(
            0,
            TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
        )
    }

    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
