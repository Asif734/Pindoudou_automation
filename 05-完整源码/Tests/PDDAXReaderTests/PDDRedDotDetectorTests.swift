import CoreGraphics
import XCTest
@testable import PDDAXReader

final class PDDRedDotDetectorTests: XCTestCase {
    func testPixelDotSelectsOnlyMatchingAXRowAtRetinaScale() {
        let window = CGRect(x: 700, y: 100, width: 1200, height: 800)
        let rows = [
            PDDConversationRow(rowID: "first", visibleLabel: "客户甲", frame: CGRect(x: 730, y: 220, width: 260, height: 52)),
            PDDConversationRow(rowID: "second", visibleLabel: "客户乙", frame: CGRect(x: 730, y: 272, width: 260, height: 52))
        ]
        var image = PDDPixelImage(
            width: 2400,
            height: 1600,
            rgba: [UInt8](repeating: 255, count: 2400 * 1600 * 4)
        )
        paintRedDot(&image, x: 138, y: 366, radius: 7)

        XCTAssertEqual(
            PDDRedDotDetector.targetIndexes(image: image, window: window, rows: rows),
            [1]
        )
    }

    func testLargeRedAvatarArtworkIsNotUnreadDot() {
        let window = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let rows = [
            PDDConversationRow(rowID: "row", visibleLabel: "客户", frame: CGRect(x: 30, y: 120, width: 260, height: 52))
        ]
        var image = PDDPixelImage(
            width: 1200,
            height: 800,
            rgba: [UInt8](repeating: 255, count: 1200 * 800 * 4)
        )
        paintRedDot(&image, x: 65, y: 146, radius: 14)

        XCTAssertTrue(PDDRedDotDetector.targetIndexes(image: image, window: window, rows: rows).isEmpty)
    }

    func testMapsRedDotWithIndependentXAndYCaptureScales() {
        let window = CGRect(x: 700, y: 100, width: 1200, height: 800)
        let rows = [
            PDDConversationRow(
                rowID: "row", visibleLabel: "客户",
                frame: CGRect(x: 730, y: 272, width: 260, height: 52)
            )
        ]
        var image = PDDPixelImage(
            width: 2400,
            height: 1200,
            rgba: [UInt8](repeating: 255, count: 2400 * 1200 * 4)
        )
        paintRedDot(&image, x: 138, y: 275, radius: 7)

        XCTAssertEqual(
            PDDRedDotDetector.targetIndexes(image: image, window: window, rows: rows),
            [0]
        )
    }

    private func paintRedDot(_ image: inout PDDPixelImage, x: Int, y: Int, radius: Int) {
        for py in max(0, y - radius)...min(image.height - 1, y + radius) {
            for px in max(0, x - radius)...min(image.width - 1, x + radius)
            where (px - x) * (px - x) + (py - y) * (py - y) <= radius * radius {
                let offset = (py * image.width + px) * 4
                image.rgba[offset] = 245
                image.rgba[offset + 1] = 20
                image.rgba[offset + 2] = 25
                image.rgba[offset + 3] = 255
            }
        }
    }
}
