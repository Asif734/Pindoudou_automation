import SwiftUI

@main
struct PDDAXReaderApp: App {
    private let mode = PDDAppMode(bundleIdentifier: Bundle.main.bundleIdentifier)

    var body: some Scene {
        WindowGroup(windowTitle) {
            Group {
                switch mode {
                case .singleParse:
                    SingleAXParseView()
                case .autoReply, .taskIsolationCandidate:
                    AutoReplyView()
                case .reader:
                    ContentView()
                }
            }
        }
        .defaultSize(width: 1_200, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }

    private var windowTitle: String {
        switch mode {
        case .reader: return BilingualText.lines("拼多多 AX 读取器", "Pinduoduo AX Reader")
        case .singleParse: return BilingualText.lines("拼多多 AX 单次解析测试器", "Pinduoduo AX Snapshot Tester")
        case .autoReply: return BilingualText.lines("拼多多全自动客服", "Pinduoduo Automatic Customer Service")
        case .taskIsolationCandidate: return "pinduodou_automation"
        }
    }
}
