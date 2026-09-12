import XCTest
@testable import PDDAXReader

final class PDDAppModeTests: XCTestCase {
    func testBundleIdentifiersRouteToFourIndependentModes() {
        XCTAssertEqual(PDDAppMode(bundleIdentifier: "com.scy.pdd-ax-reader"), .reader)
        XCTAssertEqual(PDDAppMode(bundleIdentifier: "com.scy.pdd-ax-single-parse-probe"), .singleParse)
        XCTAssertEqual(PDDAppMode(bundleIdentifier: "com.scy.pdd-auto-reply"), .autoReply)
        XCTAssertEqual(
            PDDAppMode(bundleIdentifier: "com.scy.pdd-auto-reply.task-isolation-candidate"),
            .taskIsolationCandidate
        )
    }
}
