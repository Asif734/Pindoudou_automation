import XCTest
@testable import PDDAXReader

@MainActor
final class PDDLeaseValidatedBackendTests: XCTestCase {
    func testRevokedLeasePreventsPressFromReachingLiveBackend() throws {
        let base = LeaseBackendSpy()
        let gate = PDDUIOperationLeaseGate()
        let backend = LeaseValidatedPDDAXBackend(base: base, gate: gate)
        let registry = UIOperationLeaseRegistry()
        let lease = registry.acquire(uid: "GZC-000001")
        gate.activate(lease)
        registry.revoke(operationID: lease.operationID)

        XCTAssertThrowsError(try backend.performPress(AXElementToken(rawValue: 1)))
        XCTAssertEqual(base.pressCount, 0)
    }

    func testValidLeaseAllowsReadWriteAndPress() throws {
        let base = LeaseBackendSpy()
        let gate = PDDUIOperationLeaseGate()
        let backend = LeaseValidatedPDDAXBackend(base: base, gate: gate)
        let registry = UIOperationLeaseRegistry()
        let lease = registry.acquire(uid: "GZC-000001")
        gate.activate(lease)

        _ = try backend.readSemanticTree()
        try backend.setValue("reply", on: AXElementToken(rawValue: 1))
        _ = try backend.value(of: AXElementToken(rawValue: 1))
        try backend.performPress(AXElementToken(rawValue: 1))

        XCTAssertEqual(base.readCount, 1)
        XCTAssertEqual(base.writeCount, 1)
        XCTAssertEqual(base.valueCount, 1)
        XCTAssertEqual(base.pressCount, 1)
    }

    func testClearingOperationPreventsLateActionFromOldTask() throws {
        let base = LeaseBackendSpy()
        let gate = PDDUIOperationLeaseGate()
        let backend = LeaseValidatedPDDAXBackend(base: base, gate: gate)
        let registry = UIOperationLeaseRegistry()
        let lease = registry.acquire(uid: "GZC-000001")
        gate.activate(lease)

        gate.revoke(operationID: lease.operationID)

        XCTAssertThrowsError(try backend.setValue("late", on: AXElementToken(rawValue: 1)))
        XCTAssertEqual(base.writeCount, 0)
    }
}

@MainActor
private final class LeaseBackendSpy: PDDAXBackend {
    var readCount = 0
    var pressCount = 0
    var writeCount = 0
    var valueCount = 0

    func readSemanticTree() throws -> PDDAXSemanticTree {
        readCount += 1
        return PDDAXSemanticTree(
            rootSnapshot: AXNodeSnapshot(role: "AXWindow"),
            nodes: []
        )
    }

    func performPress(_ id: AXElementToken) throws { pressCount += 1 }
    func setValue(_ text: String, on id: AXElementToken) throws { writeCount += 1 }
    func value(of id: AXElementToken) throws -> String { valueCount += 1; return "reply" }
}
