import Foundation
import AppKit
@testable import PDDAXReader

// Standalone checks for developer installations without XCTest or SwiftUI macros.
@main
struct FolderKnowledgeSmoke {
    private static func verifyBoundedTraversal() {
        var visits: [Int] = []
        let cycle: Int? = BoundedTreeSearch.firstMatch(root: 0,
            children: { $0 == 0 ? [1, 1] : [0, 0] },
            value: { node -> Int? in visits.append(node); return nil })
        precondition(cycle == nil && visits == [0, 1], "Duplicate/cyclic AX nodes must be visited once")
        visits.removeAll()
        let capped: Int? = BoundedTreeSearch.firstMatch(root: 0, maximumNodes: 5,
            children: { [$0 + 1, $0 + 2] },
            value: { node -> Int? in visits.append(node); return nil })
        precondition(capped == nil && visits.count <= 5)
        var clock: TimeInterval = 0
        visits.removeAll()
        let expired: Int? = BoundedTreeSearch.firstMatch(root: 0, timeLimit: 2,
            now: { clock }, children: { [$0 + 1] },
            value: { node -> Int? in clock += 1; visits.append(node); return nil })
        precondition(expired == nil && visits.count <= 2)
        let cancelled: Int? = BoundedTreeSearch.firstMatch(root: 0, cancelled: { true },
            children: { _ in fatalError("Cancelled search must not expand nodes") }, value: { _ in nil })
        precondition(cancelled == nil)
        let found = BoundedTreeSearch.firstMatch(root: 0, children: { $0 < 3 ? [$0 + 1] : [] },
            value: { $0 == 3 ? "chat-panel" : nil })
        precondition(found == "chat-panel")
        print("PASS: cyclic/duplicate AX traversal, node/time limits, cancellation, and valid frame discovery")
    }

    @MainActor static func main() async throws {
        verifyBoundedTraversal()
        let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let resources = KnowledgeResourceLocator.resolve(resourceRootURL: source.appendingPathComponent("Resources"))
        guard let resources, resources.knowledgeBaseURL.hasDirectoryPath else { fatalError("Primary folder not resolved") }
        precondition(CodexInstallation.resolve(environment: ["PATH": "/usr/bin:/bin"]) != nil,
                     "Codex must resolve when launched from Finder without VS Code's PATH")
        print("PASS: Codex discovery with Finder-style PATH")
        var dotPixels = [UInt8](repeating: 255, count: 1200 * 800 * 4)
        for y in 278...288 {
            for x in 64...74 where (x - 69) * (x - 69) + (y - 283) * (y - 283) <= 25 {
                let offset = (y * 1200 + x) * 4
                dotPixels[offset] = 245; dotPixels[offset + 1] = 20; dotPixels[offset + 2] = 25
            }
        }
        let provider = CGDataProvider(data: Data(dotPixels) as CFData)!
        let dotImage = CGImage(width: 1200, height: 800, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 1200 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let dotCapture = UnreadCaptureSmoke(frame: PDDOCRFrame(image: dotImage, fullWindowImage: dotImage,
            windowFrame: CGRect(x: 0, y: 0, width: 1200, height: 800)))
        let stale = PDDAXSemanticTree(rootSnapshot: AXNodeSnapshot(role: "AXWindow"), nodes: [])
        func node(_ id: Int, _ parent: Int?, _ role: String, _ value: String?, _ classes: Set<String>, _ frame: CGRect = .zero) -> PDDAXSemanticNode<AXElementToken> {
            PDDAXSemanticNode(id: AXElementToken(rawValue: id), parentID: parent.map { AXElementToken(rawValue: $0) },
                role: role, value: value, title: nil, domIdentifier: nil, domClasses: classes,
                actionNames: role == "AXRow" ? ["AXPress"] : [], isSettable: false, frame: frame)
        }
        let fresh = PDDAXSemanticTree(rootSnapshot: AXNodeSnapshot(role: "AXWindow"), nodes: [
            node(0, nil, "AXGroup", nil, ["chat-list-box"]),
            node(1, 0, "AXRow", nil, ["chat-item-box"], CGRect(x: 30, y: 272, width: 260, height: 52)),
            node(2, 1, "AXStaticText", "A***", ["chat-nickname"])
        ])
        let originalDetector = OriginalPDDLiveUnreadEvidenceDetector(capture: dotCapture)
        let detector = PDDLiveUnreadEvidenceDetector(capture: dotCapture)
        let baselineUnread = try await originalDetector.unreadRows(in: fresh)
        let unread = try await detector.unreadRows(in: fresh)
        precondition(unread == baselineUnread && unread.count == 1 && unread[0].visibleLabel == "A***")
        let baselineEmpty = try await originalDetector.unreadRows(in: stale)
        let restoredEmpty = try await detector.unreadRows(in: stale)
        precondition(restoredEmpty == baselineEmpty && restoredEmpty.isEmpty)
        do {
            _ = try await PDDLiveUnreadEvidenceDetector(capture: dotCapture, requireConversationRows: true).unreadRows(in: stale)
            fatalError("The explicit diagnostic must report missing AX rows")
        } catch PDDUnreadDetectionError.conversationRowsUnavailable { }
        print("PASS: restored automatic unread detection matches original Git 8d19661 for valid rows and missing rows; strict errors remain diagnostic-only")
        if !PDDPaddleOCREngine.hasWebOCRResources {
            _ = NSApplication.shared
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 300,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 900, height: 300).fill()
            ("Hello printer 123" as NSString).draw(at: NSPoint(x: 80, y: 180), withAttributes: [
                .font: NSFont.systemFont(ofSize: 42), .foregroundColor: NSColor.black
            ])
            NSGraphicsContext.restoreGraphicsState()
            let lines = try await PDDPaddleOCREngine().recognize(bitmap.cgImage!)
            guard let line = lines.first(where: { $0.text.lowercased().contains("hello printer 123") }) else {
                fatalError("Native OCR did not recognize the fixture: \(lines)")
            }
            precondition(line.box.minY > 40 && line.box.maxY < 150, "OCR must return top-left pixel coordinates")
            print("PASS: native macOS OCR recognizes text and returns top-left pixel coordinates")
        }
        let root = source.appendingPathComponent(".build/folder-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let message = PDDChatMessage(id: "new", sender: .customer, content: "How do I connect TD630G to WiFi?",
                                    displayTime: nil, kind: .text, capturedAt: Date())
        let timeline = try AutoReplyTimeline.make(messages: [message])
        let capture = AutoReplyCapture(uid: "GZC-000001", fullHistory: [message],
                                       batch: try timeline.freeze(after: .empty), customerCursor: timeline.cursor,
                                       unexpectedServiceMessageIDs: [])
        let localResources = KnowledgeResources(
            knowledgeBaseURL: resources.knowledgeBaseURL, knowledgeBaseSHA256: resources.knowledgeBaseSHA256,
            scriptURL: resources.scriptURL, workerScriptURL: resources.workerScriptURL,
            pythonURL: resources.pythonURL, sitePackagesURL: resources.sitePackagesURL,
            seedCacheURL: resources.seedCacheURL,
            writableCacheURL: source.appendingPathComponent(".build/folder-search-cache")
        )
        let retriever = FolderKnowledgeRetriever(resources: localResources)
        let plannerRunner = QueryPlannerSmokeRunner()
        let service = KnowledgeEvidenceService(retriever: retriever, versioner: KnowledgeBaseVersioner(),
            knowledgeBaseURL: resources.knowledgeBaseURL,
            queryPlanner: CodexSecondInspectionQueryPlanner(executableURL: URL(fileURLWithPath: "/bin/echo"), runner: plannerRunner))
        let inspection = SecondInspectionContext(failedReply: "UNTRUSTED_FAILED_DRAFT", failureSignals: ["answer_not_found"],
            firstQueries: [message.content], firstRecordIDs: ["old-record"])
        let actual = await service.prepareSemantic(capture: capture, inspection: inspection)
        precondition(actual.mode == .semanticOnly, actual.diagnostic.error ?? "Semantic evidence unavailable")
        precondition((actual.diagnostic.queries ?? []).count >= 2)
        precondition(actual.documents.contains("dot_matrix_td630g_windows_initial_wifi"))
        let plannerPrompts = await plannerRunner.prompts
        precondition(plannerPrompts.count == 1)
        precondition(plannerPrompts[0].contains("UNTRUSTED_FAILED_DRAFT"))
        precondition(plannerPrompts[0].contains("never evidence for a product fact"))
        let fallback = KnowledgeEvidenceService(retriever: retriever, versioner: KnowledgeBaseVersioner(),
            knowledgeBaseURL: resources.knowledgeBaseURL, queryPlanner: FailingQueryPlanner())
        let fallbackEvidence = await fallback.prepareSemantic(capture: capture, inspection: inspection)
        precondition(fallbackEvidence.mode == .semanticOnly)
        precondition(fallbackEvidence.diagnostic.queryPlannerIssue != nil)
        precondition((fallbackEvidence.diagnostic.queries ?? []).count >= 2)
        await retriever.shutdown()
        print("PASS: independent Codex query-planning contract and deterministic planner-failure fallback")
        print("PASS: Swift → local Python worker → multilingual semantic model → primary-folder evidence")
        let previous = PDDChatMessage(id: "previous", sender: .customer, content: "How do I connect TD630G to WiFi?",
                                     displayTime: nil, kind: .text, capturedAt: Date())
        let clarification = PDDChatMessage(id: "clarification", sender: .service, content: "Are you using Windows or Android?",
                                          displayTime: nil, kind: .text, capturedAt: Date())
        let android = PDDChatMessage(id: "android", sender: .customer, content: "Android",
                                    displayTime: nil, kind: .text, capturedAt: Date())
        let shortHistory = [previous, clarification, android]
        let shortTimeline = try AutoReplyTimeline.make(messages: shortHistory)
        let answered = try AutoReplyTimeline.make(messages: [previous]).cursor
        let shortCapture = AutoReplyCapture(uid: "GZC-000001", fullHistory: shortHistory,
            batch: try shortTimeline.freeze(after: answered), customerCursor: shortTimeline.cursor,
            unexpectedServiceMessageIDs: [])
        let input = SecondInspectionQueries.input(capture: shortCapture)
        precondition(SecondInspectionQueries.models("我的TD630G无法联网") == ["td630g"])
        precondition(SecondInspectionQueries.models("M880D的班次设置") == ["m880d"])
        precondition(input.confirmedModels == ["td630g"])
        precondition(input.customerContext.contains("connect TD630G"))
        precondition(input.dialogue.contains { $0["body"] == clarification.content })
        let plans = SecondInspectionQueries.make(input: input,
            planned: ["M880 shift configuration", "TD630G wireless setup", "TD630G wireless setup"],
            firstQueries: ["TD630G wireless setup"])
        precondition(plans.count >= 2 && Set(plans).count == plans.count)
        precondition(plans.allSatisfy { !$0.contains("M880") && $0.contains("Exact product model: td630g") })
        let switched = PDDChatMessage(id: "switched", sender: .customer, content: "How do I remove jammed paper from TD630G?",
                                     displayTime: nil, kind: .text, capturedAt: Date())
        let oldShift = PDDChatMessage(id: "old", sender: .customer, content: "M880 shifts overlap",
                                     displayTime: nil, kind: .text, capturedAt: Date())
        let switchedTimeline = try AutoReplyTimeline.make(messages: [oldShift, switched])
        let switchedCapture = AutoReplyCapture(uid: "GZC-000001", fullHistory: [oldShift, switched],
            batch: try switchedTimeline.freeze(after: AutoReplyTimeline.make(messages: [oldShift]).cursor),
            customerCursor: switchedTimeline.cursor, unexpectedServiceMessageIDs: [])
        let focused = SecondInspectionQueries.input(capture: switchedCapture)
        precondition(!focused.customerContext.contains("shifts"))
        let bilingual = SecondInspectionQueries.make(input: focused, planned: [])
        precondition(bilingual.joined().contains("取出纸张"))
        print("PASS: JD short-answer context, topic isolation, model constraints, synonym queries, deduplication, and first-query exclusion")
        for found in [false, true] {
            let runner = SmokeRunner(firstFound: found)
            let evidence = SmokeEvidence()
            let generator = AutoReplyCodexGenerator(executableURL: URL(fileURLWithPath: "/bin/echo"),
                                                    runner: runner,
                                                    sessionRegistry: CodexSessionRegistry(rootDirectory: root.appendingPathComponent(String(found))),
                                                    evidencePreparer: evidence)
            let result = try await generator.generate(capture)
            let calls = await runner.calls
            let retryCount = await evidence.retries
            precondition(calls.count == (found ? 1 : 2))
            precondition(retryCount == (found ? 0 : 1))
            if !found {
                precondition(result.reply == "SECOND_DRAFT")
                precondition(result.threadID == "thread-2")
                precondition(!calls[1].0.contains("resume"))
                precondition(!calls[1].1.contains("FIRST_EVIDENCE"))
                precondition(!calls[1].1.contains("FIRST_DRAFT"))
                precondition(calls[1].1.contains("SEMANTIC_EVIDENCE"))
            }
        }
        print("PASS: primary folder, first answer skips retry, first miss retries once, second miss stops, fresh session and isolated evidence")
    }
}

actor SmokeRunner: CodexProcessRunning {
    let firstFound: Bool
    private(set) var calls: [([String], String)] = []
    init(firstFound: Bool) { self.firstFound = firstFound }
    func run(executable: URL, arguments: [String], stdin: String, timeout: TimeInterval) async throws -> CodexProcessResult {
        calls.append((arguments, stdin))
        let index = arguments.firstIndex(of: "-o")!
        let document: [String: Any] = ["answer_found": calls.count == 1 ? firstFound : false,
                                       "action": "reply", "transfer_reason": "none",
                                       "reply_text": calls.count == 1 ? "FIRST_DRAFT" : "SECOND_DRAFT"]
        try JSONSerialization.data(withJSONObject: document).write(to: URL(fileURLWithPath: arguments[index + 1]))
        return CodexProcessResult(exitCode: 0,
                                  stdout: "{\"type\":\"thread.started\",\"thread_id\":\"thread-\(calls.count)\"}\n{\"type\":\"turn.completed\"}\n", stderr: "")
    }
}

actor SmokeEvidence: KnowledgeEvidencePreparing {
    nonisolated var supportsSemanticRetry: Bool { true }
    private(set) var retries = 0
    func prepare(capture: AutoReplyCapture) async -> KnowledgeEvidence { evidence("FIRST_EVIDENCE", "folder-hybrid") }
    func prepareSemantic(capture: AutoReplyCapture) async -> KnowledgeEvidence {
        retries += 1
        return evidence("SEMANTIC_EVIDENCE", "folder-semantic")
    }
    private func evidence(_ text: String, _ version: String) -> KnowledgeEvidence {
        KnowledgeEvidence(mode: .v2Top12, version: version, documents: [text], context: text, diagnostic: .emptyFallback)
    }
}

actor QueryPlannerSmokeRunner: CodexProcessRunning {
    private(set) var prompts: [String] = []
    func run(executable: URL, arguments: [String], stdin: String, timeout: TimeInterval) async throws -> CodexProcessResult {
        precondition(!arguments.contains("resume"))
        precondition(timeout == 15)
        prompts.append(stdin)
        let result = arguments.firstIndex(of: "-o")!
        try JSONSerialization.data(withJSONObject: ["queries": [
            "TD630G WiFi first-time wireless setup", "TD630G 无线网络 首次连接 配网 教程"
        ]]).write(to: URL(fileURLWithPath: arguments[result + 1]))
        return CodexProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

struct FailingQueryPlanner: SecondInspectionQueryPlanning {
    func plan(input: SecondInspectionQueryInput, inspection: SecondInspectionContext?) async throws -> [String] {
        throw PersistentWorkerError.timeout("query planning")
    }
}

@MainActor
final class UnreadCaptureSmoke: PDDOCRCapturing {
    let frame: PDDOCRFrame
    var didCapture = false
    init(frame: PDDOCRFrame) { self.frame = frame }
    func capture() async throws -> PDDOCRFrame { didCapture = true; return frame }
}
