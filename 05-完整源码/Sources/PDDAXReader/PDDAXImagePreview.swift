import AppKit
import ApplicationServices
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PDDPreviewImageURLPolicy {
    static func originalImageURL(
        role: String,
        domClasses: [String],
        rawURL: String
    ) -> URL? {
        guard role == (kAXImageRole as String),
              domClasses.contains(where: { $0.contains("MacPreview_imgContent") }),
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        return url
    }
}

enum PDDImagePreviewProbe: Equatable {
    case absent
    case open(url: URL?)
}

enum PDDImagePreviewControlPolicy {
    static func isDownloadControl(role: String, labels: [String], domMetadata: String) -> Bool {
        let normalizedLabels = labels.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if normalizedLabels.contains(where: {
            $0 == "下载" || $0 == "download" || $0 == "save" || $0 == "保存"
        }) { return true }
        let dom = domMetadata.lowercased()
        return dom.contains("download") || dom.contains("save-image")
    }

    static func fallbackDownloadPoint(in frame: CGRect) -> CGPoint {
        CGPoint(
            x: frame.minX + frame.width * 0.61,
            y: frame.minY + frame.height * 0.88
        )
    }
}

enum PDDImageSaveSheetPolicy {
    static func isFilenameField(role: String, labels: [String]) -> Bool {
        guard role == (kAXTextFieldRole as String) else { return false }
        return !labels.contains { $0.contains("标签编辑器") || $0.lowercased().contains("tag") }
    }

    static func isButton(role: String, labels: [String], names: Set<String>) -> Bool {
        guard role == (kAXButtonRole as String) else { return false }
        return labels.contains {
            names.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }
}

struct PDDDownloadedImageFingerprint: Equatable {
    let byteCount: Int
    let modificationDate: Date
}

final class PDDDownloadedImageMonitor {
    private let directory: URL
    private let fileManager: FileManager
    private(set) var baseline: [URL: PDDDownloadedImageFingerprint] = [:]
    private var previousPoll: [URL: PDDDownloadedImageFingerprint] = [:]

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory.standardizedFileURL
        self.fileManager = fileManager
    }

    func begin() {
        baseline = snapshot()
        previousPoll = baseline
    }

    func stableNewFile() -> URL? {
        let current = snapshot()
        defer { previousPoll = current }
        return current
            .filter { url, fingerprint in
                fingerprint.byteCount > 0
                    && baseline[url] != fingerprint
                    && previousPoll[url] == fingerprint
            }
            .max { $0.value.modificationDate < $1.value.modificationDate }?
            .key
    }

    private func snapshot() -> [URL: PDDDownloadedImageFingerprint] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [:] }
        var result: [URL: PDDDownloadedImageFingerprint] = [:]
        for file in files {
            let ext = file.pathExtension.lowercased()
            guard !["download", "crdownload", "part", "tmp"].contains(ext),
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  let modified = values.contentModificationDate else { continue }
            result[file.standardizedFileURL] = PDDDownloadedImageFingerprint(
                byteCount: size, modificationDate: modified
            )
        }
        return result
    }
}

@MainActor
protocol PDDImageDoubleClicking: AnyObject {
    func doubleClick(at point: CGPoint) throws
}

@MainActor
protocol PDDImagePreviewReading: AnyObject {
    func waitForOriginalURL() async throws -> URL
    func waitForOriginalURL(
        onPreviewOpen: @escaping @MainActor () -> Void
    ) async throws -> URL
    func closePreview()
}

extension PDDImagePreviewReading {
    func waitForOriginalURL(
        onPreviewOpen: @escaping @MainActor () -> Void
    ) async throws -> URL {
        onPreviewOpen()
        return try await waitForOriginalURL()
    }
}

@MainActor
final class PDDAXImagePreviewResolver: PDDCustomerImageResolving {
    private let clicker: any PDDImageDoubleClicking
    private let reader: any PDDImagePreviewReading

    init(clicker: any PDDImageDoubleClicking, reader: any PDDImagePreviewReading) {
        self.clicker = clicker
        self.reader = reader
    }

    func resolve(
        candidate: PDDCustomerImageCandidate,
        lease: UIOperationLease
    ) async throws -> URL {
        try lease.validate()
        try clicker.doubleClick(at: CGPoint(x: candidate.frame.midX, y: candidate.frame.midY))
        defer {
            lease.resumeDeadline()
            reader.closePreview()
        }
        try lease.validate()
        let url = try await reader.waitForOriginalURL {
            lease.suspendDeadline()
        }
        try lease.validate()
        if url.isFileURL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw PDDCustomerImageError.invalidPreviewURL
            }
        } else {
            guard url.scheme.map({ ["http", "https"].contains($0.lowercased()) }) == true else {
                throw PDDCustomerImageError.invalidPreviewURL
            }
        }
        return url
    }
}

@MainActor
final class CGEventPDDImageDoubleClicker: PDDImageDoubleClicking {
    func doubleClick(at point: CGPoint) throws {
        guard let down = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left
        ) else { throw PDDCustomerImageError.clickFailed }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        down.setIntegerValueField(.mouseEventClickState, value: 2)
        up.setIntegerValueField(.mouseEventClickState, value: 2)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

@MainActor
final class LivePDDImagePreviewReader: PDDImagePreviewReading {
    private struct ElementIdentity: Hashable {
        let element: AXUIElement
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    }

    private let bundleIdentifier: String
    private let previewOpenTimeout: TimeInterval
    private let previewLossGrace: TimeInterval
    private let previewDownloadTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private let now: @MainActor () -> Date
    private let sleep: @MainActor (TimeInterval) async throws -> Void
    private let previewProbeProvider: (@MainActor () -> PDDImagePreviewProbe)?
    private var previewWindow: AXUIElement?
    private var downloadMonitor: PDDDownloadedImageMonitor?
    private var downloadRequestedAt: Date?
    private var saveSheetSubmitted = false

    init(
        bundleIdentifier: String = "com.pinduoduo.merchantMac",
        previewOpenTimeout: TimeInterval = 2,
        previewLossGrace: TimeInterval = 2,
        previewDownloadTimeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.05,
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        previewProbeProvider: (@MainActor () -> PDDImagePreviewProbe)? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.previewOpenTimeout = previewOpenTimeout
        self.previewLossGrace = previewLossGrace
        self.previewDownloadTimeout = previewDownloadTimeout
        self.pollInterval = pollInterval
        self.now = now
        self.sleep = sleep
        self.previewProbeProvider = previewProbeProvider
    }

    func waitForOriginalURL() async throws -> URL {
        try await waitForOriginalURL(onPreviewOpen: {})
    }

    func waitForOriginalURL(
        onPreviewOpen: @escaping @MainActor () -> Void
    ) async throws -> URL {
        let started = now()
        var previewWasOpen = false
        var previewMissingSince: Date?
        while true {
            switch previewProbeProvider?() ?? probeLivePreview() {
            case .absent:
                if previewWasOpen {
                    if previewMissingSince == nil { previewMissingSince = now() }
                    if now().timeIntervalSince(previewMissingSince!) >= previewLossGrace {
                        if let capturedURL = captureVisiblePreview() { return capturedURL }
                        throw PDDCustomerImageError.previewClosedBeforeURL
                    }
                }
                if !previewWasOpen && now().timeIntervalSince(started) >= previewOpenTimeout {
                    throw PDDCustomerImageError.previewNotFound
                }
            case .open(let url):
                if !previewWasOpen { onPreviewOpen() }
                previewWasOpen = true
                previewMissingSince = nil
                if let url { return url }
                if previewProbeProvider == nil, downloadRequestedAt == nil {
                    try requestPreviewDownload()
                }
            }
            if previewProbeProvider == nil, downloadRequestedAt != nil, !saveSheetSubmitted {
                if submitSaveSheetIfPresent() {
                    saveSheetSubmitted = true
                    // The browser download does not start until the macOS Save sheet is
                    // submitted, so measure the file-write timeout from this point.
                    downloadRequestedAt = now()
                }
            }
            if let localURL = downloadMonitor?.stableNewFile() { return localURL }
            if let requested = downloadRequestedAt,
               now().timeIntervalSince(requested) >= previewDownloadTimeout {
                if let capturedURL = captureVisiblePreview() { return capturedURL }
                throw PDDCustomerImageError.previewDownloadTimedOut
            }
            try await sleep(pollInterval)
        }
    }

    func closePreview() {
        dismissSaveSheetIfPresent()
        Thread.sleep(forTimeInterval: 0.1)
        let window = currentPreviewWindow() ?? previewWindow
        var closed = false
        if let window,
           let close = copyElement(kAXCloseButtonAttribute as String, from: window) {
            closed = AXUIElementPerformAction(close, kAXPressAction as CFString) == .success
        }
        if !closed,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier,
           let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
           let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        self.previewWindow = nil
        downloadMonitor = nil
        downloadRequestedAt = nil
        saveSheetSubmitted = false
    }

    private func requestPreviewDownload() throws {
        guard let window = previewWindow,
              let downloads = FileManager.default.urls(
                for: .downloadsDirectory, in: .userDomainMask
              ).first else { throw PDDCustomerImageError.previewDownloadUnavailable }
        let monitor = PDDDownloadedImageMonitor(directory: downloads)
        monitor.begin()

        var visited = Set<ElementIdentity>()
        if let control = firstDescendant(
            from: window, depth: 0, visited: &visited,
            where: { element in
                PDDImagePreviewControlPolicy.isDownloadControl(
                    role: copyString(kAXRoleAttribute as String, from: element) ?? "",
                    labels: labels(of: element),
                    domMetadata: [
                        copyString("AXDOMIdentifier", from: element),
                        copyString("AXDOMClassList", from: element)
                    ].compactMap { $0 }.joined(separator: " ")
                )
            }
        ), AXUIElementPerformAction(control, kAXPressAction as CFString) == .success {
            downloadMonitor = monitor
            downloadRequestedAt = now()
            return
        }

        guard let frame = frame(of: window) else {
            throw PDDCustomerImageError.previewDownloadUnavailable
        }
        if let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first {
            application.activate(options: [])
        }
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        try singleClick(at: PDDImagePreviewControlPolicy.fallbackDownloadPoint(in: frame))
        downloadMonitor = monitor
        downloadRequestedAt = now()
    }

    private func captureVisiblePreview() -> URL? {
        dismissSaveSheetIfPresent()
        Thread.sleep(forTimeInterval: 0.1)
        guard CGPreflightScreenCaptureAccess(),
              let application = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
              ).first,
              let descriptions = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else { return nil }
        let windowDescription = descriptions.first { description in
            (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                == application.processIdentifier
                && (description[kCGWindowName as String] as? String)?.contains("图片预览") == true
        }
        guard let number = windowDescription?[kCGWindowNumber as String] as? NSNumber,
              let image = CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(number.uint32Value),
                [.boundsIgnoreFraming, .bestResolution]
              ) else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-image-preview-captures", isDirectory: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString).png")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            guard let encoder = CGImageDestinationCreateWithURL(
                destination as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else { return nil }
            CGImageDestinationAddImage(encoder, image, nil)
            guard CGImageDestinationFinalize(encoder) else { return nil }
            return destination
        } catch {
            return nil
        }
    }

    private func probeLivePreview() -> PDDImagePreviewProbe {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else { return .absent }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        for window in copyElements(kAXWindowsAttribute as String, from: appElement) {
            let title = copyString(kAXTitleAttribute as String, from: window) ?? ""
            guard title.contains("图片预览") else { continue }
            previewWindow = window
            var visited = Set<ElementIdentity>()
            return .open(url: findURL(in: window, depth: 0, visited: &visited))
        }
        return .absent
    }

    private func currentPreviewWindow() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return copyElements(kAXWindowsAttribute as String, from: appElement).first {
            (copyString(kAXTitleAttribute as String, from: $0) ?? "").contains("图片预览")
        }
    }

    private func submitSaveSheetIfPresent() -> Bool {
        guard let window = currentPreviewWindow() ?? previewWindow,
              let initialSheet = saveSheet(in: window),
              postDownloadsShortcut(to: initialSheet) else { return false }
        Thread.sleep(forTimeInterval: 0.25)
        guard let refreshedWindow = currentPreviewWindow() ?? previewWindow,
              let sheet = saveSheet(in: refreshedWindow) else { return false }

        var visited = Set<ElementIdentity>()
        guard let filenameField = firstDescendant(
            from: sheet, depth: 0, visited: &visited,
            where: { element in
                PDDImageSaveSheetPolicy.isFilenameField(
                    role: copyString(kAXRoleAttribute as String, from: element) ?? "",
                    labels: labels(of: element)
                )
            }
        ) else { return false }
        let filename = "pdd-customer-image-\(UUID().uuidString).png"
        guard AXUIElementSetAttributeValue(
            filenameField, kAXValueAttribute as CFString, filename as CFString
        ) == .success else { return false }

        visited.removeAll(keepingCapacity: true)
        guard let saveButton = firstDescendant(
            from: sheet, depth: 0, visited: &visited,
            where: { element in
                PDDImageSaveSheetPolicy.isButton(
                    role: copyString(kAXRoleAttribute as String, from: element) ?? "",
                    labels: labels(of: element), names: ["保存", "save"]
                )
            }
        ) else { return false }
        return AXUIElementPerformAction(saveButton, kAXPressAction as CFString) == .success
    }

    private func dismissSaveSheetIfPresent() {
        guard let window = currentPreviewWindow() ?? previewWindow,
              let sheet = saveSheet(in: window) else { return }
        var visited = Set<ElementIdentity>()
        if let cancelButton = firstDescendant(
            from: sheet, depth: 0, visited: &visited,
            where: { element in
                PDDImageSaveSheetPolicy.isButton(
                    role: copyString(kAXRoleAttribute as String, from: element) ?? "",
                    labels: labels(of: element), names: ["取消", "cancel"]
                )
            }
        ), AXUIElementPerformAction(cancelButton, kAXPressAction as CFString) == .success {
            return
        }
        _ = AXUIElementPerformAction(sheet, kAXRaiseAction as CFString)
        postEscape()
    }

    private func saveSheet(in window: AXUIElement) -> AXUIElement? {
        // The native Save sheet is a direct child of the preview window. Check these
        // small collections before recursively walking the embedded browser tree,
        // which can contain thousands of accessibility elements.
        let directChildren = copyElements("AXSheets", from: window)
            + copyElements(kAXChildrenAttribute as String, from: window)
        if let sheet = directChildren.first(where: {
            copyString(kAXRoleAttribute as String, from: $0) == (kAXSheetRole as String)
        }) {
            return sheet
        }
        var visited = Set<ElementIdentity>()
        return firstDescendant(
            from: window, depth: 0, visited: &visited,
            where: {
                copyString(kAXRoleAttribute as String, from: $0) == (kAXSheetRole as String)
            }
        )
    }

    private func postDownloadsShortcut(to sheet: AXUIElement) -> Bool {
        if let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first {
            application.activate(options: [])
        }
        _ = AXUIElementPerformAction(sheet, kAXRaiseAction as CFString)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 37, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 37, keyDown: false) else {
            return false
        }
        down.flags = [.maskCommand, .maskAlternate]
        up.flags = [.maskCommand, .maskAlternate]
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func postEscape() {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else {
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func firstDescendant(
        from element: AXUIElement,
        depth: Int,
        visited: inout Set<ElementIdentity>,
        where matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        guard depth <= 80, visited.insert(ElementIdentity(element: element)).inserted else {
            return nil
        }
        if matches(element) { return element }
        let children = copyElements("AXSheets", from: element)
            + copyElements(kAXChildrenAttribute as String, from: element)
            + copyElements("AXChildrenInNavigationOrder", from: element)
        for child in children {
            if let result = firstDescendant(
                from: child, depth: depth + 1, visited: &visited, where: matches
            ) { return result }
        }
        return nil
    }

    private func labels(of element: AXUIElement) -> [String] {
        [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXValueAttribute as String,
            kAXHelpAttribute as String
        ].compactMap { copyString($0, from: element) }
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let rawPosition = copyAttribute(kAXPositionAttribute as String, from: element),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              let rawSize = copyAttribute(kAXSizeAttribute as String, from: element),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(rawPosition, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func singleClick(at point: CGPoint) throws {
        guard let moved = CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left
        ), let down = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left
        ) else { throw PDDCustomerImageError.clickFailed }
        moved.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.2)
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func findURL(
        in element: AXUIElement,
        depth: Int,
        visited: inout Set<ElementIdentity>
    ) -> URL? {
        guard depth <= 80, visited.insert(ElementIdentity(element: element)).inserted else {
            return nil
        }
        let role = copyString(kAXRoleAttribute as String, from: element) ?? ""
        let classes = copyStrings("AXDOMClassList", from: element)
        if let raw = copyAttribute("AXURL", from: element) {
            let value = (raw as? URL)?.absoluteString ?? AXValueFormatter.string(from: raw)
            if let url = PDDPreviewImageURLPolicy.originalImageURL(
                role: role,
                domClasses: classes,
                rawURL: value
            ) {
                return url
            }
        }
        for child in copyElements(kAXChildrenAttribute as String, from: element) {
            if let result = findURL(in: child, depth: depth + 1, visited: &visited) { return result }
        }
        return nil
    }

    private func copyAttribute(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else {
            return nil
        }
        return raw
    }

    private func copyString(_ name: String, from element: AXUIElement) -> String? {
        copyAttribute(name, from: element).map(AXValueFormatter.string(from:))
    }

    private func copyStrings(_ name: String, from element: AXUIElement) -> [String] {
        guard let raw = copyAttribute(name, from: element) else { return [] }
        if let values = raw as? [String] { return values }
        return [AXValueFormatter.string(from: raw)]
    }

    private func copyElement(_ name: String, from element: AXUIElement) -> AXUIElement? {
        guard let raw = copyAttribute(name, from: element),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private func copyElements(_ name: String, from element: AXUIElement) -> [AXUIElement] {
        copyAttribute(name, from: element) as? [AXUIElement] ?? []
    }
}
