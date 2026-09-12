import AppKit
import XCTest
@testable import PDDAXReader

@MainActor
final class LivePDDOCRSmokeTests: XCTestCase {
    func testCurrentTransferDialogExposesOrdinaryTransferActionsReadOnly() throws {
        guard ProcessInfo.processInfo.environment["PDD_LIVE_TRANSFER"] == "1" else {
            throw XCTSkip("set PDD_LIVE_TRANSFER=1 while the transfer dialog is open")
        }
        let tree = try LivePDDAXBackend().readSemanticTree()
        let actions = try PDDAXControlSelection.ordinaryTransferActions(in: tree.nodes)
        print("PDD transfer ordinaryActions=\(actions.count)")
        for action in actions {
            print("PDD transfer agent=\(action.agentLabel) frame=\(action.frame)")
        }
        XCTAssertFalse(actions.isEmpty)
        XCTAssertTrue(actions.allSatisfy { $0.agentLabel != "转移并微信通知" })
        XCTAssertTrue(actions.allSatisfy { !$0.frame.isEmpty })
    }

    func testCurrentPDDWindowPrintsVisibleAXMessagesAndVideoNodes() throws {
        guard ProcessInfo.processInfo.environment["PDD_LIVE_OCR"] == "1" else {
            throw XCTSkip("set PDD_LIVE_OCR=1 for the authorized local UI probe")
        }
        let tree = try LivePDDAXBackend().readSemanticTree()
        let capturedAt = Date()
        let evidence = PDDAXVisibleMessageEvidence.extract(
            root: tree.rootSnapshot,
            capturedAt: capturedAt
        )
        print(
            "PDD AX messageNodes=\(evidence.messageNodeCount) "
                + "messages=\(evidence.messages.count) valid=\(evidence.isStructurallyValid)"
        )
        for message in evidence.messages.suffix(12) {
            print(
                "PDD AX message id=\(message.id) sender=\(message.sender.rawValue) "
                    + "kind=\(message.kind.rawValue) content=\(message.content)"
            )
        }
        for diagnostic in evidence.diagnostics.suffix(20) {
            print("PDD AX diagnostic \(diagnostic)")
        }
        let videoIDs = evidence.messages.filter { $0.kind == .video }.map(\.id)
        let videoCandidates = PDDAXVideoSelection.customerVideos(
            in: tree.nodes,
            messageIDs: videoIDs
        )
        for candidate in videoCandidates {
            print("PDD AX videoCandidate id=\(candidate.messageID) frame=\(candidate.frame)")
        }
        let byID = Dictionary(uniqueKeysWithValues: tree.nodes.map { ($0.id, $0) })
        for node in tree.nodes where
            node.domClasses.contains(where: { $0.lowercased().contains("video") })
                || [node.value, node.title].compactMap({ $0 }).contains(where: {
                    $0.range(of: #"^(?:\d{1,2}:)?\d{1,2}:\d{2}$"#, options: .regularExpression) != nil
                }) {
            print(
                "PDD AX videoNode id=\(node.id) parent=\(String(describing: node.parentID)) "
                    + "role=\(node.role) value=\(node.value ?? "nil") title=\(node.title ?? "nil") "
                    + "domIdentifier=\(node.domIdentifier ?? "nil") classes=\(node.domClasses.sorted()) "
                    + "frame=\(node.frame)"
            )
            var ancestor = node.parentID.flatMap { byID[$0] }
            var visited = Set<AXElementToken>()
            while let current = ancestor, visited.insert(current.id).inserted {
                print(
                    "  ancestor id=\(current.id) role=\(current.role) "
                        + "domIdentifier=\(current.domIdentifier ?? "nil") "
                        + "classes=\(current.domClasses.sorted()) frame=\(current.frame)"
                )
                ancestor = current.parentID.flatMap { byID[$0] }
            }
        }
        XCTAssertFalse(evidence.messages.isEmpty)
    }

    func testCurrentPDDWindowMapsPixelRedDotsOntoAXConversationRows() async throws {
        guard ProcessInfo.processInfo.environment["PDD_LIVE_OCR"] == "1" else {
            throw XCTSkip("set PDD_LIVE_OCR=1 for the authorized local UI probe")
        }
        let tree = try LivePDDAXBackend().readSemanticTree()
        let rows = try PDDAXControlSelection.conversationRows(in: tree.nodes)
        let frame = try await PDDWindowOCRCapture().capture()
        let unread = try await PDDLiveUnreadEvidenceDetector().unreadRows(in: tree)
        print(
            "PDD red-dot rows=\(rows.count) pixelUnread=\(unread.count) "
                + "window=\(frame.windowFrame) image=\(frame.fullWindowImage.width)x\(frame.fullWindowImage.height)"
        )
        for row in rows {
            print(
                "PDD conversation nickname=\(row.visibleLabel) "
                    + "domIdentifier=\(row.domIdentifier ?? "nil") frame=\(row.frame)"
            )
            let related = tree.nodes.filter { node in
                node.id == row.rowID || isDescendant(node.id, of: row.rowID, nodes: tree.nodes)
            }
            for node in related {
                print(
                    "  node=\(node.id) parent=\(String(describing: node.parentID)) role=\(node.role) "
                        + "value=\(node.value ?? "nil") title=\(node.title ?? "nil") "
                        + "domIdentifier=\(node.domIdentifier ?? "nil") classes=\(node.domClasses.sorted())"
                )
            }
        }
        for row in unread {
            print("PDD pixel unread row=\(row.visibleLabel) frame=\(row.frame)")
        }
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { !$0.frame.isEmpty })
        XCTAssertTrue(Set(unread.map(\.rowID)).isSubset(of: Set(rows.map(\.rowID))))
    }

    private func isDescendant(
        _ id: AXElementToken,
        of ancestorID: AXElementToken,
        nodes: [PDDAXSemanticNode<AXElementToken>]
    ) -> Bool {
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var current = index[id]?.parentID
        var visited = Set<AXElementToken>()
        while let token = current, visited.insert(token).inserted {
            if token == ancestorID { return true }
            current = index[token]?.parentID
        }
        return false
    }

    func testCurrentPDDWindowProducesInspectableOCRArtifacts() async throws {
        guard ProcessInfo.processInfo.environment["PDD_LIVE_OCR"] == "1" else {
            throw XCTSkip("set PDD_LIVE_OCR=1 for the authorized local UI probe")
        }
        let started = Date()
        let frame = try await PDDWindowOCRCapture().capture()
        let lines = try await PDDPaddleOCREngine().recognize(frame.image)
        let parsed = PDDOCRChatParser.parse(
            uid: "GZC-000001", lines: lines,
            imageSize: CGSize(width: frame.image.width, height: frame.image.height)
        )
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/拼多多AX记录/OCR实验", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: started).replacingOccurrences(of: ":", with: "-")
        let directory = root.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let png = NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:]) else {
            XCTFail("cannot encode screenshot"); return
        }
        try png.write(to: directory.appendingPathComponent("chat.png"))
        guard let fullPNG = NSBitmapImageRep(cgImage: frame.fullWindowImage)
            .representation(using: .png, properties: [:]) else {
            XCTFail("cannot encode full-window screenshot"); return
        }
        try fullPNG.write(to: directory.appendingPathComponent("full-window.png"))
        print(
            "PDD OCR frame window=\(frame.windowFrame) "
                + "full=\(frame.fullWindowImage.width)x\(frame.fullWindowImage.height) "
                + "chat=\(frame.image.width)x\(frame.image.height) "
                + "lines=\(lines.count) parsed=\(parsed.count)"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        try encoder.encode(lines).write(to: directory.appendingPathComponent("raw-ocr.json"))
        try encoder.encode(parsed).write(to: directory.appendingPathComponent("parsed.json"))
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        try Data("\(elapsed)\n".utf8).write(to: directory.appendingPathComponent("elapsed-ms.txt"))
        XCTAssertFalse(lines.isEmpty)
        XCTAssertFalse(parsed.isEmpty)
    }
}
