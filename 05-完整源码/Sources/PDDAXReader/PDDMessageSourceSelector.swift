import Foundation

enum PDDAXFallbackReason: String, Codable, Equatable, Sendable {
    case missingStructure
    case regressedStructure
    case unreadAXStale
}

enum PDDMessageSourceDecision: Equatable, Sendable {
    case useAX
    case resampleAX(afterNanoseconds: UInt64)
    case useOCR(reason: PDDAXFallbackReason)
}

struct PDDMessageSourceSelectorState: Codable, Equatable, Sendable {
    let fingerprint: String
    let stableIDs: [String]
}

struct PDDMessageSourceSelector: Sendable {
    private static let sampleInterval: TimeInterval = 0.2
    private static let requiredSamples = 3

    private struct StaleProbe: Sendable {
        let fingerprint: String
        var lastSampleAt: Date
        var sampleCount: Int
    }

    private var trustedByUID: [String: PDDMessageSourceSelectorState] = [:]
    private var probeByUID: [String: StaleProbe] = [:]

    mutating func restore(_ states: [String: PDDMessageSourceSelectorState]) {
        trustedByUID = states
        probeByUID = [:]
    }

    func snapshot() -> [String: PDDMessageSourceSelectorState] {
        trustedByUID
    }

    mutating func observe(
        uid: String,
        unread: Bool,
        evidence: PDDAXVisibleMessageEvidence,
        now: Date = Date()
    ) -> PDDMessageSourceDecision {
        guard evidence.isStructurallyValid else {
            probeByUID.removeValue(forKey: uid)
            let reason: PDDAXFallbackReason = evidence.messageNodeCount == 0
                ? .missingStructure
                : .regressedStructure
            return .useOCR(reason: reason)
        }

        let stableIDs = evidence.messages.map(\.id).filter {
            $0.hasPrefix("middlePanel_list_")
        }
        if let trusted = trustedByUID[uid], orderRegressed(from: trusted.stableIDs, to: stableIDs) {
            probeByUID.removeValue(forKey: uid)
            return .useOCR(reason: .regressedStructure)
        }

        guard let trusted = trustedByUID[uid] else {
            trust(uid: uid, evidence: evidence, stableIDs: stableIDs)
            return .useAX
        }

        guard trusted.fingerprint == evidence.fingerprint else {
            trust(uid: uid, evidence: evidence, stableIDs: stableIDs)
            return .useAX
        }

        guard unread else {
            probeByUID.removeValue(forKey: uid)
            return .useAX
        }

        guard var probe = probeByUID[uid], probe.fingerprint == evidence.fingerprint else {
            probeByUID[uid] = StaleProbe(
                fingerprint: evidence.fingerprint,
                lastSampleAt: now,
                sampleCount: 1
            )
            return .resampleAX(afterNanoseconds: Self.nanoseconds(Self.sampleInterval))
        }

        let sinceLastSample = now.timeIntervalSince(probe.lastSampleAt)
        if sinceLastSample + 0.001 < Self.sampleInterval {
            return .resampleAX(
                afterNanoseconds: Self.nanoseconds(Self.sampleInterval - max(0, sinceLastSample))
            )
        }

        probe.lastSampleAt = now
        probe.sampleCount += 1
        probeByUID[uid] = probe
        if probe.sampleCount >= Self.requiredSamples {
            probeByUID.removeValue(forKey: uid)
            return .useOCR(reason: .unreadAXStale)
        }
        return .resampleAX(afterNanoseconds: Self.nanoseconds(Self.sampleInterval))
    }

    private mutating func trust(
        uid: String,
        evidence: PDDAXVisibleMessageEvidence,
        stableIDs: [String]
    ) {
        trustedByUID[uid] = PDDMessageSourceSelectorState(
            fingerprint: evidence.fingerprint,
            stableIDs: stableIDs
        )
        probeByUID.removeValue(forKey: uid)
    }

    private func orderRegressed(from previous: [String], to current: [String]) -> Bool {
        let currentPositions = Dictionary(uniqueKeysWithValues: current.enumerated().map { ($1, $0) })
        let positions = previous.compactMap { currentPositions[$0] }
        guard positions.count >= 2 else { return false }
        return zip(positions, positions.dropFirst()).contains { $0 >= $1 }
    }

    private static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        let milliseconds = max(1, (interval * 1_000).rounded())
        return UInt64(milliseconds) * 1_000_000
    }
}
