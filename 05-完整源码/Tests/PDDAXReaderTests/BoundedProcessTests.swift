import Darwin
import XCTest
@testable import PDDAXReader

final class BoundedProcessTests: XCTestCase {
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
