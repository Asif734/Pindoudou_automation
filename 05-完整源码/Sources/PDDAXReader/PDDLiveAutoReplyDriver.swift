import Foundation

@MainActor
protocol PDDLiveConversationDriving: AnyObject {
    func discover() async throws -> [AutoReplyDiscovery]
    func capture(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture
    func capture(
        uid: String, after cursor: AutoReplyCursor, lease: UIOperationLease
    ) async throws -> AutoReplyCapture
    func capture(
        uid: String, after cursor: AutoReplyCursor, includeImages: Bool,
        onlyVideoMessageID: String?, lease: UIOperationLease
    ) async throws -> AutoReplyCapture
    func preflight(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture
    func preflight(
        uid: String, after cursor: AutoReplyCursor, lease: UIOperationLease
    ) async throws -> AutoReplyCapture
    func restoreConversationLocators(_ locators: [String: PDDConversationLocator])
    func restoreConversationCaptureState(
        baselinedUIDs: Set<String>,
        knownServiceMessageIDsByUID: [String: Set<String>]
    )
    func conversationLocatorsSnapshot() -> [String: PDDConversationLocator]?
    func takeConversationDiagnostics() -> [PDDConversationDiagnostic]
    func restoreProvisionalReceipts(_ receipts: [String: [PDDProvisionalReceipt]])
    func provisionalReceiptsSnapshot() -> [String: [PDDProvisionalReceipt]]
    func restoreMessageSourceSelectorStates(_ states: [String: PDDMessageSourceSelectorState])
    func messageSourceSelectorStatesSnapshot() -> [String: PDDMessageSourceSelectorState]
}

extension PDDLiveConversationDriving {
    func capture(
        uid: String, after cursor: AutoReplyCursor, includeImages: Bool,
        onlyVideoMessageID: String?, lease: UIOperationLease
    ) async throws -> AutoReplyCapture {
        try await capture(uid: uid, after: cursor, lease: lease)
    }
}

extension PDDAXConversationDriver: PDDLiveConversationDriving {}

@MainActor
protocol PDDLiveReplySending: AnyObject {
    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor
    ) async throws -> AutoReplyDeliveryResult
    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor,
        expectedCustomerMessageIDs: Set<String>
    ) async throws -> AutoReplyDeliveryResult
}

extension PDDLiveReplySending {
    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor,
        expectedCustomerMessageIDs: Set<String>
    ) async throws -> AutoReplyDeliveryResult {
        try await send(
            uid: uid, text: text, expectedCustomerCursor: expectedCustomerCursor
        )
    }
}

extension PDDAXReplySender: PDDLiveReplySending {}

@MainActor
final class PDDLiveAutoReplyDriver: AutoReplyAutomationDriver {
    private let conversationDriver: any PDDLiveConversationDriving
    private let sender: any PDDLiveReplySending
    private let transferer: (any PDDLiveConversationTransferring)?
    private let leaseGate: PDDUIOperationLeaseGate?

    init(
        conversationDriver: any PDDLiveConversationDriving,
        sender: any PDDLiveReplySending,
        transferer: (any PDDLiveConversationTransferring)? = nil,
        leaseGate: PDDUIOperationLeaseGate? = nil
    ) {
        self.conversationDriver = conversationDriver
        self.sender = sender
        self.transferer = transferer
        self.leaseGate = leaseGate
    }

    func discover() async throws -> [AutoReplyDiscovery] {
        try await conversationDriver.discover()
    }

    func capture(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture {
        try await conversationDriver.capture(uid: uid, after: cursor)
    }

    func preflight(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture? {
        try await conversationDriver.preflight(uid: uid, after: cursor)
    }

    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor
    ) async throws -> AutoReplyDeliveryResult {
        try await sender.send(uid: uid, text: text, expectedCustomerCursor: expectedCustomerCursor)
    }

    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor,
        expectedCustomerMessageIDs: Set<String>
    ) async throws -> AutoReplyDeliveryResult {
        try await sender.send(
            uid: uid,
            text: text,
            expectedCustomerCursor: expectedCustomerCursor,
            expectedCustomerMessageIDs: expectedCustomerMessageIDs
        )
    }

    func transferToAnyHuman(
        uid: String, lease: UIOperationLease
    ) async throws -> AutoReplyTransferResult {
        guard let transferer else { return .failed("当前驱动未配置转人工执行器") }
        return try await withLease(lease) {
            try await transferer.transferToAnyHuman(uid: uid, lease: lease)
        }
    }

    func discover(lease: UIOperationLease) async throws -> [AutoReplyDiscovery] {
        try await withLease(lease) { try await conversationDriver.discover() }
    }

    func capture(
        uid: String, after cursor: AutoReplyCursor, lease: UIOperationLease
    ) async throws -> AutoReplyCapture {
        try await withLease(lease) {
            try await conversationDriver.capture(uid: uid, after: cursor, lease: lease)
        }
    }

    func capture(
        uid: String, after cursor: AutoReplyCursor, includeImages: Bool,
        onlyVideoMessageID: String?, lease: UIOperationLease
    ) async throws -> AutoReplyCapture {
        try await withLease(lease) {
            try await conversationDriver.capture(
                uid: uid, after: cursor, includeImages: includeImages,
                onlyVideoMessageID: onlyVideoMessageID, lease: lease
            )
        }
    }

    func preflight(
        uid: String, after cursor: AutoReplyCursor, lease: UIOperationLease
    ) async throws -> AutoReplyCapture? {
        try await withLease(lease) {
            try await conversationDriver.preflight(uid: uid, after: cursor, lease: lease)
        }
    }

    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor,
        lease: UIOperationLease
    ) async throws -> AutoReplyDeliveryResult {
        try await withLease(lease) {
            try await sender.send(
                uid: uid, text: text, expectedCustomerCursor: expectedCustomerCursor
            )
        }
    }


    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor,
        expectedCustomerMessageIDs: Set<String>,
        lease: UIOperationLease
    ) async throws -> AutoReplyDeliveryResult {
        try await withLease(lease) {
            try await sender.send(
                uid: uid,
                text: text,
                expectedCustomerCursor: expectedCustomerCursor,
                expectedCustomerMessageIDs: expectedCustomerMessageIDs
            )
        }
    }

    func revokeCurrentUIOperation(operationID: UUID) async {
        leaseGate?.revoke(operationID: operationID)
    }

    func restoreConversationLocators(_ locators: [String: PDDConversationLocator]) {
        conversationDriver.restoreConversationLocators(locators)
    }

    func restoreConversationCaptureState(
        baselinedUIDs: Set<String>,
        knownServiceMessageIDsByUID: [String: Set<String>]
    ) {
        conversationDriver.restoreConversationCaptureState(
            baselinedUIDs: baselinedUIDs,
            knownServiceMessageIDsByUID: knownServiceMessageIDsByUID
        )
    }

    func conversationLocatorsSnapshot() -> [String: PDDConversationLocator]? {
        conversationDriver.conversationLocatorsSnapshot()
    }

    func takeConversationDiagnostics() -> [PDDConversationDiagnostic] {
        conversationDriver.takeConversationDiagnostics()
    }

    func restoreProvisionalReceipts(_ receipts: [String: [PDDProvisionalReceipt]]) {
        conversationDriver.restoreProvisionalReceipts(receipts)
    }

    func provisionalReceiptsSnapshot() -> [String: [PDDProvisionalReceipt]]? {
        conversationDriver.provisionalReceiptsSnapshot()
    }

    func restoreMessageSourceSelectorStates(
        _ states: [String: PDDMessageSourceSelectorState]
    ) {
        conversationDriver.restoreMessageSourceSelectorStates(states)
    }

    func messageSourceSelectorStatesSnapshot() -> [String: PDDMessageSourceSelectorState]? {
        conversationDriver.messageSourceSelectorStatesSnapshot()
    }

    private func withLease<Value: Sendable>(
        _ lease: UIOperationLease,
        operation: () async throws -> Value
    ) async throws -> Value {
        try lease.validate()
        leaseGate?.activate(lease)
        let result = try await operation()
        try lease.validate()
        return result
    }
}
