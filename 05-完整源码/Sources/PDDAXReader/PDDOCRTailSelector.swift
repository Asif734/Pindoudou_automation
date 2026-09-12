import CryptoKit
import Foundation

enum PDDOCRTailSelector {
    static func select(
        uid: String,
        ocrMessages: [PDDOCRMessage],
        axMessages: [PDDChatMessage],
        hasUnreadEvidence: Bool,
        capturedAt: Date = Date()
    ) -> PDDChatMessage? {
        let ordered = ocrMessages.sorted {
            if abs($0.box.midY - $1.box.midY) > 1 { return $0.box.midY < $1.box.midY }
            return $0.box.minX < $1.box.minX
        }

        let tail: ArraySlice<PDDOCRMessage>
        if let anchor = axMessages.last {
            guard anchor.kind != .image,
                  let anchorIndex = ordered.lastIndex(where: { exactMatch($0, anchor) }) else {
                return nil
            }
            tail = ordered.dropFirst(anchorIndex + 1)
        } else {
            guard hasUnreadEvidence else { return nil }
            tail = ordered[...]
        }

        let serviceContents = Set(axMessages.lazy
            .filter { $0.sender == .service }
            .map { PDDOCRNormalizer.normalize($0.content) })
        let credibleTail = tail.filter { message in
            let content = PDDOCRNormalizer.normalize(message.text)
            return !content.isEmpty
                && !serviceContents.contains(content)
                && !isNoise(content)
        }
        guard let selected = credibleTail.last, selected.sender == .customer else { return nil }

        let content = PDDOCRNormalizer.normalize(selected.text)
        return PDDChatMessage(
            id: provisionalID(uid: uid, message: selected, normalizedContent: content),
            sender: .customer,
            content: content,
            displayTime: selected.timestamp,
            kind: .text,
            capturedAt: capturedAt
        )
    }

    private static func exactMatch(_ ocr: PDDOCRMessage, _ ax: PDDChatMessage) -> Bool {
        ocr.sender == ax.sender
            && PDDOCRNormalizer.normalize(ocr.text) == PDDOCRNormalizer.normalize(ax.content)
    }

    private static func isNoise(_ content: String) -> Bool {
        if PDDOCRChatParser.isKnownPlatformNoiseText(content) { return true }
        if content.range(
            of: #"^(?:\d{1,2}:)?\d{1,2}:\d{2}$"#,
            options: .regularExpression
        ) != nil { return true }
        if ["已读", "未读", "邀请关注", "邀请下单", "小额打款", "发送", "了解更多", "复制"]
            .contains(content) {
            return true
        }
        return content == "格志"
            || content.hasPrefix("Grozziie")
            || content.hasPrefix("格志打印机小")
            || content.hasPrefix("格志官方旗舰")
            || content.contains("服务用语须严格遵守")
            || content.contains("商家在售后服务过程中")
    }

    private static func provisionalID(
        uid: String,
        message: PDDOCRMessage,
        normalizedContent: String
    ) -> String {
        let material = [uid, message.id, message.timestamp ?? "", normalizedContent]
            .joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return "ocr-provisional-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
