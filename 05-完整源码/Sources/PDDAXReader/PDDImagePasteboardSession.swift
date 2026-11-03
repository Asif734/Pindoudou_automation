import AppKit
import Foundation

/// Restores the previous clipboard only if it has not been changed by the user.
@MainActor
final class PDDImagePasteboardSession {
    private let pasteboard: NSPasteboard
    private var original: [[NSPasteboard.PasteboardType: Data]]?
    private var writtenChangeCount: Int?

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func writeImage(_ file: URL) throws {
        guard let image = NSImage(contentsOf: file), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw DatasetReplyImageError.invalid(file.lastPathComponent)
        }
        if original == nil {
            original = try (pasteboard.pasteboardItems ?? []).map { item in
                var saved: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types {
                    guard let data = item.data(forType: type) else {
                        throw DatasetReplyImageError.invalid("无法备份剪贴板，停止图片粘贴")
                    }
                    saved[type] = data
                }
                return saved
            }
        }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        guard pasteboard.writeObjects([item]) else {
            writtenChangeCount = pasteboard.changeCount
            restore()
            throw DatasetReplyImageError.invalid("写入图片剪贴板失败")
        }
        writtenChangeCount = pasteboard.changeCount
    }

    func restore() {
        defer { original = nil; writtenChangeCount = nil }
        guard let original, writtenChangeCount == pasteboard.changeCount else { return }
        pasteboard.clearContents()
        let items = original.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    func validateImageClipboard() throws {
        guard let writtenChangeCount, writtenChangeCount == pasteboard.changeCount else {
            throw DatasetReplyImageError.invalid("剪贴板已变化，停止图片粘贴")
        }
    }
}
