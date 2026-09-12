import Foundation

struct RuntimeResourceSnapshot: Codable, Equatable, Sendable {
    let date: Date
    let availableMemoryBytes: UInt64
    let activeCLI: Int
    let queueDepth: Int
    let lastLatencyMilliseconds: Int?
}

protocol RuntimeResourceMonitoring: Sendable {
    func snapshot(
        activeCLI: Int,
        queueDepth: Int,
        lastLatencyMilliseconds: Int?
    ) -> RuntimeResourceSnapshot
}

struct RuntimeResourceMonitor: RuntimeResourceMonitoring {
    let availableMemoryBytes: @Sendable () -> UInt64
    let now: @Sendable () -> Date

    init(
        availableMemoryBytes: @escaping @Sendable () -> UInt64,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.availableMemoryBytes = availableMemoryBytes
        self.now = now
    }

    func snapshot(
        activeCLI: Int,
        queueDepth: Int,
        lastLatencyMilliseconds: Int?
    ) -> RuntimeResourceSnapshot {
        RuntimeResourceSnapshot(
            date: now(),
            availableMemoryBytes: availableMemoryBytes(),
            activeCLI: activeCLI,
            queueDepth: queueDepth,
            lastLatencyMilliseconds: lastLatencyMilliseconds
        )
    }
}
