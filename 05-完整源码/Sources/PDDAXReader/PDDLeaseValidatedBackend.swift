import Foundation

final class PDDUIOperationLeaseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UIOperationLease?

    func activate(_ lease: UIOperationLease) {
        lock.lock()
        current = lease
        lock.unlock()
    }

    func validate() throws {
        lock.lock()
        let lease = current
        lock.unlock()
        guard let lease else { throw UIOperationLeaseError.revoked }
        try lease.validate()
    }

    func revoke(operationID: UUID) {
        lock.lock()
        if current?.operationID == operationID { current = nil }
        lock.unlock()
    }
}

@MainActor
final class LeaseValidatedPDDAXBackend: PDDAXBackend {
    private let base: any PDDAXBackend
    private let gate: PDDUIOperationLeaseGate

    init(base: any PDDAXBackend, gate: PDDUIOperationLeaseGate) {
        self.base = base
        self.gate = gate
    }

    func readSemanticTree() throws -> PDDAXSemanticTree {
        try gate.validate()
        let result = try base.readSemanticTree()
        try gate.validate()
        return result
    }

    func performPress(_ id: AXElementToken) throws {
        try gate.validate()
        try base.performPress(id)
        try gate.validate()
    }

    func setValue(_ text: String, on id: AXElementToken) throws {
        try gate.validate()
        try base.setValue(text, on: id)
        try gate.validate()
    }

    func value(of id: AXElementToken) throws -> String {
        try gate.validate()
        let result = try base.value(of: id)
        try gate.validate()
        return result
    }
}
