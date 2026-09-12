import Foundation

enum PDDCustomerVideoError: Error, Equatable, LocalizedError, Sendable {
    case cacheUnavailable
    case timedOutNoCacheChange
    case timedOutWithoutVideoMarker(changedFiles: Int)
    case clickFailed
    case downloadRejected
    case downloadFailed
    case invalidMedia
    case missingVideoTrack

    var errorDescription: String? {
        switch self {
        case .cacheUnavailable: return "没有找到拼多多视频缓存"
        case .timedOutNoCacheChange: return "等待视频时缓存没有变化"
        case .timedOutWithoutVideoMarker(let count): return "缓存有\(count)项变化但没有视频地址"
        case .clickFailed: return "无法打开客户视频"
        case .downloadRejected: return "视频服务器拒绝下载或返回非视频内容"
        case .downloadFailed: return "视频下载失败"
        case .invalidMedia: return "下载内容不是有效的 MP4 视频"
        case .missingVideoTrack: return "视频文件没有可读取的视频轨道"
        }
    }
}

struct PDDVideoFileSummary: Codable, Equatable, Sendable {
    let byteCount: Int64
    let sha256: String
    let durationSeconds: Double
    let width: Int
    let height: Int
    let videoCodec: String
    let audioCodec: String?
}

@MainActor
protocol PDDCustomerVideoResolving: AnyObject {
    func resolve(candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws -> URL
}

protocol PDDCustomerVideoDownloading: Sendable {
    func download(
        sourceURL: URL,
        destinationDirectory: URL,
        messageID: String
    ) async throws -> AutoReplyVideoAttachment
}
