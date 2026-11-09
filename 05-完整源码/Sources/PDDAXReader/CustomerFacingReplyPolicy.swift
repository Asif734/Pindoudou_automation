import Foundation
import NaturalLanguage

/// Last-resort delivery boundary for wording that exposes implementation details
/// or describes a handoff as a special human-verification step.
enum CustomerFacingReplyPolicy {
    private static let prohibitedPatterns: [(String, String)] = [
        (#"\b(?:I|we)\s+(?:can(?:not|['’]t)|am\s+unable\s+to|are\s+unable\s+to)\s+(?:view|watch|see|access|open)\s+(?:(?:your|the|this)\s+)?video\b|\b(?:your|the|this)\s+video\s+is\s+(?:still\s+)?(?:loading|processing)\b"#, "video processing status"),
        (#"(?:我|我们|这边).{0,8}(?:无法|不能|看不到|看不了).{0,8}视频|视频.{0,6}(?:还在|仍在|正在)?(?:加载|处理中)"#, "video processing status"),
        (#"\bAI\b"#, "AI"),
        (#"\bartificial\s+intelligence\b"#, "artificial intelligence"),
        (#"\bchat\s*bot\b|\bbot\b"#, "bot"),
        (#"\bautomation\b|\bautomated\s+(?:assistant|support|service|reply)\b"#, "automation"),
        (#"\b(?:human|live)\s+(?:agent|support|representative|customer\s+service)\b"#, "human agent"),
        (#"\bafter[- ]sales\s+agent\b"#, "after-sales agent"),
        (#"\b(?:agent|representative|colleague|support\s+(?:team|staff)|after[- ]sales\s+(?:team|staff))\b(?:\s*,?\s*(?:who|will|would|can|must|needs?\s+to|has\s+to|is\s+going\s+to|help\s+you|further)){0,5}\s+(?:verify|review|check|confirm)\b"#, "handoff verification"),
        (#"(?:人工|真人|机器人|自动客服|自动回复|自动化)"#, "technical identity"),
        (#"(?:客服|售后人员|售后同事|同事)(?:需要|将|会|来|为您|帮您|协助您|负责){0,4}(?:核实|审核|验证)"#, "handoff verification")
    ]

    static func violation(in reply: String) -> String? {
        for (pattern, label) in prohibitedPatterns
        where reply.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return label
        }
        return nil
    }
}

enum CustomerFacingFallback {
    static func videoQuestion(history: [PDDChatMessage]) -> String {
        let recognizer = NLLanguageRecognizer()
        for message in history.reversed() where message.sender == .customer && message.kind == .text {
            recognizer.reset(); recognizer.processString(message.content)
            switch recognizer.dominantLanguage {
            case .english: return "What would you like me to check in the video?"
            case .spanish: return "¿Qué te gustaría que revisara en el vídeo?"
            case .french: return "Que souhaitez-vous que je vérifie dans la vidéo ?"
            case .german: return "Was soll ich im Video überprüfen?"
            case .japanese: return "動画のどの点を確認すればよいですか？"
            case .korean: return "영상에서 어떤 부분을 확인해 드릴까요?"
            case .bengali: return "ভিডিওর কোন বিষয়টি আপনি আমাকে দেখতে বলছেন?"
            case .hindi: return "आप वीडियो में किस बात की जाँच करवाना चाहते हैं?"
            case .arabic: return "ما الذي تود مني التحقق منه في الفيديو؟"
            case .portuguese: return "O que gostaria que eu verificasse no vídeo?"
            case .russian: return "Что вы хотите, чтобы я проверил в видео?"
            case .simplifiedChinese, .traditionalChinese: return "您希望我重点帮您查看视频中的哪个问题？"
            default: continue
            }
        }
        return "您希望我重点帮您查看视频中的哪个问题？"
    }

    static func handoff(history: [PDDChatMessage]) -> String {
        let recognizer = NLLanguageRecognizer()
        for message in history.reversed() where message.sender == .customer && message.kind == .text {
            recognizer.reset(); recognizer.processString(message.content)
            switch recognizer.dominantLanguage {
            case .english: return "I’ll transfer you to a colleague for further assistance."
            case .spanish: return "Te pasaré con un compañero para que continúe ayudándote."
            case .french: return "Je vais vous mettre en relation avec un collègue pour poursuivre votre demande."
            case .german: return "Ich leite Sie an einen Kollegen weiter, der Ihnen weiterhilft."
            case .japanese: return "引き続き対応できる担当者におつなぎします。"
            case .korean: return "계속 도와드릴 수 있도록 다른 담당자에게 연결해 드리겠습니다."
            case .bengali: return "আরও সহায়তার জন্য আপনাকে একজন সহকর্মীর কাছে স্থানান্তর করছি।"
            case .hindi: return "आगे की सहायता के लिए मैं आपको एक सहकर्मी से जोड़ूँगा।"
            case .arabic: return "سأحوّلك إلى زميل لمواصلة مساعدتك."
            case .portuguese: return "Vou encaminhar você a um colega para continuar o atendimento."
            case .russian: return "Я передам ваш чат коллеге для дальнейшей помощи."
            case .simplifiedChinese, .traditionalChinese: return "我为您转接同事继续协助。"
            default: continue
            }
        }
        return "我为您转接同事继续协助。"
    }
}
