import CoreGraphics
import Foundation

struct PDDPixelImage: Equatable, Sendable {
    let width: Int
    let height: Int
    var rgba: [UInt8]

    init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    init?(cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.init(width: width, height: height, rgba: rgba)
    }
}

enum PDDRedDotDetector {
    static func targetIndexes<ID: Hashable>(
        image: PDDPixelImage,
        window: CGRect,
        rows: [PDDConversationRow<ID>]
    ) -> [Int] {
        guard image.width > 0,
              image.height > 0,
              image.width <= 20_000,
              image.height <= 20_000,
              image.rgba.count == image.width * image.height * 4,
              window.width > 0,
              window.height > 0 else { return [] }
        let scaleX = CGFloat(image.width) / window.width
        let scaleY = CGFloat(image.height) / window.height
        guard scaleX.isFinite, scaleY.isFinite,
              scaleX > 0, scaleY > 0,
              scaleX <= 10, scaleY <= 10 else { return [] }

        return rows.indices.filter { index in
            let row = rows[index]
            guard window.contains(row.frame), row.frame.height >= 30 else { return false }
            let rowHeight = row.frame.height
            let search = CGRect(
                x: row.frame.minX,
                y: row.frame.minY,
                width: rowHeight * 1.1,
                height: rowHeight
            )
            let x0 = max(0, Int((search.minX - window.minX) * scaleX))
            let x1 = min(image.width, Int(ceil((search.maxX - window.minX) * scaleX)))
            let y0 = max(0, Int((search.minY - window.minY) * scaleY))
            let y1 = min(image.height, Int(ceil((search.maxY - window.minY) * scaleY)))
            guard x0 < x1, y0 < y1 else { return false }

            func isRed(_ x: Int, _ y: Int) -> Bool {
                let offset = (y * image.width + x) * 4
                let red = Int(image.rgba[offset])
                let green = Int(image.rgba[offset + 1])
                let blue = Int(image.rgba[offset + 2])
                return red >= 185 && green < 100 && blue < 115
                    && red - green > 100 && red - blue > 85
            }

            var visited = Set<Int>()
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let key = y * image.width + x
                    guard !visited.contains(key), isRed(x, y) else { continue }
                    visited.insert(key)
                    var queue = [(x, y)]
                    var cursor = 0
                    var minX = x
                    var maxX = x
                    var minY = y
                    var maxY = y
                    while cursor < queue.count {
                        let (pixelX, pixelY) = queue[cursor]
                        cursor += 1
                        minX = min(minX, pixelX)
                        maxX = max(maxX, pixelX)
                        minY = min(minY, pixelY)
                        maxY = max(maxY, pixelY)
                        for (nextX, nextY) in [
                            (pixelX - 1, pixelY), (pixelX + 1, pixelY),
                            (pixelX, pixelY - 1), (pixelX, pixelY + 1)
                        ] where nextX >= x0 && nextX < x1 && nextY >= y0 && nextY < y1 {
                            let nextKey = nextY * image.width + nextX
                            if !visited.contains(nextKey), isRed(nextX, nextY) {
                                visited.insert(nextKey)
                                queue.append((nextX, nextY))
                            }
                        }
                    }
                    let width = CGFloat(maxX - minX + 1) / scaleX
                    let height = CGFloat(maxY - minY + 1) / scaleY
                    let centerX = (
                        CGFloat(minX + maxX) * 0.5 / scaleX + window.minX - row.frame.minX
                    ) / rowHeight
                    let centerY = (
                        CGFloat(minY + maxY) * 0.5 / scaleY + window.minY - row.frame.minY
                    ) / rowHeight
                    let density = CGFloat(queue.count) / CGFloat((maxX - minX + 1) * (maxY - minY + 1))
                    if centerX >= 0.62, centerX <= 0.93,
                       centerY >= 0.08, centerY <= 0.34,
                       width >= rowHeight * 0.07, width <= rowHeight * 0.23,
                       height >= rowHeight * 0.07, height <= rowHeight * 0.23,
                       width / height >= 0.65, width / height <= 1.5,
                       density >= 0.55,
                       minX > x0, maxX < x1 - 1, minY > y0, maxY < y1 - 1 {
                        return true
                    }
                }
            }
            return false
        }
    }
}

@MainActor
protocol PDDUnreadEvidenceDetecting: AnyObject {
    func unreadRows(in tree: PDDAXSemanticTree) async throws -> [PDDConversationRow<AXElementToken>]
}

@MainActor
final class PDDLiveUnreadEvidenceDetector: PDDUnreadEvidenceDetecting {
    private let capture: any PDDOCRCapturing
    private let requireConversationRows: Bool

    init(capture: (any PDDOCRCapturing)? = nil,
         requireConversationRows: Bool = false) {
        self.capture = capture ?? PDDWindowOCRCapture()
        self.requireConversationRows = requireConversationRows
    }

    func unreadRows(in tree: PDDAXSemanticTree) async throws -> [PDDConversationRow<AXElementToken>] {
        // Preserve the original Git version's discovery snapshot and AX tokens.
        // Re-reading the backend here can discard valid rows and remap tokens.
        let rows = try PDDAXControlSelection.conversationRows(in: tree.nodes)
        guard !rows.isEmpty else {
            if requireConversationRows { throw PDDUnreadDetectionError.conversationRowsUnavailable }
            return []
        }
        // The pixel algorithm uses fullWindowImage; chat-region OCR cropping is
        // unnecessary here and previously caused the confirmed traversal hang.
        let frame = try await capture.captureFullWindow()
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

enum PDDUnreadDetectionError: LocalizedError {
    case conversationRowsUnavailable

    var errorDescription: String? {
        BilingualText.lines(
            "无法读取拼多多会话列表，尚不能判断红点；请打开聊天页并刷新。未打开或回复任何客户。",
            "Pinduoduo's conversation list is unavailable through Accessibility; unread status is unknown. Open the Chat page and refresh. No customer was opened or replied to."
        )
    }
}
