import Foundation

enum PDDAXImageSelection {
    static func customerImages<ID: Hashable>(
        in nodes: [PDDAXSemanticNode<ID>],
        messageIDs: [String]
    ) -> [PDDCustomerImageCandidate] {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let allowed = Set(messageIDs)
        var emitted = Set<String>()
        var result: [PDDCustomerImageCandidate] = []

        for node in nodes where node.domClasses.contains("image-msg") && !node.frame.isEmpty {
            var cursor: PDDAXSemanticNode<ID>? = node
            var isCustomer = false
            var isService = false
            var messageID: String?
            var visibleChatFrame: CGRect?
            while let current = cursor {
                isCustomer = isCustomer || current.domClasses.contains("buyer-item")
                isService = isService || current.domClasses.contains("cs-item")
                if visibleChatFrame == nil,
                   current.domClasses.contains("history-box"),
                   !current.frame.isEmpty {
                    visibleChatFrame = current.frame
                }
                if messageID == nil,
                   let candidate = current.domIdentifier,
                   allowed.contains(candidate) {
                    messageID = candidate
                }
                cursor = current.parentID.flatMap { byID[$0] }
            }
            guard isCustomer, !isService,
                  let messageID,
                  isActuallyVisible(node.frame, inside: visibleChatFrame),
                  emitted.insert(messageID).inserted else { continue }
            result.append(PDDCustomerImageCandidate(messageID: messageID, frame: node.frame))
        }
        return result
    }

    private static func isActuallyVisible(_ frame: CGRect, inside visibleChatFrame: CGRect?) -> Bool {
        let visibleFrame = visibleChatFrame.map { frame.intersection($0) } ?? frame
        guard !visibleFrame.isNull && visibleFrame.width > 2 && visibleFrame.height > 2 else {
            return false
        }
        guard let visibleChatFrame else { return true }
        return visibleChatFrame.insetBy(dx: 2, dy: 2).contains(
            CGPoint(x: frame.midX, y: frame.midY)
        )
    }
}
