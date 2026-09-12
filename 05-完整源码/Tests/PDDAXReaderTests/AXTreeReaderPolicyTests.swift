import XCTest
@testable import PDDAXReader

final class AXTreeReaderPolicyTests: XCTestCase {
    func testRejectsNodeBeyondMaximumDepth() {
        var policy = AXTraversalPolicy<Int>(maxDepth: 2, maxNodes: 10)

        XCTAssertEqual(policy.enter(identifier: 1, depth: 3), .depthLimit)
    }

    func testRejectsNodeAfterMaximumCount() {
        var policy = AXTraversalPolicy<Int>(maxDepth: 10, maxNodes: 2)

        XCTAssertEqual(policy.enter(identifier: 1, depth: 0), .proceed)
        XCTAssertEqual(policy.enter(identifier: 2, depth: 1), .proceed)
        XCTAssertEqual(policy.enter(identifier: 3, depth: 1), .nodeLimit)
    }

    func testHashCollisionDoesNotHideDifferentNodesButExactDuplicateIsRejected() {
        var policy = AXTraversalPolicy<CollidingIdentifier>(maxDepth: 10, maxNodes: 10)

        XCTAssertEqual(policy.enter(identifier: CollidingIdentifier(value: 1), depth: 0), .proceed)
        XCTAssertEqual(policy.enter(identifier: CollidingIdentifier(value: 2), depth: 1), .proceed)
        XCTAssertEqual(policy.enter(identifier: CollidingIdentifier(value: 1), depth: 1), .cycle)
    }

    func testDepthLimitDoesNotConsumeNodeBudget() {
        var policy = AXTraversalPolicy<Int>(maxDepth: 0, maxNodes: 1)

        XCTAssertEqual(policy.enter(identifier: 1, depth: 1), .depthLimit)
        XCTAssertEqual(policy.enter(identifier: 2, depth: 0), .proceed)
    }

    func testSnapshotRootPrefersFocusedWindowOverAuxiliaryApplicationChildren() {
        let selected = AXSnapshotRootPreference.select(
            focusedWindow: "focused-chat-window",
            mainWindow: "main-window",
            application: "application-root"
        )

        XCTAssertEqual(selected, "focused-chat-window")
    }

    func testSnapshotRootFallsBackToMainWindowThenApplication() {
        XCTAssertEqual(
            AXSnapshotRootPreference.select(
                focusedWindow: nil as String?,
                mainWindow: "main-window",
                application: "application-root"
            ),
            "main-window"
        )
        XCTAssertEqual(
            AXSnapshotRootPreference.select(
                focusedWindow: nil as String?,
                mainWindow: nil,
                application: "application-root"
            ),
            "application-root"
        )
    }

    func testChatParsingProfileReadsOnlyParserInputs() {
        let profile = AXAttributeReadProfile.chatParsing

        XCTAssertTrue(profile.prefersNavigationChildren)
        XCTAssertFalse(profile.needsAttributeDiscovery)
        XCTAssertFalse(profile.readsActions)
        XCTAssertTrue(profile.usesBatchedReads)
        XCTAssertEqual(
            Set(profile.multipleAttributeNames),
            Set([
                "AXRole",
                "AXValue",
                "AXTitle",
                "AXDescription",
                "AXURL",
                "AXDOMClassList",
                "AXDOMIdentifier",
                "ChromeAXNodeId",
                "AXChildrenInNavigationOrder",
                "AXChildren"
            ])
        )
        XCTAssertTrue(profile.shouldRead("AXValue"))
        XCTAssertTrue(profile.shouldRead("AXDOMClassList"))
        XCTAssertTrue(profile.shouldRead("AXDOMIdentifier"))
        XCTAssertTrue(profile.shouldRead("ChromeAXNodeId"))
        XCTAssertFalse(profile.shouldRead("AXEndTextMarker"))
        XCTAssertFalse(profile.shouldRead("AXSelectedTextMarkerRange"))
        XCTAssertFalse(profile.shouldRead("AXRows"))
    }

    func testFullProfileKeepsNonStructuralAttributes() {
        XCTAssertTrue(AXAttributeReadProfile.full.needsAttributeDiscovery)
        XCTAssertTrue(AXAttributeReadProfile.full.readsActions)
        XCTAssertFalse(AXAttributeReadProfile.full.usesBatchedReads)
        XCTAssertTrue(AXAttributeReadProfile.full.multipleAttributeNames.isEmpty)
        XCTAssertFalse(AXAttributeReadProfile.full.prefersNavigationChildren)
        XCTAssertTrue(AXAttributeReadProfile.full.shouldRead("AXEndTextMarker"))
        XCTAssertFalse(AXAttributeReadProfile.full.shouldRead("AXChildren"))
        XCTAssertFalse(AXAttributeReadProfile.full.shouldRead("AXRole"))
    }
}

private struct CollidingIdentifier: Hashable {
    let value: Int

    func hash(into hasher: inout Hasher) {
        hasher.combine(0)
    }
}
