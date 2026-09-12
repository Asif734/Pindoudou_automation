import Darwin
import Foundation

struct PersistentV2Request: Codable, Sendable {
    let knowledgeBasePath: String
    let historyJSONL: String
    let cacheDirectory: String
    let seedCacheDirectory: String

    private enum CodingKeys: String, CodingKey {
        case knowledgeBasePath = "knowledge_base_path"
        case historyJSONL = "history_jsonl"
        case cacheDirectory = "cache_directory"
        case seedCacheDirectory = "seed_cache_directory"
    }
}

enum PersistentV2WorkerError: Error, LocalizedError {
    case timeout
    case processExited
    case protocolError(String)
    case workerError(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "V2 常驻工作进程超过 5 秒未响应，已重启"
        case .processExited: return "V2 常驻工作进程已退出"
        case .protocolError(let detail): return "V2 常驻协议错误：\(detail)"
        case .workerError(let detail): return "V2 检索失败：\(detail)"
        }
    }
}

actor PersistentV2Worker {
    private let pythonURL: URL
    private let scriptURL: URL
    private let environment: [String: String]
    private let hardTimeoutMilliseconds: Int32
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    init(
        pythonURL: URL,
        scriptURL: URL,
        environment: [String: String],
        hardTimeout: TimeInterval = 5
    ) {
        self.pythonURL = pythonURL
        self.scriptURL = scriptURL
        self.environment = environment
        hardTimeoutMilliseconds = Int32(max(1, hardTimeout * 1_000))
    }

    func retrieve(_ request: PersistentV2Request) async throws -> RetrievedKnowledge {
        try startIfNeeded()
        guard let process, process.isRunning, let input, let output else {
            throw PersistentV2WorkerError.processExited
        }
        let requestID = UUID()
        let envelope = RequestEnvelope(id: requestID, request: request)
        var bytes = try JSONEncoder().encode(envelope)
        bytes.append(0x0a)
        do {
            try input.write(contentsOf: bytes)
            let line = try await Task.detached(priority: .userInitiated) {
                try Self.readLine(
                    descriptor: output.fileDescriptor,
                    timeoutMilliseconds: self.hardTimeoutMilliseconds
                )
            }.value
            let response = try JSONDecoder().decode(ResponseEnvelope.self, from: line)
            guard response.id == requestID else {
                throw PersistentV2WorkerError.protocolError("响应 request ID 不匹配")
            }
            if let error = response.error { throw PersistentV2WorkerError.workerError(error) }
            guard let result = response.result else {
                throw PersistentV2WorkerError.protocolError("响应缺少 result")
            }
            return result
        } catch {
            stopWorker()
            throw error
        }
    }

    func shutdown() { stopWorker() }

    private func startIfNeeded() throws {
        if let process, process.isRunning { return }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = pythonURL
        process.arguments = [scriptURL.path, "--server"]
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
    }

    private func stopWorker() {
        try? input?.close()
        try? output?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        output = nil
    }

    private struct RequestEnvelope: Codable {
        let id: UUID
        let request: PersistentV2Request
    }

    private struct ResponseEnvelope: Codable {
        let id: UUID?
        let result: RetrievedKnowledge?
        let error: String?
    }

    private static func readLine(
        descriptor: Int32,
        timeoutMilliseconds: Int32
    ) throws -> Data {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMilliseconds) / 1_000)
        var data = Data()
        while Date() < deadline {
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            let status = poll(&item, 1, remaining)
            if status == 0 { break }
            if status < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor, &byte, 1)
            guard count == 1 else { throw PersistentV2WorkerError.processExited }
            if byte == 0x0a { return data }
            data.append(byte)
            if data.count > 2_000_000 {
                throw PersistentV2WorkerError.protocolError("单条响应超过 2 MB")
            }
        }
        throw PersistentV2WorkerError.timeout
    }
}
