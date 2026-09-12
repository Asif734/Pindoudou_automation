import Foundation

struct PDDAXSemanticNode<ID: Hashable>: Equatable {
    let id: ID
    let parentID: ID?
    let role: String
    let value: String?
    let title: String?
    let domIdentifier: String?
    let domClasses: Set<String>
    let actionNames: Set<String>
    let isSettable: Bool
    let frame: CGRect

    init(
        id: ID,
        parentID: ID?,
        role: String,
        value: String?,
        title: String?,
        domIdentifier: String?,
        domClasses: Set<String>,
        actionNames: Set<String>,
        isSettable: Bool,
        frame: CGRect = .zero
    ) {
        self.id = id
        self.parentID = parentID
        self.role = role
        self.value = value
        self.title = title
        self.domIdentifier = domIdentifier
        self.domClasses = domClasses
        self.actionNames = actionNames
        self.isSettable = isSettable
        self.frame = frame
    }
}

struct PDDConversationCandidate<ID: Hashable>: Equatable {
    let rowID: ID
    let visibleLabel: String
    let unreadCount: Int
}

struct PDDConversationRow<ID: Hashable>: Equatable {
    let rowID: ID
    let visibleLabel: String
    let domIdentifier: String?
    let frame: CGRect

    init(
        rowID: ID,
        visibleLabel: String,
        domIdentifier: String? = nil,
        frame: CGRect = .zero
    ) {
        self.rowID = rowID
        self.visibleLabel = visibleLabel
        self.domIdentifier = domIdentifier
        self.frame = frame
    }
}

struct PDDOrdinaryTransferAction<ID: Hashable>: Equatable {
    let controlID: ID
    let agentLabel: String
    let frame: CGRect
}

enum PDDAXSelectionError: Error, Equatable, LocalizedError {
    case missing(String)
    case ambiguous(String, Int)

    var errorDescription: String? {
        switch self {
        case .missing(let control): return "没有找到唯一的 \(control)"
        case .ambiguous(let control, let count): return "\(control) 候选不唯一：\(count) 个"
        }
    }
}
