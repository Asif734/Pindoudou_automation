import AppKit
import ApplicationServices
import Foundation

struct AXElementToken: Hashable, Sendable {
    let rawValue: Int
}

struct PDDAXSemanticTree {
    let rootSnapshot: AXNodeSnapshot
    let nodes: [PDDAXSemanticNode<AXElementToken>]
}

enum PDDAXWebTreeRecoveryAction: Equatable {
    case healthy
    case request
    case waiting
    case restart
}

struct PDDAXWebTreeRecoveryPolicy {
    let cooldown: TimeInterval
    let restartAfter: TimeInterval
    let restartCooldown: TimeInterval
    private var lastRequestAt: Date?
    private var missingSince: Date?
    private var lastRestartAt: Date?

    init(
        cooldown: TimeInterval = 3,
        restartAfter: TimeInterval = 12,
        restartCooldown: TimeInterval = 60
    ) {
        self.cooldown = cooldown
        self.restartAfter = restartAfter
        self.restartCooldown = restartCooldown
    }

    mutating func evaluate<ID: Hashable>(
        nodes: [PDDAXSemanticNode<ID>],
        now: Date
    ) -> PDDAXWebTreeRecoveryAction {
        let hasWebArea = nodes.contains { $0.role == "AXWebArea" }
        let hasChatSurface = nodes.contains { node in
            if node.domIdentifier?.hasPrefix("middlePanel_list_") == true { return true }
            return node.domClasses.contains { rawClass in
                let value = rawClass.lowercased()
                return value.contains("chat-list-box")
                    || value.contains("conversation-list")
                    || value.contains("middle-panel")
                    || value.contains("chat-panel")
            }
        }
        let hasTransferDialogSurface = nodes.contains { node in
            node.isSettable && ([node.value, node.title].compactMap { $0 }
                .contains("请输入内容") || node.domClasses.contains("el-input__inner"))
        } && nodes.contains { node in
            [node.value, node.title].compactMap { $0 }.contains("转移")
        }
        if (hasWebArea && hasChatSurface) || hasTransferDialogSurface {
            lastRequestAt = nil
            missingSince = nil
            return .healthy
        }
        if missingSince == nil { missingSince = now }
        if let missingSince,
           now.timeIntervalSince(missingSince) >= restartAfter,
           lastRestartAt.map({ now.timeIntervalSince($0) >= restartCooldown }) ?? true {
            lastRestartAt = now
            lastRequestAt = now
            self.missingSince = now
            return .restart
        }
        if let lastRequestAt, now.timeIntervalSince(lastRequestAt) < cooldown {
            return .waiting
        }
        lastRequestAt = now
        return .request
    }
}

@MainActor
protocol PDDAXForcedAccessibilityRestarting: AnyObject {
    func restart(_ application: NSRunningApplication) -> Bool
}

@MainActor
final class LivePDDAXForcedAccessibilityRestarter: PDDAXForcedAccessibilityRestarting {
    static let argument = "--force-renderer-accessibility"

    func restart(_ application: NSRunningApplication) -> Bool {
        guard let bundleURL = application.bundleURL, application.terminate() else { return false }
        Task { @MainActor in
            for _ in 0..<30 where !application.isTerminated {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = [Self.argument]
            configuration.activates = false
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(
                at: bundleURL,
                configuration: configuration,
                completionHandler: { _, _ in }
            )
        }
        return true
    }
}

@MainActor
protocol PDDAXBackend: AnyObject {
    func readSemanticTree() throws -> PDDAXSemanticTree
    func performPress(_ id: AXElementToken) throws
    func setValue(_ text: String, on id: AXElementToken) throws
    func value(of id: AXElementToken) throws -> String
}

enum PDDAXBackendError: LocalizedError {
    case staleElement
    case actionFailed(AXError)
    case valueReadFailed(AXError)
    case valueWriteFailed(AXError)
    case webTreeRecovering(requestAccepted: Bool)
    case webTreeRestarting(requestAccepted: Bool)

    var errorDescription: String? {
        switch self {
        case .staleElement: return "AX 元素令牌已失效"
        case .actionFailed(let error): return "AXPress 失败：\(error.rawValue)"
        case .valueReadFailed(let error): return "AXValue 读取失败：\(error.rawValue)"
        case .valueWriteFailed(let error): return "AXValue 写入失败：\(error.rawValue)"
        case .webTreeRecovering(let requestAccepted):
            return requestAccepted
                ? "拼多多聊天 AX 子树缺失；已请求 Chromium 恢复，调度器会继续重扫"
                : "拼多多聊天 AX 子树缺失；恢复请求暂未生效，调度器会继续重试"
        case .webTreeRestarting(let requestAccepted):
            return requestAccepted
                ? "拼多多聊天 AX 持续缺失；正在强制 AX 模式重启拼多多，调度器会自动接回"
                : "拼多多聊天 AX 持续缺失；自动重启请求失败，调度器会继续重试"
        }
    }
}

enum PDDAXActionPolicy {
    static func shouldReadActions(
        role: String,
        value: String?,
        title: String?,
        domClasses: Set<String>,
        insideConversationList: Bool = false
    ) -> Bool {
        insideConversationList
            || role == "AXButton"
            || value == "发送"
            || title == "发送"
            || domClasses.contains { $0.lowercased().contains("send-btn") }
    }

    static func shouldReadSettable(role: String) -> Bool {
        role == "AXTextArea" || role == "AXTextField" || role == "AXComboBox"
    }
}

enum PDDAXBackendPolicy {
    static let semanticAttributeNames = [
        kAXValueAttribute as String,
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        "AXURL",
        "AXDOMClassList",
        "AXDOMIdentifier",
    ]
}

enum PDDAXRootWindowPreference {
    static func select<T>(
        titledWindows: [(title: String, element: T)],
        focusedWindow: T?,
        mainWindow: T?,
        application: T
    ) -> T {
        titledWindows.first { $0.title.contains("拼多多商家工作台") }?.element
            ?? focusedWindow
            ?? mainWindow
            ?? application
    }
}

@MainActor
final class LivePDDAXBackend: PDDAXBackend {
    private struct ElementIdentity: Hashable {
        let element: AXUIElement
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    }

    private let targetBundleIdentifier: String
    private let maxDepth: Int
    private let maxNodes: Int
    private let now: @MainActor () -> Date
    private let forcedAccessibilityRestarter: any PDDAXForcedAccessibilityRestarting
    private var elements: [AXElementToken: AXUIElement] = [:]
    private var nextToken = 0
    private var visited = Set<ElementIdentity>()
    private var webTreeRecovery = PDDAXWebTreeRecoveryPolicy()

    init(
        targetBundleIdentifier: String = "com.pinduoduo.merchantMac",
        maxDepth: Int = 80,
        maxNodes: Int = 20_000,
        forcedAccessibilityRestarter: (any PDDAXForcedAccessibilityRestarting)? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.targetBundleIdentifier = targetBundleIdentifier
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.forcedAccessibilityRestarter = forcedAccessibilityRestarter
            ?? LivePDDAXForcedAccessibilityRestarter()
        self.now = now
    }

    func readSemanticTree() throws -> PDDAXSemanticTree {
        guard AXIsProcessTrusted() else { throw AXTreeReaderError.accessibilityPermissionRequired }
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: targetBundleIdentifier).first else {
            throw AXTreeReaderError.applicationNotRunning("拼多多商家版")
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        if AXEnhancedUserInterfaceActivation.enableIfNeeded(on: appElement) {
            Thread.sleep(forTimeInterval: 0.2)
        }
        let titledWindows = copyElements(kAXWindowsAttribute as String, from: appElement).map {
            (title: copyString(kAXTitleAttribute as String, from: $0) ?? "", element: $0)
        }
        let root = PDDAXRootWindowPreference.select(
            titledWindows: titledWindows,
            focusedWindow: copyElement(kAXFocusedWindowAttribute as String, from: appElement),
            mainWindow: copyElement(kAXMainWindowAttribute as String, from: appElement),
            application: appElement
        )
        elements.removeAll(keepingCapacity: true)
        visited.removeAll(keepingCapacity: true)
        nextToken = 0
        var nodes: [PDDAXSemanticNode<AXElementToken>] = []
        let snapshot = walk(root, parent: nil, depth: 0, nodes: &nodes)
        switch webTreeRecovery.evaluate(nodes: nodes, now: now()) {
        case .healthy:
            return PDDAXSemanticTree(rootSnapshot: snapshot, nodes: nodes)
        case .request:
            throw PDDAXBackendError.webTreeRecovering(
                requestAccepted: AXEnhancedUserInterfaceActivation.requestEnable(on: appElement)
            )
        case .waiting:
            throw PDDAXBackendError.webTreeRecovering(requestAccepted: true)
        case .restart:
            throw PDDAXBackendError.webTreeRestarting(
                requestAccepted: forcedAccessibilityRestarter.restart(application)
            )
        }
    }

    func performPress(_ id: AXElementToken) throws {
        guard let element = elements[id] else { throw PDDAXBackendError.staleElement }
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard error == .success else { throw PDDAXBackendError.actionFailed(error) }
    }

    func setValue(_ text: String, on id: AXElementToken) throws {
        guard let element = elements[id] else { throw PDDAXBackendError.staleElement }
        let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        guard error == .success else { throw PDDAXBackendError.valueWriteFailed(error) }
    }

    func value(of id: AXElementToken) throws -> String {
        guard let element = elements[id] else { throw PDDAXBackendError.staleElement }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard error == .success else { throw PDDAXBackendError.valueReadFailed(error) }
        guard let value else { return "" }
        return AXValueFormatter.string(from: value)
    }

    private func walk(
        _ element: AXUIElement,
        parent: AXElementToken?,
        depth: Int,
        nodes: inout [PDDAXSemanticNode<AXElementToken>],
        insideConversationList: Bool = false
    ) -> AXNodeSnapshot {
        guard depth <= maxDepth else { return AXNodeSnapshot(role: "⟪达到最大递归深度⟫") }
        guard nodes.count < maxNodes else { return AXNodeSnapshot(role: "⟪达到最大节点数⟫") }
        guard visited.insert(ElementIdentity(element: element)).inserted else {
            return AXNodeSnapshot(role: "⟪循环引用，已跳过⟫")
        }

        let token = AXElementToken(rawValue: nextToken)
        nextToken += 1
        elements[token] = element
        let names = [kAXRoleAttribute as String]
            + PDDAXBackendPolicy.semanticAttributeNames
            + [
                kAXPositionAttribute as String, kAXSizeAttribute as String,
                "AXChildrenInNavigationOrder",
                kAXChildrenAttribute as String,
            ]
        let values = copyMultiple(names, from: element)
        let role = values[kAXRoleAttribute as String].map(AXValueFormatter.string(from:)) ?? "AXUnknown"
        let value = values[kAXValueAttribute as String].map(AXValueFormatter.string(from:))
        let title = values[kAXTitleAttribute as String].map(AXValueFormatter.string(from:))
        let domIdentifier = values["AXDOMIdentifier"].map(AXValueFormatter.string(from:))
        let domClasses = values["AXDOMClassList"].map(AXValueFormatter.string(from:))
            .map(parseDOMClasses) ?? []
        let frame = frame(
            position: values[kAXPositionAttribute as String],
            size: values[kAXSizeAttribute as String]
        )
        let actions = PDDAXActionPolicy.shouldReadActions(
            role: role, value: value, title: title, domClasses: domClasses,
            insideConversationList: insideConversationList
        )
            ? Set(copyActionNames(from: element)) : []
        var isSettable = false
        if PDDAXActionPolicy.shouldReadSettable(role: role) {
            var settable = DarwinBoolean(false)
            let settableError = AXUIElementIsAttributeSettable(
                element, kAXValueAttribute as CFString, &settable
            )
            isSettable = settableError == .success && settable.boolValue
        }
        nodes.append(PDDAXSemanticNode(
            id: token, parentID: parent, role: role, value: value, title: title,
            domIdentifier: domIdentifier, domClasses: domClasses,
            actionNames: actions, isSettable: isSettable, frame: frame
        ))

        var attributes: [(String, String)] = []
        for name in names.dropFirst() where !name.hasPrefix("AXChildren") {
            if let raw = values[name] { attributes.append((name, AXValueFormatter.string(from: raw))) }
        }
        let navigation = values["AXChildrenInNavigationOrder"] as? [AXUIElement]
        let ordinary = values[kAXChildrenAttribute as String] as? [AXUIElement]
        let childElements = navigation.flatMap { $0.isEmpty ? nil : $0 } ?? ordinary ?? []
        let childIsInsideConversationList = insideConversationList || domClasses.contains { rawClass in
            let value = rawClass.lowercased()
            return value.contains("chat-list-box") || value.contains("conversation-list")
        }
        let children = childElements.map {
            walk(
                $0, parent: token, depth: depth + 1, nodes: &nodes,
                insideConversationList: childIsInsideConversationList
            )
        }
        return AXNodeSnapshot(role: role, attributes: attributes, actions: Array(actions), children: children)
    }

    private func frame(position: CFTypeRef?, size: CFTypeRef?) -> CGRect {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return .zero }
        let positionValue: AXValue = unsafeBitCast(position, to: AXValue.self)
        let sizeValue: AXValue = unsafeBitCast(size, to: AXValue.self)
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return .zero }
        return CGRect(origin: point, size: dimensions)
    }

    private func copyMultiple(_ names: [String], from element: AXUIElement) -> [String: CFTypeRef] {
        var rawValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &rawValues) == .success,
              let values = rawValues as? [Any], values.count == names.count else { return [:] }
        var result: [String: CFTypeRef] = [:]
        for (name, raw) in zip(names, values) {
            let value = raw as CFTypeRef
            if CFGetTypeID(value) != CFNullGetTypeID(), CFGetTypeID(value) != AXValueGetTypeID() {
                result[name] = value
            } else if CFGetTypeID(value) == AXValueGetTypeID() {
                let axValue: AXValue = unsafeBitCast(value, to: AXValue.self)
                if AXValueGetType(axValue) != .axError { result[name] = value }
            }
        }
        return result
    }

    private func copyElement(_ name: String, from element: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private func copyElements(_ name: String, from element: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw else { return [] }
        return raw as? [AXUIElement] ?? []
    }

    private func copyString(_ name: String, from element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw else { return nil }
        return AXValueFormatter.string(from: raw)
    }

    private func copyActionNames(from element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private func parseDOMClasses(_ raw: String) -> Set<String> {
        Set(raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    }
}
