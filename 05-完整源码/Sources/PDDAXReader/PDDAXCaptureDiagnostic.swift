import Foundation

enum PDDAXCaptureSurface {
    /// Reading message bubbles and locating a writable composer are separate
    /// capabilities. Recipient verification remains the driver's responsibility.
    static func hasReadableMessages(in tree: PDDAXSemanticTree) -> Bool {
        let hasPane = tree.nodes.contains { node in
            node.domClasses.contains { $0.contains("middle-panel") || $0.contains("chat-panel") }
        }
        return hasPane && PDDAXVisibleMessageEvidence.extract(root: tree.rootSnapshot).isStructurallyValid
    }
}

/// Local, replayable evidence. Never itself assigns a UID or submits to Codex.
struct PDDAXCaptureDiagnostic: Codable {
    struct Snapshot: Codable {
        let role: String
        let attributes: [String: String]
        let actions: [String]
        let children: [Snapshot]
        init(_ node: AXNodeSnapshot) {
            role = node.role
            attributes = Dictionary(node.attributes.filter {
                ["AXValue", "AXTitle", "AXDescription", "AXDOMClassList", "AXDOMIdentifier", "ChromeAXNodeId"].contains($0.0)
            }, uniquingKeysWith: { first, _ in first })
            actions = node.actions
            children = node.children.map(Snapshot.init)
        }
        var replay: AXNodeSnapshot {
            .init(role: role, attributes: attributes.sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
                actions: actions, children: children.map(\.replay))
        }
    }
    struct Node: Codable {
        let id: Int
        let parentID: Int?
        let role: String
        let value: String?
        let title: String?
        let description: String?
        let identifier: String?
        let classes: [String]
        let actions: [String]
        let settable: Bool
        let frame: CGRect
        init(_ node: PDDAXSemanticNode<AXElementToken>) {
            id = node.id.rawValue; parentID = node.parentID?.rawValue
            role = node.role; value = node.value; title = node.title; description = node.accessibilityDescription
            identifier = node.domIdentifier; classes = node.domClasses.sorted(); actions = node.actionNames.sorted()
            settable = node.isSettable; frame = node.frame
        }
        var replay: PDDAXSemanticNode<AXElementToken> {
            .init(id: .init(rawValue: id), parentID: parentID.map { .init(rawValue: $0) }, role: role,
                value: value, title: title, domIdentifier: identifier, domClasses: Set(classes),
                actionNames: Set(actions), isSettable: settable, frame: frame, accessibilityDescription: description)
        }
    }
    let schemaVersion: Int
    let reason: String
    let taskID: UUID?
    let recordedAt: Date
    let expectedLocator: PDDConversationLocator?
    let currentLocator: PDDConversationLocator?
    let ownerCandidates: Set<String>
    let messageIDs: Set<String>
    let composerCandidateCount: Int
    let snapshotActiveCount: Int
    let semanticActiveCount: Int
    let readableMessagePane: Bool
    let submittedToCodex: Bool
    let rootSnapshot: Snapshot
    let nodes: [Node]

    init(reason: String, task: PDDPendingDiscovery?, tree: PDDAXSemanticTree,
         ownerCandidates: Set<String>, at date: Date) {
        schemaVersion = 1; submittedToCodex = false
        self.reason = reason; taskID = task?.id; recordedAt = date
        expectedLocator = task?.locator
        currentLocator = PDDConversationSnapshotLocator.current(in: tree.rootSnapshot)
        self.ownerCandidates = ownerCandidates
        messageIDs = Set(PDDChatParser.parse(root: tree.rootSnapshot).messages.filter { $0.sender == .customer }.map(\.id))
        composerCandidateCount = PDDAXControlSelection.composerCandidates(in: tree.nodes).count
        snapshotActiveCount = PDDConversationSnapshotLocator.activeCount(in: tree.rootSnapshot)
        let index = Dictionary(uniqueKeysWithValues: tree.nodes.map { ($0.id, $0) })
        semanticActiveCount = ((try? PDDAXControlSelection.conversationRows(in: tree.nodes)) ?? []).filter { row in
            index[row.rowID]?.domClasses.contains { $0 == "active" || $0.contains("selected") } == true
        }.count
        readableMessagePane = PDDAXCaptureSurface.hasReadableMessages(in: tree)
        rootSnapshot = Snapshot(tree.rootSnapshot); nodes = tree.nodes.map(Node.init)
    }
    var replay: PDDAXSemanticTree { .init(rootSnapshot: rootSnapshot.replay, nodes: nodes.map(\.replay)) }

    func save(root: URL) throws -> URL {
        let directory = root.appendingPathComponent("logs/capture-diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(taskID?.uuidString ?? "visible")-\(reason).json"
        let path = directory.appendingPathComponent(name)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: path, options: .atomic)
        return path
    }
}
