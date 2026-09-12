import Foundation

enum AXDumpFormatter {
    static func format(root: AXNodeSnapshot) -> String {
        var lines: [String] = []
        append(root, depth: 0, to: &lines)
        return lines.joined(separator: "\n")
    }

    private static func append(
        _ node: AXNodeSnapshot,
        depth: Int,
        to lines: inout [String]
    ) {
        let nodeIndent = String(repeating: "  ", count: depth)
        let detailIndent = String(repeating: "  ", count: depth + 1)
        let continuationIndent = String(repeating: "  ", count: depth + 2)

        lines.append("\(nodeIndent)\(node.role)")

        for (name, value) in node.attributes {
            let valueLines = value.components(separatedBy: .newlines)
            lines.append("\(detailIndent)@\(name): \(valueLines.first ?? "")")
            for continuation in valueLines.dropFirst() {
                lines.append("\(continuationIndent)\(continuation)")
            }
        }

        if !node.actions.isEmpty {
            lines.append("\(detailIndent)actions: \(node.actions.joined(separator: ", "))")
        }

        for child in node.children {
            append(child, depth: depth + 1, to: &lines)
        }
    }
}
