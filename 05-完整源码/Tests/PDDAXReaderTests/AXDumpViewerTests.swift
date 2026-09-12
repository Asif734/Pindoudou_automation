import AppKit
import XCTest
@testable import PDDAXReader

@MainActor
final class AXDumpViewerTests: XCTestCase {
    func testDisplaysCompleteMultiMegabyteDumpWithoutWrappingOrEditing() {
        let line = "AXStaticText @AXValue: 用户消息内容\n"
        let dump = "拼多多用户 AX 完整读取结果\n" + String(repeating: line, count: 80_000)
        let viewer = AXDumpViewer()

        viewer.display(dump)

        XCTAssertEqual(viewer.textView.string, dump)
        XCTAssertGreaterThan(viewer.textView.string.utf8.count, 2_000_000)
        XCTAssertFalse(viewer.textView.isEditable)
        XCTAssertFalse(viewer.textView.isRichText)
        XCTAssertTrue(viewer.hasVerticalScroller)
        XCTAssertTrue(viewer.hasHorizontalScroller)
        XCTAssertTrue(viewer.textView.isHorizontallyResizable)
        XCTAssertFalse(viewer.textView.textContainer?.widthTracksTextView ?? true)
    }
}
