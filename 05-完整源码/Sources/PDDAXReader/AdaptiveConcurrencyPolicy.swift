import Foundation

final class AdaptiveConcurrencyPolicy: @unchecked Sendable {
    private static let gibibyte = UInt64(1) << 30
    private let emergencyCeiling: Int
    private let lock = NSLock()
    private var backpressureUntil: Date?

    init(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        emergencyCeiling: Int? = nil
    ) {
        let physicalGiB = Int(physicalMemoryBytes / Self.gibibyte)
        self.emergencyCeiling = max(1, emergencyCeiling ?? max(1, physicalGiB))
    }

    func limit(
        queueDepth: Int,
        availableMemoryBytes: UInt64,
        activeCleanup: Int,
        now: Date
    ) -> Int {
        guard queueDepth > 0 else { return 0 }
        let reserve = Self.gibibyte
        guard availableMemoryBytes > reserve else { return 0 }
        let memoryCapacity = Int((availableMemoryBytes - reserve) / Self.gibibyte)
        let totalDemand = max(queueDepth, activeCleanup)
        var capacity = min(totalDemand, memoryCapacity, emergencyCeiling)
        if isCoolingDown(at: now) { capacity /= 2 }
        return capacity
    }

    func recordBackpressure(now: Date) {
        lock.lock()
        backpressureUntil = now.addingTimeInterval(60)
        lock.unlock()
    }

    func recordSuccess(now: Date) {
        lock.lock()
        if let until = backpressureUntil, now >= until { backpressureUntil = nil }
        lock.unlock()
    }

    private func isCoolingDown(at now: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = backpressureUntil else { return false }
        if now >= until {
            backpressureUntil = nil
            return false
        }
        return true
    }
}
