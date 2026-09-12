import Foundation

struct PDDCustomerVideoCandidate: Equatable, Sendable {
    let messageID: String
    let frame: CGRect
}

enum PDDAXVideoSelection {
    static func customerVideos<ID: Hashable>(
        in nodes: [PDDAXSemanticNode<ID>],
        messageIDs: [String]
    ) -> [PDDCustomerVideoCandidate] {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let allowed = Set(messageIDs)
        var markers = nodes.filter(isVideoMarker)

        for duration in nodes where isDuration(duration.value) || isDuration(duration.title) {
            guard let thumbnail = nodes.first(where: {
                isThumbnail($0)
                    && messageIdentifier(for: $0, byID: byID) == messageIdentifier(for: duration, byID: byID)
                    && $0.frame.contains(CGPoint(x: duration.frame.midX, y: duration.frame.midY))
            }) else { continue }
            markers.append(thumbnail)
        }

        var emitted = Set<String>()
        var result: [PDDCustomerVideoCandidate] = []
        for marker in markers where marker.frame.width >= 12 && marker.frame.height >= 12 {
            var cursor: PDDAXSemanticNode<ID>? = marker
            var customer = false
            var service = false
            var messageID: String?
            var viewport: CGRect?
            var visited = Set<ID>()
            while let current = cursor, visited.insert(current.id).inserted {
                customer = customer || current.domClasses.contains("buyer-item")
                service = service || current.domClasses.contains("cs-item")
                if let identifier = current.domIdentifier, allowed.contains(identifier) {
                    messageID = identifier
                }
                if (current.domClasses.contains("msg-list") || current.domIdentifier == "msgListContainer"),
                   !current.frame.isEmpty {
                    viewport = current.frame
                }
                cursor = current.parentID.flatMap { byID[$0] }
            }
            guard customer, !service, let messageID,
                  viewport?.contains(CGPoint(x: marker.frame.midX, y: marker.frame.midY)) == true,
                  emitted.insert(messageID).inserted else { continue }
            result.append(PDDCustomerVideoCandidate(messageID: messageID, frame: marker.frame))
        }
        return result.sorted { $0.frame.minY < $1.frame.minY }
    }

    private static func isVideoMarker<ID>(_ node: PDDAXSemanticNode<ID>) -> Bool {
        node.domClasses.contains {
            let value = $0.lowercased()
            return value.contains("video") && !value.contains("avatar")
        }
    }

    private static func isDuration(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return value.range(of: #"^(?:\d{1,2}:)?\d{1,2}:\d{2}$"#, options: .regularExpression) != nil
    }

    private static func isThumbnail<ID>(_ node: PDDAXSemanticNode<ID>) -> Bool {
        guard node.frame.width >= 40, node.frame.height >= 40,
              !node.domClasses.contains(where: { $0.lowercased().contains("avatar") }) else { return false }
        if node.role.caseInsensitiveCompare("AXImage") == .orderedSame { return true }
        return [node.value, node.title].compactMap { $0?.lowercased() }.contains {
            $0.contains(".jpg") || $0.contains(".jpeg") || $0.contains(".png") || $0.contains(".webp")
        }
    }

    private static func messageIdentifier<ID: Hashable>(
        for node: PDDAXSemanticNode<ID>,
        byID: [ID: PDDAXSemanticNode<ID>]
    ) -> String? {
        var cursor: PDDAXSemanticNode<ID>? = node
        var visited = Set<ID>()
        while let current = cursor, visited.insert(current.id).inserted {
            if let identifier = current.domIdentifier, identifier.hasPrefix("middlePanel_list_") {
                return identifier
            }
            cursor = current.parentID.flatMap { byID[$0] }
        }
        return nil
    }
}
