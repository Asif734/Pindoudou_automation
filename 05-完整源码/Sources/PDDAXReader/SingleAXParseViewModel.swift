import ApplicationServices
import Foundation

@MainActor
final class SingleAXParseViewModel: ObservableObject {
    @Published var output = "在拼多多打开聊天，然后每按一次按钮，只读取一次 AX 并立即 Parse。"
    @Published var status = "准备就绪（单次快照模式）"
    @Published var isReading = false

    func refreshPermissionStatus() {
        status = AXIsProcessTrusted()
            ? "辅助功能权限已开启（单次快照模式）"
            : "需要为本测试器开启辅助功能权限"
    }

    func readOnceAndParse() {
        guard !isReading else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([key: true] as CFDictionary) else {
            status = "请在系统设置 → 隐私与安全性 → 辅助功能中允许“拼多多 AX 单次解析测试器”。"
            return
        }

        isReading = true
        status = "正在读取唯一一次 AX 快照…"
        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try SingleAXParseWorkflow().run()
                }.value
                output = report.formatted
                status = "完成：本次严格读取 1 次 AX，解析 \(report.messages.count) 条消息"
            } catch {
                status = error.localizedDescription
            }
            isReading = false
        }
    }
}
