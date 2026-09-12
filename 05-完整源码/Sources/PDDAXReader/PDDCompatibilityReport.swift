import Foundation

enum PDDCompatibilityStatus: String, Codable, Equatable, Sendable {
    case pass
    case degraded
    case fail
}

extension PDDCompatibilityStatus {
    var chineseLabel: String {
        switch self {
        case .pass: return "通过"
        case .degraded: return "降级"
        case .fail: return "失败"
        }
    }

    var englishLabel: String { rawValue.uppercased() }
}

enum PDDCompatibilityKind: String, Codable, Equatable, Sendable {
    case architecture
    case operatingSystem
    case accessibility
    case screenRecording
    case speech
    case pdd
    case python
    case knowledge
    case codex
    case videoCache
}

extension PDDCompatibilityKind {
    var chineseLabel: String {
        switch self {
        case .architecture: return "架构"
        case .operatingSystem: return "操作系统"
        case .accessibility: return "辅助功能"
        case .screenRecording: return "录屏"
        case .speech: return "语音识别"
        case .pdd: return "拼多多"
        case .python: return "Python"
        case .knowledge: return "知识库"
        case .codex: return "Codex"
        case .videoCache: return "视频缓存"
        }
    }

    var englishLabel: String {
        switch self {
        case .architecture: return "Architecture"
        case .operatingSystem: return "Operating system"
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .speech: return "Speech recognition"
        case .pdd: return "Pinduoduo"
        case .python: return "Python"
        case .knowledge: return "Knowledge base"
        case .codex: return "Codex"
        case .videoCache: return "Video cache"
        }
    }
}

struct PDDCompatibilityItem: Codable, Equatable, Sendable {
    let kind: PDDCompatibilityKind
    let status: PDDCompatibilityStatus
    let detail: String
}

struct PDDCompatibilityReport: Codable, Equatable, Sendable {
    let generatedAt: Date
    let items: [PDDCompatibilityItem]

    init(generatedAt: Date = Date(), items: [PDDCompatibilityItem]) {
        self.generatedAt = generatedAt
        self.items = items
    }

    var overallStatus: PDDCompatibilityStatus {
        if items.contains(where: { $0.status == .fail }) { return .fail }
        if items.contains(where: { $0.status == .degraded }) { return .degraded }
        return .pass
    }

    var summary: String {
        let passed = items.filter { $0.status == .pass }.count
        let degraded = items.filter { $0.status == .degraded }.count
        let failed = items.filter { $0.status == .fail }.count
        return BilingualText.lines(
            "兼容性：通过 \(passed) · 降级 \(degraded) · 失败 \(failed)",
            "Compatibility: \(passed) passed · \(degraded) degraded · \(failed) failed"
        )
    }

    func redactedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
