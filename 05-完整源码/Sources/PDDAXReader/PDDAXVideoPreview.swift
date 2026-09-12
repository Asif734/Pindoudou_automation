import AppKit
import ApplicationServices
import Foundation

enum PDDVideoPreviewElementPolicy {
    static func isPreviewMarker(_ rawLabel: String) -> Bool {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.contains("视频")
            && (label.contains("预览") || label.contains("播放"))
    }

    static func isCloseButton(role: String, labels: [String]) -> Bool {
        guard role == kAXButtonRole as String else { return false }
        return labels.contains { rawLabel in
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return label == "close" || label == "关闭" || label == "关闭视频预览"
        }
    }
}

@MainActor
final class PDDAXVideoPreviewOpener: PDDVideoPreviewOpening {
    typealias ClickOverride = @MainActor (PDDCustomerVideoCandidate) async throws -> Void
    typealias PreviewProbeOverride = @MainActor () -> Bool
    typealias ConfirmationPause = @MainActor () async throws -> Void

    private let backend: any PDDAXBackend
    private let clickOverride: ClickOverride?
    private let previewProbeOverride: PreviewProbeOverride?
    private let confirmationPause: ConfirmationPause

    convenience init() {
        self.init(backend: LivePDDAXBackend())
    }

    init(
        backend: any PDDAXBackend,
        clickOverride: ClickOverride? = nil,
        previewProbeOverride: PreviewProbeOverride? = nil,
        confirmationPause: @escaping ConfirmationPause = {
            try await Task.sleep(for: .milliseconds(250))
        }
    ) {
        self.backend = backend
        self.clickOverride = clickOverride
        self.previewProbeOverride = previewProbeOverride
        self.confirmationPause = confirmationPause
    }

    func open(_ candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws {
        try Task.checkCancellation()
        try lease.validate()
        let refreshedCandidate = (try? backend.readSemanticTree()).flatMap { tree in
            PDDAXVideoSelection.customerVideos(
                in: tree.nodes, messageIDs: [candidate.messageID]
            ).first
        } ?? candidate
        if let clickOverride {
            try await clickOverride(refreshedCandidate)
        } else {
            try await activateAndClick(refreshedCandidate)
        }
        try Task.checkCancellation()
        try lease.validate()
    }

    func waitUntilOpen() async throws -> Bool {
        for _ in 0..<6 {
            try Task.checkCancellation()
            if previewProbeOverride?() ?? isPreviewOpen() { return true }
            try await confirmationPause()
        }
        try Task.checkCancellation()
        return previewProbeOverride?() ?? isPreviewOpen()
    }

    private func activateAndClick(_ candidate: PDDCustomerVideoCandidate) async throws {
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.pinduoduo.merchantMac"
        ).first, let bundleURL = application.bundleURL else { throw PDDCustomerVideoError.clickFailed }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let workbench = copyElements(kAXWindowsAttribute as String, from: appElement).first(where: {
            copyString(kAXTitleAttribute as String, from: $0)?.contains("拼多多商家工作台") == true
        }) else { throw PDDCustomerVideoError.clickFailed }
        do {
            try await PDDWindowForegroundActivation.run(
                request: {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    configuration.createsNewApplicationInstance = false
                    configuration.allowsRunningApplicationSubstitution = false
                    let opened = try await NSWorkspace.shared.openApplication(
                        at: bundleURL, configuration: configuration
                    )
                    return opened.processIdentifier == application.processIdentifier
                },
                raise: { AXUIElementPerformAction(workbench, kAXRaiseAction as CFString) == .success },
                isFrontmost: {
                    !application.isTerminated
                        && NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PDDCustomerVideoError.clickFailed
        }
        try Task.checkCancellation()
        let point = CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
        guard let down = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left
        ) else { throw PDDCustomerVideoError.clickFailed }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        try Task.checkCancellation()
    }

    private func copyElements(_ name: String, from element: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return [] }
        return raw as? [AXUIElement] ?? []
    }

    private func copyString(_ name: String, from element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw else { return nil }
        return AXValueFormatter.string(from: raw)
    }

    func close() async {
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.pinduoduo.merchantMac"
        ).first else { return }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        for window in copyElements(kAXWindowsAttribute as String, from: appElement) {
            var visited = Set<CFHashCode>()
            var budget = 2_000
            guard let preview = firstDescendant(
                from: window,
                visited: &visited,
                budget: &budget,
                where: { element in
                    labels(of: element).contains(where: PDDVideoPreviewElementPolicy.isPreviewMarker)
                }
            ) else { continue }

            var previewScope: AXUIElement? = preview
            for _ in 0..<3 {
                guard let scope = previewScope else { break }
                visited.removeAll(keepingCapacity: true)
                budget = 250
                if let closeButton = firstDescendant(
                    from: scope,
                    visited: &visited,
                    budget: &budget,
                    where: { element in
                        PDDVideoPreviewElementPolicy.isCloseButton(
                            role: copyString(kAXRoleAttribute as String, from: element) ?? "",
                            labels: labels(of: element)
                        )
                    }
                ) {
                    _ = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
                    return
                }
                guard let parent = copyElement(kAXParentAttribute as String, from: scope) else { break }
                let parentRole = copyString(kAXRoleAttribute as String, from: parent) ?? ""
                guard parentRole != kAXWindowRole as String,
                      parentRole != kAXApplicationRole as String else { break }
                previewScope = parent
            }
        }
    }

    private func isPreviewOpen() -> Bool {
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.pinduoduo.merchantMac"
        ).first else { return false }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        for window in copyElements(kAXWindowsAttribute as String, from: appElement) {
            var visited = Set<CFHashCode>()
            var budget = 2_000
            if firstDescendant(
                from: window,
                visited: &visited,
                budget: &budget,
                where: { element in
                    if labels(of: element).contains(where: PDDVideoPreviewElementPolicy.isPreviewMarker) {
                        return true
                    }
                    let dom = [
                        copyString("AXDOMIdentifier", from: element),
                        copyString("AXDOMClassList", from: element)
                    ].compactMap { $0 }.joined(separator: " ").lowercased()
                    return dom.contains("video-preview")
                        || dom.contains("video-player")
                        || dom.contains("video-modal")
                }
            ) != nil { return true }
        }
        return false
    }

    private func firstDescendant(
        from element: AXUIElement,
        visited: inout Set<CFHashCode>,
        budget: inout Int,
        where matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        guard budget > 0, visited.insert(CFHash(element)).inserted else { return nil }
        budget -= 1
        if matches(element) { return element }
        let children = copyElements("AXChildrenInNavigationOrder", from: element)
            + copyElements(kAXChildrenAttribute as String, from: element)
        for child in children {
            if let match = firstDescendant(
                from: child, visited: &visited, budget: &budget, where: matches
            ) {
                return match
            }
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

    private func copyElement(_ name: String, from element: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }
}
