import ApplicationServices
import Foundation

enum ReaderTab: Hashable {
    case fullAX
    case parsedChat
    case reply
}

@MainActor
final class ReaderViewModel: ObservableObject {
    @Published var fullAXOutput = BilingualText.lines("在拼多多中打开一个用户，然后点击“读取、解析并生成建议”。", "Open a customer in Pinduoduo, then click Read, parse, and suggest.")
    @Published var parsedChatOutput = BilingualText.lines("尚未解析聊天。", "Chat has not been parsed yet.")
    @Published var replyOutput = BilingualText.lines("尚未生成建议。", "No suggestion generated yet.")
    @Published var status = BilingualText.lines("准备就绪", "Ready")
    @Published var isReading = false
    @Published var selectedTab: ReaderTab = .fullAX

    private let runWorkflow: @Sendable () async throws -> ReaderWorkflowResult
    private let permissionCheck: @Sendable () -> Bool
    private let permissionPrompt: @Sendable () -> Bool

    init(
        runWorkflow: @escaping @Sendable () async throws -> ReaderWorkflowResult = {
            try await Task.detached(priority: .userInitiated) {
                try await ReaderWorkflow().run()
            }.value
        },
        permissionCheck: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        permissionPrompt: @escaping @Sendable () -> Bool = {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
    ) {
        self.runWorkflow = runWorkflow
        self.permissionCheck = permissionCheck
        self.permissionPrompt = permissionPrompt
    }

    func refreshPermissionStatus() {
        status = permissionCheck()
            ? BilingualText.lines("辅助功能权限已开启", "Accessibility permission granted")
            : BilingualText.lines("需要辅助功能权限", "Accessibility permission required")
    }

    func readParseAndSuggest() {
        guard !isReading else { return }
        guard permissionPrompt() else {
            status = BilingualText.lines("请在系统设置的“隐私与安全性 → 辅助功能”中允许本程序，然后再点读取。", "Allow this app in System Settings → Privacy & Security → Accessibility, then read again.")
            return
        }
        Task { await performRead() }
    }

    func performRead() async {
        guard !isReading else { return }
        isReading = true
        status = BilingualText.lines("正在读取、保存并解析当前用户 AX…", "Reading, saving, and parsing the current customer AX tree…")
        defer { isReading = false }

        do {
            let result = try await runWorkflow()
            fullAXOutput = result.fullAXOutput
            parsedChatOutput = result.parsedChatOutput
            replyOutput = result.replyOutput
            selectedTab = .reply
            status = BilingualText.lines("完成 \(result.uid)：共 \(result.historyCount) 条历史；AX 已保存到 \(result.savedAXURL.path)", "Completed \(result.uid): \(result.historyCount) history messages; AX saved to \(result.savedAXURL.path)")
        } catch let error as ReaderWorkflowError {
            if let capturedAX = error.fullAXOutput {
                fullAXOutput = capturedAX
            }
            if error.stage == .codex {
                replyOutput = error.localizedDescription
                selectedTab = .reply
            } else if error.stage == .mergeHistory || error.stage == .parseChat {
                parsedChatOutput = error.localizedDescription
                selectedTab = .parsedChat
            }
            status = error.localizedDescription
        } catch {
            status = error.localizedDescription
        }
    }
}
