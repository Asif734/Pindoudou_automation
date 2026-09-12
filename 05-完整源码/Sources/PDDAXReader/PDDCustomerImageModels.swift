import Foundation

struct PDDCustomerImageCandidate: Equatable, Sendable {
    let messageID: String
    let frame: CGRect
}

enum PDDCustomerImageError: Error, Equatable, LocalizedError, Sendable {
    case invalidPreviewURL
    case previewNotFound
    case previewClosedBeforeURL
    case previewDownloadUnavailable
    case previewDownloadTimedOut
    case imageNoLongerClickable
    case clickFailed
    case invalidHTTPStatus(Int)
    case tooLarge
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .invalidPreviewURL: return "图片预览未提供有效的 HTTP(S) 原图 URL"
        case .previewNotFound: return "没有在时限内找到拼多多图片预览"
        case .previewClosedBeforeURL: return "图片预览已关闭，无法继续等待原图 URL"
        case .previewDownloadUnavailable: return "图片预览中找不到可用的下载控件"
        case .previewDownloadTimedOut: return "点击图片下载后未在时限内找到新文件"
        case .imageNoLongerClickable: return "客户图片在点击前已移位或离开可见聊天区域"
        case .clickFailed: return "无法双击客户图片"
        case .invalidHTTPStatus(let status): return "原图下载 HTTP 状态异常：\(status)"
        case .tooLarge: return "客户原图超过大小上限"
        case .invalidImageData: return "下载内容不是有效的 JPEG/PNG 图片"
        }
    }
}

@MainActor
protocol PDDCustomerImageResolving: AnyObject {
    func resolve(
        candidate: PDDCustomerImageCandidate,
        lease: UIOperationLease
    ) async throws -> URL
}

protocol PDDCustomerImageDownloading: Sendable {
    func download(
        sourceURL: URL,
        destinationDirectory: URL,
        messageID: String
    ) async throws -> AutoReplyImageAttachment
}
