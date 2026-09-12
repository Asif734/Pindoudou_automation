import CoreGraphics
import CryptoKit
import Foundation

struct PDDOCRLine: Codable, Equatable, Sendable {
    let text: String
    let box: CGRect
    let confidence: Double?
}

struct PDDOCRMessage: Codable, Equatable, Sendable {
    let id: String
    let sender: ChatSender
    let text: String
    let timestamp: String?
    let box: CGRect
}

enum PDDOCRNormalizer {
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

enum PDDOCRMessageID {
    static func make(
        uid: String,
        sender: ChatSender,
        timestamp: String?,
        text: String,
        occurrence: Int
    ) -> String {
        let material = [uid, sender.rawValue, timestamp ?? "", PDDOCRNormalizer.normalize(text), String(occurrence)]
            .joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return "ocr-\(digest)"
    }
}
