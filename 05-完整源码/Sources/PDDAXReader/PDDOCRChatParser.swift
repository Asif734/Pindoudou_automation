import CoreGraphics
import Foundation

enum PDDOCRChatParser {
    static func isKnownPlatformNoiseText(_ rawText: String) -> Bool {
        let text = PDDOCRNormalizer.normalize(rawText)
        return (text.contains("分歧或争议") && text.contains("商家需主动"))
            || (text.contains("存在瑕疵") && text.contains("商家应主动调查"))
            || text.contains("1.主动调查:")
            || text.contains("2.结论告知:")
            || (text.contains("基于调查结果") && text.contains("责任认定"))
            || text.contains("货物打包视频")
            || text.contains("批次质检报告")
    }

    static func parse(uid: String, lines: [PDDOCRLine], imageSize: CGSize) -> [PDDOCRMessage] {
        guard imageSize.width > 0, imageSize.height > 0 else { return [] }
        let ordered = lines
            .filter { $0.box.midY < imageSize.height * 0.96 }
            .sorted { lhs, rhs in
                abs(lhs.box.midY - rhs.box.midY) > 4 ? lhs.box.midY < rhs.box.midY : lhs.box.minX < rhs.box.minX
            }
        let toolbarTop = lines.compactMap { line -> CGFloat? in
            let text = PDDOCRNormalizer.normalize(line.text)
            guard ["邀请关注", "邀请下单", "小额打款"].contains(text) else { return nil }
            return line.box.minY - max(16, line.box.height * 0.75)
        }.min()
        var pendingTimestamp: String?
        var suppressSystemNoticeUntilY: CGFloat = -.greatestFiniteMagnitude
        var drafts: [(
            sender: ChatSender,
            text: String,
            timestamp: String?,
            box: CGRect,
            lastLineBox: CGRect
        )] = []

        for line in ordered {
            let text = PDDOCRNormalizer.normalize(line.text)
            guard !text.isEmpty else { continue }
            if text == "复制",
               ordered.contains(where: { candidate in
                   candidate.box.minX < line.box.minX
                       && line.box.minX - candidate.box.maxX <= imageSize.width * 0.08
                       && abs(candidate.box.midY - line.box.midY)
                           <= max(8, line.box.height * 0.6)
               }) {
                continue
            }
            if let toolbarTop, line.box.minY >= toolbarTop { continue }
            if isSystemNotice(text) {
                suppressSystemNoticeUntilY = max(
                    suppressSystemNoticeUntilY,
                    line.box.maxY + max(16, line.box.height * 1.5)
                )
                continue
            }
            if line.box.midY <= suppressSystemNoticeUntilY { continue }
            if let timestamp = timestamp(from: text) {
                pendingTimestamp = timestamp
                continue
            }
            if isNoise(text, box: line.box, imageWidth: imageSize.width)
                || (line.confidence ?? 1) < 0.75
                || line.box.minX <= 1 {
                continue
            }
            if let last = drafts.last,
               pendingTimestamp == nil,
               line.box.minY - last.lastLineBox.maxY >= -2,
               line.box.minY - last.lastLineBox.maxY <= max(18, last.lastLineBox.height * 1.4),
               abs(line.box.minX - last.lastLineBox.minX) <= max(24, last.lastLineBox.width * 0.12),
               sender(for: line.box, imageWidth: imageSize.width).map({ $0 == last.sender }) ?? true {
                drafts[drafts.count - 1].text += text
                drafts[drafts.count - 1].box = last.box.union(line.box)
                drafts[drafts.count - 1].lastLineBox = line.box
            } else {
                guard let sender = sender(for: line.box, imageWidth: imageSize.width) else { continue }
                drafts.append((sender, text, pendingTimestamp, line.box, line.box))
            }
            pendingTimestamp = nil
        }

        var occurrences: [String: Int] = [:]
        return drafts.compactMap { draft in
            let text = draft.text.hasSuffix("复制")
                ? String(draft.text.dropLast("复制".count))
                : draft.text
            guard !text.isEmpty else { return nil }
            let key = [draft.sender.rawValue, draft.timestamp ?? "", PDDOCRNormalizer.normalize(text)]
                .joined(separator: "\u{1f}")
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            return PDDOCRMessage(
                id: PDDOCRMessageID.make(
                    uid: uid, sender: draft.sender, timestamp: draft.timestamp,
                    text: text, occurrence: occurrence
                ),
                sender: draft.sender,
                text: text,
                timestamp: draft.timestamp,
                box: draft.box
            )
        }
    }

    private static func sender(for box: CGRect, imageWidth: CGFloat) -> ChatSender? {
        if box.minX <= imageWidth * 0.24, box.maxX <= imageWidth * 0.72 { return .customer }
        if box.minX >= imageWidth * 0.25, box.maxX >= imageWidth * 0.72 { return .service }
        return nil
    }

    private static func isNoise(_ text: String, box: CGRect, imageWidth: CGFloat) -> Bool {
        if isKnownPlatformNoiseText(text) { return true }
        if ["已读", "未读", "邀请关注", "邀请下单", "小额打款", "发送", "了解更多"].contains(text) {
            return true
        }
        if text == "格志" || text.hasPrefix("Grozziie")
            || text.hasPrefix("格志打印机小") || text.hasPrefix("格志官方旗舰") {
            return true
        }
        if text.contains("旗舰"), box.height >= 40 { return true }
        return text.contains("服务用语须严格遵守")
            || text.contains("商家在售后服务过程中")
    }

    private static func isSystemNotice(_ text: String) -> Bool {
        text.contains("将该会话转移给")
    }

    private static func timestamp(from text: String) -> String? {
        let pattern = #"(\d{4})[年/.-](\d{1,2})[月/.-](\d{1,2})日?\s*(\d{1,2}):(\d{2})(?::(\d{2}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        func part(_ index: Int) -> Int? {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[range])
        }
        guard let year = part(1), let month = part(2), let day = part(3),
              let hour = part(4), let minute = part(5) else { return nil }
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, part(6) ?? 0)
    }
}
