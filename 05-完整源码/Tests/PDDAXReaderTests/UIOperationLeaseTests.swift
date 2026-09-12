import Foundation
import XCTest
@testable import PDDAXReader

final class UIOperationLeaseTests: XCTestCase {
    func testCurrentLeaseCanSuspendAndResumeItsDeadline() throws {
        let registry = UIOperationLeaseRegistry()
        let lease = registry.acquire(uid: "customer-a")

        lease.suspendDeadline()
        XCTAssertTrue(lease.isDeadlineSuspended)

        lease.resumeDeadline()
        XCTAssertFalse(lease.isDeadlineSuspended)
    }

    func testRevocationSynchronouslyInvalidatesToken() throws {
        let registry = UIOperationLeaseRegistry()
        let token = registry.acquire(uid: "customer-a")
        XCTAssertNoThrow(try token.validate())

        registry.revoke(operationID: token.operationID)

        XCTAssertThrowsError(try token.validate()) { error in
            XCTAssertEqual(error as? UIOperationLeaseError, .revoked)
        }
    }

    func testOldReleaseCannotReleaseNewGeneration() throws {
        let registry = UIOperationLeaseRegistry()
        let old = registry.acquire(uid: "customer-a")
        registry.revoke(operationID: old.operationID)
        let new = registry.acquire(uid: "customer-b")

        registry.release(old)

        XCTAssertNoThrow(try new.validate())
        XCTAssertGreaterThan(new.generation, old.generation)
    }

    func testOnlyOneLeaseCanBeValidAtATime() throws {
        let registry = UIOperationLeaseRegistry()
        let first = registry.acquire(uid: "customer-a")
        let second = registry.acquire(uid: "customer-b")

        XCTAssertThrowsError(try first.validate())
        XCTAssertNoThrow(try second.validate())
    }
}
