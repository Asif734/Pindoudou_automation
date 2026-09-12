import Foundation

enum BilingualText {
    static func lines(_ chinese: String, _ english: String) -> String {
        "\(chinese)\n\(english)"
    }

    static func split(_ value: String) -> (chinese: String, english: String) {
        let lines = value.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count == 2 else { return (value, value) }
        return (String(lines[0]), String(lines[1]))
    }
}
