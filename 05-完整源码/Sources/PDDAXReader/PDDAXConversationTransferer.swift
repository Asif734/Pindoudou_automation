import ApplicationServices
import Foundation

@MainActor
protocol PDDLiveConversationTransferring: AnyObject {
    func transferToAnyHuman(
        uid: String, lease: UIOperationLease
    ) async throws -> AutoReplyTransferResult
}

@MainActor
protocol PDDTransferClicking: AnyObject {
    func click(at point: CGPoint) throws
}

enum PDDConversationTransferError: LocalizedError {
    case invalidControlFrame(String)
    case clickFailed

    var errorDescription: String? {
        switch self {
        case .invalidControlFrame(let control): return "转人工控件坐标无效：\(control)"
        case .clickFailed: return "无法发送转人工鼠标事件"
        }
    }
}

@MainActor
final class PDDAXConversationTransferer: PDDLiveConversationTransferring {
    private let backend: any PDDAXBackend
    private let opener: any PDDConversationOpening
    private let clicker: any PDDTransferClicking
    private let sleep: @MainActor (TimeInterval) async throws -> Void
    private let logRoot: URL?
    private let menuSubmitter: any PDDTransferMenuSubmitting

    init(
        backend: any PDDAXBackend,
        opener: any PDDConversationOpening,
        clicker: any PDDTransferClicking,
        logRoot: URL? = nil,
        menuSubmitter: (any PDDTransferMenuSubmitting)? = nil,
        sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.backend = backend
        self.opener = opener
        self.clicker = clicker
        self.sleep = sleep
        self.logRoot = logRoot
        self.menuSubmitter = menuSubmitter ?? PDDTransferMenuSubmitter(
            backend: backend, clicker: clicker, logRoot: logRoot, sleep: sleep)
    }

    func transferToAnyHuman(
        uid: String, lease: UIOperationLease
    ) async throws -> AutoReplyTransferResult {
        AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-open-started", detail: "target=after-sales")
        do {
            return try await transferToAfterSales(uid: uid, lease: lease)
        } catch {
            AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-error", detail: error.localizedDescription)
            throw error
        }
    }

    private func transferToAfterSales(uid: String, lease: UIOperationLease) async throws -> AutoReplyTransferResult {
        try lease.validate()
        try await backend.prepareForeground()
        try lease.validate()
        var tree = try await opener.openAndResolve(uid: uid)
        try lease.validate()

        if !PDDAXControlSelection.isTransferDialogVisible(in: tree.nodes) {
            tree = try await openDialog(uid: uid, initial: tree, lease: lease)
        }
        AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-dialog-opened")
        defer {
            if (try? lease.validate()) != nil,
               let current = try? backend.readSemanticTree(),
               PDDAXControlSelection.isTransferDialogVisible(in: current.nodes) {
                do {
                    var dismissed = true
                    if let close = PDDAXControlSelection.transferDialogCloseControl(in: current.nodes) {
                        try press(close, uid: uid, step: "transfer-dialog-close-clicked")
                    } else if let point = PDDAXControlSelection.transferDialogDismissPoint(in: current.nodes) {
                        // Click only the modal backdrop. Escape is also a PDD close-chat shortcut.
                        try clicker.click(at: point)
                    } else {
                        dismissed = false
                        AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-dialog-cleanup-unavailable",
                            detail: "No verified close control or modal backdrop")
                    }
                    if dismissed {
                        AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-dialog-dismissed",
                            detail: "Remaining transfer dialog dismissal requested; other conversations continue")
                    }
                } catch {
                    AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-dialog-cleanup-failed", detail: error.localizedDescription)
                }
            }
        }

        var attemptedLabels = Set<String>()
        while true {
            try lease.validate()
            let actions = try PDDAXControlSelection.afterSalesTransferActions(in: tree.nodes)
            AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-after-sales-candidates",
                detail: actions.map(\.agentLabel).joined(separator: ","))
            guard let action = actions.first(where: { !attemptedLabels.contains($0.agentLabel) }) else {
                let reason = actions.isEmpty ? "未找到标注售后/After-sales的接收客服，未转移给其他分组"
                    : "已尝试全部售后客服，均未确认转移成功"
                AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-failed", detail: reason)
                return .failed(reason)
            }
            attemptedLabels.insert(action.agentLabel)
            guard isUsable(action.frame) else {
                AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-invalid-recipient-frame", detail: action.agentLabel)
                continue
            }

            AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-recipient-selected", detail: action.agentLabel)
            guard let control = tree.nodes.first(where: { $0.id == action.controlID }) else {
                throw PDDAXSelectionError.missing("售后客服转移控件")
            }
            try press(control, uid: uid, step: "transfer-recipient-clicked")
            try await sleep(0.15)
            try lease.validate()
            AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-submit-started", detail: action.agentLabel)
            do {
                try await menuSubmitter.submit(uid: uid, anchor: action.frame, lease: lease)
            } catch {
                AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-menu-control-failed",
                    detail: "recipient=\(action.agentLabel) \(error.localizedDescription)")
                // Observe the result before any other recipient is attempted: a menu item may submit directly.
                let result = try await waitForTransferResult(recipient: action.agentLabel, lease: lease)
                if result.succeeded { return .transferred(agentLabel: action.agentLabel) }
                // An unresolved menu must never fall through into another recipient's controls.
                return .failed("无法定位转移确认控件：\(error.localizedDescription)")
            }

            let confirmation = try await waitForTransferResult(recipient: action.agentLabel, lease: lease)
            if confirmation.succeeded {
                AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-confirmed", detail: action.agentLabel)
                return .transferred(agentLabel: action.agentLabel)
            }
            AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-not-confirmed", detail: action.agentLabel)
            if !PDDAXControlSelection.isTransferDialogVisible(in: confirmation.tree.nodes) {
                return .failed("转移弹窗已关闭，但未确认接收客服为选定售后人员；停止进一步转移")
            }
            tree = confirmation.tree
        }
    }

    private func openDialog(uid: String, initial: PDDAXSemanticTree, lease: UIOperationLease) async throws -> PDDAXSemanticTree {
        var tree = initial
        for attempt in 1...3 {
            try lease.validate()
            if attempt > 1 {
                try await backend.prepareForeground()
                try lease.validate()
                tree = try backend.readSemanticTree()
                if PDDAXControlSelection.isTransferDialogVisible(in: tree.nodes) { return tree }
                tree = try await opener.openAndResolve(uid: uid)
            }
            try lease.validate()
            if PDDAXControlSelection.isTransferDialogVisible(in: tree.nodes) { return tree }
            let id = try PDDAXControlSelection.transferConversationTrigger(in: tree.nodes)
            guard let trigger = tree.nodes.first(where: { $0.id == id }), isUsable(trigger.frame) else {
                throw PDDConversationTransferError.invalidControlFrame("转移会话")
            }
            AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-open-attempt", detail: "attempt=\(attempt)/3 foreground prepared")
            do {
                try press(trigger, uid: uid, step: "transfer-trigger-clicked", forceCoordinate: attempt > 1)
            } catch {
                AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-trigger-action-failed", detail: error.localizedDescription)
            }
            if let opened = try await waitForDialog(lease: lease) { return opened }
            tree = try backend.readSemanticTree()
        }
        saveOpenFailure(uid: uid, tree: tree)
        throw PDDAXSelectionError.missing("转移会话弹窗（已前置窗口并重新定位重试3次）")
    }

    private func waitForDialog(lease: UIOperationLease) async throws -> PDDAXSemanticTree? {
        for _ in 0..<20 {
            try lease.validate()
            let tree = try backend.readSemanticTree()
            if PDDAXControlSelection.isTransferDialogVisible(in: tree.nodes) { return tree }
            try await sleep(0.1)
        }
        return nil
    }

    private func saveOpenFailure(uid: String, tree: PDDAXSemanticTree) {
        guard let logRoot else { return }
        do {
            let directory = logRoot.appendingPathComponent("logs/transfer-diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("open-failed-\(UUID().uuidString).json")
            let nodes: [[String: Any]] = tree.nodes.filter { node in
                ["AXWindow", "AXWebArea"].contains(node.role)
                    || [node.value, node.title].compactMap { $0 }.contains { $0.contains("转移") || $0 == "请输入内容" }
                    || node.domClasses.contains { $0.contains("transfer") || $0.contains("dialog") }
            }.map { node in
                ["token": node.id.rawValue, "role": node.role, "value": node.value ?? "", "title": node.title ?? "",
                 "actions": Array(node.actionNames), "classes": Array(node.domClasses),
                 "frame": ["x": node.frame.minX, "y": node.frame.minY, "width": node.frame.width, "height": node.frame.height]]
            }
            try JSONSerialization.data(withJSONObject: ["uid": uid, "nodes": nodes], options: [.prettyPrinted, .sortedKeys])
                .write(to: url, options: .atomic)
            AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-open-diagnostic-saved", detail: url.path)
        } catch {
            AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-open-diagnostic-failed", detail: error.localizedDescription)
        }
    }

    private func waitForTransferResult(
        recipient: String,
        lease: UIOperationLease
    ) async throws -> (succeeded: Bool, tree: PDDAXSemanticTree) {
        var latest = try backend.readSemanticTree()
        for _ in 0..<10 {
            try lease.validate()
            if !PDDAXControlSelection.isTransferDialogVisible(in: latest.nodes),
               PDDAXIncomingTransfer.latestTransferRecipient(in: latest.rootSnapshot) == recipient {
                return (true, latest)
            }
            try await sleep(0.1)
            latest = try backend.readSemanticTree()
        }
        return (false, latest)
    }

    private func isUsable(_ frame: CGRect) -> Bool {
        PDDTransferMenuControls.valid(frame)
    }

    private func press(_ node: PDDAXSemanticNode<AXElementToken>, uid: String, step: String, forceCoordinate: Bool = false) throws {
        let useAX = node.actionNames.contains("AXPress") && !forceCoordinate
        if useAX { try backend.performPress(node.id) }
        else { try clicker.click(at: CGPoint(x: node.frame.midX, y: node.frame.midY)) }
        AutomationStepLog.record(root: logRoot, uid: uid, step: step,
            detail: "route=\(useAX ? "AXPress" : "AX-frame") x=\(node.frame.midX) y=\(node.frame.midY)")
    }
}

@MainActor
final class CGEventPDDTransferClicker: PDDTransferClicking {
    func click(at point: CGPoint) throws {
        guard let moved = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left), let down = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left
        ) else { throw PDDConversationTransferError.clickFailed }
        moved.post(tap: .cghidEventTap)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

}
