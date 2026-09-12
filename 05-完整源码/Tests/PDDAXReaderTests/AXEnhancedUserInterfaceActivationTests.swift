import ApplicationServices
import XCTest
@testable import PDDAXReader

final class AXEnhancedUserInterfaceActivationTests: XCTestCase {
    func testEnableRequestsChromiumEnhancedAccessibilityMode() {
        var receivedAttribute: String?
        var receivedValue: Bool?
        let activation = AXEnhancedUserInterfaceActivation(
            readBoolean: { _ in false },
            setBoolean: { attribute, value in
                receivedAttribute = attribute
                receivedValue = value
                return .success
            }
        )

        let changed = activation.enableIfNeeded()

        XCTAssertTrue(changed)
        XCTAssertEqual(receivedAttribute, "AXEnhancedUserInterface")
        XCTAssertEqual(receivedValue, true)
    }

    func testAlreadyEnabledModeDoesNotTriggerChromiumTreeRebuild() {
        var writeCount = 0
        let activation = AXEnhancedUserInterfaceActivation(
            readBoolean: { attribute in
                XCTAssertEqual(attribute, "AXEnhancedUserInterface")
                return true
            },
            setBoolean: { _, _ in
                writeCount += 1
                return .success
            }
        )

        let changed = activation.enableIfNeeded()

        XCTAssertFalse(changed)
        XCTAssertEqual(writeCount, 0)
    }

    func testRecoveryRequestReassertsEnabledModeEvenWhenChromiumReportsItEnabled() {
        var writes: [(String, Bool)] = []
        let activation = AXEnhancedUserInterfaceActivation(
            readBoolean: { _ in true },
            setBoolean: { attribute, value in
                writes.append((attribute, value))
                return .success
            }
        )

        let accepted = activation.requestEnable()

        XCTAssertTrue(accepted)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.0, "AXEnhancedUserInterface")
        XCTAssertEqual(writes.first?.1, true)
    }
}
