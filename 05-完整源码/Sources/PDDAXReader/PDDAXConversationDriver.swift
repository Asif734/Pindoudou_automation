import Foundation

enum PDDAXConversationDriverError: LocalizedError {
    case uidNotFound(String)
    case uidNotAllowed(String)
    case nicknameCandidatesExhausted(String)

    var errorDescription: String? {
        switch self {
        case .uidNotFound(let uid): return "无法通过 AX 打开并核对会话：\(uid)"
        case .uidNotAllowed(let uid): return "UID 不在自动回复允许范围：\(uid)"
        case .nicknameCandidatesExhausted(let uid):
            return "当前列表前两个同昵称会话均不包含目标消息，已放弃定位：\(uid)"
        }
    }
}

@MainActor
protocol PDDConversationOpening: AnyObject {
    func openAndResolve(uid: String) async throws -> PDDAXSemanticTree
    func openAndResolve(
        uid: String,
        expectedCustomerMessageIDs: Set<String>
    ) async throws -> PDDAXSemanticTree
}

extension PDDConversationOpening {
    func openAndResolve(
        uid: String,
        expectedCustomerMessageIDs: Set<String>
    ) async throws -> PDDAXSemanticTree {
        try await openAndResolve(uid: uid)
    }
}

@MainActor
final class PDDAXConversationDriver: PDDConversationOpening {
    private let backend: any PDDAXBackend
    private let chatStore: PerUserChatStore
    private let allowedUIDs: Set<String>?
    private let ocrSupplement: (any PDDOCRSupplementing)?
    private let unreadEvidence: any PDDUnreadEvidenceDetecting
    private let imageResolver: (any PDDCustomerImageResolving)?
    private let imageDownloader: (any PDDCustomerImageDownloading)?
    private let imageRootDirectory: URL?
    private let frozenImageStore: FrozenImageStore?
    private let videoCoordinator: PDDVideoForegroundCoordinator?
    private var unreadUIDs = Set<String>()
    private var baselinedUIDs = Set<String>()
    private var knownServiceIDsByUID: [String: Set<String>] = [:]
    private var conversationLabelByUID: [String: String] = [:]
    private var conversationLocatorsByUID: [String: PDDConversationLocator] = [:]
    private var conversationDiagnostics: [PDDConversationDiagnostic] = []
    private var sourceSelector = PDDMessageSourceSelector()
    private var provisionalReceiptsByUID: [String: [PDDProvisionalReceipt]] = [:]
    var onOCRDiagnostic: ((String) -> Void)?

    init(
        backend: any PDDAXBackend,
        chatStore: PerUserChatStore,
        allowedUIDs: Set<String>?,
        ocrSupplement: (any PDDOCRSupplementing)? = nil,
        unreadEvidence: (any PDDUnreadEvidenceDetecting)? = nil,
        imageResolver: (any PDDCustomerImageResolving)? = nil,
        imageDownloader: (any PDDCustomerImageDownloading)? = nil,
        imageRootDirectory: URL? = nil,
        videoResolver: (any PDDCustomerVideoResolving)? = nil,
        videoDownloader: (any PDDCustomerVideoDownloading)? = nil,
        videoRootDirectory: URL? = nil,
        videoArmer: (any PDDVideoTransferArming)? = nil,
        videoPreviewOpener: (any PDDVideoPreviewOpening)? = nil,
        videoOperationTimeout: Duration = .seconds(12),
        captureOperationTimeout: Duration = .seconds(25)
    ) {
        self.backend = backend
        self.chatStore = chatStore
        self.allowedUIDs = allowedUIDs
        self.ocrSupplement = ocrSupplement
        self.unreadEvidence = unreadEvidence ?? PDDLiveUnreadEvidenceDetector()
        self.imageResolver = imageResolver
        self.imageDownloader = imageDownloader
        self.imageRootDirectory = imageRootDirectory
        self.frozenImageStore = imageRootDirectory.map {
            FrozenImageStore(
                rootDirectory: $0.deletingLastPathComponent()
                    .appendingPathComponent("frozen-images", isDirectory: true)
            )
        }
        if let videoArmer, let videoPreviewOpener {
            videoCoordinator = PDDVideoForegroundCoordinator(
                armer: videoArmer, opener: videoPreviewOpener
            )
        } else {
            videoCoordinator = nil
        }
        _ = videoResolver
        _ = videoDownloader
        _ = videoRootDirectory
        _ = videoOperationTimeout
        _ = captureOperationTimeout
    }

    func discover() async throws -> [AutoReplyDiscovery] {
        var tree = try backend.readSemanticTree()

        if let row = try await unreadEvidence.unreadRows(in: tree).first {
            try backend.performPress(row.rowID)
            try await Task.sleep(nanoseconds: 80_000_000)
            tree = try backend.readSemanticTree()
            let locator = PDDConversationLocator(
                domIdentifier: row.domIdentifier,
                nickname: row.visibleLabel
            )
            let uid = PDDConversationKey.make(locator: locator)
            let legacyUID = PDDCustomerIdentity.resolve(from: tree.rootSnapshot)
            guard isAllowed(uid) || legacyUID.map(isAllowed) == true,
                  legacyUID != nil || isUsableChatSurface(tree) else { return [] }
            conversationLabelByUID[uid] = row.visibleLabel
            conversationLocatorsByUID[uid] = locator
            unreadUIDs.insert(uid)
            if let legacyUID {
                conversationLabelByUID[legacyUID] = row.visibleLabel
                unreadUIDs.insert(legacyUID)
            }
            return [.init(uid: uid, hasUnreadEvidence: true)]
        }

        if isUsableChatSurface(tree),
           let row = try PDDAXControlSelection.currentConversationRow(in: tree.nodes) {
            let locator = PDDConversationLocator(
                domIdentifier: row.domIdentifier,
                nickname: row.visibleLabel
            )
            let currentUID = PDDConversationKey.make(locator: locator)
            guard isAllowed(currentUID) else { return [] }
            conversationLocatorsByUID[currentUID] = locator
            return [.init(uid: currentUID, hasUnreadEvidence: false)]
        }
        if isUsableChatSurface(tree),
           let currentUID = conversationLocatorsByUID.keys.sorted().first,
           isAllowed(currentUID) {
            return [.init(uid: currentUID, hasUnreadEvidence: false)]
        }
        return []
    }

    func openAndResolve(uid: String) async throws -> PDDAXSemanticTree {
        try await openAndResolve(uid: uid, expectedCustomerMessageIDs: [])
    }

    func openAndResolve(
        uid: String,
        expectedCustomerMessageIDs: Set<String>
    ) async throws -> PDDAXSemanticTree {
        guard isAllowed(uid) else { throw PDDAXConversationDriverError.uidNotAllowed(uid) }
        var tree = try backend.readSemanticTree()
        if PDDCustomerIdentity.resolve(from: tree.rootSnapshot) == uid { return tree }
        if uid.hasPrefix("PDD-"), let locator = conversationLocatorsByUID[uid] {
            if !expectedCustomerMessageIDs.isEmpty,
               containsAnyMessageID(expectedCustomerMessageIDs, in: tree.rootSnapshot) {
                return tree
            }
            let rows = try PDDAXControlSelection.conversationRows(in: tree.nodes)
            let identifierMatch = locator.domIdentifier.flatMap { identifier in
                rows.first { $0.domIdentifier == identifier }
            }
            let nicknameMatches = rows.filter {
                normalizedNickname($0.visibleLabel) == locator.normalizedNickname
            }
            if let identifierMatch {
                try backend.performPress(identifierMatch.rowID)
                try await Task.sleep(nanoseconds: 80_000_000)
                tree = try backend.readSemanticTree()
                if isUsableChatSurface(tree)
                    || PDDCustomerIdentity.resolve(from: tree.rootSnapshot) == uid {
                    return tree
                }
            }

            let nicknameCandidates = Array(nicknameMatches.prefix(2))
            if nicknameMatches.count > 1 {
                conversationDiagnostics.append(.init(
                    uid: uid,
                    kind: "conversation-nickname-ambiguous",
                    detail: "昵称 \(locator.normalizedNickname) 匹配到 \(nicknameMatches.count) 个会话，只核对列表前两个"
                ))
            }
            for selected in nicknameCandidates {
                try backend.performPress(selected.rowID)
                try await Task.sleep(nanoseconds: 80_000_000)
                tree = try backend.readSemanticTree()
                let targetMatches = expectedCustomerMessageIDs.isEmpty
                    || containsAnyMessageID(expectedCustomerMessageIDs, in: tree.rootSnapshot)
                if targetMatches && (isUsableChatSurface(tree)
                    || PDDCustomerIdentity.resolve(from: tree.rootSnapshot) == uid) {
                    if let refreshed = selected.domIdentifier,
                       refreshed != locator.domIdentifier {
                        conversationLocatorsByUID[uid]?.domIdentifier = refreshed
                        conversationDiagnostics.append(.init(
                            uid: uid,
                            kind: "conversation-identifier-refreshed",
                            detail: "旧 identifier 已失效，已通过昵称和目标消息重新定位并刷新"
                        ))
                    }
                    return tree
                }
            }
            if !expectedCustomerMessageIDs.isEmpty {
                throw PDDAXConversationDriverError.nicknameCandidatesExhausted(uid)
            }
            if nicknameCandidates.isEmpty, isUsableChatSurface(tree) {
                conversationDiagnostics.append(.init(
                    uid: uid,
                    kind: "conversation-current-fallback",
                    detail: "identifier 与昵称均未找到，继续使用当前可用聊天页面"
                ))
                return tree
            }
            throw PDDAXConversationDriverError.uidNotFound(uid)
        }
        var visitedRowIDs = Set<AXElementToken>()
        while true {
            let rows = try PDDAXControlSelection.conversationRows(in: tree.nodes)
            let targetLabel = conversationLabelByUID[uid]
            guard let row = rows.first(where: { candidate in
                (targetLabel == nil || candidate.visibleLabel == targetLabel)
                    && visitedRowIDs.insert(candidate.rowID).inserted
            }) else { break }
            try backend.performPress(row.rowID)
            try await Task.sleep(nanoseconds: 80_000_000)
            tree = try backend.readSemanticTree()
            if PDDCustomerIdentity.resolve(from: tree.rootSnapshot) == uid { return tree }
        }
        throw PDDAXConversationDriverError.uidNotFound(uid)
    }

    private func containsAnyMessageID(
        _ expected: Set<String>,
        in root: AXNodeSnapshot
    ) -> Bool {
        if let identifier = root.attribute(named: "AXDOMIdentifier"),
           expected.contains(identifier) {
            return true
        }
        return root.children.contains { containsAnyMessageID(expected, in: $0) }
    }

    func restoreConversationLocators(_ locators: [String: PDDConversationLocator]) {
        conversationLocatorsByUID = locators
    }

    func restoreConversationCaptureState(
        baselinedUIDs: Set<String>,
        knownServiceMessageIDsByUID: [String: Set<String>]
    ) {
        self.baselinedUIDs = baselinedUIDs
        knownServiceIDsByUID = knownServiceMessageIDsByUID
    }

    func restoreProvisionalReceipts(_ receipts: [String: [PDDProvisionalReceipt]]) {
        provisionalReceiptsByUID = receipts
    }

    func provisionalReceiptsSnapshot() -> [String: [PDDProvisionalReceipt]] {
        provisionalReceiptsByUID
    }

    func restoreMessageSourceSelectorStates(
        _ states: [String: PDDMessageSourceSelectorState]
    ) {
        sourceSelector.restore(states)
    }

    func messageSourceSelectorStatesSnapshot() -> [String: PDDMessageSourceSelectorState] {
        sourceSelector.snapshot()
    }

    func conversationLocatorsSnapshot() -> [String: PDDConversationLocator]? {
        conversationLocatorsByUID
    }

    func takeConversationDiagnostics() -> [PDDConversationDiagnostic] {
        defer { conversationDiagnostics.removeAll() }
        return conversationDiagnostics
    }

    func capture(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture {
        try await capture(
            uid: uid, after: cursor, lease: nil, allowOCR: true,
            enrichAttachments: true
        )
    }

    func capture(
        uid: String,
        after cursor: AutoReplyCursor,
        lease: UIOperationLease
    ) async throws -> AutoReplyCapture {
        try await capture(uid: uid, after: cursor, includeImages: true, lease: lease)
    }

    func capture(
        uid: String,
        after cursor: AutoReplyCursor,
        includeImages: Bool,
        lease: UIOperationLease
    ) async throws -> AutoReplyCapture {
        try await capture(
            uid: uid, after: cursor, lease: Optional(lease), allowOCR: true,
            enrichAttachments: true, includeImages: includeImages
        )
    }

    func capture(
        uid: String,
        after cursor: AutoReplyCursor,
        includeImages: Bool,
        onlyVideoMessageID: String?,
        lease: UIOperationLease
    ) async throws -> AutoReplyCapture {
        try await capture(
            uid: uid, after: cursor, lease: Optional(lease), allowOCR: true,
            enrichAttachments: true, includeImages: includeImages,
            onlyVideoMessageID: onlyVideoMessageID
        )
    }

    func preflight(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture {
        try await capture(
            uid: uid, after: cursor, lease: nil, allowOCR: false,
            enrichAttachments: false
        )
    }

    func preflight(
        uid: String,
        after cursor: AutoReplyCursor,
        lease: UIOperationLease
    ) async throws -> AutoReplyCapture {
        try await capture(
            uid: uid, after: cursor, lease: Optional(lease), allowOCR: false,
            enrichAttachments: false
        )
    }

    private func capture(
        uid: String,
        after cursor: AutoReplyCursor,
        lease: UIOperationLease?,
        allowOCR: Bool,
        enrichAttachments: Bool,
        includeImages: Bool = true,
        onlyVideoMessageID: String? = nil
    ) async throws -> AutoReplyCapture {
        var openedTree = try await openAndResolve(uid: uid)
        let hasUnreadEvidence = unreadUIDs.contains(uid)
        var capturedAt = Date()
        var evidence = authoritativeEvidence(in: openedTree, capturedAt: capturedAt)
        let existingAXFirst = try chatStore.loadAXFirst(uid: uid)
        let existingIDs = Set(existingAXFirst.map(\.id))
        var provisionalMessage: PDDChatMessage?
        var sourceDiagnostic: String

        sourceLoop: while true {
            switch sourceSelector.observe(
                uid: uid,
                unread: hasUnreadEvidence,
                evidence: evidence,
                now: capturedAt
            ) {
            case .useAX:
                sourceDiagnostic = "AX 权威读取：\(evidence.messages.count) 条可见消息"
                break sourceLoop
            case .resampleAX(let delay):
                try lease?.validate()
                try await Task.sleep(nanoseconds: delay)
                try lease?.validate()
                openedTree = try backend.readSemanticTree()
                capturedAt = Date()
                evidence = authoritativeEvidence(in: openedTree, capturedAt: capturedAt)
            case .useOCR(let reason):
                guard allowOCR else {
                    sourceDiagnostic = "无红点，跳过 OCR；AX \(reason.rawValue)"
                    break sourceLoop
                }
                guard let ocrSupplement else {
                    throw PDDOCRError.engine("AX 失效且未配置 OCR 尾部兜底读取器")
                }
                let ocr: [PDDOCRMessage]
                do {
                    ocr = try await ocrSupplement.messages(uid: uid)
                } catch {
                    onOCRDiagnostic?(error.localizedDescription)
                    throw error
                }
                provisionalMessage = PDDOCRTailSelector.select(
                    uid: uid,
                    ocrMessages: ocr,
                    axMessages: evidence.isStructurallyValid
                        ? evidence.messages
                        : existingAXFirst.filter { !$0.id.hasPrefix("ocr-provisional-") },
                    hasUnreadEvidence: hasUnreadEvidence,
                    capturedAt: capturedAt
                )
                if let provisionalMessage {
                    sourceDiagnostic = "OCR 临时客户消息：\(String(provisionalMessage.content.prefix(80)))"
                } else {
                    sourceDiagnostic = "AX/OCR 均无可信新消息，继续轮询"
                }
                if reason == .unreadAXStale {
                    sourceDiagnostic = "AX 未前进（3/3），启用尾部 OCR；" + sourceDiagnostic
                } else {
                    sourceDiagnostic = "AX \(reason.rawValue)，启用尾部 OCR；" + sourceDiagnostic
                }
                break sourceLoop
            }
        }

        var ledger = PDDProvisionalMessageLedger(
            receipts: provisionalReceiptsByUID[uid] ?? []
        )
        let newAXMessages = evidence.messages.filter { !existingIDs.contains($0.id) }
        let reconciliation = ledger.reconcile(axMessages: newAXMessages, now: capturedAt)
        if !reconciliation.absorbedAXMessageIDs.isEmpty {
            sourceDiagnostic += "；AX 已恢复并吸收 OCR 临时消息"
        }
        if let provisionalMessage,
           !ledger.receipts.contains(where: {
               $0.provisionalMessageID == provisionalMessage.id
           }) {
            ledger.receipts.append(PDDProvisionalReceipt(
                provisionalMessageID: provisionalMessage.id,
                normalizedContent: PDDOCRNormalizer.normalize(provisionalMessage.content),
                firstObservedAt: capturedAt,
                answered: false,
                absorbedAXMessageID: nil
            ))
        }
        provisionalReceiptsByUID[uid] = ledger.receipts

        var messagesToMerge = evidence.isStructurallyValid ? evidence.messages : []
        if let provisionalMessage { messagesToMerge.append(provisionalMessage) }
        let stored = try chatStore.mergeAXFirst(uid: uid, messages: messagesToMerge).history
        let absorbedIDs = Set(ledger.receipts.compactMap(\.absorbedAXMessageID))
        let merged = stored.filter { !absorbedIDs.contains($0.id) }
        var ocrDiagnostic = sourceDiagnostic
        onOCRDiagnostic?(sourceDiagnostic)
        let timeline = try AutoReplyTimeline.make(messages: merged)
        let serviceIDs = Set(merged.filter { $0.sender == .service }.map(\.id))
        let wasBaselined = baselinedUIDs.contains(uid)
        let previousServiceIDs = knownServiceIDsByUID[uid] ?? []
        let unexpected = wasBaselined
            ? serviceIDs.subtracting(previousServiceIDs).sorted()
            : []
        knownServiceIDsByUID[uid, default: []].formUnion(serviceIDs)

        let batch: FrozenCustomerBatch?
        if !wasBaselined && cursor == .empty {
            baselinedUIDs.insert(uid)
            if unreadUIDs.remove(uid) != nil {
                let lastServiceIndex = merged.lastIndex { $0.sender == .service }
                let prefix = lastServiceIndex.map { Array(merged[...$0]) } ?? []
                let initialCursor = try AutoReplyTimeline.make(messages: prefix).cursor
                batch = try timeline.freeze(after: initialCursor)
            } else {
                batch = nil
            }
        } else {
            do {
                batch = try timeline.freeze(after: cursor)
            } catch AutoReplyTimelineError.invalidPrefix {
                let lastServiceIndex = merged.lastIndex { $0.sender == .service }
                let prefix = lastServiceIndex.map { Array(merged[...$0]) } ?? []
                let serviceCursor = try AutoReplyTimeline.make(messages: prefix).cursor
                let recoveredCount = min(cursor.count, serviceCursor.count)
                guard let recoveredCursor = timeline.prefixCursor(at: recoveredCount) else {
                    throw AutoReplyTimelineError.invalidPrefix
                }
                batch = try timeline.freeze(after: recoveredCursor)
            }
        }
        unreadUIDs.remove(uid)

        var imageAttachments: [AutoReplyImageAttachment] = []
        if enrichAttachments, includeImages,
           let batch,
           let lease,
           let imageResolver,
           let imageDownloader,
           let imageRootDirectory {
            let imageIDs = batch.events.filter { $0.kind == .image }.map(\.messageID)
            let candidates = PDDAXImageSelection.customerImages(
                in: openedTree.nodes, messageIDs: imageIDs
            )
            var imageErrors: [String] = []
            for candidate in candidates {
                do {
                    try lease.validate()
                    let refreshedTree = try backend.readSemanticTree()
                    try lease.validate()
                    guard let refreshedCandidate = PDDAXImageSelection.customerImages(
                        in: refreshedTree.nodes,
                        messageIDs: [candidate.messageID]
                    ).first else {
                        throw PDDCustomerImageError.imageNoLongerClickable
                    }
                    let sourceURL = try await imageResolver.resolve(
                        candidate: refreshedCandidate, lease: lease
                    )
                    let directory = imageRootDirectory
                        .appendingPathComponent(uid, isDirectory: true)
                        .appendingPathComponent(batch.endCursor.digest, isDirectory: true)
                    let attachment = try await imageDownloader.download(
                        sourceURL: sourceURL,
                        destinationDirectory: directory,
                        messageID: candidate.messageID
                    )
                    try lease.validate()
                    imageAttachments.append(try frozenImageStore?.freeze(attachment) ?? attachment)
                } catch {
                    imageErrors.append("\(candidate.messageID): \(error.localizedDescription)")
                }
            }
            if !imageErrors.isEmpty {
                ocrDiagnostic += "；图片失败 \(imageErrors.joined(separator: " | "))"
            }
            let hasText = batch.events.contains { $0.kind == .text && !$0.content.isEmpty }
            if !hasText, !imageIDs.isEmpty, imageAttachments.isEmpty {
                ocrDiagnostic += "；纯图片批次原图不可用，保留 [图片] 占位并请求客户补充说明"
            }
        }

        let videoAttachments: [AutoReplyVideoAttachment] = []
        var pendingVideoMessageIDs: [String] = []
        if enrichAttachments,
           let batch,
           let lease,
           let videoCoordinator {
            let videoIDs = batch.events.filter {
                $0.kind == .video
                    && (onlyVideoMessageID == nil || $0.messageID == onlyVideoMessageID)
            }.map(\.messageID)
            let candidates = PDDAXVideoSelection.customerVideos(
                in: openedTree.nodes, messageIDs: videoIDs
            )
            if !candidates.isEmpty {
                do {
                    pendingVideoMessageIDs = try await videoCoordinator.begin(
                        uid: uid, candidates: candidates, lease: lease
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    ocrDiagnostic += "；视频启动失败 \(error.localizedDescription)"
                }
            }
            if !videoIDs.isEmpty, pendingVideoMessageIDs.isEmpty {
                ocrDiagnostic += "；视频尚未成功启动后台读取"
            }
        }

        return AutoReplyCapture(
            uid: uid,
            fullHistory: merged,
            batch: batch,
            customerCursor: timeline.cursor,
            unexpectedServiceMessageIDs: unexpected,
            ocrDiagnostic: ocrDiagnostic,
            imageAttachments: imageAttachments,
            videoAttachments: videoAttachments,
            pendingVideoMessageIDs: pendingVideoMessageIDs
        )
    }

    private func isAllowed(_ uid: String) -> Bool {
        allowedUIDs?.contains(uid) ?? true
    }

    private func isUsableChatSurface(_ tree: PDDAXSemanticTree) -> Bool {
        (try? PDDAXControlSelection.composer(in: tree.nodes)) != nil
    }

    private func authoritativeEvidence(
        in tree: PDDAXSemanticTree,
        capturedAt: Date
    ) -> PDDAXVisibleMessageEvidence {
        let evidence = PDDAXVisibleMessageEvidence.extract(
            root: tree.rootSnapshot,
            capturedAt: capturedAt
        )
        guard isUsableChatSurface(tree) else {
            return PDDAXVisibleMessageEvidence(
                messageNodeCount: evidence.messageNodeCount,
                messages: evidence.messages,
                diagnostics: evidence.diagnostics + ["聊天输入框缺失"],
                fingerprint: evidence.fingerprint,
                isStructurallyValid: false
            )
        }
        return evidence
    }

    private func normalizedNickname(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
