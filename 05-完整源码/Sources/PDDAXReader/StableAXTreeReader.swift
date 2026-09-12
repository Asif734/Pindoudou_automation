import Foundation

enum PDDAXSnapshotOrder {
    static func newestMessageOrdinal(in root: AXNodeSnapshot) -> UInt64? {
        newestMessageIdentifier(in: root).flatMap(messageOrdinal(from:))
    }

    static func newestMessageIdentifier(in root: AXNodeSnapshot) -> String? {
        var newestIdentifier: String?
        var newestOrdinal: UInt64?
        visit(root) { identifier in
            guard let ordinal = messageOrdinal(from: identifier) else {
                if newestIdentifier == nil { newestIdentifier = identifier }
                return
            }
            if newestOrdinal == nil || ordinal > newestOrdinal! {
                newestIdentifier = identifier
                newestOrdinal = ordinal
            }
        }
        return newestIdentifier
    }

    static func messageOrdinal(from identifier: String) -> UInt64? {
        guard identifier.hasPrefix("middlePanel_list_"),
              let suffix = identifier.split(separator: "_").last else { return nil }
        return UInt64(suffix)
    }

    private static func visit(_ node: AXNodeSnapshot, identifier: (String) -> Void) {
        if node.domClasses.contains("onemsg"),
           let value = node.attribute(named: "AXDOMIdentifier") {
            identifier(value)
        }
        for child in node.children {
            visit(child, identifier: identifier)
        }
    }
}

struct StableAXTreeReader: @unchecked Sendable {
    let sampleCount: Int
    let interval: TimeInterval
    let readOnce: @Sendable () throws -> AXReadResult
    let pause: @Sendable (TimeInterval) -> Void

    init(
        sampleCount: Int = 3,
        interval: TimeInterval = 0.35,
        readOnce: @escaping @Sendable () throws -> AXReadResult,
        pause: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.sampleCount = max(1, sampleCount)
        self.interval = max(0, interval)
        self.readOnce = readOnce
        self.pause = pause
    }

    func read() throws -> AXReadResult {
        var best = try readOnce()
        guard sampleCount > 1 else { return best }

        for _ in 1..<sampleCount {
            pause(interval)
            guard let candidate = try? readOnce() else { continue }
            if isNewer(candidate, than: best) {
                best = candidate
            }
        }
        return best
    }

    private func isNewer(_ candidate: AXReadResult, than current: AXReadResult) -> Bool {
        let candidateOrdinal = PDDAXSnapshotOrder.newestMessageOrdinal(in: candidate.root)
        let currentOrdinal = PDDAXSnapshotOrder.newestMessageOrdinal(in: current.root)
        switch (candidateOrdinal, currentOrdinal) {
        case let (candidate?, current?):
            return candidate > current
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return candidate.nodeCount > current.nodeCount
        }
    }
}

enum PDDMessageChronology {
    static func latest(in messages: [PDDChatMessage]) -> PDDChatMessage? {
        guard var latest = messages.first else { return nil }
        for candidate in messages.dropFirst() {
            let candidateOrdinal = PDDAXSnapshotOrder.messageOrdinal(from: candidate.id)
            let latestOrdinal = PDDAXSnapshotOrder.messageOrdinal(from: latest.id)
            switch (candidateOrdinal, latestOrdinal) {
            case let (candidateValue?, latestValue?) where candidateValue > latestValue:
                latest = candidate
            case (nil, nil) where candidate.capturedAt >= latest.capturedAt:
                latest = candidate
            case (nil, _?) where candidate.capturedAt > latest.capturedAt:
                latest = candidate
            default:
                break
            }
        }
        return latest
    }
}
