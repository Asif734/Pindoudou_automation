import Foundation

enum UIOperationLeaseError: Error, Equatable, Sendable {
    case revoked
}

struct UIOperationLease: Equatable, Sendable {
    let operationID: UUID
    let generation: UInt64
    let uid: String
    private let registry: UIOperationLeaseRegistry

    fileprivate init(
        operationID: UUID,
        generation: UInt64,
        uid: String,
        registry: UIOperationLeaseRegistry
    ) {
        self.operationID = operationID
        self.generation = generation
        self.uid = uid
        self.registry = registry
    }

    func validate() throws {
        guard registry.isValid(self) else { throw UIOperationLeaseError.revoked }
    }

    func suspendDeadline() {
        registry.suspendDeadline(for: self)
    }

    func resumeDeadline() {
        registry.resumeDeadline(for: self)
    }

    var isDeadlineSuspended: Bool {
        registry.isDeadlineSuspended(for: self)
    }

    static func == (lhs: UIOperationLease, rhs: UIOperationLease) -> Bool {
        lhs.operationID == rhs.operationID
            && lhs.generation == rhs.generation
            && lhs.uid == rhs.uid
            && lhs.registry === rhs.registry
    }
}

final class UIOperationLeaseRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var currentIdentity: (operationID: UUID, generation: UInt64, uid: String)?
    private var deadlineSuspendedOperationID: UUID?

    func acquire(uid: String, operationID: UUID = UUID()) -> UIOperationLease {
        lock.lock()
        generation &+= 1
        let identity = (operationID: operationID, generation: generation, uid: uid)
        currentIdentity = identity
        deadlineSuspendedOperationID = nil
        lock.unlock()
        return UIOperationLease(
            operationID: identity.operationID,
            generation: identity.generation,
            uid: identity.uid,
            registry: self
        )
    }

    func isValid(_ lease: UIOperationLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let currentIdentity else { return false }
        return currentIdentity.operationID == lease.operationID
            && currentIdentity.generation == lease.generation
            && currentIdentity.uid == lease.uid
    }

    func revoke(operationID: UUID) {
        lock.lock()
        if currentIdentity?.operationID == operationID {
            generation &+= 1
            currentIdentity = nil
            deadlineSuspendedOperationID = nil
        }
        lock.unlock()
    }

    func revokeAll() {
        lock.lock()
        generation &+= 1
        currentIdentity = nil
        deadlineSuspendedOperationID = nil
        lock.unlock()
    }

    func release(_ lease: UIOperationLease) {
        lock.lock()
        if currentIdentity?.operationID == lease.operationID,
           currentIdentity?.generation == lease.generation {
            currentIdentity = nil
            deadlineSuspendedOperationID = nil
        }
        lock.unlock()
    }

    fileprivate func suspendDeadline(for lease: UIOperationLease) {
        lock.lock()
        if currentIdentity?.operationID == lease.operationID,
           currentIdentity?.generation == lease.generation,
           currentIdentity?.uid == lease.uid {
            deadlineSuspendedOperationID = lease.operationID
        }
        lock.unlock()
    }

    fileprivate func resumeDeadline(for lease: UIOperationLease) {
        lock.lock()
        if deadlineSuspendedOperationID == lease.operationID {
            deadlineSuspendedOperationID = nil
        }
        lock.unlock()
    }

    fileprivate func isDeadlineSuspended(for lease: UIOperationLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return deadlineSuspendedOperationID == lease.operationID
            && currentIdentity?.operationID == lease.operationID
            && currentIdentity?.generation == lease.generation
            && currentIdentity?.uid == lease.uid
    }
}
