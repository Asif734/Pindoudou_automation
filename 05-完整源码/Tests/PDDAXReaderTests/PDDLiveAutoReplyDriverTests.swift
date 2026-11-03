import XCTest
@testable import PDDAXReader

@MainActor
final class PDDLiveAutoReplyDriverTests: XCTestCase {
    func testConversationVisibilityInventoryReachesSchedulerDriver() {
        let conversation = LiveConversationSpy()
        conversation.visibleLocators = [.init(nickname: "visible")]
        let driver = PDDLiveAutoReplyDriver(conversationDriver: conversation, sender: LiveSenderSpy())
        XCTAssertEqual(driver.visibleConversationsSnapshot(), conversation.visibleLocators)
    }
    func testImagePayloadAndDeliveryIdentityReachSenderWithValidLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try makeDatasetReplyImageFixture(root: root)
        let sender = LiveSenderSpy()
        let driver = PDDLiveAutoReplyDriver(conversationDriver: LiveConversationSpy(), sender: sender)
        let id = UUID()
        let lease = UIOperationLeaseRegistry().acquire(uid: "PDD-test")
        let result = try await driver.send(uid: "PDD-test", text: "Sample", outgoingImages: [image], deliveryID: id,
            expectedCustomerCursor: .empty, expectedCustomerMessageIDs: ["m1"], lease: lease)
        XCTAssertEqual(result, .sent(serviceMessageID: "image-test"))
        XCTAssertEqual(sender.images, [image])
        XCTAssertEqual(sender.deliveryID, id)
        XCTAssertEqual(sender.messageIDs, ["m1"])
    }
    func testLeaseCaptureCallsCaptureSurface() async throws {
        let conversation = LiveConversationSpy()
        let driver = PDDLiveAutoReplyDriver(
            conversationDriver: conversation,
            sender: LiveSenderSpy()
        )
        let lease = UIOperationLeaseRegistry().acquire(uid: "PDD-test")

        let result = try await driver.capture(uid: "PDD-test", after: .empty, lease: lease)

        XCTAssertEqual(result.ocrDiagnostic, "capture")
        XCTAssertEqual(conversation.captureCalls, 1)
        XCTAssertEqual(conversation.preflightCalls, 0)
    }

    func testLeasePreflightCallsPreflightSurface() async throws {
        let conversation = LiveConversationSpy()
        let driver = PDDLiveAutoReplyDriver(
            conversationDriver: conversation,
            sender: LiveSenderSpy()
        )
        let lease = UIOperationLeaseRegistry().acquire(uid: "PDD-test")

        let result = try await driver.preflight(uid: "PDD-test", after: .empty, lease: lease)

        XCTAssertEqual(result?.ocrDiagnostic, "preflight")
        XCTAssertEqual(conversation.captureCalls, 0)
        XCTAssertEqual(conversation.preflightCalls, 1)
    }

    func testLeaseTransferUsesDedicatedTransferer() async throws {
        let transferer = LiveTransferSpy()
        let driver = PDDLiveAutoReplyDriver(
            conversationDriver: LiveConversationSpy(), sender: LiveSenderSpy(),
            transferer: transferer
        )
        let lease = UIOperationLeaseRegistry().acquire(uid: "PDD-test")

        let result = try await driver.transferToAnyHuman(uid: "PDD-test", lease: lease)

        XCTAssertEqual(result, .transferred(agentLabel: "客服甲"))
        XCTAssertEqual(transferer.uids, ["PDD-test"])
    }
}

@MainActor
private final class LiveConversationSpy: PDDLiveConversationDriving {
    var visibleLocators: [PDDConversationLocator]?
    func visibleConversationsSnapshot() -> [PDDConversationLocator]? { visibleLocators }
    var captureCalls = 0
    var preflightCalls = 0

    func discover() async throws -> [AutoReplyDiscovery] { [] }
    func capture(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture {
        captureCalls += 1
        return result(uid: uid, marker: "capture")
    }
    func capture(
        uid: String, after cursor: AutoReplyCursor, lease: UIOperationLease
    ) async throws -> AutoReplyCapture {
        captureCalls += 1
        return result(uid: uid, marker: "capture")
    }
    func preflight(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture {
        preflightCalls += 1
        return result(uid: uid, marker: "preflight")
    }
    func preflight(
        uid: String, after cursor: AutoReplyCursor, lease: UIOperationLease
    ) async throws -> AutoReplyCapture {
        preflightCalls += 1
        return result(uid: uid, marker: "preflight")
    }
    func restoreConversationLocators(_ locators: [String: PDDConversationLocator]) {}
    func restoreConversationCaptureState(
        baselinedUIDs: Set<String>, knownServiceMessageIDsByUID: [String: Set<String>]
    ) {}
    func conversationLocatorsSnapshot() -> [String: PDDConversationLocator]? { [:] }
    func takeConversationDiagnostics() -> [PDDConversationDiagnostic] { [] }
    func restoreProvisionalReceipts(_ receipts: [String: [PDDProvisionalReceipt]]) {}
    func provisionalReceiptsSnapshot() -> [String: [PDDProvisionalReceipt]] { [:] }
    func restoreMessageSourceSelectorStates(_ states: [String: PDDMessageSourceSelectorState]) {}
    func messageSourceSelectorStatesSnapshot() -> [String: PDDMessageSourceSelectorState] { [:] }

    private func result(uid: String, marker: String) -> AutoReplyCapture {
        AutoReplyCapture(
            uid: uid,
            fullHistory: [],
            batch: nil,
            customerCursor: .empty,
            unexpectedServiceMessageIDs: [],
            ocrDiagnostic: marker
        )
    }
}

@MainActor
private final class LiveSenderSpy: PDDLiveReplySending {
    var images: [DatasetReplyImage] = []
    var deliveryID: UUID?
    var messageIDs = Set<String>()
    func send(uid: String, text: String, outgoingImages: [DatasetReplyImage], deliveryID: UUID,
              expectedCustomerCursor: AutoReplyCursor, expectedCustomerMessageIDs: Set<String>,
              lease: UIOperationLease?) async throws -> AutoReplyDeliveryResult {
        try XCTUnwrap(lease).validate()
        images = outgoingImages
        self.deliveryID = deliveryID
        messageIDs = expectedCustomerMessageIDs
        return .sent(serviceMessageID: "image-test")
    }
    func send(
        uid: String, text: String, expectedCustomerCursor: AutoReplyCursor
    ) async throws -> AutoReplyDeliveryResult {
        .sent(serviceMessageID: "test")
    }
}

@MainActor
private final class LiveTransferSpy: PDDLiveConversationTransferring {
    private(set) var uids: [String] = []
    func transferToAnyHuman(
        uid: String, lease: UIOperationLease
    ) async throws -> AutoReplyTransferResult {
        try lease.validate()
        uids.append(uid)
        return .transferred(agentLabel: "客服甲")
    }
}
