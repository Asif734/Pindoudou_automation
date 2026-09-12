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
        case .reader: return "拼多多 AX 读取器"
        case .singleParse: return "拼多多 AX 单次解析测试器"
        case .autoReply: return "拼多多全自动客服"
        case .taskIsolationCandidate: return "pinduodou_automation"
        }
    }
}
