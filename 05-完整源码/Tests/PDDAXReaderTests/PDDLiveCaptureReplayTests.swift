import XCTest
@testable import PDDAXReader

@MainActor
final class PDDLiveCaptureReplayTests: XCTestCase {
    func testRecordedEmptyHistoryWithComposerRetainsTaskAndRequestsRecovery() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/20261112-empty-history.json")
        let diagnostic = try JSONDecoder().decode(PDDAXCaptureDiagnostic.self, from: Data(contentsOf: fixture))
        let tree = diagnostic.replay
        XCTAssertEqual(PDDAXControlSelection.composerCandidates(in: tree.nodes).count, 1)
        XCTAssertEqual(PDDConversationSnapshotLocator.activeCount(in: tree.rootSnapshot), 1)
        XCTAssertTrue(PDDChatParser.parse(root: tree.rootSnapshot).messages.isEmpty)
        XCTAssertFalse(PDDAXCaptureSurface.hasReadableMessages(in: tree))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = ReplayBackend(tree: tree)
        let date = Date(timeIntervalSince1970: 100)
        let locator = try XCTUnwrap(diagnostic.currentLocator)
        var task = PDDPendingDiscovery(locator: locator, occurrence: 0, unread: true, at: date.addingTimeInterval(-60))
        task.attempts = 3
        try PDDPendingDiscoveryStore(root: root).save([task])
        let driver = PDDAXConversationDriver(backend: backend, chatStore: .init(rootDirectory: root),
            allowedUIDs: nil, unreadEvidence: backend, now: { date })
        let result = try await driver.discover()
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(backend.refreshes, 1, "A composer cannot suppress recovery of the missing history")
        XCTAssertEqual(try PDDPendingDiscoveryStore(root: root).load().count, 1)
        XCTAssertTrue(try PDDVerifiedCaptureInbox(root: root).entries().isEmpty)
        XCTAssertTrue(backend.writes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("message-receipts.json").path))
    }
}

@MainActor private final class ReplayBackend: PDDAXBackend, PDDUnreadEvidenceDetecting {
    let tree: PDDAXSemanticTree
    var refreshes = 0
    var writes: [String] = []
    init(tree: PDDAXSemanticTree) { self.tree = tree }
    func requestAccessibilityRefresh() throws { refreshes += 1 }
    func readSemanticTree() throws -> PDDAXSemanticTree { tree }
    func performPress(_ id: AXElementToken) throws {}
    func setValue(_ text: String, on id: AXElementToken) throws { writes.append(text) }
    func value(of id: AXElementToken) throws -> String { "" }
    func unreadRows(in tree: PDDAXSemanticTree) async throws -> [PDDConversationRow<AXElementToken>] { [] }
}
