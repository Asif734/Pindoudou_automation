import Foundation
import Vision

/// Only the selected recipient's menu is eligible. Never use the chat composer Send.
enum PDDTransferMenuControls {
    static let reason = "无原因直接转移"
    static let labels = [reason, "催发货", "催售后处理", "发货/物流问题", "退款/退货问题", "换货问题", "发送"]

    static func normalized(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite
            && rect.width > 1 && rect.height > 1
    }

    static func axControl<ID: Hashable>(in nodes: [PDDAXSemanticNode<ID>],
                                       label: String, anchor: CGRect,
                                       reasonFrame: CGRect? = nil) -> PDDAXSemanticNode<ID>? {
        let matches = nodes.filter { node in
            valid(node.frame) && texts(node)
                .contains { normalized($0) == label }
                && nearMenu(node.frame, anchor: anchor)
                && (reasonFrame.map { sameRowSend(node.frame, reason: $0) } ?? true)
        }
        // Parent and text child can expose the same label. Collapse only overlapping controls.
        guard let first = matches.first,
              matches.allSatisfy({ $0.frame.intersects(first.frame) }) else { return nil }
        return matches.first(where: { $0.actionNames.contains("AXPress") })
            ?? matches.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    static func texts<ID>(_ node: PDDAXSemanticNode<ID>) -> [String] {
        [node.value, node.title, node.accessibilityDescription].compactMap { $0 }
    }

    /// Chromium sometimes exposes the highlighted row as one text element, with
    /// no independently addressable Send. This is an anchor, never a Send target.
    static func combinedReasonRow<ID: Hashable>(
        in nodes: [PDDAXSemanticNode<ID>], anchor: CGRect
    ) -> PDDAXSemanticNode<ID>? {
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let matches = nodes.filter { node in
            valid(node.frame) && node.frame.height <= 80 && node.frame.width <= 600
                && nearMenu(node.frame, anchor: anchor)
                && texts(node).contains { normalized($0) == reason + "发送" }
                && belongsToReasonMenu(node, index: index, nodes: nodes)
        }
        guard let first = matches.first,
              matches.allSatisfy({ $0.frame.intersects(first.frame) }) else { return nil }
        return matches.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    static func combinedRowSend<ID: Hashable>(
        in nodes: [PDDAXSemanticNode<ID>], row: PDDAXSemanticNode<ID>
    ) -> PDDAXSemanticNode<ID>? {
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let matches = nodes.filter { node in
            node.id != row.id && valid(node.frame)
                && texts(node).contains { normalized($0) == "发送" }
                && insideSendPortion(node.frame, row: row.frame)
                && (isDescendant(node, of: row.id, index: index)
                    || row.parentID.flatMap { index[$0] }.map { parent in
                        parent.frame.height <= 80 && parent.frame.width <= 600
                            && parent.frame.contains(row.frame)
                            && isDescendant(node, of: parent.id, index: index)
                    } == true)
        }
        guard let first = matches.first,
              matches.allSatisfy({ $0.frame.intersects(first.frame) }) else { return nil }
        return matches.first { $0.actionNames.contains("AXPress") }
            ?? matches.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    static func combinedRowSend(in lines: [PDDOCRLine], row: CGRect) -> CGRect? {
        let matches = lines.filter {
            normalized($0.text) == "发送" && reliable($0) && insideSendPortion($0.box, row: row)
        }
        return matches.count == 1 ? matches.first?.box : nil
    }

    private static func insideSendPortion(_ rect: CGRect, row: CGRect) -> Bool {
        row.insetBy(dx: -4, dy: -4).contains(rect)
            && rect.midX > row.midX
            && abs(rect.midY - row.midY) <= max(8, row.height * 0.65)
    }

    private static func isDescendant<ID: Hashable>(
        _ node: PDDAXSemanticNode<ID>, of ancestor: ID,
        index: [ID: PDDAXSemanticNode<ID>]
    ) -> Bool {
        var parent = node.parentID
        var visited = Set<ID>()
        while let id = parent, visited.insert(id).inserted {
            if id == ancestor { return true }
            parent = index[id]?.parentID
        }
        return false
    }

    private static func belongsToReasonMenu<ID: Hashable>(
        _ row: PDDAXSemanticNode<ID>, index: [ID: PDDAXSemanticNode<ID>],
        nodes: [PDDAXSemanticNode<ID>]
    ) -> Bool {
        var parent = row.parentID
        var visited = Set<ID>()
        while let id = parent, visited.insert(id).inserted, let node = index[id] {
            // A portal popup may be a sibling of the dialog, so scope to the
            // bounded menu itself rather than requiring dialog ancestry.
            if valid(node.frame), node.frame.width <= 600, node.frame.height <= 900,
               node.frame.insetBy(dx: -4, dy: -4).contains(row.frame) {
                let otherReasons = Set(nodes.filter {
                    isDescendant($0, of: id, index: index)
                }.flatMap(texts).map(normalized)).intersection(Set(labels.dropFirst().dropLast()))
                if otherReasons.count >= 2 { return true }
            }
            parent = node.parentID
        }
        return false
    }

    static func reasonControl(in lines: [PDDOCRLine], anchor: CGRect) -> CGRect? {
        let candidates = lines.filter {
            normalized($0.text) == reason && reliable($0) && nearMenu($0.box, anchor: anchor)
        }
        guard candidates.count == 1, let candidate = candidates.first else { return nil }
        let otherLabels = Set(lines.filter {
            reliable($0) && labels.dropFirst().dropLast().contains(normalized($0.text))
                && abs($0.box.minX - candidate.box.minX) < 45
                && abs($0.box.midY - candidate.box.midY) < 350
        }.map { normalized($0.text) })
        // Require a real transfer menu, not a matching phrase in customer chat.
        return otherLabels.count >= 2 ? candidate.box : nil
    }

    static func sendControl(in lines: [PDDOCRLine], reason: CGRect) -> CGRect? {
        let matches = lines.filter {
            normalized($0.text) == "发送" && reliable($0) && sameRowSend($0.box, reason: reason)
        }
        return matches.count == 1 ? matches.first?.box : nil
    }

    private static func reliable(_ line: PDDOCRLine) -> Bool {
        valid(line.box) && (line.confidence ?? 0) >= 0.75
    }

    private static func nearMenu(_ rect: CGRect, anchor: CGRect) -> Bool {
        valid(anchor) && abs(rect.midX - anchor.midX) < 300
            && abs(rect.midY - anchor.midY) < 600
    }

    private static func sameRowSend(_ rect: CGRect, reason: CGRect) -> Bool {
        rect.minX > reason.maxX && rect.minX - reason.maxX < 220
            && abs(rect.midY - reason.midY) <= max(8, max(rect.height, reason.height) * 0.65)
    }
}

/// Vision supplies individual substring bounds even when it merges the label and Send into one line.
@MainActor
final class PDDTransferMenuVisionRecognizer: PDDOCRRecognizing {
    func recognize(_ image: CGImage) async throws -> [PDDOCRLine] {
        let result = try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).flatMap { observation -> [PDDOCRLine] in
                guard let candidate = observation.topCandidates(1).first else { return [] }
                return PDDTransferMenuControls.labels.compactMap { label in
                    guard let range = candidate.string.range(of: label),
                          let box = try? candidate.boundingBox(for: range)?.boundingBox else { return nil }
                    return PDDOCRLine(text: label,
                        box: CGRect(x: box.minX * CGFloat(image.width),
                                    y: (1 - box.maxY) * CGFloat(image.height),
                                    width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height)),
                        confidence: Double(candidate.confidence))
                }
            }
        }.value
        try Task.checkCancellation()
        return result
    }
}

@MainActor
protocol PDDTransferMenuReading: AnyObject {
    /// Returned boxes use global screen points, the same coordinates as AX frames.
    func controls(anchor: CGRect) async throws -> [PDDOCRLine]
}

@MainActor
final class PDDLiveTransferMenuReader: PDDTransferMenuReading {
    private let capture: any PDDOCRCapturing
    private let recognizer: any PDDOCRRecognizing

    init(capture: (any PDDOCRCapturing)? = nil, recognizer: (any PDDOCRRecognizing)? = nil) {
        self.capture = capture ?? PDDWindowOCRCapture()
        self.recognizer = recognizer ?? PDDTransferMenuVisionRecognizer()
    }

    func controls(anchor: CGRect) async throws -> [PDDOCRLine] {
        let frame = try await capture.captureFullWindow()
        let image = frame.fullWindowImage
        guard PDDTransferMenuControls.valid(frame.windowFrame) else {
            throw PDDConversationTransferError.invalidControlFrame("截图窗口")
        }
        let scaleX = CGFloat(image.width) / frame.windowFrame.width
        let scaleY = CGFloat(image.height) / frame.windowFrame.height
        let region = CGRect(x: anchor.midX - 300, y: anchor.midY - 600, width: 600, height: 1200)
            .intersection(frame.windowFrame)
        let crop = CGRect(x: (region.minX - frame.windowFrame.minX) * scaleX,
                          y: (region.minY - frame.windowFrame.minY) * scaleY,
                          width: region.width * scaleX, height: region.height * scaleY).integral
        guard !crop.isEmpty, let cropped = image.cropping(to: crop) else {
            throw PDDConversationTransferError.invalidControlFrame("转移菜单截图")
        }
        return try await recognizer.recognize(cropped).map { line in
            .init(text: line.text,
                  box: CGRect(x: frame.windowFrame.minX + (crop.minX + line.box.minX) / scaleX,
                              y: frame.windowFrame.minY + (crop.minY + line.box.minY) / scaleY,
                              width: line.box.width / scaleX, height: line.box.height / scaleY),
                  confidence: line.confidence)
        }
    }
}

@MainActor
protocol PDDTransferMenuSubmitting: AnyObject {
    func submit(uid: String, anchor: CGRect, lease: UIOperationLease) async throws
}

@MainActor
final class PDDTransferMenuSubmitter: PDDTransferMenuSubmitting {
    private let backend: any PDDAXBackend
    private let clicker: any PDDTransferClicking
    private let reader: any PDDTransferMenuReading
    private let logRoot: URL?
    private let sleep: @MainActor (TimeInterval) async throws -> Void

    init(backend: any PDDAXBackend, clicker: any PDDTransferClicking,
         reader: (any PDDTransferMenuReading)? = nil, logRoot: URL? = nil,
         sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.backend = backend; self.clicker = clicker
        self.reader = reader ?? PDDLiveTransferMenuReader(); self.logRoot = logRoot; self.sleep = sleep
    }

    func submit(uid: String, anchor: CGRect, lease: UIOperationLease) async throws {
        var selectedReason: CGRect?
        for attempt in 1...4 {
            try lease.validate()
            let tree = try backend.readSemanticTree()
            guard PDDAXControlSelection.isTransferDialogVisible(in: tree.nodes) else { return }
            if let row = PDDTransferMenuControls.combinedReasonRow(in: tree.nodes, anchor: anchor) {
                selectedReason = row.frame
                log(uid: uid, step: "transfer-no-reason-row-ready", route: "AX-combined", rect: row.frame)
                break
            }
            if let control = PDDTransferMenuControls.axControl(in: tree.nodes,
                label: PDDTransferMenuControls.reason, anchor: anchor) {
                try press(control, uid: uid, step: "transfer-no-reason-selected", lease: lease)
                selectedReason = control.frame
                break
            }
            let lines = try await reader.controls(anchor: anchor)
            try lease.validate()
            guard PDDAXControlSelection.isTransferDialogVisible(in: try backend.readSemanticTree().nodes) else { return }
            if let rect = PDDTransferMenuControls.reasonControl(in: lines, anchor: anchor) {
                try click(rect, uid: uid, step: "transfer-no-reason-selected", lease: lease)
                selectedReason = rect
                break
            }
            saveLookupFailure(uid: uid, phase: "reason", attempt: attempt,
                anchor: anchor, nodes: tree.nodes, lines: lines)
            try await sleep(0.12)
        }
        guard let selectedReason else { throw PDDAXSelectionError.missing("无原因直接转移菜单项") }
        for attempt in 1...4 {
            try await sleep(0.12)
            try lease.validate()
            let tree = try backend.readSemanticTree()
            // Some versions submit directly when the no-reason item is clicked.
            guard PDDAXControlSelection.isTransferDialogVisible(in: tree.nodes) else { return }
            if let row = PDDTransferMenuControls.combinedReasonRow(in: tree.nodes, anchor: anchor),
               let send = PDDTransferMenuControls.combinedRowSend(in: tree.nodes, row: row) {
                try press(send, uid: uid, step: "transfer-final-send-clicked", lease: lease)
                return
            }
            let reasonFrame = PDDTransferMenuControls.axControl(in: tree.nodes,
                label: PDDTransferMenuControls.reason, anchor: anchor)?.frame ?? selectedReason
            if let control = PDDTransferMenuControls.axControl(in: tree.nodes,
                label: "发送", anchor: anchor, reasonFrame: reasonFrame) {
                try press(control, uid: uid, step: "transfer-final-send-clicked", lease: lease)
                return
            }
            let lines = try await reader.controls(anchor: anchor)
            try lease.validate()
            let current = try backend.readSemanticTree()
            guard PDDAXControlSelection.isTransferDialogVisible(in: current.nodes) else { return }
            let previousRow = PDDTransferMenuControls.combinedReasonRow(in: tree.nodes, anchor: anchor)
            let currentRow = PDDTransferMenuControls.combinedReasonRow(in: current.nodes, anchor: anchor)
            if let previousRow, previousRow.frame != currentRow?.frame {
                saveLookupFailure(uid: uid, phase: "send-row-changed", attempt: attempt,
                    anchor: anchor, nodes: current.nodes, lines: lines)
                continue
            }
            // Combined AX text establishes the selected row. OCR only needs to
            // locate Send inside it; it need not recognize every other reason again.
            if previousRow != nil, let row = currentRow,
               let send = PDDTransferMenuControls.combinedRowSend(in: lines, row: row.frame) {
                try click(send, uid: uid, step: "transfer-final-send-clicked", lease: lease,
                    route: "AX-combined-row-OCR")
                return
            }
            // Re-locate the reason on the latest screenshot; menu placement can change.
            if let reason = PDDTransferMenuControls.reasonControl(in: lines, anchor: anchor),
               let send = PDDTransferMenuControls.sendControl(in: lines, reason: reason) {
                try click(send, uid: uid, step: "transfer-final-send-clicked", lease: lease)
                return
            }
            saveLookupFailure(uid: uid, phase: "send", attempt: attempt,
                anchor: anchor, nodes: current.nodes, lines: lines)
        }
        throw PDDAXSelectionError.missing("无原因直接转移同一行的发送按钮")
    }

    private func saveLookupFailure(uid: String, phase: String, attempt: Int,
                                   anchor: CGRect, nodes: [PDDAXSemanticNode<AXElementToken>],
                                   lines: [PDDOCRLine]) {
        guard let logRoot else { return }
        do {
            func box(_ rect: CGRect) -> [String: Double] {
                ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
            }
            let candidates: [[String: Any]] = nodes.filter { node in
                abs(node.frame.midX - anchor.midX) < 300 && abs(node.frame.midY - anchor.midY) < 600
                    && PDDTransferMenuControls.texts(node).contains { text in
                        PDDTransferMenuControls.labels.contains { text.contains($0) }
                    }
            }.prefix(40).map {
                ["role": $0.role, "texts": PDDTransferMenuControls.texts($0),
                 "frame": box($0.frame), "actions": Array($0.actionNames), "classes": Array($0.domClasses)]
            }
            let recognized: [[String: Any]] = lines.map {
                ["text": $0.text, "confidence": $0.confidence ?? 0, "frame": box($0.box)]
            }
            let directory = logRoot.appendingPathComponent("logs/transfer-diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("menu-lookup-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: ["uid": uid, "phase": phase,
                "attempt": attempt, "anchor": box(anchor), "axCandidates": candidates,
                "ocrCandidates": recognized], options: [.sortedKeys, .prettyPrinted]).write(to: file, options: .atomic)
            AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-menu-lookup-missed",
                detail: "phase=\(phase) attempt=\(attempt)/4 diagnostics=\(file.path)")
        } catch {
            AutomationStepLog.record(root: logRoot, uid: uid, step: "transfer-menu-diagnostic-failed",
                detail: error.localizedDescription)
        }
    }

    private func press(_ node: PDDAXSemanticNode<AXElementToken>, uid: String, step: String,
                       lease: UIOperationLease) throws {
        try lease.validate()
        if node.actionNames.contains("AXPress") {
            try backend.performPress(node.id)
            log(uid: uid, step: step, route: "AXPress", rect: node.frame)
        } else { try click(node.frame, uid: uid, step: step, lease: lease, route: "AX-frame") }
    }

    private func click(_ rect: CGRect, uid: String, step: String, lease: UIOperationLease,
                       route: String = "menu-text-OCR") throws {
        try lease.validate()
        try clicker.click(at: CGPoint(x: rect.midX, y: rect.midY))
        log(uid: uid, step: step, route: route, rect: rect)
    }

    private func log(uid: String, step: String, route: String, rect: CGRect) {
        AutomationStepLog.record(root: logRoot, uid: uid, step: step,
            detail: "route=\(route) x=\(rect.midX) y=\(rect.midY) width=\(rect.width) height=\(rect.height)")
    }
}
