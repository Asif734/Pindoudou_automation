import Foundation

enum PDDCustomerIdentity {
    private static let pattern = try! NSRegularExpression(
        pattern: #"\bGZC-[0-9]+\b"#,
        options: []
    )

    static func resolve(from root: AXNodeSnapshot) -> String? {
        var identifiers = Set<String>()
        collect(from: root, into: &identifiers)
        return identifiers.count == 1 ? identifiers.first : nil
    }

    private static func collect(from node: AXNodeSnapshot, into identifiers: inout Set<String>) {
        for (_, value) in node.attributes {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            for match in pattern.matches(in: value, options: [], range: range) {
                guard let swiftRange = Range(match.range, in: value) else { continue }
                identifiers.insert(String(value[swiftRange]))
            }
        }

        for child in node.children {
            collect(from: child, into: &identifiers)
        }
    }
}
