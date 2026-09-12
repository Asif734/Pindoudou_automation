import CryptoKit
import Foundation

struct PDDAXVisibleMessageEvidence: Equatable, Sendable {
    let messageNodeCount: Int
    let messages: [PDDChatMessage]
    let diagnostics: [String]
    let fingerprint: String
    let isStructurallyValid: Bool

    static func extract(
        root: AXNodeSnapshot,
        capturedAt: Date = Date()
    ) -> PDDAXVisibleMessageEvidence {
        var nodes: [AXNodeSnapshot] = []
        collectMessageNodes(in: root, into: &nodes)
        var messages: [PDDChatMessage] = []
        var diagnostics: [String] = []
        for node in nodes {
            let result = PDDChatParser.parse(root: node, capturedAt: capturedAt)
            diagnostics.append(contentsOf: result.diagnostics)
            for message in result.messages {
                guard message.kind == .image, message.id.hasPrefix("fallback-") else {
                    messages.append(message)
                    continue
                }
                guard let chromeNodeID = stableImageNodeID(in: node) else {
                    diagnostics.append("跳过无稳定 AX 节点 ID 的图片消息")
                    continue
                }
                messages.append(PDDChatMessage(
                    id: "\(message.id)-chrome-\(chromeNodeID)",
                    sender: message.sender,
                    content: message.content,
                    displayTime: message.displayTime,
                    kind: message.kind,
                    capturedAt: message.capturedAt
                ))
            }
        }
        let messageNodeCount = nodes.count
        let fingerprint = fingerprint(for: messages)
        let hasAmbiguousSender = diagnostics.contains {
            $0.contains("同时存在客户和客服标记")
        }
        return PDDAXVisibleMessageEvidence(
            messageNodeCount: messageNodeCount,
            messages: messages,
            diagnostics: diagnostics,
            fingerprint: fingerprint,
            isStructurallyValid: messageNodeCount > 0
                && !messages.isEmpty
                && !hasAmbiguousSender
        )
    }

    private static func collectMessageNodes(
        in node: AXNodeSnapshot,
        into result: inout [AXNodeSnapshot]
    ) {
        if node.domClasses.contains("onemsg") {
            result.append(node)
            return
        }
        for child in node.children { collectMessageNodes(in: child, into: &result) }
    }

    private static func stableImageNodeID(in node: AXNodeSnapshot) -> String? {
        if node.domClasses.contains("image-msg"),
           let raw = node.attribute(named: "ChromeAXNodeId")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           raw.allSatisfy(\.isNumber) {
            return raw
        }
        for child in node.children {
            if let result = stableImageNodeID(in: child) { return result }
        }
        return nil
    }

    private static func fingerprint(for messages: [PDDChatMessage]) -> String {
        let canonical = messages.map { message in
            [
                message.id,
                message.sender.rawValue,
                message.kind.rawValue,
                message.displayTime ?? "",
                PDDOCRNormalizer.normalize(message.content)
            ].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
