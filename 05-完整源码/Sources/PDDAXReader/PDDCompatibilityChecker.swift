import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Speech

@MainActor
enum PDDCompatibilityChecker {
    static func check(
        codexProbe: CodexCompatibilityProbe = CodexCompatibilityProbe()
    ) async -> PDDCompatibilityReport {
        var items: [PDDCompatibilityItem] = []
#if arch(arm64)
        items.append(.init(kind: .architecture, status: .pass, detail: BilingualText.lines("Apple Silicon", "Apple Silicon")))
#else
        items.append(.init(kind: .architecture, status: .fail, detail: BilingualText.lines("仅支持 Apple Silicon", "Only Apple Silicon is supported")))
#endif
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        items.append(.init(
            kind: .operatingSystem,
            status: major >= 14 ? .pass : .fail,
            detail: major >= 14 ? BilingualText.lines("macOS 14 或更高", "macOS 14 or later") : BilingualText.lines("需要 macOS 14 或更高", "macOS 14 or later is required")
        ))
        items.append(.init(
            kind: .accessibility,
            status: AXIsProcessTrusted() ? .pass : .fail,
            detail: AXIsProcessTrusted() ? BilingualText.lines("辅助功能已授权", "Accessibility authorized") : BilingualText.lines("辅助功能未授权", "Accessibility not authorized")
        ))
        let screen = CGPreflightScreenCaptureAccess()
        items.append(.init(
            kind: .screenRecording,
            status: screen ? .pass : .fail,
            detail: screen ? BilingualText.lines("录屏权限已授权", "Screen Recording authorized") : BilingualText.lines("录屏权限未授权", "Screen Recording not authorized")
        ))
        let speech = SFSpeechRecognizer.authorizationStatus()
        items.append(.init(
            kind: .speech,
            status: speech == .authorized ? .pass : .degraded,
            detail: speech == .authorized ? BilingualText.lines("视频语音识别已授权", "Video speech recognition authorized") : BilingualText.lines("语音不可用时仍处理视频画面", "Video frames are still processed when speech is unavailable")
        ))

        let pdd = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.pinduoduo.merchantMac"
        ).first
        items.append(.init(
            kind: .pdd,
            status: pdd == nil ? .fail : .pass,
            detail: pdd == nil ? BilingualText.lines("拼多多商家工作台未运行", "Pinduoduo Merchant Workbench is not running") : BilingualText.lines("拼多多商家工作台已运行", "Pinduoduo Merchant Workbench is running")
        ))
        do {
            try DirectLocalKnowledge().validate()
            items.append(.init(kind: .knowledge, status: .pass, detail:
                BilingualText.lines("本地知识目录可直接读取", "Local knowledge folder is ready for direct reading")))
        } catch {
            items.append(.init(kind: .knowledge, status: .fail, detail: error.localizedDescription))
        }
        let codexURL = CodexInstallation.resolve()
        items.append(await codexProbe.check(executableURL: codexURL).compatibilityItem)

        let cefRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.pinduoduo.merchantMac/PMDataRelease/Caches/cef")
        let videoCacheAvailable = (try? PDDVideoCacheLocator.findCacheDataDirectories(
            inCEFRoot: cefRoot
        ).isEmpty == false) == true
        items.append(.init(
            kind: .videoCache,
            status: videoCacheAvailable ? .pass : .degraded,
            detail: videoCacheAvailable ? BilingualText.lines("PDD 视频缓存可用", "PDD video cache is available") : BilingualText.lines("视频缓存不可用；文字和图片仍可运行", "Video cache is unavailable; text and images still work")
        ))
        return PDDCompatibilityReport(items: items)
    }
}
