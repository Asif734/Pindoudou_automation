import Foundation
import XCTest
@testable import PDDAXReader

final class OperationDeadlineTests: XCTestCase {
    func testDeadlineDoesNotFireWhileOperationReportsApprovedSuspension() async throws {
        let result: String = try await withOperationDeadline(
            .milliseconds(20),
            stage: "capture",
            shouldDeferTimeout: { true }
        ) {
            try await Task.sleep(for: .milliseconds(60))
            return "finished"
        }

        XCTAssertEqual(result, "finished")
    }

    func testDeadlineReturnsWithoutWaitingForOperationThatIgnoresCancellation() async {
        let started = Date()

        do {
            let _: String = try await withOperationDeadline(
                .milliseconds(30), stage: "capture"
            ) {
                await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
                return "unreachable"
            }
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? OperationTimeout, OperationTimeout(stage: "capture"))
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3)
    }

    func testParentCancellationReturnsCancellationErrorPromptly() async {
        let task = Task<String, Error> {
            try await withOperationDeadline(.seconds(10), stage: "send") {
                await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
                return "unreachable"
            }
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
