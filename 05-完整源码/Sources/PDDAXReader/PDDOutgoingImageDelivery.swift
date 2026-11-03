import Foundation

struct PDDOutgoingImageReceipt: Codable, Equatable {
    let uid: String
    let imageSHA256: String
    let baselineMessageIDs: Set<String>
    let submittedAt: Date
    var confirmedMessageID: String?
    var previewSubmittedAt: Date? = nil
}

struct PDDOutgoingImageReceiptStore {
    let root: URL

    private func url(deliveryID: UUID, hash: String) -> URL {
        root.appendingPathComponent("outgoing-image-deliveries")
            .appendingPathComponent("\(deliveryID.uuidString)-\(hash).json")
    }

    func load(deliveryID: UUID, hash: String) throws -> PDDOutgoingImageReceipt? {
        let file = url(deliveryID: deliveryID, hash: hash)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(PDDOutgoingImageReceipt.self, from: Data(contentsOf: file))
    }

    func save(_ receipt: PDDOutgoingImageReceipt, deliveryID: UUID) throws {
        let file = url(deliveryID: deliveryID, hash: receipt.imageSHA256)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(receipt).write(to: file, options: .atomic)
    }
}

@MainActor
protocol PDDOutgoingImageUploading {
    /// beforeCommit must succeed before any operation that could publish the file.
    func upload(file: URL, beforeCommit: () throws -> Void) async throws
    func finish()
}

extension PDDOutgoingImageUploading {
    func finish() {}
}

struct PDDImagePreviewSendTarget {
    let id: AXElementToken
    let point: CGPoint
    let allowsAXPress: Bool
    let sourceLabel: String
}

enum PDDOutgoingImageControls {
    static func imageMessageIDs(in tree: PDDAXSemanticTree) -> Set<String> {
        Set(PDDChatParser.parse(root: tree.rootSnapshot).messages.filter {
            $0.sender == .service && $0.kind == .image && $0.id.hasPrefix("middlePanel_list_")
        }.map(\.id))
    }

    static func confirmedImageMessageIDs(in tree: PDDAXSemanticTree) -> Set<String> {
        let images = imageMessageIDs(in: tree)
        var confirmed = Set<String>()
        func visit(_ node: AXNodeSnapshot) {
            if let id = node.attribute(named: "AXDOMIdentifier"), images.contains(id) {
                func flatten(_ current: AXNodeSnapshot) -> [AXNodeSnapshot] { [current] + current.children.flatMap(flatten) }
                let all = flatten(node)
                let failedOrPending = all.contains { item in
                    item.domClasses.contains { ["sending", "loading", "failed", "error"].contains($0.lowercased()) }
                        || item.attributes.contains { ["发送失败", "发送中", "上传中"].contains($0.1) }
                }
                let remoteImage = all.filter { $0.domClasses.contains("image-msg") }.flatMap(flatten).contains {
                    $0.attributes.contains { ["AXURL", "AXValue", "AXDescription"].contains($0.0)
                        && ($0.1.hasPrefix("https://") || $0.1.hasPrefix("http://")) }
                }
                if !failedOrPending && remoteImage { confirmed.insert(id) }
                return
            }
            node.children.forEach(visit)
        }
        visit(tree.rootSnapshot)
        return confirmed
    }

    static func previewSendControl(in nodes: [PDDAXSemanticNode<AXElementToken>]) -> PDDImagePreviewSendTarget? {
        previewActionControl(in: nodes, action: "发送")
    }

    static func previewCancelControl(in nodes: [PDDAXSemanticNode<AXElementToken>]) -> PDDImagePreviewSendTarget? {
        // Only dismiss an idle confirmation we can positively identify. A
        // sending/uploading status is not a second actionable Send/Cancel pair.
        guard previewSendControl(in: nodes) != nil else { return nil }
        return previewActionControl(in: nodes, action: "取消")
    }

    private static func previewActionControl(in nodes: [PDDAXSemanticNode<AXElementToken>], action: String) -> PDDImagePreviewSendTarget? {
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let children = Dictionary(grouping: nodes, by: \.parentID)
        func labels(_ node: PDDAXSemanticNode<AXElementToken>) -> [String] {
            [node.value, node.title].compactMap { value in
                value.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            }
        }
        func combinedButtons(_ node: PDDAXSemanticNode<AXElementToken>) -> Bool {
            labels(node).contains { $0 == "发送 取消" || $0 == "发送取消" }
        }
        func sendTarget(_ node: PDDAXSemanticNode<AXElementToken>) -> PDDImagePreviewSendTarget {
            let combined = combinedButtons(node)
            // This PDD build exposes the two buttons as one horizontal AX text element.
            // Send is the first (left) button; clicking the combined element's center
            // could hit Cancel or the gap. Use the center of its left half instead.
            let point = CGPoint(x: combined ? node.frame.minX + node.frame.width * (action == "发送" ? 0.25 : 0.75) : node.frame.midX,
                                y: node.frame.midY)
            return PDDImagePreviewSendTarget(id: node.id, point: point,
                allowsAXPress: !combined && node.actionNames.contains("AXPress"),
                sourceLabel: combined ? (action == "发送" ? "发送 取消 (left Send)" : "发送 取消 (right Cancel)") : action)
        }
        func isMessageOrSidebar(_ node: PDDAXSemanticNode<AXElementToken>) -> Bool {
            node.domClasses.contains("onemsg") || node.domClasses.contains(where: {
                $0.contains("chat-list-box") || $0.contains("conversation-list")
            })
        }
        func insideMessageOrSidebar(_ node: PDDAXSemanticNode<AXElementToken>) -> Bool {
            var current: PDDAXSemanticNode<AXElementToken>? = node
            var visited = Set<AXElementToken>()
            while let element = current, visited.insert(element.id).inserted {
                if isMessageOrSidebar(element) { return true }
                current = element.parentID.flatMap { index[$0] }
            }
            return false
        }
        func descendants(_ root: PDDAXSemanticNode<AXElementToken>) -> [PDDAXSemanticNode<AXElementToken>] {
            var pending = [root]
            var visited = Set<AXElementToken>()
            var result: [PDDAXSemanticNode<AXElementToken>] = []
            while let element = pending.popLast() {
                guard visited.insert(element.id).inserted, !isMessageOrSidebar(element) else { continue }
                result.append(element)
                pending.append(contentsOf: children[element.id] ?? [])
            }
            return result
        }
        let headings = nodes.filter {
            !insideMessageOrSidebar($0) && labels($0).contains(where: ["是否发送图片", "发送图片"].contains)
        }
        var selected: [AXElementToken: PDDImagePreviewSendTarget] = [:]
        for heading in headings {
            var current: PDDAXSemanticNode<AXElementToken>? = heading
            var visited = Set<AXElementToken>()
            while let container = current, visited.insert(container.id).inserted {
                guard !isMessageOrSidebar(container), container.role != "AXWindow", container.role != "AXWebArea",
                      !container.domClasses.contains(where: { $0.contains("middle-panel") || $0.contains("chat-panel") }) else { break }
                let scoped = descendants(container)
                let buttons = scoped.filter {
                    guard $0.frame.width > 1, $0.frame.height > 1 else { return false }
                    if combinedButtons($0) { return $0.frame.width > $0.frame.height * 1.5 }
                    return labels($0).contains(action)
                        && ($0.actionNames.contains("AXPress") || ["AXButton", "AXStaticText", "AXGroup"].contains($0.role))
                }
                let buttonIDs = Set(buttons.map(\.id))
                let uniqueButtons = buttons.filter { node in
                    var parent = node.parentID
                    var visited = Set<AXElementToken>()
                    while let id = parent, visited.insert(id).inserted, let ancestor = index[id] {
                        if buttonIDs.contains(id) { return false }
                        parent = ancestor.parentID
                    }
                    return true
                }
                let hasCancel = scoped.contains { labels($0).contains("取消") || combinedButtons($0) }
                let hasPreview = scoped.contains { $0.role == "AXImage" && !$0.domClasses.contains("avatar") }
                let isDialog = container.role == "AXDialog" || container.domClasses.contains {
                    $0.lowercased().contains("dialog") || $0.lowercased().contains("modal")
                }
                if hasCancel, hasPreview || isDialog, uniqueButtons.count == 1, let button = uniqueButtons.first {
                    selected[button.id] = sendTarget(button)
                    break
                }
                current = container.parentID.flatMap { index[$0] }
            }
        }
        guard selected.count == 1 else { return nil }
        return selected.values.first
    }
}
