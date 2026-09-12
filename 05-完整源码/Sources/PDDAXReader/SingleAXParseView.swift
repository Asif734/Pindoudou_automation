import SwiftUI

struct SingleAXParseView: View {
    @StateObject private var model = SingleAXParseViewModel()

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button(action: model.readOnceAndParse) {
                    Label(
                        model.isReading ? "正在读取一次…" : "单次读取 AX 并 Parse",
                        systemImage: "scope"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isReading)

                Spacer()
                if model.isReading { ProgressView().controlSize(.small) }
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            AXDumpTextView(contents: model.output)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
        }
        .padding(16)
        .frame(minWidth: 860, minHeight: 620)
        .onAppear(perform: model.refreshPermissionStatus)
    }
}
