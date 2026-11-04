import AppKit
import Darwin
import Foundation
import Speech

enum PDDMediaPermissionStatus: String, Sendable {
    case authorized, denied, restricted, notDetermined, unavailable

    var label: String {
        switch self {
        case .authorized: return BilingualText.lines("已允许", "Allowed")
        case .denied: return BilingualText.lines("已拒绝", "Denied")
        case .restricted: return BilingualText.lines("受系统限制", "Restricted")
        case .notDetermined: return BilingualText.lines("尚未选择", "Not requested")
        case .unavailable: return BilingualText.lines("不可用", "Unavailable")
        }
    }

    init(speech status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .unavailable
        }
    }
}

struct PDDMediaFilePermissionResult: Sendable {
    let status: PDDMediaPermissionStatus
    var detail: String = ""
}

enum PDDMediaPermissionSettingsPage: String {
    case filesAndFolders, speechRecognition

    var url: URL {
        let anchor = self == .filesAndFolders ? "Privacy_FilesAndFolders" : "Privacy_SpeechRecognition"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

/// Explicit preflight for the same Downloads and speech access used by media
/// handling. Does not start automation, modify files, or reset macOS decisions.
@MainActor
final class PDDMediaPermissionController: ObservableObject {
    @Published private(set) var isRequesting = false
    @Published private(set) var fileStatus: PDDMediaPermissionStatus?
    @Published private(set) var speechStatus: PDDMediaPermissionStatus?
    @Published private(set) var statusText: String?

    private let logRoot: URL?
    private let requestFiles: @Sendable () async -> PDDMediaFilePermissionResult
    private let requestSpeech: @Sendable () async -> PDDMediaPermissionStatus
    private let settingsOpener: (PDDMediaPermissionSettingsPage) -> Bool

    init(
        logRoot: URL? = PDDRuntimeIdentity.forMode(PDDAppMode(bundleIdentifier: Bundle.main.bundleIdentifier)).dataRoot,
        requestFiles: @escaping @Sendable () async -> PDDMediaFilePermissionResult = {
            await PDDMediaPermissionController.requestDownloadsAccess()
        },
        requestSpeech: @escaping @Sendable () async -> PDDMediaPermissionStatus = {
            await PDDMediaPermissionController.requestSpeechAccess()
        },
        settingsOpener: @escaping (PDDMediaPermissionSettingsPage) -> Bool = { NSWorkspace.shared.open($0.url) }
    ) {
        self.logRoot = logRoot
        self.requestFiles = requestFiles
        self.requestSpeech = requestSpeech
        self.settingsOpener = settingsOpener
    }

    func requestPermissions() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        statusText = BilingualText.lines("正在请求下载文件夹权限，请在系统提示中选择…", "Requesting Downloads access; respond to the macOS prompt…")
        record("media-permissions-started")
        record("media-files-permission-requested", "scope=Downloads read-only")
        let files = await requestFiles()
        fileStatus = files.status
        record("media-files-permission-result", "status=\(files.status.rawValue) \(files.detail)")

        statusText = BilingualText.lines("正在请求语音识别权限，请在系统提示中选择…", "Requesting speech recognition; respond to the macOS prompt…")
        record("media-speech-permission-requested", "saved-video-audio; microphone_not_requested=true")
        speechStatus = await requestSpeech()
        record("media-speech-permission-result", "status=\(speechStatus?.rawValue ?? "unknown")")
        let fileLabel = BilingualText.split(files.status.label)
        let speechLabel = BilingualText.split((speechStatus ?? .unavailable).label)
        statusText = BilingualText.lines(
            "下载文件夹：\(fileLabel.chinese) · 语音识别：\(speechLabel.chinese)",
            "Downloads: \(fileLabel.english) · Speech recognition: \(speechLabel.english)")
        record("media-permissions-completed", "files=\(files.status.rawValue) speech=\(speechStatus?.rawValue ?? "unknown")")
    }

    func openSettings(_ page: PDDMediaPermissionSettingsPage) {
        let opened = settingsOpener(page)
        record("media-permission-settings-opened", "page=\(page.rawValue) opened=\(opened)")
    }

    private func record(_ step: String, _ detail: String = "") {
        AutomationStepLog.record(root: logRoot, uid: nil, step: step, detail: detail)
    }

    nonisolated private static func requestDownloadsAccess() async -> PDDMediaFilePermissionResult {
        await Task.detached(priority: .userInitiated) { () -> PDDMediaFilePermissionResult in
            guard let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
                return .init(status: .unavailable, detail: "Downloads directory unavailable")
            }
            do {
                // The image-download monitor uses this same folder. Accessing
                // it asks macOS for Files & Folders consent when undecided.
                _ = try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                return .init(status: .authorized)
            } catch {
                let error = error as NSError
                let denied = error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoPermission.rawValue
                    || error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code)
                return .init(status: denied ? .denied : .unavailable,
                    detail: "domain=\(error.domain) code=\(error.code)")
            }
        }.value
    }

    nonisolated private static func requestSpeechAccess() async -> PDDMediaPermissionStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return .init(speech: status) }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: .init(speech: $0)) }
        }
    }
}
