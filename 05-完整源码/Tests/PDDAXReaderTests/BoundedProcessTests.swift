import Darwin
import XCTest
@testable import PDDAXReader

final class BoundedProcessTests: XCTestCase {
    func testDispatchWorkerSignalMaskDoesNotLeakIntoChild() async {
        let script = "$old=POSIX::SigSet->new; $empty=POSIX::SigSet->new; POSIX::sigprocmask(SIG_BLOCK,$empty,$old); print $old->ismember(SIGCHLD).\":\".$old->ismember(SIGTERM);"
        let result = await BoundedProcess.run(.init(executable: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-MPOSIX=:signal_h", "-e", script]),
            softDeadline: .seconds(1), hardDeadline: .seconds(3))
        XCTAssertEqual(result.termination, .exited(0))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "0:0",
            "Codex must receive both child-exit and termination signals")
    }

    func testChildCanTerminateItselfWithoutInheritedBlockedSIGTERM() async {
        let result = await BoundedProcess.run(.init(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "kill -TERM $$; printf signal-was-blocked"]),
            softDeadline: .seconds(1), hardDeadline: .seconds(3))
        XCTAssertEqual(result.termination, .exited(128 + SIGTERM))
        XCTAssertTrue(result.stdout.isEmpty)
    }
    func testEscapedChildHoldingStdinCannotHoldInputWriterAfterParentExits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pidFile = root.appendingPathComponent("child.pid")
        defer {
            if let text = try? String(contentsOf: pidFile), let pid = Int32(text) { _ = kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: root)
        }
        let script = """
        import os,sys,time
        r,w=os.pipe()
        child=os.fork()
        if child==0:
            os.setsid()
            os.close(1);os.close(2)
            os.write(w,b'1')
            time.sleep(5)
            os._exit(0)
        os.close(w)
        os.read(r,1)
        open(sys.argv[1],'w').write(str(child))
        os._exit(0)
        """
        let started = Date()
        let flag = InputDeliveryFlag()
        let result = await BoundedProcess.run(.init(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, pidFile.path], standardInput: Data(repeating: 65, count: 2_000_000),
            onStandardInputClosed: { flag.mark() }), softDeadline: .seconds(1), hardDeadline: .seconds(2))
        XCTAssertEqual(result.termination, .exited(0))
        XCTAssertFalse(flag.wasMarked)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testCancellationTerminatesProcessWithoutWaitingForHardDeadline() async throws {
        let task = Task {
            await BoundedProcess.run(.init(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]),
                softDeadline: .seconds(10), hardDeadline: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(30))
        let started = Date()
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result.processGroupStillAlive)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
    }
    func testPartialInputWriteDoesNotReportSuccessfulInputDelivery() async {
        let flag = InputDeliveryFlag()
        let result = await BoundedProcess.run(
            .init(executable: URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "1"],
                standardInput: Data(repeating: 65, count: 2_000_000),
                onStandardInputClosed: { flag.mark() }),
            softDeadline: .seconds(1), hardDeadline: .seconds(2)
        )
        XCTAssertEqual(result.termination, .exited(0))
        XCTAssertFalse(flag.wasMarked)
    }

    func testHardDeadlineTerminatesProcessGroup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-bounded-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let childPIDURL = root.appendingPathComponent("child.pid")
        let command = "sleep 30 & child=$!; printf '%s' \"$child\" > '\(childPIDURL.path)'; wait"

        let result = await BoundedProcess.run(
            .init(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command]),
            softDeadline: .milliseconds(20),
            hardDeadline: .milliseconds(100)
        )

        XCTAssertEqual(result.termination, .hardDeadline)
        XCTAssertTrue(result.softDeadlineExceeded)
        XCTAssertFalse(result.processGroupStillAlive)
        if let text = try? String(contentsOf: childPIDURL), let pid = Int32(text) {
            XCTAssertNotEqual(kill(pid, 0), 0)
        }
    }

    func testCapturesOutputAndExitStatus() async {
        let result = await BoundedProcess.run(
            .init(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf out; printf err >&2; exit 7"]
            ),
            softDeadline: .seconds(1),
            hardDeadline: .seconds(2)
        )

        XCTAssertEqual(result.termination, .exited(7))
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err")
        XCTAssertFalse(result.processGroupStillAlive)
    }
}

private final class InputDeliveryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var wasMarked: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func mark() { lock.lock(); value = true; lock.unlock() }
}
