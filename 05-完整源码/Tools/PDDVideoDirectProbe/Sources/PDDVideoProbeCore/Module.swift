import AVFoundation
import CryptoKit
import Foundation

public struct PDDVideoAXNode: Equatable, Sendable {
    public let id: Int
    public let parentID: Int?
    public let role: String
    public let value: String?
    public let title: String?
    public let description: String?
    public let domIdentifier: String?
    public let domClasses: Set<String>
    public let frame: CGRect
    public let isHidden: Bool

    public init(
        id: Int,
        parentID: Int?,
        role: String,
        value: String?,
        title: String?,
        description: String?,
        domIdentifier: String?,
        domClasses: Set<String>,
        frame: CGRect,
        isHidden: Bool = false
    ) {
        self.id = id
        self.parentID = parentID
        self.role = role
        self.value = value
        self.title = title
        self.description = description
        self.domIdentifier = domIdentifier
        self.domClasses = domClasses
        self.frame = frame
        self.isHidden = isHidden
    }
}

public struct PDDVideoAXCandidate: Equatable, Sendable {
    public let messageID: String
    public let frame: CGRect

    public init(messageID: String, frame: CGRect) {
        self.messageID = messageID
        self.frame = frame
    }
}

public enum PDDVideoForegroundActivation {
    public static func run(
        request: () async throws -> Bool,
        raise: () -> Bool,
        isFrontmost: () -> Bool,
        sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async throws {
        if isFrontmost() { return }
        guard try await request(), raise() else {
            throw PDDVideoProbeError.applicationActivationFailed
        }
        for attempt in 0...20 {
            if isFrontmost() {
                await sleep(.milliseconds(150))
                return
            }
            if attempt < 20 { await sleep(.milliseconds(50)) }
        }
        throw PDDVideoProbeError.applicationActivationFailed
    }
}

public enum PDDVideoAXCandidateSelector {
    public static func latestCustomerVideo(
        in nodes: [PDDVideoAXNode],
        isComplete: Bool = true
    ) -> PDDVideoAXCandidate? {
        guard isComplete else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var candidates: [(candidate: PDDVideoAXCandidate, sequence: Int?, visualOrder: CGFloat)] = []

        var markerNodes = nodes.filter(isVideoMarker)
        for durationNode in nodes where isVideoDuration(durationNode) {
            guard let thumbnail = nodes.first(where: { imageNode in
                isThumbnail(imageNode)
                    && belongsToSameMessage(durationNode, imageNode, byID: byID)
                    && imageNode.frame.contains(
                        CGPoint(x: durationNode.frame.midX, y: durationNode.frame.midY)
                    )
            }) else { continue }
            markerNodes.append(thumbnail)
        }

        for node in markerNodes {
            var cursor: PDDVideoAXNode? = node
            var messageID: String?
            var isMessage = false
            var isCustomer = false
            var isService = false
            var isHidden = node.isHidden
            var messageViewport: CGRect?
            var visited = Set<Int>()

            while let current = cursor, visited.insert(current.id).inserted {
                let classes = Set(current.domClasses.map { $0.lowercased() })
                isMessage = isMessage || classes.contains("onemsg")
                isCustomer = isCustomer || classes.contains("buyer-item")
                isService = isService || classes.contains("cs-item")
                isHidden = isHidden || current.isHidden
                if messageViewport == nil,
                   (classes.contains("msg-list") || current.domIdentifier == "msgListContainer"),
                   !current.frame.isEmpty {
                    messageViewport = current.frame
                }
                if messageID == nil, let identifier = current.domIdentifier,
                   identifier.hasPrefix("middlePanel_list_") {
                    messageID = identifier
                }
                cursor = current.parentID.flatMap { byID[$0] }
            }

            let clickFrame = node.frame
            guard isMessage, isCustomer, !isService, !isHidden,
                  clickFrame.width >= 12, clickFrame.height >= 12,
                  let messageID, let messageViewport,
                  messageViewport.contains(CGPoint(x: clickFrame.midX, y: clickFrame.midY)) else { continue }
            let suffix = messageID.dropFirst("middlePanel_list_".count)
            candidates.append((
                PDDVideoAXCandidate(messageID: messageID, frame: clickFrame),
                Int(suffix),
                clickFrame.maxY
            ))
        }
        return candidates.max { lhs, rhs in
            switch (lhs.sequence, rhs.sequence) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return false
            case (nil, _?): return true
            default: return lhs.visualOrder < rhs.visualOrder
            }
        }?.candidate
    }

    private static func isVideoMarker(_ node: PDDVideoAXNode) -> Bool {
        node.domClasses.contains { rawClass in
            let value = rawClass.lowercased()
            return value.contains("video") && !value.contains("avatar")
        }
    }

    private static func isVideoDuration(_ node: PDDVideoAXNode) -> Bool {
        let text = [node.value, node.title, node.description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let text else { return false }
        return text.range(of: #"^(?:\d{1,2}:)?\d{1,2}:\d{2}$"#, options: .regularExpression) != nil
    }

    private static func isThumbnail(_ node: PDDVideoAXNode) -> Bool {
        let classes = node.domClasses.map { $0.lowercased() }
        guard !classes.contains(where: { $0.contains("avatar") }),
              node.frame.width >= 40, node.frame.height >= 40 else { return false }
        if node.role.caseInsensitiveCompare("AXImage") == .orderedSame { return true }
        return [node.value, node.title, node.description]
            .compactMap { $0?.lowercased() }
            .contains { text in
                [".jpg", ".jpeg", ".png", ".webp"].contains { text.contains($0) }
            }
    }

    private static func belongsToSameMessage(
        _ lhs: PDDVideoAXNode,
        _ rhs: PDDVideoAXNode,
        byID: [Int: PDDVideoAXNode]
    ) -> Bool {
        messageIdentifier(for: lhs, byID: byID) == messageIdentifier(for: rhs, byID: byID)
    }

    private static func messageIdentifier(
        for node: PDDVideoAXNode,
        byID: [Int: PDDVideoAXNode]
    ) -> String? {
        var cursor: PDDVideoAXNode? = node
        var visited = Set<Int>()
        while let current = cursor, visited.insert(current.id).inserted {
            if let identifier = current.domIdentifier,
               identifier.hasPrefix("middlePanel_list_") {
                return identifier
            }
            cursor = current.parentID.flatMap { byID[$0] }
        }
        return nil
    }
}

public struct PDDVideoAXCandidateWaiter: Sendable {
    private let pollInterval: Duration

    public init(pollInterval: Duration = .milliseconds(200)) {
        self.pollInterval = pollInterval
    }

    public func wait(
        timeout: Duration,
        scan: @Sendable () async throws -> PDDVideoAXCandidate?
    ) async throws -> PDDVideoAXCandidate {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if let candidate = try await scan() { return candidate }
            try await Task.sleep(for: pollInterval)
        }
        throw PDDVideoProbeError.videoMessageNotFound
    }
}

public enum PDDVideoCacheLocator {
    public static func findCacheDataDirectories(inCEFRoot root: URL) throws -> [URL] {
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let candidates = children.compactMap { profile -> URL? in
            let name = profile.lastPathComponent
            guard name == "cef_default" || (!name.isEmpty && name.allSatisfy(\.isNumber)) else {
                return nil
            }
            let cacheData = profile.appendingPathComponent("Cache/Cache_Data", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cacheData.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return cacheData
        }
        guard !candidates.isEmpty else { throw PDDVideoProbeError.cacheUnavailable }
        return candidates.sorted { $0.path < $1.path }
    }

    public static func findCacheDataDirectory(inCEFRoot root: URL) throws -> URL {
        let children = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let candidates = children.compactMap { profile -> (URL, Date)? in
            guard !profile.lastPathComponent.isEmpty,
                  profile.lastPathComponent.allSatisfy(\.isNumber) else { return nil }
            let cacheData = profile.appendingPathComponent("Cache/Cache_Data", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cacheData.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            let modified = (try? profile.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (cacheData, modified)
        }
        guard let selected = candidates.max(by: { $0.1 < $1.1 })?.0 else {
            throw PDDVideoProbeError.cacheUnavailable
        }
        return selected
    }
}

public enum PDDVideoCacheMetadata {
    private static let expression = try! NSRegularExpression(
        pattern: #"https://[^\s\x00]+\.mp4(?:\?[^\s\x00]*)?"#,
        options: [.caseInsensitive]
    )

    public static func extractCandidate(from data: Data) -> URL? {
        let text = String(decoding: data, as: UTF8.self)
        guard text.range(
            of: #"content-type:\s*video/mp4"#,
            options: [.caseInsensitive, .regularExpression]
        ) != nil else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text),
                  let url = URL(string: String(text[swiftRange])),
                  url.scheme?.lowercased() == "https",
                  url.pathExtension.lowercased() == "mp4",
                  PDDVideoHostPolicy.accepts(url.host) else { continue }
            return url
        }
        return nil
    }
}

public enum PDDVideoHostPolicy {
    public static func accepts(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let labels = host.split(separator: ".")
        guard labels.count >= 3, labels[0].hasPrefix("video") else { return false }
        return host.hasSuffix(".yangkeduo.com") || host.hasSuffix(".pddcdn.com")
    }
}

public struct PDDVideoCacheSnapshot: Sendable {
    fileprivate struct Fingerprint: Equatable, Sendable {
        let size: UInt64
        let modificationTime: TimeInterval
    }

    fileprivate let files: [String: Fingerprint]

    public static func capture(directory: URL) throws -> PDDVideoCacheSnapshot {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            throw PDDVideoProbeError.cacheUnavailable
        }

        var files: [String: Fingerprint] = [:]
        for case let url as URL in enumerator
        where url.lastPathComponent.hasSuffix("_0") || url.lastPathComponent.hasSuffix("_s") {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            guard values.isRegularFile == true else { continue }
            files[url.path] = Fingerprint(
                size: UInt64(values.fileSize ?? 0),
                modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            )
        }
        return PDDVideoCacheSnapshot(files: files)
    }
}

public struct PDDVideoCacheBaseline: Sendable {
    fileprivate let directory: URL
    fileprivate let snapshot: PDDVideoCacheSnapshot

    public static func capture(directories: [URL]) throws -> [PDDVideoCacheBaseline] {
        try directories.map {
            PDDVideoCacheBaseline(directory: $0, snapshot: try PDDVideoCacheSnapshot.capture(directory: $0))
        }
    }
}

public struct PDDVideoCacheWatcher: Sendable {
    private let pollInterval: Duration

    public init(pollInterval: Duration = .milliseconds(200)) {
        self.pollInterval = pollInterval
    }

    public func waitForNewCandidate(
        in directory: URL,
        baseline: PDDVideoCacheSnapshot,
        timeout: Duration
    ) async throws -> URL {
        try await waitForNewCandidate(
            in: [PDDVideoCacheBaseline(directory: directory, snapshot: baseline)],
            timeout: timeout
        )
    }

    public func waitForNewCandidate(
        in baselines: [PDDVideoCacheBaseline],
        timeout: Duration
    ) async throws -> URL {
        guard !baselines.isEmpty else { throw PDDVideoProbeError.cacheUnavailable }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var changedPaths = Set<String>()
        var observed = Dictionary(uniqueKeysWithValues: baselines.map { ($0.directory.path, $0.snapshot) })
        while clock.now < deadline {
            try Task.checkCancellation()
            var candidates: [(url: URL, modificationTime: TimeInterval, path: String)] = []
            for baseline in baselines {
                guard let current = try? PDDVideoCacheSnapshot.capture(directory: baseline.directory) else {
                    continue
                }
                let previous = observed[baseline.directory.path] ?? baseline.snapshot
                for removedPath in previous.files.keys where current.files[removedPath] == nil {
                    changedPaths.insert(removedPath)
                }
                for (path, fingerprint) in current.files where previous.files[path] != fingerprint {
                    changedPaths.insert(path)
                    guard let data = try? readMetadataPrefix(at: URL(fileURLWithPath: path)) else {
                        continue
                    }
                    if let candidate = PDDVideoCacheMetadata.extractCandidate(from: data) {
                        candidates.append((candidate, fingerprint.modificationTime, path))
                    }
                }
                observed[baseline.directory.path] = current
            }
            if let newest = candidates.max(by: {
                if $0.modificationTime == $1.modificationTime { return $0.path < $1.path }
                return $0.modificationTime < $1.modificationTime
            }) {
                return newest.url
            }
            try await Task.sleep(for: pollInterval)
        }
        if changedPaths.isEmpty {
            throw PDDVideoProbeError.timedOutNoCacheChange
        }
        throw PDDVideoProbeError.timedOutWithoutVideoMarker(changedFiles: changedPaths.count)
    }

    private func readMetadataPrefix(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 1_048_576) ?? Data()
    }
}

public enum PDDVideoProbeError: Error, Equatable, Sendable {
    case accessibilityPermissionRequired
    case applicationNotRunning
    case applicationActivationFailed
    case cacheUnavailable
    case invalidMedia
    case missingVideoTrack
    case timedOutNoCacheChange
    case timedOutWithoutVideoMarker(changedFiles: Int)
    case downloadRejected
    case downloadFailed
    case outputFailed
    case videoClickFailed
    case videoMessageNotFound
}

extension PDDVideoProbeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired: return "需要在系统设置的辅助功能中允许拼多多视频直链测试器"
        case .applicationNotRunning: return "没有检测到正在运行的拼多多商家版"
        case .applicationActivationFailed: return "无法将拼多多工作台切换到前台"
        case .cacheUnavailable: return "没有找到拼多多视频缓存；请先启动拼多多商家版"
        case .invalidMedia: return "下载内容不是有效的MP4视频"
        case .missingVideoTrack: return "下载文件中没有可读取的视频轨道"
        case .timedOutNoCacheChange: return "60秒内CEF缓存没有发生变化；请确认已点开视频且拼多多开始加载"
        case .timedOutWithoutVideoMarker(let changedFiles):
            return "CEF缓存有\(changedFiles)个文件发生变化，但没有出现可识别的视频标记"
        case .downloadRejected: return "视频服务器拒绝下载或返回了非视频内容"
        case .downloadFailed: return "视频下载失败"
        case .outputFailed: return "测试结果无法写入桌面"
        case .videoClickFailed: return "已定位客户视频，但自动点击失败"
        case .videoMessageNotFound: return "当前聊天中没有找到可见的客户视频消息"
        }
    }
}

public enum PDDVideoDownloadPolicy {
    public static func accepts(statusCode: Int, mimeType: String?) -> Bool {
        guard statusCode == 200 || statusCode == 206 else { return false }
        guard let mimeType = mimeType?.lowercased(), !mimeType.isEmpty else { return true }
        return mimeType == "video/mp4" || mimeType == "application/octet-stream"
    }
}

public struct PDDVideoDownloadReceipt: Sendable {
    public let fileURL: URL
    public let statusCode: Int
    public let elapsedMilliseconds: Int

    public init(fileURL: URL, statusCode: Int, elapsedMilliseconds: Int) {
        self.fileURL = fileURL
        self.statusCode = statusCode
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public struct PDDVideoDownloadClient: Sendable {
    public init() {}

    public func download(from sourceURL: URL, to destinationURL: URL) async throws -> PDDVideoDownloadReceipt {
        let started = Date()
        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: sourceURL)
            guard let http = response as? HTTPURLResponse,
                  PDDVideoDownloadPolicy.accepts(statusCode: http.statusCode, mimeType: response.mimeType) else {
                throw PDDVideoProbeError.downloadRejected
            }
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                throw PDDVideoProbeError.outputFailed
            }
            try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
            return PDDVideoDownloadReceipt(
                fileURL: destinationURL,
                statusCode: http.statusCode,
                elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1_000))
            )
        } catch let error as PDDVideoProbeError {
            throw error
        } catch {
            throw PDDVideoProbeError.downloadFailed
        }
    }
}

public struct SanitizedPDDVideoProbeReport: Codable, Equatable, Sendable {
    public enum Result: String, Codable, Sendable { case passed, failed }

    public struct Machine: Codable, Equatable, Sendable {
        public let macOS: String
        public let architecture: String
        public let pddVersion: String

        public init(macOS: String, architecture: String, pddVersion: String) {
            self.macOS = macOS
            self.architecture = architecture
            self.pddVersion = pddVersion
        }
    }

    public struct FileSummary: Codable, Equatable, Sendable {
        public let name: String
        public let bytes: Int64
        public let sha256: String
        public let durationSeconds: Double
        public let width: Int
        public let height: Int
        public let videoCodec: String
        public let audioCodec: String?

        public init(
            name: String,
            bytes: Int64,
            sha256: String,
            durationSeconds: Double,
            width: Int,
            height: Int,
            videoCodec: String,
            audioCodec: String?
        ) {
            self.name = name
            self.bytes = bytes
            self.sha256 = sha256
            self.durationSeconds = durationSeconds
            self.width = width
            self.height = height
            self.videoCodec = videoCodec
            self.audioCodec = audioCodec
        }
    }

    public let machine: Machine
    public let result: Result
    public let discoveryMilliseconds: Int
    public let downloadMilliseconds: Int
    public let httpStatus: Int?
    public let file: FileSummary?
    public let failure: String?

    public init(
        machine: Machine,
        result: Result,
        discoveryMilliseconds: Int,
        downloadMilliseconds: Int,
        httpStatus: Int?,
        file: FileSummary?,
        failure: String?
    ) {
        self.machine = machine
        self.result = result
        self.discoveryMilliseconds = discoveryMilliseconds
        self.downloadMilliseconds = downloadMilliseconds
        self.httpStatus = httpStatus
        self.file = file
        self.failure = failure
    }
}

public enum PDDVideoProbeReportMarkdown {
    public static func render(_ report: SanitizedPDDVideoProbeReport) -> String {
        var lines = [
            "# 拼多多视频直链测试报告",
            "",
            "- 结果：\(report.result == .passed ? "PASS" : "FAIL")",
            "- macOS：\(report.machine.macOS)",
            "- 架构：\(report.machine.architecture)",
            "- 拼多多版本：\(report.machine.pddVersion)",
            "- 发现耗时：\(report.discoveryMilliseconds) ms",
            "- 下载耗时：\(report.downloadMilliseconds) ms",
            "- HTTP状态：\(report.httpStatus.map(String.init) ?? "未取得")"
        ]
        if let file = report.file {
            lines += [
                "- 文件：\(file.name)",
                "- 大小：\(file.bytes) bytes",
                "- SHA-256：\(file.sha256)",
                "- 时长：\(String(format: "%.3f", file.durationSeconds)) 秒",
                "- 分辨率：\(file.width) × \(file.height)",
                "- 视频编码：\(file.videoCodec)",
                "- 音频编码：\(file.audioCodec ?? "无音轨")"
            ]
        }
        if let failure = report.failure { lines.append("- 失败原因：\(failure)") }
        lines += [
            "",
            "> 报告不包含视频地址、拼多多缓存原文或登录凭证。",
            ""
        ]
        return lines.joined(separator: "\n")
    }
}

public enum PDDVideoFileSHA256 {
    public static func hexDigest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum PDDVideoFileInspector {
    public static func inspect(_ url: URL) async throws -> SanitizedPDDVideoProbeReport.FileSummary {
        guard try hasISOBaseMediaHeader(url) else { throw PDDVideoProbeError.invalidMedia }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first,
                  duration.isNumeric,
                  duration.seconds.isFinite,
                  duration.seconds > 0 else {
                throw PDDVideoProbeError.missingVideoTrack
            }
            async let naturalSize = videoTrack.load(.naturalSize)
            async let transform = videoTrack.load(.preferredTransform)
            async let videoFormats = videoTrack.load(.formatDescriptions)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let audioFormats = try await audioTracks.first?.load(.formatDescriptions) ?? []
            let loadedVideoFormats = try await videoFormats
            let oriented = CGRect(origin: .zero, size: try await naturalSize)
                .applying(try await transform)
                .standardized
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            return .init(
                name: url.lastPathComponent,
                bytes: byteCount,
                sha256: try PDDVideoFileSHA256.hexDigest(of: url),
                durationSeconds: duration.seconds,
                width: Int(oriented.width.rounded()),
                height: Int(oriented.height.rounded()),
                videoCodec: loadedVideoFormats.first.map(codecName) ?? "unknown",
                audioCodec: audioFormats.first.map(codecName)
            )
        } catch let error as PDDVideoProbeError {
            throw error
        } catch {
            throw PDDVideoProbeError.invalidMedia
        }
    }

    private static func hasISOBaseMediaHeader(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 12) ?? Data()
        guard prefix.count >= 8 else { return false }
        return String(decoding: prefix[4..<8], as: UTF8.self) == "ftyp"
    }

    private static func codecName(_ description: CMFormatDescription) -> String {
        let value = CMFormatDescriptionGetMediaSubType(description)
        switch value {
        case kCMVideoCodecType_H264: return "H.264"
        case kCMVideoCodecType_HEVC: return "HEVC"
        case kAudioFormatMPEG4AAC: return "AAC"
        default:
            let bytes: [UInt8] = [
                UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
            ]
            return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "unknown"
        }
    }
}
