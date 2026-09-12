import Foundation

enum ReaderWorkflowStage: String, Equatable, Sendable {
    case readAX = "读取 AX"
    case identifyUser = "识别用户"
    case saveAX = "保存 AX"
    case parseChat = "解析聊天"
    case mergeHistory = "合并历史"
    case codex = "生成 Codex 建议"
}

struct ReaderWorkflowError: LocalizedError {
    let stage: ReaderWorkflowStage
    let detail: String
    let fullAXOutput: String?

    var errorDescription: String? {
        "\(stage.rawValue)失败：\(detail)"
    }
}

struct ReaderWorkflowResult: Equatable {
    let uid: String
    let fullAXOutput: String
    let parsedChatOutput: String
    let replyOutput: String
    let savedAXURL: URL
    let historyCount: Int
}

struct ReaderWorkflowDependencies: @unchecked Sendable {
    let readAX: @Sendable () throws -> AXReadResult
    let saveAX: @Sendable (String, String) throws -> URL
    let parseChat: @Sendable (AXNodeSnapshot, Date) -> PDDChatParseResult
    let mergeHistory: @Sendable (String, [PDDChatMessage]) throws -> ChatMergeResult
    let generateReply: @Sendable (String, [PDDChatMessage]) async throws -> CodexReplyResult

    static func live(
        rootDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/拼多多AX记录", isDirectory: true)
    ) -> ReaderWorkflowDependencies {
        let reader = AXTreeReader()
        let stableReader = StableAXTreeReader(readOnce: { try reader.read() })
        let axStore = PerUserAXStore(rootDirectory: rootDirectory)
        let chatStore = PerUserChatStore(rootDirectory: rootDirectory)
        let replyService = CodexReplyService(
            sessionRegistry: CodexSessionRegistry(rootDirectory: rootDirectory)
        )
        return ReaderWorkflowDependencies(
            readAX: { try stableReader.read() },
            saveAX: { uid, contents in try axStore.save(uid: uid, contents: contents) },
            parseChat: { root, capturedAt in PDDChatParser.parse(root: root, capturedAt: capturedAt) },
            mergeHistory: { uid, messages in try chatStore.merge(uid: uid, messages: messages) },
            generateReply: { uid, history in try await replyService.generate(uid: uid, history: history) }
        )
    }
}

struct ReaderWorkflow: Sendable {
    let dependencies: ReaderWorkflowDependencies

    init(dependencies: ReaderWorkflowDependencies = .live()) {
        self.dependencies = dependencies
    }

    func run(capturedAt: Date = Date()) async throws -> ReaderWorkflowResult {
        let readResult: AXReadResult
        do {
            readResult = try dependencies.readAX()
        } catch {
            throw ReaderWorkflowError(stage: .readAX, detail: error.localizedDescription, fullAXOutput: nil)
        }

        guard let uid = PDDCustomerIdentity.resolve(from: readResult.root)
            ?? PDDConversationSnapshotLocator.current(in: readResult.root).map({
                PDDConversationKey.make(locator: $0)
            }) else {
            throw ReaderWorkflowError(
                stage: .identifyUser,
                detail: PerUserAXStoreError.invalidUID.localizedDescription,
                fullAXOutput: AXDumpFormatter.format(root: readResult.root)
            )
        }
        let fullAXOutput = formatFullAX(result: readResult, uid: uid, capturedAt: capturedAt)
        let savedAXURL: URL
        do {
            savedAXURL = try dependencies.saveAX(uid, fullAXOutput)
        } catch {
            throw ReaderWorkflowError(stage: .saveAX, detail: error.localizedDescription, fullAXOutput: fullAXOutput)
        }

        let parsed = dependencies.parseChat(readResult.root, capturedAt)
        let merged: ChatMergeResult
        do {
            merged = try dependencies.mergeHistory(uid, parsed.messages)
        } catch {
            throw ReaderWorkflowError(
                stage: .mergeHistory,
                detail: error.localizedDescription,
                fullAXOutput: fullAXOutput
            )
        }
        let parsedOutput = formatParsed(uid: uid, merged: merged, diagnostics: parsed.diagnostics)

        let replyOutput: String
        let latestMessage = PDDMessageChronology.latest(in: merged.history)
        if latestMessage?.sender == .customer {
            do {
                replyOutput = try await dependencies.generateReply(uid, merged.history).reply
            } catch {
                throw ReaderWorkflowError(stage: .codex, detail: error.localizedDescription, fullAXOutput: fullAXOutput)
            }
        } else if latestMessage?.sender == .service {
            replyOutput = "当前无需回复：最后一条有效消息来自客服。"
        } else {
            replyOutput = "当前无需回复：没有解析到有效聊天消息。"
        }

        return ReaderWorkflowResult(
            uid: uid,
            fullAXOutput: fullAXOutput,
            parsedChatOutput: parsedOutput,
            replyOutput: replyOutput,
            savedAXURL: savedAXURL,
            historyCount: merged.history.count
        )
    }

    private func formatFullAX(result: AXReadResult, uid: String, capturedAt: Date) -> String {
        """
        拼多多用户 AX 完整读取结果
        用户：\(uid)
        应用：\(result.applicationName)
        节点数：\(result.nodeCount)
        耗时：\(String(format: "%.3f", result.elapsedSeconds)) 秒
        读取时间：\(capturedAt.formatted(date: .numeric, time: .standard))

        \(AXDumpFormatter.format(root: result.root))
        """
    }

    private func formatParsed(
        uid: String,
        merged: ChatMergeResult,
        diagnostics: [String]
    ) -> String {
        var lines = [
            "用户：\(uid)",
            "历史消息：\(merged.history.count) 条，本次新增：\(merged.insertedCount) 条",
            ""
        ]
        for message in merged.history {
            let sender = message.sender == .customer ? "客户" : "客服"
            let time = message.displayTime.map { "[\($0)] " } ?? ""
            lines.append("\(time)\(sender)：\(message.content)  〈\(message.kind.rawValue)〉")
        }
        if !diagnostics.isEmpty {
            lines.append("")
            lines.append("解析诊断：")
            lines.append(contentsOf: diagnostics)
        }
        return lines.joined(separator: "\n")
    }
}
