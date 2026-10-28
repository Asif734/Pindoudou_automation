import SwiftUI

struct ContentView: View {
    @StateObject private var model = ReaderViewModel()

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button(action: model.readParseAndSuggest) {
                    Label(
                        model.isReading ? BilingualText.lines("正在处理…", "Processing…") : BilingualText.lines("读取、解析并生成建议", "Read, parse, and suggest"),
                        systemImage: model.isReading ? "hourglass" : "accessibility"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isReading)

                Spacer()

                if model.isReading {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            TabView(selection: $model.selectedTab) {
                panel(contents: model.fullAXOutput)
                    .tabItem { Label(BilingualText.lines("完整 AX", "Full AX tree"), systemImage: "list.bullet.rectangle") }
                    .tag(ReaderTab.fullAX)

                panel(contents: model.parsedChatOutput)
                    .tabItem { Label(BilingualText.lines("解析聊天", "Parsed chat"), systemImage: "bubble.left.and.bubble.right") }
                    .tag(ReaderTab.parsedChat)

                panel(contents: model.replyOutput)
                    .tabItem { Label(BilingualText.lines("Codex 建议回复", "Codex suggested reply"), systemImage: "sparkles") }
                    .tag(ReaderTab.reply)
            }
        }
        .padding(16)
        .frame(minWidth: 820, minHeight: 560)
        .onAppear(perform: model.refreshPermissionStatus)
    }

    private func panel(contents: String) -> some View {
        AXDumpTextView(contents: contents)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
    }
}
