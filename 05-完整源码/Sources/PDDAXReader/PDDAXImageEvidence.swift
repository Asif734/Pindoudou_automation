import Foundation

struct PDDAXTailEvidence {
    let allImageCount: Int
    let parsedTailMessages: [PDDChatMessage]

    var customerImages: [PDDChatMessage] {
        parsedTailMessages.filter { $0.sender == .customer && $0.kind == .image }
    }

    static func extract(root: AXNodeSnapshot, capturedAt: Date) -> PDDAXTailEvidence {
        var nodes: [AXNodeSnapshot] = []
        collectMessageNodes(root, into: &nodes)
        let allImageCount = nodes.filter { containsClass("image-msg", in: $0) }.count
        let lastBoundary = nodes.lastIndex { node in
            let hasCustomer = containsClass("buyer-item", in: node)
            let hasService = containsClass("cs-item", in: node)
            return hasService || !hasCustomer
        }
        let tailNodes = nodes.dropFirst(lastBoundary.map { $0 + 1 } ?? 0)
        let sharedEvidence = PDDAXVisibleMessageEvidence.extract(root: root, capturedAt: capturedAt)
        let lastParsedBoundary = sharedEvidence.messages.lastIndex { $0.sender != .customer }
        let tailMessages = sharedEvidence.messages.dropFirst(lastParsedBoundary.map { $0 + 1 } ?? 0)
        var stableImageNodeIDs = tailNodes
            .filter { containsClass("image-msg", in: $0) }
            .map { stableImageNodeID(in: $0) }
            .makeIterator()
        var parsed: [PDDChatMessage] = []
        for message in tailMessages {
            guard message.kind == .image else {
                parsed.append(message)
                continue
            }
            let stableImageNodeID = stableImageNodeIDs.next() ?? nil
            guard message.id.hasPrefix("fallback-"), !message.id.contains("-chrome-") else {
                parsed.append(message)
                continue
            }
            guard let stableImageNodeID else { continue }
            parsed.append(PDDChatMessage(
                id: "\(message.id)-chrome-\(stableImageNodeID)",
                sender: message.sender,
                content: message.content,
                displayTime: message.displayTime,
                kind: message.kind,
                capturedAt: message.capturedAt
            ))
        }
        return PDDAXTailEvidence(allImageCount: allImageCount, parsedTailMessages: parsed)
    }

    private static func stableImageNodeID(in node: AXNodeSnapshot) -> String? {
        if node.domClasses.contains("image-msg"),
           let raw = node.attribute(named: "ChromeAXNodeId")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           raw.allSatisfy(\.isNumber) {
            return raw
        }
        for child in node.children {
            if let result = stableImageNodeID(in: child) { return result }
        }
        return nil
    }

    private static func collectMessageNodes(
        _ node: AXNodeSnapshot,
        into result: inout [AXNodeSnapshot]
    ) {
        if node.domClasses.contains("onemsg") {
            result.append(node)
            return
        }
        for child in node.children {
            collectMessageNodes(child, into: &result)
        }
    }

    private static func containsClass(_ className: String, in node: AXNodeSnapshot) -> Bool {
        node.domClasses.contains(className)
            || node.children.contains { containsClass(className, in: $0) }
    }
}

enum PDDHybridMessageOrdering {
    static func merge(
        ocrMessages: [PDDChatMessage],
        axTailMessages: [PDDChatMessage]
    ) -> [PDDChatMessage] {
        let images = axTailMessages.enumerated().filter {
            $0.element.sender == .customer && $0.element.kind == .image
        }
        guard !images.isEmpty else { return ocrMessages }

        let prefixEnd = ocrMessages.lastIndex { $0.sender == .service }.map { $0 + 1 } ?? 0
        let prefix = Array(ocrMessages.prefix(prefixEnd))
        let ocrTail = Array(ocrMessages.dropFirst(prefixEnd))
        var matches: [(axIndex: Int, ocrIndex: Int)] = []
        var nextOCRIndex = 0

        for (axIndex, message) in axTailMessages.enumerated() where message.kind != .image {
            guard nextOCRIndex < ocrTail.count,
                  let match = ocrTail[nextOCRIndex...].firstIndex(where: {
                      sameVisibleMessage($0, message)
                  }) else { continue }
            matches.append((axIndex, match))
            nextOCRIndex = match + 1
        }

        var imagesBySlot: [Int: [PDDChatMessage]] = [:]
        for image in images {
            let nextMatch = matches.first { $0.axIndex > image.offset }
            let previousMatch = matches.last { $0.axIndex < image.offset }
            let slot = nextMatch?.ocrIndex ?? previousMatch.map { $0.ocrIndex + 1 } ?? ocrTail.count
            imagesBySlot[slot, default: []].append(image.element)
        }

        var result = prefix
        for index in 0...ocrTail.count {
            result.append(contentsOf: imagesBySlot[index] ?? [])
            if index < ocrTail.count { result.append(ocrTail[index]) }
        }
        return result
    }

    private static func sameVisibleMessage(_ lhs: PDDChatMessage, _ rhs: PDDChatMessage) -> Bool {
        lhs.sender == rhs.sender
            && PDDOCRNormalizer.normalize(lhs.content) == PDDOCRNormalizer.normalize(rhs.content)
    }
}
