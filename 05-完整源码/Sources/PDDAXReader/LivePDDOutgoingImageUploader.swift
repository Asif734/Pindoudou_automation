import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol PDDChatImagePasteTarget {
    func focusComposer() async throws
    func pasteImage() throws
}

/// Copies validated image bytes directly into the current chatbox.
/// There is no media-toolbar or file-picker path.
@MainActor
final class LivePDDOutgoingImageUploader: PDDOutgoingImageUploading {
    private let logRoot: URL?
    private let pasteboardSession: PDDImagePasteboardSession
    private let target: any PDDChatImagePasteTarget

    init(logRoot: URL? = nil, pasteboardSession: PDDImagePasteboardSession? = nil,
         target: (any PDDChatImagePasteTarget)? = nil) {
        self.logRoot = logRoot
        self.pasteboardSession = pasteboardSession ?? PDDImagePasteboardSession()
        self.target = target ?? LivePDDChatImagePasteTarget()
    }

    func upload(file: URL, beforeCommit: () throws -> Void) async throws {
        try Task.checkCancellation()
        try await target.focusComposer()
        AutomationStepLog.record(root: logRoot, uid: nil, step: "image-chatbox-focused", detail: file.lastPathComponent)
        try Task.checkCancellation()
        try pasteboardSession.writeImage(file)
        AutomationStepLog.record(root: logRoot, uid: nil, step: "image-copied-to-clipboard", detail: file.lastPathComponent)
        try Task.checkCancellation()
        try pasteboardSession.validateImageClipboard()
        // Verify the customer and persist the delivery receipt immediately before Cmd-V.
        try beforeCommit()
        try pasteboardSession.validateImageClipboard()
        try target.pasteImage()
        AutomationStepLog.record(root: logRoot, uid: nil, step: "image-paste-submitted", detail: file.lastPathComponent)
    }

    func finish() { pasteboardSession.restore() }
}

@MainActor
private final class LivePDDChatImagePasteTarget: PDDChatImagePasteTarget {
    private let bundleIdentifier = "com.pinduoduo.merchantMac"
    private var application: NSRunningApplication?
    private var composer: AXUIElement?

    func focusComposer() async throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            throw failure("商家程序未运行")
        }
        application = nil
        composer = nil
        app.activate(options: [])
        let deadline = Date().addingTimeInterval(2)
        repeat {
            try Task.checkCancellation()
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            let windows = attribute(kAXWindowsAttribute, appElement) as? [AXUIElement] ?? []
            guard !windows.contains(where: { string(kAXIdentifierAttribute, $0) == "open-panel"
                || string(kAXIdentifierAttribute, $0) == "GoToWindow" }) else {
                throw failure("请先关闭文件选择窗口，再粘贴图片")
            }
            if let window = windows.first(where: { (string(kAXTitleAttribute, $0) ?? "").contains("商家工作台") }) {
                let composers = chatComposers(in: window)
                guard composers.count == 1, let field = composers.first else {
                    throw failure("没有找到唯一的聊天输入框，停止图片粘贴")
                }
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                   bool(kAXFocusedAttribute, field) {
                    application = app
                    composer = field
                    return
                }
            }
            try await Task.sleep(nanoseconds: 85_000_000)
        } while Date() < deadline
        throw failure("图片粘贴前未确认聊天输入框焦点")
    }

    func pasteImage() throws {
        try Task.checkCancellation()
        guard let app = application, !app.isTerminated, let composer,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              bool(kAXFocusedAttribute, composer),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            throw failure("商家聊天输入框焦点已变化，停止图片粘贴")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(app.processIdentifier)
        up.postToPid(app.processIdentifier)
    }

    private func chatComposers(in window: AXUIElement) -> [AXUIElement] {
        var pending = [(window, 0)]
        var visited = Set<CFHashCode>()
        var result: [AXUIElement] = []
        while let (element, depth) = pending.popLast() {
            guard depth < 70, visited.insert(CFHash(element)).inserted else { continue }
            guard string(kAXRoleAttribute, element) != "AXSheet" else { continue }
            if string(kAXRoleAttribute, element) == "AXTextArea" {
                var settable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
                   settable.boolValue { result.append(element) }
            }
            let children = attribute(kAXChildrenAttribute, element) as? [AXUIElement] ?? []
            pending.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return result
    }

    private func attribute(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func string(_ name: String, _ element: AXUIElement) -> String? { attribute(name, element) as? String }
    private func bool(_ name: String, _ element: AXUIElement) -> Bool { attribute(name, element) as? Bool ?? false }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "PDDImagePaste", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
