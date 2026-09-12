import CryptoKit
import Foundation

enum PDDChatParser {
    static func parse(root: AXNodeSnapshot, capturedAt: Date = Date()) -> PDDChatParseResult {
        var messages: [PDDChatMessage] = []
        var diagnostics: [String] = []
        visit(root, capturedAt: capturedAt, messages: &messages, diagnostics: &diagnostics)
        return PDDChatParseResult(messages: messages, diagnostics: diagnostics)
    }

    private static func visit(
        _ node: AXNodeSnapshot,
        capturedAt: Date,
        messages: inout [PDDChatMessage],
        diagnostics: inout [String]
    ) {
        if node.domClasses.contains("onemsg") {
            switch parseMessage(node, capturedAt: capturedAt) {
            case .success(let message):
                messages.append(message)
            case .failure(let reason):
                let identifier = node.attribute(named: "AXDOMIdentifier") ?? "无消息 ID"
                diagnostics.append("跳过 \(identifier)：\(reason)")
            }
            return
        }

        for child in node.children {
            visit(child, capturedAt: capturedAt, messages: &messages, diagnostics: &diagnostics)
        }
    }

    private enum MessageResult {
        case success(PDDChatMessage)
        case failure(String)
    }

    private static func parseMessage(_ node: AXNodeSnapshot, capturedAt: Date) -> MessageResult {
        let hasCustomer = containsClass("buyer-item", in: node)
        let hasService = containsClass("cs-item", in: node)
        guard hasCustomer != hasService else {
            return .failure(hasCustomer ? "同时存在客户和客服标记" : "没有发送方标记")
        }
        let sender: ChatSender = hasCustomer ? .customer : .service

        var contentRoots: [AXNodeSnapshot] = []
        collectContentRoots(in: node, into: &contentRoots)
        if contentRoots.isEmpty, containsExplicitVideo(in: node) {
            contentRoots = [node]
        }
        let isVideo = contentRoots.contains { containsVideo(in: $0) }
        let isImage = !isVideo && contentRoots.contains { containsClass("image-msg", in: $0) }

        var values: [String] = []
        var hasLink = false
        if !isImage && !isVideo {
            for contentRoot in contentRoots {
                collectVisibleContent(in: contentRoot, values: &values, hasLink: &hasLink)
            }
        }
        values = orderedUnique(values.map(normalize).filter { !$0.isEmpty })

        let kind: ChatContentKind
        let content: String
        if isVideo {
            kind = .video
            content = "[视频]"
        } else if isImage {
            kind = .image
            content = "[图片]"
        } else {
            guard !values.isEmpty else { return .failure("消息正文为空") }
            kind = hasLink ? .link : .text
            content = values.joined(separator: "\n")
        }

        let displayTime = firstVisibleValue(inClass: "message-time", node: node)
        let messageID = node.attribute(named: "AXDOMIdentifier")
            .flatMap { $0.hasPrefix("middlePanel_list_") ? $0 : nil }
            ?? fallbackID(sender: sender, kind: kind, time: displayTime, content: content)

        return .success(PDDChatMessage(
            id: messageID,
            sender: sender,
            content: content,
            displayTime: displayTime,
            kind: kind,
            capturedAt: capturedAt
        ))
    }

    private static func containsVideo(in node: AXNodeSnapshot) -> Bool {
        if containsExplicitVideo(in: node) { return true }

        var hasThumbnail = false
        var hasDuration = false
        func scan(_ current: AXNodeSnapshot) {
            if current.role.caseInsensitiveCompare("AXImage") == .orderedSame,
               !current.domClasses.contains(where: { $0.lowercased().contains("avatar") }) {
                hasThumbnail = true
            }
            for (_, rawValue) in current.attributes {
                let value = normalize(rawValue)
                if value.range(of: #"^(?:\d{1,2}:)?\d{1,2}:\d{2}$"#, options: .regularExpression) != nil {
                    hasDuration = true
                }
            }
            for child in current.children { scan(child) }
        }
        scan(node)
        return hasThumbnail && hasDuration
    }

    private static func containsExplicitVideo(in node: AXNodeSnapshot) -> Bool {
        if node.domClasses.contains(where: {
            let value = $0.lowercased()
            return value.contains("video") && !value.contains("avatar")
        }) { return true }
        return node.children.contains(where: containsExplicitVideo)
    }

    private static func collectContentRoots(
        in node: AXNodeSnapshot,
        into roots: inout [AXNodeSnapshot]
    ) {
        if node.domClasses.contains("msg-content-box") {
            roots.append(node)
            return
        }
        if node.domClasses.contains("msg-content") {
            var boxes: [AXNodeSnapshot] = []
            for child in node.children {
                collectMessageContentBoxes(in: child, into: &boxes)
            }
            roots.append(contentsOf: boxes.isEmpty ? [node] : boxes)
            return
        }
        for child in node.children {
            collectContentRoots(in: child, into: &roots)
        }
    }

    private static func collectMessageContentBoxes(
        in node: AXNodeSnapshot,
        into boxes: inout [AXNodeSnapshot]
    ) {
        if node.domClasses.contains("msg-content-box") {
            boxes.append(node)
            return
        }
        for child in node.children {
            collectMessageContentBoxes(in: child, into: &boxes)
        }
    }

    private static func collectVisibleContent(
        in node: AXNodeSnapshot,
        values: inout [String],
        hasLink: inout Bool
    ) {
        let allowedNames: Set<String> = ["AXValue", "AXTitle", "AXDescription", "AXURL"]
        for (name, rawValue) in node.attributes where allowedNames.contains(name) {
            let value = normalize(rawValue)
            guard !value.isEmpty else { continue }
            if name == "AXURL" && !looksLikeURL(value) { continue }
            values.append(value)
            if looksLikeURL(value) { hasLink = true }
        }
        for child in node.children {
            collectVisibleContent(in: child, values: &values, hasLink: &hasLink)
        }
    }

    private static func containsClass(_ className: String, in node: AXNodeSnapshot) -> Bool {
        node.domClasses.contains(className)
            || node.children.contains { containsClass(className, in: $0) }
    }

    private static func firstVisibleValue(inClass className: String, node: AXNodeSnapshot) -> String? {
        if node.domClasses.contains(className) {
            var values: [String] = []
            var ignoredLink = false
            collectVisibleContent(in: node, values: &values, hasLink: &ignoredLink)
            return orderedUnique(values.map(normalize).filter { !$0.isEmpty }).first
        }
        for child in node.children {
            if let result = firstVisibleValue(inClass: className, node: child) { return result }
        }
        return nil
    }

    private static func fallbackID(
        sender: ChatSender,
        kind: ChatContentKind,
        time: String?,
        content: String
    ) -> String {
        let canonical = [sender.rawValue, kind.rawValue, time ?? "", content].joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return "fallback-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<AX error ") ? "" : trimmed
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func looksLikeURL(_ value: String) -> Bool {
        value.range(of: #"https?://[^\s]+"#, options: .regularExpression) != nil
    }
}
