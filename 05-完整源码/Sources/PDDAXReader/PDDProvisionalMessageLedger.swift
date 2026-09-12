import Foundation

struct PDDProvisionalReconciliation: Equatable, Sendable {
    let actionableAXMessages: [PDDChatMessage]
    let absorbedAXMessageIDs: [String]
}

struct PDDProvisionalMessageLedger: Equatable, Sendable {
    private static let absorptionWindow: TimeInterval = 30

    var receipts: [PDDProvisionalReceipt]

    init(receipts: [PDDProvisionalReceipt] = []) {
        self.receipts = receipts
    }

    mutating func reconcile(
        axMessages: [PDDChatMessage],
        now: Date = Date()
    ) -> PDDProvisionalReconciliation {
        var actionable: [PDDChatMessage] = []
        var absorbedIDs: [String] = []

        for message in axMessages {
            guard message.sender == .customer else {
                actionable.append(message)
                continue
            }

            if receipts.contains(where: { $0.absorbedAXMessageID == message.id }) {
                absorbedIDs.append(message.id)
                continue
            }

            let normalized = PDDOCRNormalizer.normalize(message.content)
            let match = receipts.indices.first { index in
                let receipt = receipts[index]
                let elapsed = now.timeIntervalSince(receipt.firstObservedAt)
                return receipt.absorbedAXMessageID == nil
                    && receipt.normalizedContent == normalized
                    && elapsed >= 0
                    && elapsed <= Self.absorptionWindow
            }
            guard let match else {
                actionable.append(message)
                continue
            }
            receipts[match].absorbedAXMessageID = message.id
            absorbedIDs.append(message.id)
        }

        return PDDProvisionalReconciliation(
            actionableAXMessages: actionable,
            absorbedAXMessageIDs: absorbedIDs
        )
    }
}
