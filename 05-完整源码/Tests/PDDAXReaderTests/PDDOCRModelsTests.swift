import CoreGraphics
import XCTest
@testable import PDDAXReader

final class PDDOCRModelsTests: XCTestCase {
    func testNormalizerCollapsesWhitespaceAndCompatibilityCharactersWithoutDroppingPunctuation() {
        XCTAssertEqual(PDDOCRNormalizer.normalize("  ＡＢＣ\n  你好， 世界！ "), "ABC 你好, 世界!")
    }

    func testStableIDIncludesOccurrenceSoEqualVisibleMessagesStayDistinct() {
        let first = PDDOCRMessageID.make(
            uid: "GZC-000001", sender: .customer,
            timestamp: "2026-08-29 09:31:52", text: "你好", occurrence: 0
        )
        let second = PDDOCRMessageID.make(
            uid: "GZC-000001", sender: .customer,
            timestamp: "2026-08-29 09:31:52", text: "你好", occurrence: 1
        )
        XCTAssertEqual(first, "ocr-f2e09f3fd3c463086ca3013f15da4bf8357ab5ae8d5da4eaf5bd51cea3db94ec")
        XCTAssertNotEqual(first, second)
    }
}
