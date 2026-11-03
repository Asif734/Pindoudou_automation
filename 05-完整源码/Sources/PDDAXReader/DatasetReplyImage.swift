import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An immutable, validated copy of an image selected from the local knowledge base.
struct DatasetReplyImage: Codable, Equatable, Sendable {
    let datasetRelativePath: String
    let localURL: URL
    let sha256: String
    let mimeType: String
    let byteCount: Int

    func verify(in root: URL) throws {
        let directory = root.appendingPathComponent("outgoing-images").resolvingSymlinksInPath()
        guard localURL.isFileURL,
              localURL.resolvingSymlinksInPath().deletingLastPathComponent() == directory,
              let data = try? Data(contentsOf: localURL), data.count == byteCount,
              Self.digest(data) == sha256 else { throw DatasetReplyImageError.invalid(datasetRelativePath) }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum DatasetReplyImageError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let path): return "回复图片无效或不在批准的知识库目录：\(path)" }
    }
}

struct DatasetReplyImageResolver {
    let datasetRoot: URL
    let outputRoot: URL

    func resolve(_ paths: [String]) throws -> [DatasetReplyImage] {
        guard paths.count <= 3 else { throw DatasetReplyImageError.invalid("最多三张图片") }
        let root = datasetRoot.resolvingSymlinksInPath().standardizedFileURL
        var seen = Set<String>()
        return try paths.compactMap { path in
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !path.contains(":"), !path.contains("\\"),
                  !components.contains(".."), !components.contains("."),
                  !components.contains(""),
                  path.hasPrefix("assets/") || path.hasPrefix("sources/user_uploads/") else {
                throw DatasetReplyImageError.invalid(path)
            }
            let source = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            let approved = path.hasPrefix("assets/") ? "assets" : "sources/user_uploads"
            let approvedRoot = root.appendingPathComponent(approved).standardizedFileURL
            guard source.path.hasPrefix(approvedRoot.path + "/"),
                  source.path.hasPrefix(root.path + "/"),
                  ["png", "jpg", "jpeg", "webp"].contains(source.pathExtension.lowercased()),
                  let size = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]).fileSize,
                  size > 0, size <= 10 * 1024 * 1024,
                  try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw DatasetReplyImageError.invalid(path)
            }
            let data = try Data(contentsOf: source)
            guard data.count == size,
                  let image = CGImageSourceCreateWithData(data as CFData, nil),
                  let typeID = CGImageSourceGetType(image),
                  let type = UTType(typeID as String),
                  [UTType.png, .jpeg, .webP].contains(type),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16_384, height <= 16_384,
                  width * height <= 40_000_000,
                  CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else {
                throw DatasetReplyImageError.invalid(path)
            }
            let hash = DatasetReplyImage.digest(data)
            guard seen.insert(hash).inserted else { return nil }
            let directory = outputRoot.appendingPathComponent("outgoing-images", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(hash + "." + (type.preferredFilenameExtension ?? "png"))
            try data.write(to: destination, options: .atomic)
            return DatasetReplyImage(datasetRelativePath: path, localURL: destination,
                sha256: hash, mimeType: type.preferredMIMEType ?? "image/png", byteCount: data.count)
        }
    }

    static var prompt: String {
        """
        <outgoing_dataset_images>
        本应用可以发送本地知识库图片。客户需要样例、外观或图解时，直接阅读相关文档和图片，确认图片与当前型号和问题相符，再填入 image_paths。
        image_paths 是最多三项的数组，路径必须相对于知识库根目录且位于 assets/ 或 sources/user_uploads/，只支持 PNG/JPEG/WebP；不用图片时为 []。
        必须先查看实际文件、确认内容，不能猜测文件名、杜撰图片、选择头像或用不相符型号代替。图片由应用实际上传，reply_text 只写简短说明，不写本地路径，也不要因旧历史里说不能发图而继续拒绝。
        M880 纸卡相关参考（仍须阅读文档确认适用性并查看原图）：sources/user_uploads/attendance_machine/tht_official_attendance_card_mark.png；assets/technical_media/attendance_machine/attendance_settings_card/time_card_layout_2_52000ms.png。
        这些是纸卡样例/布局图，不是机器外观照片；应准确说明图示用途。不存在适用图片时不要承诺已发送。转接回复 image_paths=[]。
        </outgoing_dataset_images>
        """
    }
}
