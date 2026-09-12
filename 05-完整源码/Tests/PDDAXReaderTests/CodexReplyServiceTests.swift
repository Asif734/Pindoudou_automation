import XCTest
@testable import PDDAXReader

final class CodexReplyServiceTests: XCTestCase {
    func testCreatesSessionThenResumesExactThreadID() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeCodexRunner(responses: [
            .success(reply: "第一条建议", stdout: events(threadID: "thread-new-1")),
            .success(reply: "第二条建议", stdout: completedEvent)
        ])
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let service = CodexReplyService(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner,
            sessionRegistry: CodexSessionRegistry(rootDirectory: root),
            now: { now }
        )

        let first = try await service.generate(uid: "GZC-000001", history: [message("1")])
        let second = try await service.generate(uid: "GZC-000001", history: [message("1"), message("2")])
        let invocations = await runner.invocations

        XCTAssertEqual(first, CodexReplyResult(reply: "第一条建议", threadID: "thread-new-1"))
        XCTAssertEqual(second, CodexReplyResult(reply: "第二条建议", threadID: "thread-new-1"))
        XCTAssertEqual(invocations.count, 2)
        XCTAssertFalse(invocations[0].arguments.contains("resume"))
        XCTAssertTrue(invocations[1].arguments.contains("resume"))
        XCTAssertTrue(invocations[1].arguments.contains("thread-new-1"))
        XCTAssertFalse(invocations[1].arguments.contains("--last"))
        XCTAssertTrue(invocations[0].stdin.contains("客户：消息 1"))
        XCTAssertTrue(invocations[1].stdin.contains("客户：消息 2"))
    }

    func testFailedResumeInvalidatesOnlyThatUIDAndRecreatesOnce() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let registry = CodexSessionRegistry(rootDirectory: root)
        try registry.save(CodexSessionBinding(uid: "GZC-000001", threadID: "stale", lastUsedAt: now))
        try registry.save(CodexSessionBinding(uid: "GZC-000002", threadID: "keep", lastUsedAt: now))
        let runner = FakeCodexRunner(responses: [
            .failure(code: 1, stderr: "resume failed"),
            .success(reply: "恢复建议", stdout: events(threadID: "fresh"))
        ])
        let service = CodexReplyService(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            runner: runner,
            sessionRegistry: registry,
            now: { now }
        )

        let result = try await service.generate(uid: "GZC-000001", history: [message("1")])
        let invocations = await runner.invocations

        XCTAssertEqual(result.threadID, "fresh")
        XCTAssertEqual(invocations.count, 2)
        XCTAssertTrue(invocations[0].arguments.contains("stale"))
        XCTAssertFalse(invocations[1].arguments.contains("resume"))
        XCTAssertEqual(try registry.activeBinding(uid: "GZC-000002", now: now)?.threadID, "keep")
    }

    func testRejectsMissingCompletionAndEmptyReply() async throws {
        for response in [
            FakeCodexResponse.success(reply: "表面正常", stdout: "{\"type\":\"thread.started\",\"thread_id\":\"x\"}\n"),
            FakeCodexResponse.success(reply: "   ", stdout: events(threadID: "x"))
        ] {
            let root = temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let service = CodexReplyService(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                runner: FakeCodexRunner(responses: [response]),
                sessionRegistry: CodexSessionRegistry(rootDirectory: root)
            )
            do {
                _ = try await service.generate(uid: "GZC-000001", history: [message("1")])
                XCTFail("无效结构必须失败")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
    }

    func testProcessRunnerDrainsOutputAndPassesStdin() async throws {
        let script = "read line; printf '%s' \"$line\"; printf 'err' >&2"
        let result = try await CodexProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            stdin: "hello-from-stdin\n",
            timeout: 5
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello-from-stdin")
        XCTAssertEqual(result.stderr, "err")
    }

    func testProcessRunnerStreamsStdoutBeforeProcessExit() async throws {
        let started = Date()
        let callbackTime = ThreadSafeDateBox()
        let result = try await CodexProcessRunner().runStreaming(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf first; sleep 0.3; printf second"],
            stdin: "",
            timeout: 5,
            onStandardOutput: { _ in callbackTime.setIfNil(Date()) },
            onStandardInputClosed: {}
        )

        let firstChunkDelay = try XCTUnwrap(callbackTime.value).timeIntervalSince(started)
        let total = Date().timeIntervalSince(started)
        XCTAssertLessThan(firstChunkDelay, 0.2)
        XCTAssertGreaterThan(total, 0.25)
        XCTAssertEqual(result.stdout, "firstsecond")
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-codex-service-\(UUID().uuidString)")
    }

    private func message(_ id: String) -> PDDChatMessage {
        PDDChatMessage(
            id: id,
            sender: .customer,
            content: "消息 \(id)",
            displayTime: nil,
            kind: .text,
            capturedAt: Date(timeIntervalSince1970: 1_777_000_000)
        )
    }

    private var completedEvent: String { "{\"type\":\"turn.completed\"}\n" }

    private func events(threadID: String) -> String {
        "{\"type\":\"thread.started\",\"thread_id\":\"\(threadID)\"}\n" + completedEvent
    }
}

private final class ThreadSafeDateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date?
    func setIfNil(_ date: Date) { lock.lock(); if stored == nil { stored = date }; lock.unlock() }
    var value: Date? { lock.lock(); defer { lock.unlock() }; return stored }
}

private struct FakeCodexResponse: Sendable {
    let result: CodexProcessResult
    let replyJSON: String?

    static func success(reply: String, stdout: String) -> Self {
        Self(
            result: CodexProcessResult(exitCode: 0, stdout: stdout, stderr: ""),
            replyJSON: "{\"reply\":\"\(reply)\"}"
        )
    }

    static func failure(code: Int32, stderr: String) -> Self {
        Self(result: CodexProcessResult(exitCode: code, stdout: "", stderr: stderr), replyJSON: nil)
    }
}

private struct FakeCodexInvocation: Sendable {
    let arguments: [String]
    let stdin: String
}

private actor FakeCodexRunner: CodexProcessRunning {
    private var responses: [FakeCodexResponse]
    private(set) var invocations: [FakeCodexInvocation] = []

    init(responses: [FakeCodexResponse]) {
        self.responses = responses
    }

    func run(
        executable: URL,
        arguments: [String],
        stdin: String,
        timeout: TimeInterval
    ) async throws -> CodexProcessResult {
        invocations.append(FakeCodexInvocation(arguments: arguments, stdin: stdin))
        guard !responses.isEmpty else { throw CocoaError(.fileReadUnknown) }
        let response = responses.removeFirst()
        if let json = response.replyJSON,
           let outputIndex = arguments.firstIndex(of: "-o"),
           arguments.indices.contains(outputIndex + 1) {
            try Data(json.utf8).write(to: URL(fileURLWithPath: arguments[outputIndex + 1]))
        }
        return response.result
    }
}
