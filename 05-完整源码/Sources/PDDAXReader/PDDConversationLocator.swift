import CryptoKit
import Foundation

struct PDDConversationLocator: Codable, Equatable, Sendable {
    var domIdentifier: String?
    var nickname: String

    var normalizedNickname: String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum PDDConversationKey {
    static func make(locator: PDDConversationLocator) -> String {
        let identifier = locator.domIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usableIdentifier = identifier.flatMap { $0.isEmpty ? nil : $0 }
        let source = usableIdentifier ?? locator.normalizedNickname
        let prefix = usableIdentifier == nil ? "PDD-NAME-" : "PDD-ID-"
        let digest = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return prefix + String(digest.prefix(24))
    }
}

struct PDDConversationDiagnostic: Equatable, Sendable {
    let uid: String
    let kind: String
    let detail: String
}

enum PDDConversationSnapshotLocator {
    static func current(in root: AXNodeSnapshot) -> PDDConversationLocator? {
        let allNodes = flattened(root)
        guard let row = allNodes.first(where: { node in
            let classes = Set(node.domClasses.map { $0.lowercased() })
            return classes.contains(where: { $0.contains("chat-item-box") })
                && classes.contains(where: { $0 == "active" || $0.contains("selected") })
        }),
        let nicknameBox = flattened(row).first(where: { node in
            node.domClasses.contains { $0.lowercased().contains("chat-nickname") }
        }),
        let nickname = flattened(nicknameBox).compactMap({ node in
            [node.attribute(named: "AXValue"), node.attribute(named: "AXTitle")]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !$0.hasPrefix("下单数") }
        }).first else { return nil }
        let rawIdentifier = row.attribute(named: "AXDOMIdentifier")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PDDConversationLocator(
            domIdentifier: rawIdentifier.flatMap { $0.isEmpty ? nil : $0 },
            nickname: nickname
        )
    }

    private static func flattened(_ root: AXNodeSnapshot) -> [AXNodeSnapshot] {
        [root] + root.children.flatMap(flattened)
    }
}
