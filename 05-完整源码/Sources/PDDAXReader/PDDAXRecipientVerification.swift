import Foundation

/// Recipient identity is independent of OCR and of whether the triggering
/// message is still rendered. A composer alone never establishes identity.
enum PDDAXRecipientVerification {
    static func reason(uid: String, locator: PDDConversationLocator? = nil,
                       expectedAXMessageIDs: Set<String> = [], tree: PDDAXSemanticTree) -> String? {
        if !uid.hasPrefix("PDD-") {
            return PDDCustomerIdentity.resolve(from: tree.rootSnapshot) == uid ? "ax-customer-id" : nil
        }
        guard PDDConversationSnapshotLocator.activeCount(in: tree.rootSnapshot) <= 1 else { return nil }
        let semanticRows = (try? PDDAXControlSelection.conversationRows(in: tree.nodes)) ?? []
        let snapshotRows = PDDConversationSnapshotLocator.all(in: tree.rootSnapshot)
        let activeSemanticRows = semanticRows.filter { row in
            tree.nodes.contains { $0.id == row.rowID && $0.domClasses.contains {
                $0 == "active" || $0.contains("selected")
            } }
        }
        guard activeSemanticRows.count <= 1 else { return nil }
        let snapshotCurrent = PDDConversationSnapshotLocator.current(in: tree.rootSnapshot)
        let semanticCurrent = activeSemanticRows.first.map { PDDConversationLocator(domIdentifier: $0.domIdentifier, nickname: $0.visibleLabel) }
        let snapshotID = PDDConversationSnapshotLocator.activeIdentifier(in: tree.rootSnapshot)
        let semanticID = semanticCurrent?.normalizedIdentifier
        if let snapshotID, let semanticID, snapshotID != semanticID { return nil }
        let activeID = snapshotID ?? semanticID
        if let activeID, let expectedID = locator?.normalizedIdentifier {
            return activeID == expectedID ? "ax-conversation-id" : nil
        }
        if let activeID, uid.hasPrefix("PDD-ID-") {
            return PDDConversationKey.make(locator: .init(domIdentifier: activeID, nickname: "")) == uid
                ? "ax-conversation-id" : nil
        }
        // Actual customer message IDs survive masked-name changes. A
        // contradictory stable ID or multiple active rows above still vetoes
        // this evidence; display-name mismatches alone must not veto it.
        let actualIDs = Set(PDDChatParser.parse(root: tree.rootSnapshot).messages.filter {
            $0.sender == .customer
        }.map(\.id))
        if !actualIDs.isDisjoint(with: expectedAXMessageIDs) { return "ax-customer-message-id" }
        if let snapshotCurrent, let semanticCurrent,
           snapshotCurrent.normalizedNickname != semanticCurrent.normalizedNickname { return nil }
        let current = snapshotCurrent ?? semanticCurrent
        if let current {
            // A visitor label can belong to many people and never proves a recipient.
            guard !PDDConversationIdentityStore.generic(current.nickname),
                  locator.map({ !PDDConversationIdentityStore.generic($0.nickname) }) ?? true else { return nil }
            if let locator, current.normalizedNickname != locator.normalizedNickname { return nil }
            let nameKey = PDDConversationKey.make(locator: .init(nickname: current.nickname))
            guard locator != nil || nameKey == uid else { return nil }
            let semanticCount = semanticRows.filter {
                $0.visibleLabel.trimmingCharacters(in: .whitespacesAndNewlines) == current.normalizedNickname
            }.count
            let snapshotCount = snapshotRows.filter { $0.normalizedNickname == current.normalizedNickname }.count
            if max(semanticCount, snapshotCount) == 1 { return "ax-unique-active-conversation" }
        }
        return nil
    }
}
