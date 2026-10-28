import Foundation

/// Reads platform transfer notices, never customer-request keywords.
enum PDDAXIncomingTransfer {
    static func recipient(_ text: String) -> String? {
        guard let marker = text.range(of: "将该会话转移给") else { return nil }
        let tail = text[marker.upperBound...]
        let name = tail.prefix { !["，", ",", "。", "\n"].contains($0) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func currentAgent(in root: AXNodeSnapshot) -> String? {
        if root.role == "AXWebArea" {
            return root.attribute(named: "AXTitle")?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return root.children.compactMap { currentAgent(in: $0) }.first
    }

    static func pendingRows(in tree: PDDAXSemanticTree) -> [PDDConversationRow<AXElementToken>] {
        guard let agent = currentAgent(in: tree.rootSnapshot), !agent.isEmpty,
              let rows = try? PDDAXControlSelection.conversationRows(in: tree.nodes) else { return [] }
        let children = Dictionary(grouping: tree.nodes, by: \.parentID)
        func hasNotice(_ id: AXElementToken) -> Bool {
            (children[id] ?? []).contains { node in
                [node.value, node.title].compactMap { $0 }.contains { recipient($0) == agent }
                    || hasNotice(node.id)
            }
        }
        return rows.filter { hasNotice($0.rowID) }
    }

    /// Only the latest system transfer matters. A service reply after it closes
    /// this special handoff path; an ordinary customer bubble cannot forge it.
    static func customerIDsForUnansweredHandoff(in root: AXNodeSnapshot) -> [String] {
        guard let agent = currentAgent(in: root), !agent.isEmpty else { return [] }
        enum Entry { case message(PDDChatMessage); case transfer(String) }
        var entries: [Entry] = []
        func visit(_ node: AXNodeSnapshot) {
            if node.domClasses.contains(where: { $0.contains("chat-item-box") }) { return }
            if node.domClasses.contains("onemsg") {
                let parsed = PDDChatParser.parse(root: node).messages
                if !parsed.isEmpty {
                    entries.append(contentsOf: parsed.map(Entry.message))
                    return
                }
            }
            // Customer/service content is never a platform transfer notice.
            if node.domClasses.contains("buyer-item") || node.domClasses.contains("cs-item") { return }
            if node.role == "AXStaticText",
               let text = node.attribute(named: "AXValue") ?? node.attribute(named: "AXTitle"),
               let target = recipient(text) {
                entries.append(.transfer(target))
                return
            }
            node.children.forEach(visit)
        }
        visit(root)
        guard let notice = entries.lastIndex(where: { if case .transfer = $0 { return true }; return false }),
              case .transfer(let target) = entries[notice], target == agent else { return [] }
        let after = entries.suffix(from: notice + 1).compactMap { entry -> PDDChatMessage? in
            if case .message(let message) = entry { return message }; return nil
        }
        guard !after.contains(where: { $0.sender == .service }) else { return [] }
        let before = entries.prefix(notice).compactMap { entry -> PDDChatMessage? in
            if case .message(let message) = entry { return message }; return nil
        }
        guard let last = before.lastIndex(where: { $0.sender == .customer }) else { return [] }
        var start = last
        while start > 0 && before[start - 1].sender == .customer { start -= 1 }
        return before[start...last].map(\.id) + after.filter { $0.sender == .customer }.map(\.id)
    }

    static func recoveryCursor(in history: [PDDChatMessage], customerIDs: [String]) throws -> AutoReplyCursor? {
        let ids = Set(customerIDs)
        guard let first = history.firstIndex(where: { $0.sender == .customer && ids.contains($0.id) }) else { return nil }
        return try AutoReplyTimeline.make(messages: Array(history.prefix(first))).cursor
    }
}
