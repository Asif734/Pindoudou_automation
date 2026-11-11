import CryptoKit
import Foundation
import NaturalLanguage

/// Reads platform transfer notices, never customer-request keywords.
enum PDDAXIncomingTransfer {
    static func fallbackReply(history: [PDDChatMessage]) -> String {
        let recognizer = NLLanguageRecognizer()
        for message in history.reversed() where message.sender == .customer && message.kind == .text {
            recognizer.reset()
            recognizer.processString(message.content)
            switch recognizer.dominantLanguage {
            case .english: return "I’ve received your conversation and am here to continue helping you."
            case .spanish: return "He recibido tu conversación y estoy aquí para seguir ayudándote."
            case .french: return "J’ai bien reçu votre conversation et je suis là pour continuer à vous aider."
            case .german: return "Ich habe Ihren Chat übernommen und helfe Ihnen gerne weiter."
            case .japanese: return "会話を引き継ぎました。引き続きお手伝いいたします。"
            case .korean: return "대화를 전달받았습니다. 계속 도와드리겠습니다."
            case .bengali: return "আপনার কথোপকথনটি পেয়েছি। আপনাকে সহায়তা করতে আমি আছি।"
            case .hindi: return "आपकी बातचीत मुझे मिल गई है। मैं आपकी मदद जारी रखूँगा।"
            case .arabic: return "وصلتني محادثتك، وأنا هنا لمواصلة مساعدتك."
            case .portuguese: return "Recebi sua conversa e estou aqui para continuar ajudando."
            case .russian: return "Я получил ваш чат и готов продолжить помогать вам."
            case .simplifiedChinese, .traditionalChinese: return "我已接到您的会话，会继续协助您处理。"
            default: continue
            }
        }
        return "我已接到您的会话，会继续协助您处理。"
    }

    struct Handoff: Equatable {
        let boundaryKey: String
        let priorCustomerIDs: [String]
        let currentCustomerIDs: [String]
    }

    struct Record {
        let handoff: Handoff
        let hasServiceReply: Bool
        let identityBoundaryKey: String?
    }

    static func recipient(_ text: String) -> String? {
        guard let marker = text.range(of: "将该会话转移给") else { return nil }
        let tail = text[marker.upperBound...]
        let name = tail.prefix { !["，", ",", "。", "\n"].contains($0) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    static func latestTransferRecipient(in root: AXNodeSnapshot) -> String? {
        if root.domClasses.contains(where: {
            $0.contains("chat-item-box") || ["buyer-item", "cs-item"].contains($0)
        }) { return nil }
        if root.domClasses.contains("onemsg"), !PDDChatParser.parse(root: root).messages.isEmpty { return nil }
        if root.role == "AXStaticText",
           let text = root.attribute(named: "AXValue") ?? root.attribute(named: "AXTitle"),
           let target = recipient(text) { return target }
        return root.children.reversed().compactMap { latestTransferRecipient(in: $0) }.first
    }

    static func currentAgent(in root: AXNodeSnapshot) -> String? {
        if root.role == "AXWebArea" {
            return root.attribute(named: "AXTitle")?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return root.children.compactMap { currentAgent(in: $0) }.first
    }

    static func pendingRows(in tree: PDDAXSemanticTree) -> [PDDConversationRow<AXElementToken>] {
        guard let agent = currentAgent(in: tree.rootSnapshot), !agent.isEmpty,
              let rows = try? PDDAXControlSelection.conversationRows(in: tree.nodes) else { return [] }
        let children = Dictionary(grouping: tree.nodes, by: \.parentID)
        func hasNotice(_ id: AXElementToken) -> Bool {
            (children[id] ?? []).contains { node in
                [node.value, node.title].compactMap { $0 }.contains { recipient($0) == agent }
                    || hasNotice(node.id)
            }
        }
        return rows.filter { hasNotice($0.rowID) }
    }

    /// Only the latest system transfer matters. A service reply after it closes
    /// this special handoff path; an ordinary customer bubble cannot forge it.
    /// Messages before the notice are context only and never become current work.
    static func unansweredHandoff(in root: AXNodeSnapshot) -> Handoff? {
        guard let record = incomingRecord(in: root), !record.hasServiceReply else { return nil }
        return record.handoff
    }

    /// Retains the same identity evidence after a service reply closes a handoff.
    static func incomingRecord(in root: AXNodeSnapshot) -> Record? {
        guard let agent = currentAgent(in: root), !agent.isEmpty else { return nil }
        enum Entry {
            case message(PDDChatMessage)
            case transfer(target: String, marker: String, stableMarker: Bool)
        }
        var entries: [Entry] = []
        func visit(_ node: AXNodeSnapshot, noticeID: String? = nil) {
            var noticeID = noticeID
            if node.domClasses.contains(where: { $0.contains("chat-item-box") }) { return }
            if node.domClasses.contains("onemsg") {
                let parsed = PDDChatParser.parse(root: node).messages
                if !parsed.isEmpty {
                    entries.append(contentsOf: parsed.map(Entry.message))
                    return
                }
                noticeID = node.attribute(named: "AXDOMIdentifier") ?? noticeID
            }
            // Customer/service content is never a platform transfer notice.
            if node.domClasses.contains("buyer-item") || node.domClasses.contains("cs-item") { return }
            if node.role == "AXStaticText",
               let text = node.attribute(named: "AXValue") ?? node.attribute(named: "AXTitle"),
               let target = recipient(text) {
                entries.append(.transfer(
                    target: target,
                    marker: node.attribute(named: "AXDOMIdentifier") ?? noticeID ?? text,
                    stableMarker: node.attribute(named: "AXDOMIdentifier") != nil || noticeID != nil
                ))
                return
            }
            node.children.forEach { visit($0, noticeID: noticeID) }
        }
        visit(root)
        guard let notice = entries.lastIndex(where: {
            if case .transfer = $0 { return true }
            return false
        }), case .transfer(let target, let marker, let stableMarker) = entries[notice], target == agent else {
            return nil
        }
        let after = entries.suffix(from: notice + 1).compactMap { entry -> PDDChatMessage? in
            if case .message(let message) = entry { return message }; return nil
        }
        let before = entries.prefix(notice).compactMap { entry -> PDDChatMessage? in
            if case .message(let message) = entry { return message }; return nil
        }
        let boundaryMaterial = [agent, target, marker, before.last?.id ?? ""]
            .joined(separator: "\n")
        let boundaryKey = SHA256.hash(data: Data(boundaryMaterial.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return Record(handoff: Handoff(
            boundaryKey: boundaryKey,
            priorCustomerIDs: before.filter { $0.sender == .customer }.map(\.id),
            currentCustomerIDs: after.filter { $0.sender == .customer }.map(\.id)
        ), hasServiceReply: after.contains { $0.sender == .service },
           identityBoundaryKey: stableMarker || !before.isEmpty ? boundaryKey : nil)
    }

    static func customerIDsForUnansweredHandoff(in root: AXNodeSnapshot) -> [String] {
        unansweredHandoff(in: root)?.currentCustomerIDs ?? []
    }

    static func recoveryCursor(in history: [PDDChatMessage], customerIDs: [String]) throws -> AutoReplyCursor? {
        let ids = Set(customerIDs)
        guard let first = history.firstIndex(where: { $0.sender == .customer && ids.contains($0.id) }) else { return nil }
        return try AutoReplyTimeline.make(messages: Array(history.prefix(first))).cursor
    }
}
