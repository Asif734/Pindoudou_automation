import Foundation

/// Last-resort delivery boundary for wording that exposes implementation details
/// or describes a handoff as a special human-verification step.
enum CustomerFacingReplyPolicy {
    private static let prohibitedPatterns: [(String, String)] = [
        (#"\bAI\b"#, "AI"),
        (#"\bartificial\s+intelligence\b"#, "artificial intelligence"),
        (#"\bchat\s*bot\b|\bbot\b"#, "bot"),
        (#"\bautomation\b|\bautomated\s+(?:assistant|support|service|reply)\b"#, "automation"),
        (#"\b(?:human|live)\s+(?:agent|support|representative|customer\s+service)\b"#, "human agent"),
        (#"\bafter[- ]sales\s+agent\b"#, "after-sales agent"),
        (#"\b(?:agent|support|after[- ]sales|representative|colleague)\b.{0,48}\b(?:verify|verification|review|check|confirm)\b"#, "handoff verification"),
        (#"(?:人工|真人|机器人|自动客服|自动回复|自动化)"#, "technical identity"),
        (#"(?:客服|售后|同事).{0,24}(?:核实|审核|验证)"#, "handoff verification")
    ]

    static func violation(in reply: String) -> String? {
        for (pattern, label) in prohibitedPatterns
        where reply.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return label
        }
        return nil
    }
}
