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
            return "当前会话的目标消息暂未核对成功，将重试定位：\(uid)"
        }
    }
}

@MainActor
protocol PDDConversationOpening: AnyObject {
    func recipientVerificationReason(uid: String, expectedCustomerMessageIDs: Set<String>,
                                     in tree: PDDAXSemanticTree) -> String?
    func openAndResolve(uid: String) async throws -> PDDAXSemanticTree
    func openAndResolve(
        uid: String,
        expectedCustomerMessageIDs: Set<String>
    ) async throws -> PDDAXSemanticTree
}

extension PDDConversationOpening {
    func recipientVerificationReason(uid: String, expectedCustomerMessageIDs: Set<String>,
                                     in tree: PDDAXSemanticTree) -> String? {
        PDDAXRecipientVerification.reason(uid: uid, expectedAXMessageIDs: expectedCustomerMessageIDs, tree: tree)
    }
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
    private var lastDiscoveryCandidate: String?
    private var latestVisibleConversations: [PDDConversationLocator]?
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
        latestVisibleConversations = nil
        var tree = try backend.readSemanticTree()
        try refreshVisibleConversations(in: tree)

        let transferRows = PDDAXIncomingTransfer.pendingRows(in: tree)
        let unreadRows = try await unreadEvidence.unreadRows(in: tree)
        var seenRows = Set<AXElementToken>()
        let candidates = (transferRows + unreadRows).filter { seenRows.insert($0.rowID).inserted }
        func candidateKey(_ row: PDDConversationRow<AXElementToken>) -> String {
            PDDConversationKey.make(locator: .init(domIdentifier: row.domIdentifier, nickname: row.visibleLabel))
        }
        let previousIndex = candidates.firstIndex { candidateKey($0) == lastDiscoveryCandidate }
        let nextIndex = previousIndex.map { ($0 + 1) % max(1, candidates.count) } ?? 0
        if !candidates.isEmpty {
            let row = candidates[nextIndex]
            // Advance before pressing: even a broken first row must yield to
            // the other unread/transfer rows on the next discovery pass.
            lastDiscoveryCandidate = candidateKey(row)
            try backend.performPress(row.rowID)
            try await Task.sleep(nanoseconds: 80_000_000)
            tree = try backend.readSemanticTree()
            try refreshVisibleConversations(in: tree)
            let locator = PDDConversationLocator(
                domIdentifier: row.domIdentifier,
                nickname: row.visibleLabel
            )
            let uid = knownConversationUID(in: tree) ?? PDDConversationKey.make(locator: locator)
            let legacyUID = PDDCustomerIdentity.resolve(from: tree.rootSnapshot)
            guard isAllowed(uid) || legacyUID.map(isAllowed) == true,
                  legacyUID != nil || isUsableChatSurface(tree) else { return [] }
            rememberLocator(locator, uid: uid)
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
            let currentUID = knownConversationUID(in: tree) ?? PDDConversationKey.make(locator: locator)
            guard isAllowed(currentUID) else { return [] }
            rememberLocator(locator, uid: currentUID)
            let knownIDs = Set(try chatStore.loadAXFirst(uid: currentUID).map(\.id))
            let newCustomer = baselinedUIDs.contains(currentUID)
                && PDDAXVisibleMessageEvidence.extract(root: tree.rootSnapshot).messages.contains {
                    $0.sender == .customer && !knownIDs.contains($0.id)
                }
            if newCustomer {
                AutomationStepLog.record(root: chatStore.rootDirectory, uid: currentUID,
                    step: "visible-customer-message-without-red-dot")
            }
            return [.init(uid: currentUID, hasUnreadEvidence: false, hasUncapturedCustomerMessages: newCustomer)]
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
            if let reason = recipientVerificationReason(uid: uid, expectedCustomerMessageIDs: expectedCustomerMessageIDs, in: tree),
               isUsableChatSurface(tree) {
                logRecipientVerification(uid: uid, reason: reason, tree: tree)
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
                if let reason = recipientVerificationReason(uid: uid, expectedCustomerMessageIDs: expectedCustomerMessageIDs, in: tree),
                   isUsableChatSurface(tree) {
                    logRecipientVerification(uid: uid, reason: reason, tree: tree)
                    return tree
                }
            }

            let nicknameCandidates = nicknameMatches
            if nicknameMatches.count > 1 {
                conversationDiagnostics.append(.init(
                    uid: uid,
                    kind: "conversation-nickname-ambiguous",
                    detail: "昵称 \(locator.normalizedNickname) 匹配到 \(nicknameMatches.count) 个会话，按 AX 身份逐一核对"
                ))
            }
            for (position, candidate) in nicknameCandidates.enumerated() {
                // AX element tokens are rebuilt after every tree read. Resolve
                // the row again instead of pressing a token from the old list.
                let refreshedRows = try PDDAXControlSelection.conversationRows(in: tree.nodes)
                let refreshedMatches = refreshedRows.filter {
                    normalizedNickname($0.visibleLabel) == locator.normalizedNickname
                }
                let exactRow = candidate.domIdentifier.flatMap { identifier in
                    refreshedRows.first { $0.domIdentifier == identifier }
                }
                guard let selected = exactRow ?? (refreshedMatches.indices.contains(position) ? refreshedMatches[position] : nil)
                else { continue }
                try backend.performPress(selected.rowID)
                try await Task.sleep(nanoseconds: 80_000_000)
                tree = try backend.readSemanticTree()
                // An expired row identifier can refresh only when actual
                // customer-message evidence independently identifies the chat.
                let previousLocator = conversationLocatorsByUID[uid]
                if let refreshed = selected.domIdentifier, refreshed != locator.domIdentifier,
                   containsTargetMessage(expectedCustomerMessageIDs, uid: uid, in: tree.rootSnapshot) {
                    conversationLocatorsByUID[uid]?.domIdentifier = refreshed
                }
                if let reason = recipientVerificationReason(uid: uid, expectedCustomerMessageIDs: expectedCustomerMessageIDs, in: tree),
                   isUsableChatSurface(tree) {
                    logRecipientVerification(uid: uid, reason: reason, tree: tree)
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
                conversationLocatorsByUID[uid] = previousLocator
            }
            if !expectedCustomerMessageIDs.isEmpty {
                throw PDDAXConversationDriverError.nicknameCandidatesExhausted(uid)
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

    // OCR IDs belong to our receipt ledger, not Pinduoduo's DOM. Resolve the
    // recorded AX alias before locating a chat. Without an alias, only an
    // independently verified, unique active chat may use the OCR fallback.
    private func containsTargetMessage(_ expected: Set<String>, uid: String, in root: AXNodeSnapshot) -> Bool {
        let actual = Set(PDDChatParser.parse(root: root).messages.filter { $0.sender == .customer }.map(\.id))
        if !actual.isDisjoint(with: expected) { return true }
        let receipts = (provisionalReceiptsByUID[uid] ?? []).filter {
            expected.contains($0.provisionalMessageID)
        }
        let aliases = Set(receipts.compactMap(\.absorbedAXMessageID))
        if !aliases.isEmpty, !actual.isDisjoint(with: aliases) {
            AutomationStepLog.record(root: chatStore.rootDirectory, uid: uid,
                step: "reply-target-ocr-alias-resolved", detail: aliases.sorted().joined(separator: ","))
            return true
        }
        return false
    }

    func recipientVerificationReason(uid: String, expectedCustomerMessageIDs: Set<String>,
                                     in tree: PDDAXSemanticTree) -> String? {
        let aliases = (provisionalReceiptsByUID[uid] ?? []).filter {
            expectedCustomerMessageIDs.contains($0.provisionalMessageID)
        }.compactMap(\.absorbedAXMessageID)
        return PDDAXRecipientVerification.reason(uid: uid, locator: conversationLocatorsByUID[uid],
            expectedAXMessageIDs: expectedCustomerMessageIDs.union(aliases), tree: tree)
    }

    private func logRecipientVerification(uid: String, reason: String, tree: PDDAXSemanticTree) {
        if let current = PDDConversationSnapshotLocator.current(in: tree.rootSnapshot),
           reason == "ax-customer-message-id" || current.normalizedNickname == conversationLocatorsByUID[uid]?.normalizedNickname {
            rememberLocator(current, uid: uid)
        }
        AutomationStepLog.record(root: chatStore.rootDirectory, uid: uid,
            step: "reply-target-ax-verified", detail: "route=\(reason) ocr_required=false")
    }

    private func rememberLocator(_ locator: PDDConversationLocator, uid: String) {
        if let previous = conversationLocatorsByUID[uid], previous.normalizedNickname != locator.normalizedNickname {
            AutomationStepLog.record(root: chatStore.rootDirectory, uid: uid,
                step: "conversation-display-name-refreshed",
                detail: "previous=\(previous.normalizedNickname) current=\(locator.normalizedNickname) identity=customer-message-id")
        }
        conversationLabelByUID[uid] = locator.nickname
        conversationLocatorsByUID[uid] = .init(
            domIdentifier: locator.domIdentifier ?? conversationLocatorsByUID[uid]?.domIdentifier,
            nickname: locator.nickname)
    }

    private func knownConversationUID(in tree: PDDAXSemanticTree) -> String? {
        let actual = Set(PDDChatParser.parse(root: tree.rootSnapshot).messages.filter { $0.sender == .customer }.map(\.id))
        guard !actual.isEmpty else { return nil }
        // Older versions could split one chat into several masked-name folders.
        // Prefer the established history when the same exact AX IDs occur in
        // those aliases. No fuzzy text/name match is used to select a recipient.
        let matches = conversationLocatorsByUID.compactMap { uid, locator -> (String, Int, Int)? in
            guard let history = try? chatStore.loadAXFirst(uid: uid) else { return nil }
            let known = Set(history.filter { $0.sender == .customer }.map(\.id))
            let overlap = actual.intersection(known).count
            guard overlap > 0,
                  PDDAXRecipientVerification.reason(uid: uid, locator: locator, expectedAXMessageIDs: actual.intersection(known), tree: tree) != nil
            else { return nil }
            return (uid, overlap, known.count)
        }
        return matches.sorted {
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0 < $1.0
        }.first?.0
    }

    private func refreshVisibleConversations(in tree: PDDAXSemanticTree) throws {
        guard tree.nodes.contains(where: { node in
            node.domClasses.contains { $0.lowercased().contains("chat-list-box") || $0.lowercased().contains("conversation-list") }
        }) else { latestVisibleConversations = nil; return }
        var locators = try PDDAXControlSelection.conversationRows(in: tree.nodes).map {
            PDDConversationLocator(domIdentifier: $0.domIdentifier, nickname: $0.visibleLabel)
        }
        for locator in PDDConversationSnapshotLocator.all(in: tree.rootSnapshot) where !locators.contains(locator) {
            locators.append(locator)
        }
        let hasUnparsedRows = tree.nodes.contains { node in
            node.domClasses.contains { $0.lowercased().contains("chat-item-box") }
        } && locators.isEmpty
        guard !hasUnparsedRows else { latestVisibleConversations = nil; return }
        if let uid = knownConversationUID(in: tree), let known = conversationLocatorsByUID[uid], !locators.contains(known) {
            locators.append(known)
        }
        latestVisibleConversations = locators
    }

    func restoreConversationLocators(_ locators: [String: PDDConversationLocator]) {
        conversationLocatorsByUID = locators
    }

    func visibleConversationsSnapshot() -> [PDDConversationLocator]? { latestVisibleConversations }

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

    /// Preserve messages seen during a send before the UI can clear unread state.
    func observeSendSnapshot(uid: String, root: AXNodeSnapshot) throws {
        let evidence = PDDAXVisibleMessageEvidence.extract(root: root)
        guard evidence.isStructurallyValid else { return }
        let known = Set(try chatStore.loadAXFirst(uid: uid).map(\.id))
        let newIDs = Set(evidence.messages.filter { $0.sender == .customer && !known.contains($0.id) }.map(\.id))
        _ = try chatStore.mergeAXFirst(uid: uid, messages: evidence.messages)
        try CustomerMessageReceipts(root: chatStore.rootDirectory)
            .observe(uid: uid, messages: evidence.messages, actionableIDs: newIDs)
        if !newIDs.isEmpty {
            AutomationStepLog.record(root: chatStore.rootDirectory, uid: uid, step: "customer-messages-captured-during-send",
                detail: "message_ids=\(newIDs.sorted().joined(separator: ","))")
        }
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
        AutomationStepLog.record(root: chatStore.rootDirectory, uid: uid, step: "capture-started")
        var openedTree = try await openAndResolve(uid: uid)
        let hasUnreadEvidence = unreadUIDs.contains(uid)
        var capturedAt = Date()
        var evidence = authoritativeEvidence(in: openedTree, capturedAt: capturedAt)
        let existingAXFirst = try chatStore.loadAXFirst(uid: uid)
        let existingIDs = Set(existingAXFirst.map(\.id))
        var provisionalMessage: PDDChatMessage?
        var sourceDiagnostic: String

        sourceLoop: while true {
            // The trusted platform notice is actionable even when chat history
            // has not loaded; do not wait for OCR to manufacture a customer turn.
            if PDDAXIncomingTransfer.unansweredHandoff(in: openedTree.rootSnapshot) != nil {
                sourceDiagnostic = "AX 平台转入事件：\(evidence.messages.count) 条可见历史消息"
                break sourceLoop
            }
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
        if let handoff = PDDAXIncomingTransfer.unansweredHandoff(in: openedTree.rootSnapshot) {
            let beganBoundary = try await CustomerTransferPolicyStore.shared.beginIncomingHandoff(
                root: chatStore.rootDirectory,
                uid: uid,
                boundaryKey: handoff.boundaryKey,
                priorMessageIDs: Set(handoff.priorCustomerIDs)
            )
            if beganBoundary {
                try CodexSessionRegistry(rootDirectory: chatStore.rootDirectory).invalidate(uid: uid)
            }
            AutomationStepLog.record(root: chatStore.rootDirectory, uid: uid,
                step: "incoming-handoff-detected",
                detail: "boundary=\(handoff.boundaryKey) reset=\(beganBoundary) prior=\(handoff.priorCustomerIDs.count) current=\(handoff.currentCustomerIDs.count)")
            baselinedUIDs.insert(uid)
            if let handoffCursor = try PDDAXIncomingTransfer.recoveryCursor(
                in: merged,
                customerIDs: handoff.currentCustomerIDs
            ) {
                batch = try timeline.freeze(after: handoffCursor)
                ocrDiagnostic += "；检测到转入本账号的系统转接行，仅处理转接后新客户消息"
            } else {
                let closed = try await CustomerTransferPolicyStore.shared.closedMessageIDs(
                    root: chatStore.rootDirectory, uid: uid
                )
                let acknowledged = closed.contains(FrozenCustomerBatch.incomingHandoffPrefix + handoff.boundaryKey)
                batch = acknowledged ? nil : .incomingHandoff(key: handoff.boundaryKey, cursor: timeline.cursor)
                ocrDiagnostic += acknowledged ? "；本次转入已有确认回复，跳过重复"
                    : "；检测到转入本账号的系统转接行，按历史上下文生成一次接续回复"
            }
        } else if !wasBaselined && cursor == .empty {
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

        AutomationStepLog.record(root: chatStore.rootDirectory, uid: uid, step: "capture-completed",
            detail: "history=\(merged.count) batch=\(batch?.events.count ?? 0) \(ocrDiagnostic)")
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
