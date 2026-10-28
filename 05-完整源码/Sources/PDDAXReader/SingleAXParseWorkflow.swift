import Foundation

struct SingleAXParseReport: Equatable {
    let uid: String
    let capturedAt: Date
    let nodeCount: Int
    let elapsedSeconds: TimeInterval
    let newestRawMessageID: String?
    let messages: [PDDChatMessage]
    let diagnostics: [String]

    var latestMessage: PDDChatMessage? {
        PDDMessageChronology.latest(in: messages.filter { $0.sender == .customer })
    }

    var formatted: String {
        var lines = [BilingualText.lines("用户：\(uid)", "User: \(uid)")]
        if let latestMessage {
            let time = latestMessage.displayTime ?? capturedAt.formatted(
                .dateTime.year().month().day().hour().minute().second()
            )
            lines.append(BilingualText.lines("时间：\(time)", "Time: \(time)"))
            lines.append(BilingualText.lines("客户：\(latestMessage.content)", "Customer: \(latestMessage.content)"))
        } else {
            let time = capturedAt.formatted(.dateTime.year().month().day().hour().minute().second())
            lines.append(BilingualText.lines("时间：\(time)", "Time: \(time)"))
            lines.append(BilingualText.lines("客户：本次 AX 没有解析到客户消息", "Customer: no customer message was parsed in this AX snapshot"))
        }
        return lines.joined(separator: "\n")
    }
}

struct SingleAXParseWorkflow: @unchecked Sendable {
    let readAX: @Sendable () throws -> AXReadResult

    init(readAX: @escaping @Sendable () throws -> AXReadResult = {
        try AXTreeReader(readProfile: .chatParsing).read()
    }) {
        self.readAX = readAX
    }

    func run(capturedAt: Date = Date()) throws -> SingleAXParseReport {
        let result = try readAX()
        guard let uid = PDDCustomerIdentity.resolve(from: result.root)
            ?? PDDConversationSnapshotLocator.current(in: result.root).map({
                PDDConversationKey.make(locator: $0)
            }) else {
            throw PerUserAXStoreError.invalidUID
        }
        let parsed = PDDChatParser.parse(root: result.root, capturedAt: capturedAt)
        return SingleAXParseReport(
            uid: uid,
            capturedAt: capturedAt,
            nodeCount: result.nodeCount,
            elapsedSeconds: result.elapsedSeconds,
            newestRawMessageID: PDDAXSnapshotOrder.newestMessageIdentifier(in: result.root),
            messages: parsed.messages,
            diagnostics: parsed.diagnostics
        )
    }
}
