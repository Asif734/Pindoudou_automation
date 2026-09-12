import Foundation

enum PDDAXControlSelection {
    static func conversationCandidates<ID: Hashable>(
        in nodes: [PDDAXSemanticNode<ID>]
    ) throws -> [PDDConversationCandidate<ID>] {
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return try conversationRows(in: nodes).compactMap { row -> PDDConversationCandidate<ID>? in
            let rowNodes: [PDDAXSemanticNode<ID>] = [index[row.rowID]].compactMap { $0 }
                + descendants(of: row.rowID, nodes: nodes)
            let markers = rowNodes.filter(isUnreadMarker)
            guard !markers.isEmpty else { return nil }
            let numericCounts = markers.flatMap { marker in
                [marker] + descendants(of: marker.id, nodes: nodes)
            }.compactMap { node -> Int? in
                [node.value, node.title].compactMap { $0 }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .compactMap(Int.init).max()
            }
            return PDDConversationCandidate(
                rowID: row.rowID,
                visibleLabel: row.visibleLabel,
                unreadCount: max(1, numericCounts.max() ?? 1)
            )
        }
    }

    static func conversationRows<ID: Hashable>(
        in nodes: [PDDAXSemanticNode<ID>]
    ) throws -> [PDDConversationRow<ID>] {
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let rows = nodes.compactMap { node -> PDDConversationRow<ID>? in
            let isPressableRow = node.role == "AXRow" || node.actionNames.contains("AXPress")
            guard isPressableRow,
                  hasAncestor(node, in: index, matching: isConversationList),
                  !hasAncestor(node, in: index, matching: { ancestor in
                      (ancestor.role == "AXRow" || ancestor.actionNames.contains("AXPress"))
                          && !isConversationList(ancestor)
                  }) else { return nil }
            let children = descendants(of: node.id, nodes: nodes)
            let preferredTexts = children
                .filter(isNicknameNode)
                .flatMap { nicknameNode in
                    [nicknameNode] + descendants(of: nicknameNode.id, nodes: nodes)
                }
                .flatMap { [$0.value, $0.title] }
                .compactMap(normalizedConversationLabel)
            let fallbackTexts = ([node] + children)
                .flatMap { [$0.value, $0.title] }
                .compactMap(normalizedConversationLabel)
            guard let label = (preferredTexts + fallbackTexts).first else { return nil }
            let identifier = ([node] + children)
                .compactMap { normalizedDOMIdentifier($0.domIdentifier) }
                .first
            return PDDConversationRow(
                rowID: node.id,
                visibleLabel: label,
                domIdentifier: identifier,
                frame: node.frame
            )
        }
        let identifierCounts = Dictionary(grouping: rows.compactMap(\.domIdentifier), by: { $0 })
            .mapValues(\.count)
        return rows.map { row in
            guard let identifier = row.domIdentifier, identifierCounts[identifier] == 1 else {
                return PDDConversationRow(
                    rowID: row.rowID,
                    visibleLabel: row.visibleLabel,
                    frame: row.frame
                )
            }
            return row
        }
    }

    static func currentConversationRow<ID: Hashable>(
        in nodes: [PDDAXSemanticNode<ID>]
    ) throws -> PDDConversationRow<ID>? {
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        return try conversationRows(in: nodes).first { row in
            guard let node = index[row.rowID] else { return false }
            return node.domClasses.contains { rawClass in
                let value = rawClass.lowercased()
                return value == "active" || value.contains("selected")
            }
        }
    }

    static func composer<ID: Hashable>(in nodes: [PDDAXSemanticNode<ID>]) throws -> ID {
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let candidates = nodes.filter { node in
            node.role == "AXTextArea" && node.isSettable
                && hasAncestor(node, in: index, matching: isChatContainer)
        }
        return try uniqueID(candidates, name: "聊天输入框")
    }

    static func sendControl<ID: Hashable>(in nodes: [PDDAXSemanticNode<ID>]) throws -> ID {
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let candidates = nodes.filter { node in
            let texts = [node.value, node.title].compactMap { $0 }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let descendantHasExactLabel = descendants(of: node.id, nodes: nodes).contains { child in
                [child.value, child.title].compactMap { $0 }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .contains("发送")
            }
            let isSendControl = texts.contains("发送")
                || (hasClass(node, fragment: "send-btn") && descendantHasExactLabel)
            return isSendControl
                && node.actionNames.contains("AXPress")
                && hasAncestor(node, in: index, matching: isChatContainer)
        }
        return try uniqueID(candidates, name: "发送控件")
    }

    static func transferConversationTrigger<ID: Hashable>(
        in nodes: [PDDAXSemanticNode<ID>]
    ) throws -> ID {
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let dialogID = transferDialog(in: nodes)?.id
        let candidates = nodes.filter { node in
            exactTexts(node).contains("转移会话")
                && hasAncestor(node, in: index, matching: isChatContainer)
                && !hasAncestor(node, in: index, matching: isConversationList)
                && !isDescendant(node, of: dialogID, in: index)
        }
        return try uniqueID(candidates, name: "当前会话的转移会话控件")
    }

    static func ordinaryTransferActions<ID: Hashable>(
        in nodes: [PDDAXSemanticNode<ID>]
    ) throws -> [PDDOrdinaryTransferAction<ID>] {
        guard let dialog = transferDialog(in: nodes) else {
            throw PDDAXSelectionError.missing("转移会话弹窗")
        }
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let dialogNodes = descendants(of: dialog.id, nodes: nodes)
        return dialogNodes.filter { exactTexts($0).contains("转移") }.compactMap { labelNode in
            let control = nearestAncestor(
                of: labelNode, in: index,
                matching: { hasClass($0, fragment: "item-btn-transfer") }
            ) ?? labelNode
            let sameVisualRow = dialogNodes.filter { candidate in
                guard candidate.id != labelNode.id,
                      candidate.role == "AXStaticText",
                      candidate.frame.maxX < control.frame.minX,
                      abs(candidate.frame.midY - control.frame.midY) <= 24 else { return false }
                return exactTexts(candidate).contains { text in
                    !transferDialogNoiseLabels.contains(text) && Int(text) == nil
                }
            }
            let hierarchicalRow = nearestAncestor(
                of: labelNode, in: index, matching: { $0.role == "AXRow" }
            ).map { [ $0 ] + descendants(of: $0.id, nodes: nodes) } ?? []
            let label = (sameVisualRow.sorted { $0.frame.minX < $1.frame.minX }
                + hierarchicalRow).flatMap(exactTexts).first { text in
                    !transferDialogNoiseLabels.contains(text) && Int(text) == nil
            } ?? "未命名客服"
            return PDDOrdinaryTransferAction(
                controlID: control.id, agentLabel: label, frame: control.frame
            )
        }.sorted {
            if $0.frame.minY == $1.frame.minY { return $0.frame.minX < $1.frame.minX }
            return $0.frame.minY < $1.frame.minY
        }
    }

    static func isTransferDialogVisible<ID: Hashable>(
        in nodes: [PDDAXSemanticNode<ID>]
    ) -> Bool {
        transferDialog(in: nodes) != nil
    }

    private static func uniqueID<ID: Hashable>(
        _ nodes: [PDDAXSemanticNode<ID>],
        name: String
    ) throws -> ID {
        guard !nodes.isEmpty else { throw PDDAXSelectionError.missing(name) }
        guard nodes.count == 1 else { throw PDDAXSelectionError.ambiguous(name, nodes.count) }
        return nodes[0].id
    }

    private static func transferDialog<ID: Hashable>(
        in nodes: [PDDAXSemanticNode<ID>]
    ) -> PDDAXSemanticNode<ID>? {
        if let explicitlyLabelled = nodes.first(where: { node in
            exactTexts(node).contains("转移会话")
                && descendants(of: node.id, nodes: nodes).contains { child in
                    child.isSettable && exactTexts(child).contains("请输入内容")
                }
        }) {
            return explicitlyLabelled
        }
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        guard let search = nodes.first(where: {
            $0.isSettable && (exactTexts($0).contains("请输入内容")
                || hasClass($0, fragment: "el-input__inner"))
        }) else { return nil }
        var parentID = search.parentID
        var visited = Set<ID>()
        while let id = parentID, visited.insert(id).inserted, let parent = index[id] {
            let children = descendants(of: id, nodes: nodes)
            if children.contains(where: { exactTexts($0).contains("转移") })
                && children.contains(where: {
                    hasClass($0, fragment: "item-btn-transfer") || $0.role == "AXRow"
                }) {
                return parent
            }
            parentID = parent.parentID
        }
        return nil
    }

    private static let transferDialogNoiseLabels: Set<String> = [
        "转移会话", "转移", "转移并微信通知", "账号名", "昵称", "备注", "当前未回复", "操作"
    ]

    private static func nearestAncestor<ID: Hashable>(
        of node: PDDAXSemanticNode<ID>,
        in index: [ID: PDDAXSemanticNode<ID>],
        matching predicate: (PDDAXSemanticNode<ID>) -> Bool
    ) -> PDDAXSemanticNode<ID>? {
        var parentID = node.parentID
        var visited = Set<ID>()
        while let id = parentID, visited.insert(id).inserted, let parent = index[id] {
            if predicate(parent) { return parent }
            parentID = parent.parentID
        }
        return nil
    }

    private static func exactTexts<ID>(_ node: PDDAXSemanticNode<ID>) -> [String] {
        [node.value, node.title].compactMap { raw in
            guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return text
        }
    }

    private static func isDescendant<ID: Hashable>(
        _ node: PDDAXSemanticNode<ID>,
        of ancestorID: ID?,
        in index: [ID: PDDAXSemanticNode<ID>]
    ) -> Bool {
        guard let ancestorID else { return false }
        return hasAncestor(node, in: index, matching: { $0.id == ancestorID })
    }

    private static func isChatContainer<ID>(_ node: PDDAXSemanticNode<ID>) -> Bool {
        node.domClasses.contains { rawClass in
            let value = rawClass.lowercased()
            return value.contains("chat-panel") || value.contains("middle-panel")
        }
    }

    private static func isConversationList<ID>(_ node: PDDAXSemanticNode<ID>) -> Bool {
        hasClass(node, fragment: "chat-list-box")
            || hasClass(node, fragment: "conversation-list")
    }

    private static func isUnreadMarker<ID>(_ node: PDDAXSemanticNode<ID>) -> Bool {
        node.domClasses.contains { rawClass in
            let value = rawClass.lowercased()
            return value.contains("unread") || value.contains("red-dot")
        }
    }

    private static func normalizedVisibleText(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, Int(value) == nil else { return nil }
        return value
    }

    private static func normalizedConversationLabel(_ raw: String?) -> String? {
        guard var value = normalizedVisibleText(raw) else { return nil }
        value = value.replacingOccurrences(
            of: #"\s+[0-9]+$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.range(of: #"^[0-9]{1,2}:[0-9]{2}$"#, options: .regularExpression) == nil,
              !conversationNoiseLabels.contains(value) else { return nil }
        return value
    }

    private static func normalizedDOMIdentifier(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func isNicknameNode<ID>(_ node: PDDAXSemanticNode<ID>) -> Bool {
        node.domClasses.contains { rawClass in
            let value = rawClass.lowercased()
            return value.contains("nickname")
                || value.contains("user-name")
                || value.contains("buyer-name")
        }
    }

    private static let conversationNoiseLabels: Set<String> = [
        "转移会话", "已经没有更多了哦~", "已经没有更多了哦", "加载更多会话"
    ]

    private static func hasClass<ID>(_ node: PDDAXSemanticNode<ID>, fragment: String) -> Bool {
        node.domClasses.contains { $0.lowercased().contains(fragment) }
    }

    private static func hasAncestor<ID: Hashable>(
        _ node: PDDAXSemanticNode<ID>,
        in index: [ID: PDDAXSemanticNode<ID>],
        matching predicate: (PDDAXSemanticNode<ID>) -> Bool
    ) -> Bool {
        var parentID = node.parentID
        var visited = Set<ID>()
        while let id = parentID, visited.insert(id).inserted, let parent = index[id] {
            if predicate(parent) { return true }
            parentID = parent.parentID
        }
        return false
    }

    private static func descendants<ID: Hashable>(
        of parentID: ID,
        nodes: [PDDAXSemanticNode<ID>]
    ) -> [PDDAXSemanticNode<ID>] {
        var result: [PDDAXSemanticNode<ID>] = []
        var frontier = [parentID]
        var cursor = 0
        while cursor < frontier.count {
            let current = frontier[cursor]
            cursor += 1
            let children = nodes.filter { $0.parentID == current }
            result.append(contentsOf: children)
            frontier.append(contentsOf: children.map(\.id))
        }
        return result
    }
}
