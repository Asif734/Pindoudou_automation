import ApplicationServices
import Foundation

@MainActor
final class SingleAXParseViewModel: ObservableObject {
    @Published var output = BilingualText.lines("在拼多多打开聊天，然后每按一次按钮，只读取一次 AX 并立即 Parse。", "Open a Pinduoduo chat. Each button press reads and parses exactly one AX snapshot.")
    @Published var status = BilingualText.lines("准备就绪（单次快照模式）", "Ready (single-snapshot mode)")
    @Published var isReading = false

    func refreshPermissionStatus() {
        status = AXIsProcessTrusted()
            ? BilingualText.lines("辅助功能权限已开启（单次快照模式）", "Accessibility granted (single-snapshot mode)")
            : BilingualText.lines("需要为本测试器开启辅助功能权限", "Grant Accessibility permission to this tester")
    }

    func readOnceAndParse() {
        guard !isReading else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([key: true] as CFDictionary) else {
            status = BilingualText.lines("请在系统设置 → 隐私与安全性 → 辅助功能中允许“拼多多 AX 单次解析测试器”。", "Allow Pinduoduo AX Snapshot Tester in System Settings → Privacy & Security → Accessibility.")
            return
        }

        isReading = true
        status = BilingualText.lines("正在读取唯一一次 AX 快照…", "Reading one AX snapshot…")
        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try SingleAXParseWorkflow().run()
                }.value
                output = report.formatted
                status = BilingualText.lines("完成：本次严格读取 1 次 AX，解析 \(report.messages.count) 条消息", "Completed: exactly one AX read; \(report.messages.count) messages parsed")
            } catch {
                status = error.localizedDescription
            }
            isReading = false
        }
    }
}
