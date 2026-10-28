// Original unread detector from Git commit 8d19661; only the type name is changed.
import CoreGraphics
import Foundation
@testable import PDDAXReader

@MainActor
final class OriginalPDDLiveUnreadEvidenceDetector: PDDUnreadEvidenceDetecting {
    private let capture: any PDDOCRCapturing

    init(capture: (any PDDOCRCapturing)? = nil) {
        self.capture = capture ?? PDDWindowOCRCapture()
    }

    func unreadRows(in tree: PDDAXSemanticTree) async throws -> [PDDConversationRow<AXElementToken>] {
        let rows = try PDDAXControlSelection.conversationRows(in: tree.nodes)
        guard !rows.isEmpty else { return [] }
        let frame = try await capture.capture()
        guard let pixels = PDDPixelImage(cgImage: frame.fullWindowImage) else {
            throw PDDOCRError.capture("无法读取红点截图像素")
        }
        return PDDRedDotDetector.targetIndexes(
            image: pixels,
            window: frame.windowFrame,
            rows: rows
        ).map { rows[$0] }
    }
}
