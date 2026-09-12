import AppKit
import ApplicationServices
import Foundation

enum AXTraversalDecision: Equatable {
    case proceed
    case depthLimit
    case nodeLimit
    case cycle
}

enum AXSnapshotRootPreference {
    static func select<T>(focusedWindow: T?, mainWindow: T?, application: T) -> T {
        focusedWindow ?? mainWindow ?? application
    }
}

enum AXAttributeReadProfile {
    case full
    case chatParsing

    var prefersNavigationChildren: Bool {
        self == .chatParsing
    }

    var needsAttributeDiscovery: Bool {
        self == .full
    }

    var readsActions: Bool {
        self == .full
    }

    var usesBatchedReads: Bool {
        self == .chatParsing
    }

    var parserAttributeNames: [String] {
        [
            "AXValue",
            "AXTitle",
            "AXDescription",
            "AXURL",
            "AXDOMClassList",
            "AXDOMIdentifier",
            "ChromeAXNodeId"
        ]
    }

    var multipleAttributeNames: [String] {
        guard usesBatchedReads else { return [] }
        return [kAXRoleAttribute as String]
            + parserAttributeNames
            + ["AXChildrenInNavigationOrder", kAXChildrenAttribute as String]
    }

    func shouldRead(_ name: String) -> Bool {
        guard name != kAXChildrenAttribute as String,
              name != kAXRoleAttribute as String else {
            return false
        }
        switch self {
        case .full:
            return true
        case .chatParsing:
            return parserAttributeNames.contains(name)
        }
    }
}

struct AXTraversalPolicy<Identifier: Hashable> {
    let maxDepth: Int
    let maxNodes: Int

    private(set) var visitedIdentifiers: Set<Identifier> = []
    private(set) var nodeCount = 0

    mutating func enter(identifier: Identifier, depth: Int) -> AXTraversalDecision {
        guard depth <= maxDepth else { return .depthLimit }
        guard nodeCount < maxNodes else { return .nodeLimit }
        guard visitedIdentifiers.insert(identifier).inserted else { return .cycle }

        nodeCount += 1
        return .proceed
    }
}

private struct AXElementIdentity: Hashable {
    let element: AXUIElement

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }

    static func == (lhs: AXElementIdentity, rhs: AXElementIdentity) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

struct AXReadResult {
    let root: AXNodeSnapshot
    let nodeCount: Int
    let elapsedSeconds: TimeInterval
    let applicationName: String
}

struct AXEnhancedUserInterfaceActivation {
    let readBoolean: (_ attribute: String) -> Bool?
    let setBoolean: (_ attribute: String, _ value: Bool) -> AXError

    func enableIfNeeded() -> Bool {
        let attribute = "AXEnhancedUserInterface"
        guard readBoolean(attribute) != true else { return false }
        _ = setBoolean(attribute, true)
        return true
    }

    func requestEnable() -> Bool {
        setBoolean("AXEnhancedUserInterface", true) == .success
    }

    static func enableIfNeeded(on element: AXUIElement) -> Bool {
        AXEnhancedUserInterfaceActivation(
            readBoolean: { attribute in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                      let number = value as? NSNumber else {
                    return nil
                }
                return number.boolValue
            },
            setBoolean: { attribute, value in
                AXUIElementSetAttributeValue(
                    element,
                    attribute as CFString,
                    value ? kCFBooleanTrue : kCFBooleanFalse
                )
            }
        ).enableIfNeeded()
    }

    static func requestEnable(on element: AXUIElement) -> Bool {
        AXEnhancedUserInterfaceActivation(
            readBoolean: { _ in nil },
            setBoolean: { attribute, value in
                AXUIElementSetAttributeValue(
                    element,
                    attribute as CFString,
                    value ? kCFBooleanTrue : kCFBooleanFalse
                )
            }
        ).requestEnable()
    }
}

enum AXTreeReaderError: LocalizedError {
    case accessibilityPermissionRequired
    case applicationNotRunning(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "需要在“系统设置 → 隐私与安全性 → 辅助功能”中允许本程序。"
        case .applicationNotRunning(let name):
            return "没有找到正在运行的\(name)，请先打开客服页面。"
        }
    }
}

final class AXTreeReader {
    private enum AttributeReadResult {
        case success(CFTypeRef)
        case failure(AXError)
    }

    let targetBundleIdentifier: String
    let maxDepth: Int
    let maxNodes: Int
    let readProfile: AXAttributeReadProfile

    init(
        targetBundleIdentifier: String = "com.pinduoduo.merchantMac",
        maxDepth: Int = 80,
        maxNodes: Int = 20_000,
        readProfile: AXAttributeReadProfile = .full
    ) {
        self.targetBundleIdentifier = targetBundleIdentifier
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.readProfile = readProfile
    }

    func read() throws -> AXReadResult {
        guard AXIsProcessTrusted() else {
            throw AXTreeReaderError.accessibilityPermissionRequired
        }

        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: targetBundleIdentifier)
            .first else {
            throw AXTreeReaderError.applicationNotRunning("拼多多商家版")
        }

        let startedAt = Date()
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        if AXEnhancedUserInterfaceActivation.enableIfNeeded(on: applicationElement) {
            Thread.sleep(forTimeInterval: 0.2)
        }
        let rootElement = AXSnapshotRootPreference.select(
            focusedWindow: copyElementAttribute(kAXFocusedWindowAttribute as String, of: applicationElement),
            mainWindow: copyElementAttribute(kAXMainWindowAttribute as String, of: applicationElement),
            application: applicationElement
        )
        var policy = AXTraversalPolicy<AXElementIdentity>(maxDepth: maxDepth, maxNodes: maxNodes)
        let root = snapshot(element: rootElement, depth: 0, policy: &policy)

        return AXReadResult(
            root: root,
            nodeCount: policy.nodeCount,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            applicationName: application.localizedName ?? "拼多多商家版"
        )
    }

    private func snapshot(
        element: AXUIElement,
        depth: Int,
        policy: inout AXTraversalPolicy<AXElementIdentity>
    ) -> AXNodeSnapshot {
        let identifier = AXElementIdentity(element: element)

        switch policy.enter(identifier: identifier, depth: depth) {
        case .depthLimit:
            return AXNodeSnapshot(role: "⟪达到最大递归深度 \(maxDepth)⟫")
        case .nodeLimit:
            return AXNodeSnapshot(role: "⟪达到最大节点数 \(maxNodes)⟫")
        case .cycle:
            return AXNodeSnapshot(role: "⟪循环引用，已跳过⟫")
        case .proceed:
            break
        }

        if readProfile.usesBatchedReads,
           let batched = copyMultipleAttributeResults(
               readProfile.multipleAttributeNames,
               of: element
           ) {
            return snapshotBatched(
                depth: depth,
                policy: &policy,
                results: batched
            )
        }

        let attributeNames = readProfile.needsAttributeDiscovery
            ? copyAttributeNames(of: element)
            : readProfile.parserAttributeNames
        let role = copyAttribute(kAXRoleAttribute as String, of: element)
            .map(AXValueFormatter.string(from:)) ?? "AXUnknown"

        var attributes: [(String, String)] = []
        for name in attributeNames.sorted() where readProfile.shouldRead(name) {
            switch copyAttributeResult(name, of: element) {
            case .success(let value):
                attributes.append((name, AXValueFormatter.string(from: value)))
            case .failure(let error):
                attributes.append((name, "<AX error \(error.rawValue)>"))
            }
        }

        let childElements = copyChildren(of: element)
        if attributeNames.contains(kAXChildrenAttribute as String) {
            attributes.append(("AXChildrenCount", "\(childElements.count)"))
        }

        let children = childElements.map {
            snapshot(element: $0, depth: depth + 1, policy: &policy)
        }

        let actions = readProfile.readsActions ? copyActionNames(of: element).sorted() : []
        return AXNodeSnapshot(
            role: role,
            attributes: attributes,
            actions: actions,
            children: children
        )
    }

    private func snapshotBatched(
        depth: Int,
        policy: inout AXTraversalPolicy<AXElementIdentity>,
        results: [String: AttributeReadResult]
    ) -> AXNodeSnapshot {
        let role = successfulValue(in: results[kAXRoleAttribute as String])
            .map(AXValueFormatter.string(from:)) ?? "AXUnknown"

        var attributes: [(String, String)] = []
        for name in readProfile.parserAttributeNames {
            switch results[name] {
            case .success(let value):
                attributes.append((name, AXValueFormatter.string(from: value)))
            case .failure(let error):
                attributes.append((name, "<AX error \(error.rawValue)>"))
            case nil:
                break
            }
        }

        let navigationChildren = successfulValue(in: results["AXChildrenInNavigationOrder"])
            .flatMap { $0 as? [AXUIElement] }
        let ordinaryChildren = successfulValue(in: results[kAXChildrenAttribute as String])
            .flatMap { $0 as? [AXUIElement] }
        let childElements = navigationChildren.flatMap { $0.isEmpty ? nil : $0 }
            ?? ordinaryChildren
            ?? []

        let children = childElements.map {
            snapshot(element: $0, depth: depth + 1, policy: &policy)
        }
        return AXNodeSnapshot(
            role: role,
            attributes: attributes,
            actions: [],
            children: children
        )
    }

    private func copyAttributeNames(of element: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyAttributeNames(element, &value) == .success else { return [] }
        return value as? [String] ?? []
    }

    private func copyActionNames(of element: AXUIElement) -> [String] {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success else { return [] }
        return value as? [String] ?? []
    }

    private func copyAttribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        guard case .success(let value) = copyAttributeResult(name, of: element) else { return nil }
        return value
    }

    private func copyElementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = copyAttribute(name, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func copyAttributeResult(
        _ name: String,
        of element: AXUIElement
    ) -> AttributeReadResult {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success, let value else { return .failure(error) }
        return .success(value)
    }

    private func copyMultipleAttributeResults(
        _ names: [String],
        of element: AXUIElement
    ) -> [String: AttributeReadResult]? {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            names as CFArray,
            [],
            &values
        )
        guard error == .success,
              let rawValues = values as? [Any],
              rawValues.count == names.count else {
            return nil
        }

        var results: [String: AttributeReadResult] = [:]
        for (name, rawValue) in zip(names, rawValues) {
            let value = rawValue as CFTypeRef
            if CFGetTypeID(value) == AXValueGetTypeID() {
                let axValue: AXValue = unsafeBitCast(value, to: AXValue.self)
                if AXValueGetType(axValue) == .axError {
                    var axError = AXError.failure
                    if AXValueGetValue(axValue, .axError, &axError) {
                        results[name] = .failure(axError)
                        continue
                    }
                }
            }
            if CFGetTypeID(value) == CFNullGetTypeID() {
                results[name] = .failure(.noValue)
            } else {
                results[name] = .success(value)
            }
        }
        return results
    }

    private func successfulValue(in result: AttributeReadResult?) -> CFTypeRef? {
        guard case .success(let value) = result else { return nil }
        return value
    }

    private func copyChildren(of element: AXUIElement) -> [AXUIElement] {
        if readProfile.prefersNavigationChildren,
           let value = copyAttribute("AXChildrenInNavigationOrder", of: element),
           let children = value as? [AXUIElement],
           !children.isEmpty {
            return children
        }
        guard let value = copyAttribute(kAXChildrenAttribute as String, of: element) else { return [] }
        return value as? [AXUIElement] ?? []
    }
}

enum AXValueFormatter {
    static func string(from value: CFTypeRef) -> String {
        if CFGetTypeID(value) == AXValueGetTypeID() {
            let axValue: AXValue = unsafeBitCast(value, to: AXValue.self)
            return string(from: axValue)
        }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let url = value as? URL { return url.absoluteString }
        if let data = value as? Data { return "<data \(data.count) bytes>" }

        if let array = value as? [Any] {
            return "[" + array.map { String(describing: $0) }.joined(separator: ", ") + "]"
        }

        return String(describing: value)
    }

    private static func string(from value: AXValue) -> String {
        switch AXValueGetType(value) {
        case .cgPoint:
            var point = CGPoint.zero
            guard AXValueGetValue(value, .cgPoint, &point) else { return "<invalid CGPoint>" }
            return "x=\(decimal(point.x)), y=\(decimal(point.y))"
        case .cgSize:
            var size = CGSize.zero
            guard AXValueGetValue(value, .cgSize, &size) else { return "<invalid CGSize>" }
            return "width=\(decimal(size.width)), height=\(decimal(size.height))"
        case .cfRange:
            var range = CFRange()
            guard AXValueGetValue(value, .cfRange, &range) else { return "<invalid CFRange>" }
            return "location=\(range.location), length=\(range.length)"
        case .cgRect:
            var rect = CGRect.zero
            guard AXValueGetValue(value, .cgRect, &rect) else { return "<invalid CGRect>" }
            return "x=\(decimal(rect.origin.x)), y=\(decimal(rect.origin.y)), width=\(decimal(rect.width)), height=\(decimal(rect.height))"
        case .axError:
            var error = AXError.success
            guard AXValueGetValue(value, .axError, &error) else { return "<invalid AXError>" }
            return "AXError(\(error.rawValue))"
        case .illegal:
            return "<illegal AXValue>"
        @unknown default:
            return "<unknown AXValue>"
        }
    }

    private static func decimal(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }
}
