import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct PDDOCRFrame: @unchecked Sendable {
    let image: CGImage
    let fullWindowImage: CGImage
    let windowFrame: CGRect
}

enum PDDOCRCropGeometry {
    static func pixelCrop(
        imageSize: CGSize,
        windowFrame: CGRect,
        chatPanelFrame: CGRect?
    ) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0,
              windowFrame.width > 0, windowFrame.height > 0 else { return nil }
        if let chatPanelFrame {
            let clipped = chatPanelFrame.intersection(windowFrame)
            if !clipped.isNull,
               clipped.width >= 100,
               clipped.height >= 100,
               clipped.width >= chatPanelFrame.width * 0.9,
               clipped.height >= chatPanelFrame.height * 0.9 {
                let scaleX = imageSize.width / windowFrame.width
                let scaleY = imageSize.height / windowFrame.height
                return CGRect(
                    x: ((clipped.minX - windowFrame.minX) * scaleX).rounded(),
                    y: ((clipped.minY - windowFrame.minY) * scaleY).rounded(),
                    width: (clipped.width * scaleX).rounded(),
                    height: (clipped.height * scaleY).rounded()
                )
            }
        }
        return fallbackPixelCrop(imageSize: imageSize)
    }

    static func fallbackPixelCrop(imageSize: CGSize) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        return CGRect(
            x: (imageSize.width * 0.198).rounded(),
            y: (imageSize.height * 0.300).rounded(),
            width: (imageSize.width * 0.602).rounded(),
            height: (imageSize.height * 0.520).rounded()
        )
    }
}

@MainActor
enum PDDWindowForegroundActivation {
    static func run(
        request: () async throws -> Bool,
        raise: () -> Bool,
        isFrontmost: () -> Bool,
        sleep: (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) }
    ) async throws {
        if isFrontmost() { return }
        guard try await request(), raise() else {
            throw PDDOCRError.capture("无法将拼多多工作台切到前台")
        }
        for attempt in 0...20 {
            if isFrontmost() {
                await sleep(150_000_000)
                return
            }
            if attempt < 20 { await sleep(50_000_000) }
        }
        throw PDDOCRError.capture("拼多多工作台前台激活超时")
    }
}

@MainActor
protocol PDDOCRCapturing: AnyObject {
    func capture() async throws -> PDDOCRFrame
}

@MainActor
final class PDDWindowOCRCapture: PDDOCRCapturing {
    private let bundleIdentifier: String

    init(bundleIdentifier: String = "com.pinduoduo.merchantMac") {
        self.bundleIdentifier = bundleIdentifier
    }

    func capture() async throws -> PDDOCRFrame {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw PDDOCRError.screenRecordingPermission
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            throw PDDOCRError.windowNotFound
        }
        let workbench = try await activateWorkbench(application: app)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows
            .filter({ $0.owningApplication?.processID == app.processIdentifier })
            .sorted(by: { ($0.title?.contains("拼多多商家工作台") == true ? 0 : 1) < ($1.title?.contains("拼多多商家工作台") == true ? 0 : 1) })
            .first else { throw PDDOCRError.windowNotFound }
        let scale = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((window.frame.width * scale).rounded()))
        configuration.height = max(1, Int((window.frame.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let full: CGImage
        do {
            full = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration
            )
        } catch { throw PDDOCRError.capture(error.localizedDescription) }
        guard let crop = PDDOCRCropGeometry.pixelCrop(
            imageSize: CGSize(width: full.width, height: full.height),
            windowFrame: window.frame,
            chatPanelFrame: findChatPanelFrame(in: workbench)
        ), let image = full.cropping(to: crop) else {
            throw PDDOCRError.capture("聊天区域裁剪无效")
        }
        return PDDOCRFrame(image: image, fullWindowImage: full, windowFrame: window.frame)
    }

    private func activateWorkbench(application: NSRunningApplication) async throws -> AXUIElement {
        guard let bundleURL = application.bundleURL else { throw PDDOCRError.windowNotFound }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        let windows = copyElements(kAXWindowsAttribute as String, from: appElement)
        guard let workbench = windows.first(where: {
            copyString(kAXTitleAttribute as String, from: $0)?.contains("拼多多商家工作台") == true
        }) else { throw PDDOCRError.windowNotFound }

        try await PDDWindowForegroundActivation.run(
            request: {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.createsNewApplicationInstance = false
                configuration.allowsRunningApplicationSubstitution = false
                let opened = try await NSWorkspace.shared.openApplication(
                    at: bundleURL,
                    configuration: configuration
                )
                return opened.processIdentifier == application.processIdentifier
            },
            raise: {
                AXUIElementPerformAction(workbench, kAXRaiseAction as CFString) == .success
            },
            isFrontmost: {
                !application.isTerminated
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier
                        == application.processIdentifier
            }
        )
        return workbench
    }

    private func findChatPanelFrame(in root: AXUIElement, depth: Int = 0) -> CGRect? {
        guard depth <= 40 else { return nil }
        let classes = copyStrings("AXDOMClassList", from: root)
        if classes.contains(where: {
            let value = $0.lowercased()
            return value.contains("middle-panel") || value.contains("chat-panel")
        }), let frame = copyFrame(from: root), frame.width > 0, frame.height > 0 {
            return frame
        }
        for child in copyElements("AXChildrenInNavigationOrder", from: root)
            + copyElements(kAXChildrenAttribute as String, from: root) {
            if let frame = findChatPanelFrame(in: child, depth: depth + 1) { return frame }
        }
        return nil
    }

    private func copyFrame(from element: AXUIElement) -> CGRect? {
        var positionRaw: CFTypeRef?
        var sizeRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &positionRaw
        ) == .success,
        AXUIElementCopyAttributeValue(
            element, kAXSizeAttribute as CFString, &sizeRaw
        ) == .success,
        let positionValue = positionRaw as! AXValue?,
        let sizeValue = sizeRaw as! AXValue? else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func copyStrings(_ name: String, from element: AXUIElement) -> [String] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else {
            return []
        }
        if let strings = raw as? [String] { return strings }
        if let string = raw as? String { return [string] }
        return []
    }

    private func copyElements(_ name: String, from element: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let result = raw as? [AXUIElement] else { return [] }
        return result
    }

    private func copyString(_ name: String, from element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else {
            return nil
        }
        return raw as? String
    }
}
