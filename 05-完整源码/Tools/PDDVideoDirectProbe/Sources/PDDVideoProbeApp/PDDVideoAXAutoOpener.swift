import AppKit
import ApplicationServices
import Foundation
import PDDVideoProbeCore

@MainActor
final class PDDVideoAXAutoOpener {
    private struct ElementIdentity: Hashable {
        let element: AXUIElement

        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    }

    private let bundleIdentifier = "com.pinduoduo.merchantMac"
    private let maxSearchDepth = 50
    private let maxSearchNodes = 1_200
    private let maxMessageNodes = 1_200
    private let scanBudget: TimeInterval = 1.5
    private var targetProcessIdentifier: pid_t?
    private let diagnosticURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pdd-video-ax-diagnostic.txt")

    func latestCustomerVideo() async throws -> PDDVideoAXCandidate? {
        writeDiagnostic("stage=entered")
        targetProcessIdentifier = nil
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
            throw PDDVideoProbeError.accessibilityPermissionRequired
        }
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else {
            throw PDDVideoProbeError.applicationNotRunning
        }
        guard let bundleURL = application.bundleURL else {
            throw PDDVideoProbeError.applicationNotRunning
        }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.20)
        _ = AXUIElementSetAttributeValue(
            applicationElement,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
        guard let root = preferredRoot(applicationElement) else {
            writeDiagnostic("stage=root_missing")
            return nil
        }
        try await PDDVideoForegroundActivation.run(
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
                AXUIElementPerformAction(root, kAXRaiseAction as CFString) == .success
            },
            isFrontmost: {
                !application.isTerminated
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier
                        == application.processIdentifier
            }
        )
        writeDiagnostic("stage=activated pid=\(application.processIdentifier)")
        let deadline = Date().addingTimeInterval(scanBudget)
        guard let messageList = findMessageList(in: root, deadline: deadline) else {
            writeDiagnostic("stage=message_list_missing")
            return nil
        }
        var visited = Set<ElementIdentity>()
        var nodes: [PDDVideoAXNode] = []
        let completed = walk(
            messageList, parentID: nil, depth: 0, deadline: deadline,
            visited: &visited, nodes: &nodes
        )

        let candidate = PDDVideoAXCandidateSelector.latestCustomerVideo(in: nodes, isComplete: completed)
        let videoClassCount = nodes.filter { node in
            node.domClasses.contains { $0.lowercased().contains("video") }
        }.count
        let imageRoleCount = nodes.filter {
            $0.role.caseInsensitiveCompare("AXImage") == .orderedSame
        }.count
        let durationCount = nodes.filter { node in
            [node.value, node.title, node.description].compactMap { $0 }.contains { value in
                value.range(of: #"^(?:\d{1,2}:)?\d{1,2}:\d{2}$"#, options: .regularExpression) != nil
            }
        }.count
        let messageIDCount = nodes.filter {
            $0.domIdentifier?.hasPrefix("middlePanel_list_") == true
        }.count
        writeDiagnostic(
            "stage=selection completed=\(completed) nodes=\(nodes.count) "
                + "message_ids=\(messageIDCount) video_classes=\(videoClassCount) "
                + "image_roles=\(imageRoleCount) durations=\(durationCount) "
                + "candidate=\(candidate != nil)"
        )
        if candidate != nil { targetProcessIdentifier = application.processIdentifier }
        return candidate
    }

    private func writeDiagnostic(_ text: String) {
        try? Data((text + "\n").utf8).write(to: diagnosticURL, options: .atomic)
    }

    func click(_ candidate: PDDVideoAXCandidate) throws {
        guard let targetProcessIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetProcessIdentifier,
              NSRunningApplication(processIdentifier: targetProcessIdentifier)?.isActive == true else {
            throw PDDVideoProbeError.videoClickFailed
        }
        let point = CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw PDDVideoProbeError.videoClickFailed
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func preferredRoot(_ application: AXUIElement) -> AXUIElement? {
        let mainRead = copyElementChecked(kAXMainWindowAttribute as String, from: application)
        guard !mainRead.failed else { return nil }
        if let main = mainRead.value {
            return main
        }
        let focusedRead = copyElementChecked(kAXFocusedWindowAttribute as String, from: application)
        guard !focusedRead.failed else { return nil }
        if let focused = focusedRead.value {
            return focused
        }
        let windowsRead = copyElementsChecked(kAXWindowsAttribute as String, from: application)
        guard !windowsRead.failed else { return nil }
        for window in windowsRead.value ?? [] {
            let titleRead = copyStringChecked(kAXTitleAttribute as String, from: window)
            guard !titleRead.failed else { return nil }
            if titleRead.value?.contains("拼多多商家工作台") == true { return window }
        }
        return nil
    }

    private func findMessageList(in root: AXUIElement, deadline: Date) -> AXUIElement? {
        var stack: [(element: AXUIElement, depth: Int, ancestorHidden: Bool)] = [(root, 0, false)]
        var visited = Set<ElementIdentity>()
        var inspected = 0
        while let (element, depth, ancestorHidden) = stack.popLast(),
              depth <= maxSearchDepth, inspected < maxSearchNodes, Date() < deadline {
            guard visited.insert(ElementIdentity(element: element)).inserted else { continue }
            inspected += 1
            let hiddenRead = copyBoolChecked(kAXHiddenAttribute as String, from: element)
            let visibleRead = copyBoolChecked("AXVisible", from: element)
            guard !hiddenRead.failed, !visibleRead.failed else { return nil }
            let hidden = ancestorHidden || hiddenRead.value == true || visibleRead.value == false
            guard !hidden, Date() < deadline else { continue }
            let identifierRead = copyStringChecked("AXDOMIdentifier", from: element)
            let classesRead = copyDOMClassesChecked(from: element)
            guard !identifierRead.failed, !classesRead.failed else { return nil }
            let identifier = identifierRead.value
            let classes = classesRead.value.map { $0.lowercased() }
            if identifier == "msgListContainer" || classes.contains("msg-list") {
                return element
            }
            let navigationRead = copyElementsChecked("AXChildrenInNavigationOrder", from: element)
            guard !navigationRead.failed else { return nil }
            let children: [AXUIElement]
            if let navigationChildren = navigationRead.value, !navigationChildren.isEmpty {
                children = navigationChildren
            } else {
                let ordinaryRead = copyElementsChecked(kAXChildrenAttribute as String, from: element)
                guard !ordinaryRead.failed else { return nil }
                children = ordinaryRead.value ?? []
            }
            for child in children.reversed() { stack.append((child, depth + 1, hidden)) }
        }
        return nil
    }

    private func walk(
        _ element: AXUIElement,
        parentID: Int?,
        depth: Int,
        deadline: Date,
        visited: inout Set<ElementIdentity>,
        nodes: inout [PDDVideoAXNode]
    ) -> Bool {
        guard Date() < deadline, depth <= maxSearchDepth,
              nodes.count < maxMessageNodes else { return false }
        guard visited.insert(ElementIdentity(element: element)).inserted else { return true }
        let id = nodes.count
        let domIdentifierRead = copyStringChecked("AXDOMIdentifier", from: element)
        guard !domIdentifierRead.failed else { return false }
        let domIdentifier = domIdentifierRead.value
        guard Date() < deadline else { return false }
        let domClassesRead = copyDOMClassesChecked(from: element)
        guard !domClassesRead.failed else { return false }
        let domClasses = domClassesRead.value
        guard Date() < deadline else { return false }
        let roleRead = copyStringChecked(kAXRoleAttribute as String, from: element)
        let valueRead = copyStringChecked(kAXValueAttribute as String, from: element)
        let descriptionRead = copyStringChecked(kAXDescriptionAttribute as String, from: element)
        guard !roleRead.failed, !valueRead.failed, !descriptionRead.failed else { return false }
        guard Date() < deadline else { return false }
        let frameRead = copyFrameChecked(from: element)
        guard !frameRead.failed else { return false }
        let frame = frameRead.value
        guard Date() < deadline else { return false }
        let hiddenRead = copyBoolChecked(kAXHiddenAttribute as String, from: element)
        let visibleRead = copyBoolChecked("AXVisible", from: element)
        guard !hiddenRead.failed, !visibleRead.failed else { return false }
        let isHidden = hiddenRead.value == true || visibleRead.value == false
        nodes.append(PDDVideoAXNode(
            id: id,
            parentID: parentID,
            role: roleRead.value ?? "AXUnknown",
            value: valueRead.value,
            title: nil,
            description: descriptionRead.value,
            domIdentifier: domIdentifier,
            domClasses: domClasses,
            frame: frame,
            isHidden: isHidden
        ))
        guard Date() < deadline else { return false }
        let navigationRead = copyElementsChecked("AXChildrenInNavigationOrder", from: element)
        guard !navigationRead.failed else { return false }
        let navigationChildren = navigationRead.value
        let children: [AXUIElement]
        if let navigationChildren, !navigationChildren.isEmpty {
            children = navigationChildren
        } else {
            let ordinaryRead = copyElementsChecked(kAXChildrenAttribute as String, from: element)
            guard !ordinaryRead.failed else { return false }
            children = ordinaryRead.value ?? []
        }
        for child in children {
            guard walk(
                child, parentID: id, depth: depth + 1, deadline: deadline,
                visited: &visited, nodes: &nodes
            ) else { return false }
        }
        return true
    }

    private func copyFrameChecked(from element: AXUIElement) -> (value: CGRect, failed: Bool) {
        let positionRead = copyAttributeChecked(kAXPositionAttribute as String, from: element)
        let sizeRead = copyAttributeChecked(kAXSizeAttribute as String, from: element)
        guard !positionRead.failed, !sizeRead.failed else { return (.zero, true) }
        guard let positionRaw = positionRead.value,
              let sizeRaw = sizeRead.value,
              CFGetTypeID(positionRaw) == AXValueGetTypeID(),
              CFGetTypeID(sizeRaw) == AXValueGetTypeID() else { return (.zero, false) }
        let positionValue: AXValue = unsafeBitCast(positionRaw, to: AXValue.self)
        let sizeValue: AXValue = unsafeBitCast(sizeRaw, to: AXValue.self)
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return (.zero, false) }
        return (CGRect(origin: point, size: size), false)
    }

    private func copyDOMClassesChecked(from element: AXUIElement) -> (value: Set<String>, failed: Bool) {
        let read = copyAttributeChecked("AXDOMClassList", from: element)
        guard !read.failed else { return ([], true) }
        guard let raw = read.value else { return ([], false) }
        if let values = raw as? [String] { return (Set(values), false) }
        let text = String(describing: raw)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return (Set(text.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }.filter { !$0.isEmpty }), false)
    }

    private func copyString(_ attribute: String, from element: AXUIElement) -> String? {
        copyStringChecked(attribute, from: element).value
    }

    private func copyStringChecked(
        _ attribute: String,
        from element: AXUIElement
    ) -> (value: String?, failed: Bool) {
        let read = copyAttributeChecked(attribute, from: element)
        guard !read.failed else { return (nil, true) }
        guard let raw = read.value else { return (nil, false) }
        if let value = raw as? String { return (value, false) }
        if let value = raw as? URL { return (value.absoluteString, false) }
        return (String(describing: raw), false)
    }

    private func copyBoolChecked(
        _ attribute: String,
        from element: AXUIElement
    ) -> (value: Bool?, failed: Bool) {
        let read = copyAttributeChecked(attribute, from: element)
        guard !read.failed else { return (nil, true) }
        guard let raw = read.value else { return (nil, false) }
        if let value = raw as? Bool { return (value, false) }
        if let value = raw as? NSNumber { return (value.boolValue, false) }
        return (nil, false)
    }

    private func copyElementChecked(
        _ attribute: String,
        from element: AXUIElement
    ) -> (value: AXUIElement?, failed: Bool) {
        let read = copyAttributeChecked(attribute, from: element)
        guard !read.failed else { return (nil, true) }
        guard let raw = read.value else { return (nil, false) }
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return (nil, true) }
        return (unsafeBitCast(raw, to: AXUIElement.self), false)
    }

    private func copyElementsChecked(
        _ attribute: String,
        from element: AXUIElement
    ) -> (value: [AXUIElement]?, failed: Bool) {
        let read = copyAttributeChecked(attribute, from: element)
        guard !read.failed else { return (nil, true) }
        guard let raw = read.value else { return (nil, false) }
        guard let elements = raw as? [AXUIElement] else { return (nil, true) }
        return (elements, false)
    }

    private func copyAttributeChecked(
        _ attribute: String,
        from element: AXUIElement
    ) -> (value: CFTypeRef?, failed: Bool) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        switch error {
        case .success:
            return (value, false)
        case .attributeUnsupported, .noValue:
            return (nil, false)
        default:
            return (nil, true)
        }
    }
}
