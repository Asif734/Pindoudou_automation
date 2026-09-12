import CoreGraphics
import XCTest
@testable import PDDAXReader

@MainActor
final class PDDOCRCaptureTests: XCTestCase {
    func testUsesAXChatPanelFrameInsteadOfWholeWindowRatio() {
        let crop = PDDOCRCropGeometry.pixelCrop(
            imageSize: CGSize(width: 2400, height: 1600),
            windowFrame: CGRect(x: 100, y: 100, width: 1200, height: 800),
            chatPanelFrame: CGRect(x: 430, y: 220, width: 700, height: 560)
        )

        XCTAssertEqual(crop, CGRect(x: 660, y: 240, width: 1400, height: 1120))
    }

    func testInvalidAXChatPanelFrameUsesExistingFallback() {
        XCTAssertEqual(
            PDDOCRCropGeometry.pixelCrop(
                imageSize: CGSize(width: 2600, height: 1402),
                windowFrame: CGRect(x: 0, y: 0, width: 1300, height: 701),
                chatPanelFrame: CGRect(x: 2000, y: 2000, width: 10, height: 10)
            ),
            CGRect(x: 515, y: 421, width: 1565, height: 729)
        )
    }

    func testFallbackChatCropIncludesBottomBubbleAboveComposerAtTwoX() {
        let crop = PDDOCRCropGeometry.fallbackPixelCrop(
            imageSize: CGSize(width: 2600, height: 1402)
        )
        XCTAssertEqual(crop, CGRect(x: 515, y: 421, width: 1565, height: 729))
    }

    func testCurrentWorkbenchCropIncludesLeftCustomerAndRightServiceColumns() {
        let crop = PDDOCRCropGeometry.fallbackPixelCrop(
            imageSize: CGSize(width: 1920, height: 1170)
        )
        XCTAssertEqual(crop, CGRect(x: 380, y: 351, width: 1156, height: 608))
        XCTAssertLessThanOrEqual(380, crop?.minX ?? .greatestFiniteMagnitude)
        XCTAssertGreaterThanOrEqual(crop?.maxX ?? 0, 1_535)
        XCTAssertGreaterThanOrEqual(crop?.maxY ?? 0, 959)
    }

    func testFallbackCropRejectsEmptyImage() {
        XCTAssertNil(PDDOCRCropGeometry.fallbackPixelCrop(imageSize: .zero))
    }

    func testForegroundActivationRequestsRaisesAndWaitsForTargetBeforeSettling() async throws {
        var requested = 0
        var raised = 0
        var frontmostChecks = 0
        var sleeps: [UInt64] = []

        try await PDDWindowForegroundActivation.run(
            request: { requested += 1; return true },
            raise: { raised += 1; return true },
            isFrontmost: {
                frontmostChecks += 1
                return frontmostChecks >= 4
            },
            sleep: { sleeps.append($0) }
        )

        XCTAssertEqual(requested, 1)
        XCTAssertEqual(raised, 1)
        XCTAssertEqual(frontmostChecks, 4)
        XCTAssertEqual(sleeps, [50_000_000, 50_000_000, 150_000_000])
    }

    func testForegroundActivationDoesNotStealFocusWhenTargetIsAlreadyFrontmost() async throws {
        var requested = false
        var raised = false

        try await PDDWindowForegroundActivation.run(
            request: { requested = true; return true },
            raise: { raised = true; return true },
            isFrontmost: { true },
            sleep: { _ in }
        )

        XCTAssertFalse(requested)
        XCTAssertFalse(raised)
    }

    func testForegroundActivationFailsWhenExactWindowCannotBeRaised() async {
        do {
            try await PDDWindowForegroundActivation.run(
                request: { true },
                raise: { false },
                isFrontmost: { false },
                sleep: { _ in }
            )
            XCTFail("expected activation failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("前台"))
        }
    }
}
