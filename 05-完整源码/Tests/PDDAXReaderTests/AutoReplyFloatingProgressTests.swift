import XCTest
@testable import PDDAXReader

@MainActor
final class AutoReplyFloatingProgressTests: XCTestCase {
    func testRunningAutomationKeepsProgressPanelInteractive() {
        let panel = AutoReplyFloatingProgressPanel()

        panel.setAutomationActive(true)

        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.isMovable)
        XCTAssertTrue(panel.isMovableByWindowBackground)
        XCTAssertTrue(panel.styleMask.contains(.closable))
        XCTAssertTrue(panel.styleMask.contains(.resizable))
    }
}
