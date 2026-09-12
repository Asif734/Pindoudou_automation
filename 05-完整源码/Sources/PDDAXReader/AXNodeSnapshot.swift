import Foundation

struct AXNodeSnapshot {
    let role: String
    let attributes: [(String, String)]
    let actions: [String]
    let children: [AXNodeSnapshot]

    init(
        role: String,
        attributes: [(String, String)] = [],
        actions: [String] = [],
        children: [AXNodeSnapshot] = []
    ) {
        self.role = role
        self.attributes = attributes
        self.actions = actions
        self.children = children
    }

    func attribute(named name: String) -> String? {
        attributes.first { $0.0 == name }?.1
    }

    var domClasses: Set<String> {
        guard let raw = attribute(named: "AXDOMClassList") else { return [] }
        return Set(
            raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }
}
