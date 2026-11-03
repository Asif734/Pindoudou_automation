import CryptoKit
import Foundation

struct PDDConversationLocator: Codable, Equatable, Sendable {
    var domIdentifier: String?
    var nickname: String

    var normalizedNickname: String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedIdentifier: String? {
        domIdentifier.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    // Masked names are display labels, not durable customer identifiers. A
    // changed mask cannot prove that the customer left the conversation list.
    func couldBeSameDisplayedCustomer(as other: PDDConversationLocator) -> Bool {
        let left = normalizedNickname.lowercased()
        let right = other.normalizedNickname.lowercased()
        let generic: Set<String> = ["", "游客", "访客", "visitor", "guest"]
        if generic.contains(left) || generic.contains(right) { return true }
        if left == right { return true }
        guard left.contains("*") || right.contains("*") else { return false }
        let lp = String(left.prefix { $0 != "*" })
        let rp = String(right.prefix { $0 != "*" })
        let ls = String(left.reversed().prefix { $0 != "*" }.reversed())
        let rs = String(right.reversed().prefix { $0 != "*" }.reversed())
        return (lp.hasPrefix(rp) || rp.hasPrefix(lp)) && (ls.hasSuffix(rs) || rs.hasSuffix(ls))
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
        let activeRows = allNodes.filter { node in
            let classes = Set(node.domClasses.map { $0.lowercased() })
            return classes.contains(where: { $0.contains("chat-item-box") })
                && classes.contains(where: { $0 == "active" || $0.contains("selected") })
        }
        guard activeRows.count == 1, let row = activeRows.first else { return nil }
        return locator(from: row)
    }

    static func all(in root: AXNodeSnapshot) -> [PDDConversationLocator] {
        flattened(root).filter { node in
            node.domClasses.contains { $0.lowercased().contains("chat-item-box") }
        }.compactMap { locator(from: $0) }
    }

    static func activeCount(in root: AXNodeSnapshot) -> Int {
        flattened(root).filter { node in
            node.domClasses.contains { $0.lowercased().contains("chat-item-box") }
                && node.domClasses.contains { $0.lowercased() == "active" || $0.lowercased().contains("selected") }
        }.count
    }

    static func activeIdentifier(in root: AXNodeSnapshot) -> String? {
        let rows = flattened(root).filter { node in
            node.domClasses.contains { $0.lowercased().contains("chat-item-box") }
                && node.domClasses.contains { $0.lowercased() == "active" || $0.lowercased().contains("selected") }
        }
        guard rows.count == 1 else { return nil }
        guard let identifier = rows.first?.attribute(named: "AXDOMIdentifier")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty else { return nil }
        return identifier
    }

    private static func locator(from row: AXNodeSnapshot) -> PDDConversationLocator? {
        guard let nicknameBox = flattened(row).first(where: { node in
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
