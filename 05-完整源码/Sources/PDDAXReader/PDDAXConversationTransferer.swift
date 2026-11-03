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
    func submitNoReasonTransfer(anchorFrame: CGRect) async throws
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

    init(
        backend: any PDDAXBackend,
        opener: any PDDConversationOpening,
        clicker: any PDDTransferClicking,
        logRoot: URL? = nil,
        sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.backend = backend
        self.opener = opener
        self.clicker = clicker
        self.sleep = sleep
        self.logRoot = logRoot
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
        var tree = try await opener.openAndResolve(uid: uid)
        try lease.validate()

        if !PDDAXControlSelection.isTransferDialogVisible(in: tree.nodes) {
            let triggerID = try PDDAXControlSelection.transferConversationTrigger(in: tree.nodes)
            guard let trigger = tree.nodes.first(where: { $0.id == triggerID }),
                  isUsable(trigger.frame) else {
                throw PDDConversationTransferError.invalidControlFrame("转移会话")
            }
            try clicker.click(at: CGPoint(x: trigger.frame.midX, y: trigger.frame.midY))
            tree = try await waitForDialog(lease: lease)
        }
        AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-dialog-opened")
        defer {
            if (try? lease.validate()) != nil,
               let current = try? backend.readSemanticTree(),
               let close = PDDAXControlSelection.transferDialogCloseControl(in: current.nodes) {
                do {
                    if close.actionNames.contains("AXPress") { try backend.performPress(close.id) }
                    else { try clicker.click(at: CGPoint(x: close.frame.midX, y: close.frame.midY)) }
                    AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-dialog-dismissed",
                        detail: "Remaining transfer dialog closed; other conversations continue")
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
            try clicker.click(at: CGPoint(x: action.frame.midX, y: action.frame.midY))
            try await sleep(0.15)
            try lease.validate()
            AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-submit-started", detail: action.agentLabel)
            try await clicker.submitNoReasonTransfer(anchorFrame: action.frame)

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

    private func waitForDialog(lease: UIOperationLease) async throws -> PDDAXSemanticTree {
        for _ in 0..<15 {
            try lease.validate()
            let tree = try backend.readSemanticTree()
            if PDDAXControlSelection.isTransferDialogVisible(in: tree.nodes) { return tree }
            try await sleep(0.1)
        }
        throw PDDAXSelectionError.missing("转移会话弹窗")
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
        frame.width > 1 && frame.height > 1
    }
}

@MainActor
final class CGEventPDDTransferClicker: PDDTransferClicking {
    func click(at point: CGPoint) throws {
        guard let down = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left
        ) else { throw PDDConversationTransferError.clickFailed }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    func submitNoReasonTransfer(anchorFrame: CGRect) async throws {
        // 拼多多的原因菜单没有独立 AX 节点；位置由 AX 中“转移”控件的矩形推导。
        let reasonPoint = CGPoint(
            x: anchorFrame.midX,
            y: anchorFrame.maxY + 175
        )
        let sendPoint = CGPoint(
            x: anchorFrame.midX + 65,
            y: anchorFrame.maxY + 232
        )
        try click(at: reasonPoint)
        try await Task.sleep(for: .milliseconds(120))
        try click(at: sendPoint)
    }
}
