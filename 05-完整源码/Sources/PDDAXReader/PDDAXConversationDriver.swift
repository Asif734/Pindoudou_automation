import CryptoKit
import Foundation

enum PDDAXConversationDriverError: LocalizedError {
    case uidNotFound(String)
    case uidNotAllowed(String)
    case nicknameCandidatesExhausted(String)
    case identityRedirect(String, String)

    var errorDescription: String? {
        switch self {
        case .uidNotFound(let uid): return "无法通过 AX 打开并核对会话：\(uid)"
        case .identityRedirect(let uid, let canonical): return "会话身份已核对：\(uid) → \(canonical)，待处理消息保留并重新定位"
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
    private var restoredPendingDiscovery = false
    private var observedAXMessageIDs = Set<String>()
    private var diagnosticRecordedAt: [String: Date] = [:]
    private var handledHandoffsByUID: [String: String] = [:]
    private var settlingSince: [String: Date] = [:]
    private var settlingAttention = Set<String>()
    private var unresolvedSnapshots: [String: (since: Date, observations: Int)] = [:]
    private let now: @Sendable () -> Date
    private var identities: PDDConversationIdentityStore { .init(root: chatStore.rootDirectory) }
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
        captureOperationTimeout: Duration = .seconds(25),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.backend = backend
        self.now = now
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

    private var discoveryStore: PDDPendingDiscoveryStore { .init(root: chatStore.rootDirectory) }
    private var signalStore: PDDDiscoverySignalStore { .init(root: chatStore.rootDirectory) }

    private var captureInbox: PDDVerifiedCaptureInbox { .init(root: chatStore.rootDirectory) }

    private func pendingInboxEntries(includeReceiptRecovery: Bool = false) throws -> [PDDVerifiedCaptureInbox.Entry] {
        var entries: [String: PDDVerifiedCaptureInbox.Entry] = [:]
        for entry in try captureInbox.entries(includingAcknowledged: includeReceiptRecovery) {
            do {
                let uid = try identities.canonicalUID(entry.uid)
                if entry.acknowledged == true {
                    let receipts = try CustomerMessageReceipts(root: chatStore.rootDirectory).receipts(uid: uid)
                    guard entry.messages.contains(where: { message in
                        guard let receipt = receipts[message.id] else { return false }
                        return receipt.requiresSubmission && receipt.submittedAt == nil && receipt.closedAt == nil && receipt.replySentAt == nil
                    }) else { continue }
                }
                let old = entries[uid]
                entries[uid] = .init(uid: uid, locator: entry.locator,
                    messages: PDDVerifiedCaptureInbox.merging(old?.messages ?? [], entry.messages),
                    snapshot: entry.snapshot, unread: entry.unread || old?.unread == true, capturedAt: entry.capturedAt)
            } catch {
                discoveryLog("capture-inbox-owner-deferred", uid: entry.uid, detail: error.localizedDescription)
            }
        }
        return entries.values.sorted { $0.capturedAt < $1.capturedAt }
    }

    func discover() async throws -> [AutoReplyDiscovery] {
        let saved = try pendingInboxEntries()
        let live: [AutoReplyDiscovery]
        do { live = try await discoverLive() }
        catch {
            guard !saved.isEmpty else { throw error }
            discoveryLog("discovery-live-read-deferred", detail: error.localizedDescription)
            return saved.map { .init(uid: $0.uid, hasUnreadEvidence: $0.unread, hasUncapturedCustomerMessages: true) }
        }
        var result = live
        for entry in saved where !result.contains(where: { $0.uid == entry.uid }) {
            result.append(.init(uid: entry.uid, hasUnreadEvidence: entry.unread, hasUncapturedCustomerMessages: true))
        }
        return result
    }

    private func discoverLive() async throws -> [AutoReplyDiscovery] {
        latestVisibleConversations = nil
        var tree = try backend.readSemanticTree()
        recordFirstObservedMessages(in: tree)
        try refreshVisibleConversations(in: tree)
        var tasks = try discoveryStore.load()
        let originalTasks = tasks
        if !restoredPendingDiscovery {
            restoredPendingDiscovery = true
            for index in tasks.indices { tasks[index].nextAttemptAt = min(tasks[index].nextAttemptAt, now()) }
        }
        let transferRows = PDDAXIncomingTransfer.pendingRows(in: tree)
        var unreadDetectionSucceeded = true
        let unreadRows: [PDDConversationRow<AXElementToken>]
        do { unreadRows = try await unreadEvidence.unreadRows(in: tree) }
        catch {
            guard !tasks.isEmpty else { throw error }
            unreadRows = []
            unreadDetectionSucceeded = false
            discoveryLog("discovery-unread-refresh-deferred", detail: error.localizedDescription)
        }
        var seen = Set<AXElementToken>()
        let triggered = (transferRows + unreadRows).filter { seen.insert($0.rowID).inserted }
        let parsed = (try? PDDAXControlSelection.conversationRows(in: tree.nodes)) ?? []
        seen = []
        let rows = (parsed + triggered).filter { seen.insert($0.rowID).inserted }.sorted {
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            return $0.rowID.rawValue < $1.rowID.rawValue
        }
        var signals = try signalStore.load()
        var activeSignalKeys = Set<String>()
        for row in triggered {
            let locator = PDDConversationLocator(domIdentifier: row.domIdentifier, nickname: row.visibleLabel)
            let occurrence = rows.filter { $0.visibleLabel == row.visibleLabel }.firstIndex { $0.rowID == row.rowID } ?? 0
            let unread = unreadRows.contains { $0.rowID == row.rowID }
            let transferOnly = !unread && transferRows.contains { $0.rowID == row.rowID }
            let texts = discoveryRowTexts(row.rowID, tree: tree)
            let key = "\(locator.normalizedIdentifier ?? locator.normalizedNickname):\(occurrence):\(transferOnly ? "transfer" : "unread")"
            let material = texts.joined(separator: "\n")
            let signature = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
            activeSignalKeys.insert(key)
            var old = signals[key]
            if transferOnly {
                let unreadKey = "\(locator.normalizedIdentifier ?? locator.normalizedNickname):\(occurrence):unread"
                if let previous = signals[unreadKey], previous.signature == signature, previous.handled {
                    old = previous
                    old?.active = true // Clearing the dot is not a second transfer.
                }
            }
            // A continuously lit dot can hide two identical previews within the
            // same minute. A slow verification probe protects against that ambiguity.
            let unreadRecheckDue = !transferOnly && old?.handledAt.map { now().timeIntervalSince($0) >= 30 } == true
            let unchangedHandled = old?.active == true && old?.signature == signature && old?.handled == true && !unreadRecheckDue
            signals[key] = .init(signature: signature, active: true, handled: unchangedHandled,
                handledAt: unchangedHandled ? old?.handledAt : nil)
            guard !unchangedHandled else { continue }
            if unreadRecheckDue {
                discoveryLog("discovery-unread-signal-recheck", detail: "signal=\(key); persistent unread recheck after 30s; identical previews may coalesce")
            }
            let id = PDDPendingDiscoveryStore.retain(locator: locator, occurrence: occurrence,
                unread: true, at: now(), in: &tasks)
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index].signalKey = key
                tasks[index].signalSignature = signature
                tasks[index].transferOnly = transferOnly
                tasks[index].previewTexts = texts
            }
            if !originalTasks.contains(where: { $0.id == id }) {
                discoveryLog("discovery-task-retained", detail: "task=\(id) source=\(transferOnly ? "transfer" : "unread") label=\(row.visibleLabel); retained before selection")
            }
        }
        for key in Array(signals.keys) where !activeSignalKeys.contains(key) {
            // A failed screenshot is unknown, not a cleared unread edge.
            if unreadDetectionSucceeded || key.hasSuffix(":transfer") { signals[key]?.active = false }
        }
        try signalStore.save(signals)
        // Persist the trigger before a click can clear Pinduoduo's unread dot.
        if tasks != originalTasks { try discoveryStore.save(tasks) }
        for pending in tasks where pending.nextAttemptAt <= now() {
            guard let index = tasks.firstIndex(where: { $0.id == pending.id }) else { continue }
            guard var row = pendingRow(pending, in: rows) else {
                tasks[index].nextAttemptAt = now().addingTimeInterval(15)
                try discoveryStore.save(tasks)
                continue
            }
            var task = tasks.remove(at: index)
            task.previewTexts = discoveryRowTexts(row.rowID, tree: tree)
            let age = now().timeIntervalSince(task.firstSeenAt)
            let firstAttempt = task.attempts == 0
            task.attempts += 1
            task.nextAttemptAt = now().addingTimeInterval(min(15, pow(2, Double(min(task.attempts, 4)))))
            tasks.append(task) // Fair retry order survives unread/list changes.
            try discoveryStore.save(tasks)
            // A healthy chat tree is sufficient. Optional Chromium exposure
            // recovery must never become a prerequisite for capture.
            if !PDDAXCaptureSurface.hasReadableMessages(in: tree), age >= 10 && (task.lastRefreshAt.map { now().timeIntervalSince($0) >= 10 } ?? true) {
                tasks[tasks.count - 1].lastRefreshAt = now()
                task.lastRefreshAt = now()
                try discoveryStore.save(tasks)
                do {
                    try backend.requestAccessibilityRefresh()
                    discoveryLog("discovery-AX-refresh-requested", detail: "task=\(task.id) age=\(Int(age))s")
                } catch {
                    discoveryLog("discovery-AX-refresh-deferred", detail: "task=\(task.id); request is optional; \(error.localizedDescription)")
                }
                do {
                    // Re-read even when the optional request is rejected. Only
                    // the actual tree determines whether capture can proceed.
                    tree = try backend.readSemanticTree()
                    recordFirstObservedMessages(in: tree)
                    try refreshVisibleConversations(in: tree)
                    let freshRows = (try? PDDAXControlSelection.conversationRows(in: tree.nodes)) ?? []
                    guard let fresh = pendingRow(task, in: freshRows) else { return [] }
                    row = fresh
                } catch {
                    discoveryLog("discovery-AX-resample-deferred", detail: "task=\(task.id) \(error.localizedDescription)")
                    return []
                }
            }
            let active = try? PDDAXControlSelection.currentConversationRow(in: tree.nodes)
            let reselect = firstAttempt || active?.rowID != row.rowID
            if reselect {
                task.lastSelectionAt = now()
                tasks[tasks.count - 1].lastSelectionAt = now()
                try discoveryStore.save(tasks)
                try backend.performPress(row.rowID)
                discoveryLog("discovery-row-selected", detail: "task=\(task.id) attempt=\(task.attempts) age=\(Int(age))s")
                // Keep ownership while AX catches up; readiness, not a fixed sleep,
                // ends the probe. The budget bounds one customer's UI occupancy.
                let deadline = ContinuousClock.now.advanced(by: .milliseconds(1500))
                repeat {
                    try Task.checkCancellation()
                    tree = try backend.readSemanticTree()
                    recordFirstObservedMessages(in: tree)
                    if try discoverySelectionReady(task: task, tree: tree) { break }
                    if ContinuousClock.now >= deadline { break }
                    try await Task.sleep(nanoseconds: 120_000_000)
                } while true
                try refreshVisibleConversations(in: tree)
            }
            let current = try refreshedLocator(in: tree)
            let locator = current ?? PDDConversationLocator(domIdentifier: row.domIdentifier, nickname: row.visibleLabel)
            if !(try discoverySelectionReady(task: task, tree: tree)) {
                recordCaptureDiagnostic("selected-pane-mismatch", task: task, tree: tree)
                noteSettling(key: task.id.uuidString, label: task.locator.nickname)
                discoveryLog("discovery-selected-chat-loading", detail: "task=\(task.id) expected=\(task.locator.nickname) observed=\(current?.nickname ?? "unknown") messages=\(customerIDs(in: tree).count); readiness not confirmed; task retained")
                return []
            }
            guard let uid = try resolveForDiscovery(in: tree, locator: locator, task: task) else {
                recordCaptureDiagnostic("identity-unresolved", task: task, tree: tree)
                noteSettling(key: task.id.uuidString, label: locator.nickname)
                return []
            }
            if let expected = task.resolvedUID, try identities.canonicalUID(expected) != uid {
                recordCaptureDiagnostic("resolved-owner-changed", task: task, tree: tree)
                discoveryLog("discovery-task-identity-deferred", detail: "task=\(task.id); resolved customer changed; original task retained")
                return []
            }
            let legacyUID = PDDCustomerIdentity.resolve(from: tree.rootSnapshot)
            guard isAllowed(uid) || legacyUID.map(isAllowed) == true else {
                recordCaptureDiagnostic("customer-not-allowed", task: task, tree: tree)
                return []
            }
            guard legacyUID != nil || isReadableChatSurface(tree) else {
                recordCaptureDiagnostic("message-surface-unreadable", task: task, tree: tree)
                return []
            }
            if PDDAXControlSelection.composerCandidates(in: tree.nodes).count != 1 {
                recordCaptureDiagnostic("verified-read-without-unique-composer", task: task, tree: tree)
            }
            tasks[tasks.count - 1].resolvedUID = uid
            tasks[tasks.count - 1].locator = locator
            tasks[tasks.count - 1].observedCustomerIDs.formUnion(customerIDs(in: tree))
            try discoveryStore.save(tasks)
            settlingSince.removeValue(forKey: task.id.uuidString)
            settlingAttention.remove(task.id.uuidString)
            unresolvedSnapshots.removeValue(forKey: task.id.uuidString)
            try stageVerifiedCapture(uid: uid, locator: locator, tree: tree, unread: task.requiresUnreadCapture)
            rememberLocator(locator, uid: uid)
            if task.requiresUnreadCapture { unreadUIDs.insert(uid) }
            if let legacyUID, task.requiresUnreadCapture {
                conversationLabelByUID[legacyUID] = row.visibleLabel
                unreadUIDs.insert(legacyUID)
            }
            discoveryLog("discovery-task-identified", detail: "task=\(task.id) uid=\(uid); awaiting durable capture")
            return [.init(uid: uid, hasUnreadEvidence: task.requiresUnreadCapture,
                          hasUncapturedCustomerMessages: hasNewVisibleCustomer(uid: uid, in: tree))]
        }

        if isReadableChatSurface(tree), let row = try PDDAXControlSelection.currentConversationRow(in: tree.nodes) {
            guard !customerIDs(in: tree).isEmpty || PDDAXIncomingTransfer.unansweredHandoff(in: tree.rootSnapshot) != nil else {
                return [] // Merely opening an empty chat is not new work.
            }
            let locator = PDDConversationLocator(domIdentifier: row.domIdentifier, nickname: row.visibleLabel)
            // A pending row has its own retry schedule; do not busy-loop or reset its grace.
            if tasks.contains(where: { task in
                if let left = task.locator.normalizedIdentifier, let right = locator.normalizedIdentifier {
                    return left == right
                }
                // A visitor/mask compatibility hint must never suppress an
                // unrelated active customer's red-dot-free message check.
                return task.locator.normalizedNickname == locator.normalizedNickname
                    && pendingRow(task, in: rows)?.rowID == row.rowID
            }) { return [] }
            guard let uid = try resolveForDiscovery(in: tree, locator: locator) else {
                let id = PDDPendingDiscoveryStore.retain(locator: locator, occurrence: 0,
                    unread: false, at: now(), in: &tasks)
                if let index = tasks.firstIndex(where: { $0.id == id }) { tasks[index].attempts = max(tasks[index].attempts, 1) }
                try discoveryStore.save(tasks)
                noteSettling(key: id.uuidString, label: locator.nickname)
                return []
            }
            guard isAllowed(uid) else { return [] }
            rememberLocator(locator, uid: uid)
            let fresh = hasNewVisibleCustomer(uid: uid, in: tree)
            if fresh {
                try stageVerifiedCapture(uid: uid, locator: locator, tree: tree, unread: false)
                discoveryLog("visible-customer-message-without-red-dot", uid: uid)
            }
            return [.init(uid: uid, hasUnreadEvidence: false, hasUncapturedCustomerMessages: fresh)]
        }
        return []
    }

    func acknowledgeDiscoveryCapture(_ capture: AutoReplyCapture) throws {
        let ids = Set(capture.fullHistory.map(\.id))
        let receiptIDs = Set(try CustomerMessageReceipts(root: chatStore.rootDirectory).receipts(uid: capture.uid).keys)
        for entry in try captureInbox.entries() where try identities.canonicalUID(entry.uid) == capture.uid {
            guard Set(entry.messages.filter { $0.sender == .customer }.map(\.id)).isSubset(of: receiptIDs) else { continue }
            try captureInbox.acknowledge(uid: entry.uid, capturedIDs: ids)
        }
        let tasks = try discoveryStore.load()
        guard !tasks.isEmpty else { return }
        let capturedIDs = Set(capture.fullHistory.filter { $0.sender == .customer }.map(\.id))
        let retained = tasks.filter { task in
            guard let resolved = task.resolvedUID,
                  resolved == capture.uid || (try? identities.canonicalUID(resolved)) == capture.uid else { return true }
            guard task.observedCustomerIDs.isSubset(of: capturedIDs) else { return true }
            // Identifying the chat or reading its old history is not proof
            // that the unread customer message has been captured.
            if task.requiresUnreadCapture && capture.batch == nil {
                let handledTransfer = handledHandoffsByUID[capture.uid] != nil
                    && (task.transferOnly == true || task.signalKey == nil
                        || (task.previewTexts ?? []).contains { PDDAXIncomingTransfer.recipient($0) != nil })
                let latest = capture.fullHistory.last
                let previewMatches = latest.map { message in
                    let content = PDDOCRNormalizer.normalize(message.content)
                    return !content.isEmpty && (task.previewTexts ?? []).contains {
                        PDDOCRNormalizer.normalize($0) == content
                    }
                } ?? false
                let receipts = (try? CustomerMessageReceipts(root: chatStore.rootDirectory).receipts(uid: capture.uid)) ?? [:]
                let customerIDs = task.observedCustomerIDs
                let allCaptured = !customerIDs.isEmpty && customerIDs.allSatisfy { receipts[$0] != nil }
                // A handled transfer or an exact preview of an already replied
                // thread is positive no-work evidence. Partial/empty reads stay pending.
                return !(handledTransfer || (latest?.sender == .service && previewMatches && allCaptured))
            }
            return capture.batch == nil && (task.observedCustomerIDs.isEmpty
                || !task.observedCustomerIDs.isSubset(of: capturedIDs))
        }
        guard retained != tasks else { return }
        // Save signal disposition first. A crash before queue removal can only
        // cause another inspection, never an unrecorded message loss.
        for task in tasks where !retained.contains(where: { $0.id == task.id }) {
            try signalStore.finish(task, at: now())
        }
        try discoveryStore.save(retained)
        for task in tasks where !retained.contains(where: { $0.id == task.id }) {
            settlingSince.removeValue(forKey: task.id.uuidString)
            settlingAttention.remove(task.id.uuidString)
            unresolvedSnapshots.removeValue(forKey: task.id.uuidString)
            let legacyKey = "locator:\(task.locator.normalizedIdentifier ?? task.locator.normalizedNickname)"
            settlingSince.removeValue(forKey: legacyKey)
            settlingAttention.remove(legacyKey)
            unresolvedSnapshots.removeValue(forKey: legacyKey)
            discoveryLog(capture.batch == nil ? "discovery-inspection-no-work" : "discovery-capture-confirmed", uid: capture.uid,
                         detail: "task=\(task.id); receipts and trigger evidence checked; pending trigger released")
        }
    }

    private func recordCaptureDiagnostic(_ reason: String, task: PDDPendingDiscovery?, tree: PDDAXSemanticTree) {
        let key = "\(task?.id.uuidString ?? "visible"):\(reason)"
        let date = now()
        guard diagnosticRecordedAt[key].map({ date.timeIntervalSince($0) >= 30 }) ?? true else { return }
        diagnosticRecordedAt[key] = date
        let record = PDDAXIncomingTransfer.incomingRecord(in: tree.rootSnapshot)
        let owners = (try? identities.evidenceOwners(messageIDs: customerIDs(in: tree),
            stableID: (try? refreshedLocator(in: tree))?.normalizedIdentifier,
            boundary: record?.identityBoundaryKey)) ?? []
        let diagnostic = PDDAXCaptureDiagnostic(reason: reason, task: task, tree: tree,
            ownerCandidates: owners, at: date)
        do {
            let path = try diagnostic.save(root: chatStore.rootDirectory)
            discoveryLog("capture-readiness-diagnostic", detail:
                "reason=\(reason) task=\(task?.id.uuidString ?? "visible") owners=\(owners.sorted().joined(separator: ",")) composer_candidates=\(diagnostic.composerCandidateCount) readable_messages=\(diagnostic.readableMessagePane) customer_ids=\(diagnostic.messageIDs.count) snapshot=\(path.path); no submission from diagnostic")
        } catch {
            // Diagnostic I/O must never become another capture prerequisite.
            discoveryLog("capture-diagnostic-write-deferred", detail: error.localizedDescription)
        }
    }

    private func recordFirstObservedMessages(in tree: PDDAXSemanticTree) {
        for id in customerIDs(in: tree).sorted() where observedAXMessageIDs.insert(id).inserted {
            discoveryLog("ax-customer-message-first-observed", detail:
                "message_id=\(id) observed_at_ms=\(Int(now().timeIntervalSince1970 * 1000)); first AX observation in this runtime, not a platform arrival receipt")
        }
    }

    private func discoverySelectionReady(task: PDDPendingDiscovery, tree: PDDAXSemanticTree) throws -> Bool {
        if let current = try refreshedLocator(in: tree), !pendingLocatorMatches(task.locator, current) { return false }
        if let semantic = try PDDAXControlSelection.currentConversationRow(in: tree.nodes),
           !pendingLocatorMatches(task.locator, .init(domIdentifier: semantic.domIdentifier, nickname: semantic.visibleLabel)) { return false }
        // Selected CSS can update before the message pane. Old messages belonging
        // to a different known customer must not be rebound to the new selection.
        if let owner = try? knownConversationUID(in: tree),
           let prior = conversationLocatorsByUID[owner],
           !pendingLocatorMatches(task.locator, prior) { return false }
        return PDDAXCaptureSurface.hasReadableMessages(in: tree)
            || PDDAXIncomingTransfer.unansweredHandoff(in: tree.rootSnapshot) != nil
            || PDDCustomerIdentity.resolve(from: tree.rootSnapshot) != nil
    }

    private func stageVerifiedCapture(uid: String, locator: PDDConversationLocator,
                                      tree: PDDAXSemanticTree, unread: Bool) throws {
        let evidence = PDDAXVisibleMessageEvidence.extract(root: tree.rootSnapshot, capturedAt: now())
        guard PDDAXCaptureSurface.hasReadableMessages(in: tree)
            || PDDAXIncomingTransfer.unansweredHandoff(in: tree.rootSnapshot) != nil else { return }
        // The caller already resolved identity. Recheck contradictions before saving.
        guard PDDAXRecipientVerification.reason(uid: uid, locator: locator,
            expectedAXMessageIDs: customerIDs(in: tree), tree: tree) != nil
            || recipientVerificationReason(uid: uid, expectedCustomerMessageIDs: customerIDs(in: tree), in: tree) != nil else { return }
        try captureInbox.stage(uid: uid, locator: locator, messages: evidence.messages,
            snapshot: tree.rootSnapshot, unread: unread, at: now())
        discoveryLog("discovery-message-content-staged", uid: uid,
            detail: "message_ids=\(evidence.messages.filter { $0.sender == .customer }.map(\.id).joined(separator: ",")); durable=true submitted=false")
    }

    private func discoveryRowTexts(_ row: AXElementToken, tree: PDDAXSemanticTree) -> [String] {
        let children = Dictionary(grouping: tree.nodes, by: \.parentID)
        func visit(_ id: AXElementToken) -> [String] {
            (children[id] ?? []).flatMap { node -> [String] in
                if node.domClasses.contains(where: { $0.contains("nickname") }) { return [] }
                let texts = [node.value, node.title].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !$0.contains("秒后超时") }
                return texts + visit(node.id)
            }
        }
        return visit(row)
    }

    private func hasNewVisibleCustomer(uid: String, in tree: PDDAXSemanticTree) -> Bool {
        let known = Set(((try? chatStore.loadAXFirst(uid: uid)) ?? []).map(\.id))
        return baselinedUIDs.contains(uid) && PDDAXVisibleMessageEvidence.extract(root: tree.rootSnapshot)
            .messages.contains { $0.sender == .customer && !known.contains($0.id) }
    }

    private func pendingRow(_ task: PDDPendingDiscovery, in rows: [PDDConversationRow<AXElementToken>]) -> PDDConversationRow<AXElementToken>? {
        if let id = task.locator.normalizedIdentifier {
            return rows.first { $0.domIdentifier == id }
        }
        let exact = rows.filter { $0.visibleLabel.trimmingCharacters(in: .whitespacesAndNewlines) == task.locator.normalizedNickname }
        if exact.indices.contains(task.occurrence) { return exact[task.occurrence] }
        let compatible = rows.filter { pendingLocatorMatches(task.locator, .init(domIdentifier: $0.domIdentifier, nickname: $0.visibleLabel)) }
        return compatible.count == 1 ? compatible[0] : nil
    }

    private func pendingLocatorMatches(_ left: PDDConversationLocator, _ right: PDDConversationLocator) -> Bool {
        if let l = left.normalizedIdentifier, let r = right.normalizedIdentifier { return l == r }
        return left.couldBeSameDisplayedCustomer(as: right)
    }

    private func discoveryLog(_ kind: String, uid: String? = nil, detail: String = "") {
        AutomationStepLog.record(root: chatStore.rootDirectory, uid: uid, step: kind, detail: detail)
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
        // Reconcile a proven split before checking expected target ownership.
        // This never presses a control or relies on a nickname alone.
        _ = try? knownConversationUID(in: tree)
        let canonical = try identities.canonicalUID(uid)
        if canonical != uid { throw PDDAXConversationDriverError.identityRedirect(uid, canonical) }
        if let owner = try identities.owner(messageIDs: expectedCustomerMessageIDs.filter { !$0.hasPrefix(FrozenCustomerBatch.incomingHandoffPrefix) },
            boundary: expectedCustomerMessageIDs.first { $0.hasPrefix(FrozenCustomerBatch.incomingHandoffPrefix) }.map { String($0.dropFirst(FrozenCustomerBatch.incomingHandoffPrefix.count)) }), owner != uid {
            throw PDDAXConversationDriverError.identityRedirect(uid, owner)
        }
        if PDDCustomerIdentity.resolve(from: tree.rootSnapshot) == uid { return tree }
        if uid.hasPrefix("PDD-"), let locator = conversationLocatorsByUID[uid] {
            if let reason = recipientVerificationReason(uid: uid, expectedCustomerMessageIDs: expectedCustomerMessageIDs, in: tree),
               isReadableChatSurface(tree) {
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
                tree = try await waitForRecipient(uid: uid, expected: expectedCustomerMessageIDs)
                if let reason = recipientVerificationReason(uid: uid, expectedCustomerMessageIDs: expectedCustomerMessageIDs, in: tree),
                   isReadableChatSurface(tree) {
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
                tree = try await waitForRecipient(uid: uid, expected: expectedCustomerMessageIDs)
                // An expired row identifier can refresh only when actual
                // customer-message evidence independently identifies the chat.
                let previousLocator = conversationLocatorsByUID[uid]
                if let refreshed = selected.domIdentifier, refreshed != locator.domIdentifier,
                   containsTargetMessage(expectedCustomerMessageIDs, uid: uid, in: tree.rootSnapshot) {
                    conversationLocatorsByUID[uid]?.domIdentifier = refreshed
                }
                if let reason = recipientVerificationReason(uid: uid, expectedCustomerMessageIDs: expectedCustomerMessageIDs, in: tree),
                   isReadableChatSurface(tree) {
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
            tree = try await waitForRecipient(uid: uid, expected: expectedCustomerMessageIDs)
            if PDDCustomerIdentity.resolve(from: tree.rootSnapshot) == uid { return tree }
        }
        throw PDDAXConversationDriverError.uidNotFound(uid)
    }

    private func waitForRecipient(uid: String, expected: Set<String>) async throws -> PDDAXSemanticTree {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(1500))
        var tree = try backend.readSemanticTree()
        while true {
            try Task.checkCancellation()
            // A loaded but wrong candidate must be rejected by the caller,
            // not polled until it accidentally becomes a different candidate.
            if PDDAXCaptureSurface.hasReadableMessages(in: tree)
                || PDDCustomerIdentity.resolve(from: tree.rootSnapshot) != nil
                || PDDAXIncomingTransfer.unansweredHandoff(in: tree.rootSnapshot) != nil { return tree }
            let proof = recipientVerificationReason(uid: uid, expectedCustomerMessageIDs: expected, in: tree)
            if proof == "ax-conversation-id" || (!expected.isEmpty && proof != nil) { return tree }
            if ContinuousClock.now >= deadline { return tree }
            try await Task.sleep(nanoseconds: 120_000_000)
            tree = try backend.readSemanticTree()
        }
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
        let actual = customerIDs(in: tree)
        let record = PDDAXIncomingTransfer.incomingRecord(in: tree.rootSnapshot)
        do {
            if let owner = try identities.owner(messageIDs: actual, boundary: record?.identityBoundaryKey), owner != uid { return nil }
            if let owner = try identities.owner(boundary: record?.identityBoundaryKey), owner == uid,
               record?.identityBoundaryKey != nil, isReadableChatSurface(tree) { return "ax-incoming-transfer-identity" }
        } catch { return nil }
        let known = (try? identities.anchors(uid: uid)) ?? []
        return PDDAXRecipientVerification.reason(uid: uid, locator: conversationLocatorsByUID[uid],
            expectedAXMessageIDs: expectedCustomerMessageIDs.union(aliases).union(known), tree: tree)
    }

    private func logRecipientVerification(uid: String, reason: String, tree: PDDAXSemanticTree) {
        if let current = try? refreshedLocator(in: tree),
           ["ax-customer-message-id", "ax-incoming-transfer-identity", "ax-conversation-id"].contains(reason)
                || current.normalizedNickname == conversationLocatorsByUID[uid]?.normalizedNickname {
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

    private func customerIDs(in tree: PDDAXSemanticTree) -> Set<String> {
        Set(PDDChatParser.parse(root: tree.rootSnapshot).messages.filter { $0.sender == .customer }.map(\.id))
    }

    private func refreshedLocator(in tree: PDDAXSemanticTree) throws -> PDDConversationLocator? {
        if let current = PDDConversationSnapshotLocator.current(in: tree.rootSnapshot) { return current }
        return try PDDAXControlSelection.currentConversationRow(in: tree.nodes).map {
            PDDConversationLocator(domIdentifier: $0.domIdentifier, nickname: $0.visibleLabel)
        }
    }

    private func resolveDiscoveredUID(in tree: PDDAXSemanticTree, locator: PDDConversationLocator, task: PDDPendingDiscovery? = nil) throws -> String? {
        let ids = customerIDs(in: tree)
        let incoming = PDDAXIncomingTransfer.incomingRecord(in: tree.rootSnapshot)
        let boundary = incoming?.identityBoundaryKey
        let uid: String
        if let known = try knownConversationUID(in: tree) { uid = known }
        else if let stable = locator.normalizedIdentifier { uid = PDDConversationKey.make(locator: .init(domIdentifier: stable, nickname: locator.nickname)) }
        else if incoming != nil && ids.isEmpty {
            recordCaptureDiagnostic("handoff-without-message-identity", task: task, tree: tree)
            return nil
        }
        else if !ids.isEmpty {
            let labelKey = PDDConversationKey.make(locator: locator)
            let previous = try chatStore.loadAXFirst(uid: labelKey)
            if !PDDConversationIdentityStore.generic(locator.nickname), previous.isEmpty,
               (try identities.anchors(uid: labelKey)).isEmpty {
                uid = labelKey
            } else {
                // An occupied masked label plus a disjoint one-message AX read
                // is unresolved, not immediate evidence of a second customer.
                let key = PDDConversationIdentityStore.anchoredUID(messageIDs: ids, boundary: boundary)
                let waitKey = task?.id.uuidString ?? "locator:\(locator.normalizedIdentifier ?? locator.normalizedNickname)"
                if !PDDConversationIdentityStore.generic(locator.nickname), boundary == nil {
                    let prior = unresolvedSnapshots[waitKey]
                    let since = task?.firstSeenAt ?? prior?.since ?? now()
                    let observations = max(prior?.observations ?? 0, (task?.attempts ?? 1) - 1)
                    unresolvedSnapshots[waitKey] = (since, observations + 1)
                    guard now().timeIntervalSince(since) >= 30, observations >= 1 else {
                        recordCaptureDiagnostic("waiting-for-message-anchors", task: task, tree: tree)
                        return nil
                    }
                }
                uid = key
            }
        } else if !PDDConversationIdentityStore.generic(locator.nickname),
                  (try chatStore.loadAXFirst(uid: PDDConversationKey.make(locator: locator))).isEmpty {
            // Empty named rows may be discovered, but cannot trigger a customer turn.
            uid = PDDConversationKey.make(locator: locator)
        } else {
            recordCaptureDiagnostic("no-message-identity", task: task, tree: tree)
            return nil
        }
        let legacy = PDDCustomerIdentity.resolve(from: tree.rootSnapshot)
        let emptyHistory = try chatStore.loadAXFirst(uid: uid).isEmpty
        guard PDDAXRecipientVerification.reason(uid: uid, locator: locator, expectedAXMessageIDs: ids, tree: tree) != nil
            || (boundary != nil && isReadableChatSurface(tree))
            || (locator.normalizedIdentifier != nil && isReadableChatSurface(tree))
            || (legacy != nil && !PDDConversationIdentityStore.generic(locator.nickname))
            || (ids.isEmpty && boundary == nil && !PDDConversationIdentityStore.generic(locator.nickname)
                && emptyHistory && isReadableChatSurface(tree)) else {
            recordCaptureDiagnostic("recipient-proof-rejected", task: task, tree: tree)
            return nil
        }
        if isReadableChatSurface(tree), legacy == nil {
            try identities.remember(uid: uid, messageIDs: ids, stableID: locator.normalizedIdentifier, boundary: boundary,
                provisional: uid.hasPrefix("PDD-CHAT-") && locator.normalizedIdentifier == nil && boundary == nil, at: now())
        }
        return uid
    }

    private func resolveForDiscovery(in tree: PDDAXSemanticTree, locator: PDDConversationLocator, task: PDDPendingDiscovery? = nil) throws -> String? {
        do { return try resolveDiscoveredUID(in: tree, locator: locator, task: task) }
        catch PDDConversationIdentityStore.IdentityError.conflictingEvidence {
            recordCaptureDiagnostic("conflicting-owner-evidence", task: task, tree: tree)
            noteSettling(key: task?.id.uuidString ?? "locator:\(locator.normalizedIdentifier ?? locator.normalizedNickname)", label: locator.nickname)
            return nil
        }
    }

    /// Used by the stopped app's read-only check. Reads the supplied current
    /// tree only; it never opens a conversation, generates, or sends a message.
    func reconcileVisibleIdentity(in tree: PDDAXSemanticTree) throws {
        recordCaptureDiagnostic("visible-read-check", task: nil, tree: tree)
        guard let uid = try knownConversationUID(in: tree),
              let locator = try refreshedLocator(in: tree) else { return }
        rememberLocator(locator, uid: uid)
    }

    private func noteSettling(key: String, label: String) {
        let date = now()
        if settlingSince[key] == nil {
            settlingSince[key] = date
            conversationDiagnostics.append(.init(uid: "identity-pending", kind: "conversation-identity-settling",
                detail: "已打开转入/访客会话，等候可核对身份；30秒宽限；其他客户继续 label=\(label)"))
        }
        if date.timeIntervalSince(settlingSince[key] ?? date) >= 30, settlingAttention.insert(key).inserted {
            conversationDiagnostics.append(.init(uid: "identity-pending", kind: "conversation-identity-attention",
                detail: "会话身份超过30秒仍未核对；保留待处理，继续轮询其他客户，不按游客名称创建客户"))
        }
    }

    private func knownConversationUID(in tree: PDDAXSemanticTree) throws -> String? {
        let actual = Set(PDDChatParser.parse(root: tree.rootSnapshot).messages.filter { $0.sender == .customer }.map(\.id))
        let record = PDDAXIncomingTransfer.incomingRecord(in: tree.rootSnapshot)
        let stable = try refreshedLocator(in: tree)?.normalizedIdentifier
        do {
            if let owner = try identities.owner(messageIDs: actual, stableID: stable, boundary: record?.identityBoundaryKey) {
                try persistVerifiedRepairHistory(uid: owner, actual: actual, tree: tree)
                return owner
            }
        } catch PDDConversationIdentityStore.IdentityError.conflictingEvidence {
            guard hasSingleActiveChat(tree),
                  let repair = try identities.reconcileVerifiedThread(messageIDs: actual, stableID: stable,
                    boundary: record?.identityBoundaryKey) else { throw PDDConversationIdentityStore.IdentityError.conflictingEvidence }
            try persistVerifiedRepairHistory(uid: repair.canonicalUID, actual: actual, tree: tree)
            return repair.canonicalUID
        }
        guard !actual.isEmpty else { return nil }
        // Older versions could split one chat into several masked-name folders.
        // Prefer the established history when the same exact AX IDs occur in
        // those aliases. No fuzzy text/name match is used to select a recipient.
        let matches = conversationLocatorsByUID.compactMap { uid, locator -> (String, Int, Int)? in
            guard !PDDConversationIdentityStore.isSharedVisitorUID(uid),
                  let history = try? chatStore.loadAXFirst(uid: uid) else { return nil }
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

    private func hasSingleActiveChat(_ tree: PDDAXSemanticTree) -> Bool {
        guard isReadableChatSurface(tree) else { return false }
        let semantic = ((try? PDDAXControlSelection.conversationRows(in: tree.nodes)) ?? []).filter { row in
            tree.nodes.contains { $0.id == row.rowID && $0.domClasses.contains { $0 == "active" || $0.contains("selected") } }
        }.count
        let snapshot = PDDConversationSnapshotLocator.activeCount(in: tree.rootSnapshot)
        guard let locator = try? refreshedLocator(in: tree) else { return false }
        return max(semantic, snapshot) == 1
            && PDDAXRecipientVerification.reason(uid: PDDConversationKey.make(locator: locator),
                locator: locator, expectedAXMessageIDs: customerIDs(in: tree), tree: tree) != nil
    }

    private func persistVerifiedRepairHistory(uid: String, actual: Set<String>, tree: PDDAXSemanticTree) throws {
        let proof = try identities.repairProof(uid: uid)
        guard !proof.isEmpty, proof.isSubset(of: actual), hasSingleActiveChat(tree) else { return }
        let history = try chatStore.loadAXFirst(uid: uid)
        guard !proof.isSubset(of: Set(history.filter { $0.sender == .customer }.map(\.id))) else { return }
        _ = try chatStore.mergeAXFirst(uid: uid, messages: PDDChatParser.parse(root: tree.rootSnapshot).messages)
        AutomationStepLog.record(root: chatStore.rootDirectory, uid: uid, step: "identity-recovery-current-thread-captured",
            detail: "verified_message_ids=\(actual.sorted().joined(separator: ",")); current AX only; no folder merge")
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
        if let uid = try? knownConversationUID(in: tree), let known = conversationLocatorsByUID[uid], !locators.contains(known) {
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
        if let owner = try identities.owner(messageIDs: Set(evidence.messages.filter { $0.sender == .customer }.map(\.id))), owner != uid {
            throw PDDAXConversationDriverError.identityRedirect(uid, owner)
        }
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
            enrichAttachments: false, useInbox: false
        )
    }

    func preflight(
        uid: String,
        after cursor: AutoReplyCursor,
        lease: UIOperationLease
    ) async throws -> AutoReplyCapture {
        try await capture(
            uid: uid, after: cursor, lease: Optional(lease), allowOCR: false,
            enrichAttachments: false, useInbox: false
        )
    }

    private func capture(
        uid: String,
        after cursor: AutoReplyCursor,
        lease: UIOperationLease?,
        allowOCR: Bool,
        enrichAttachments: Bool,
        useInbox: Bool = true,
        includeImages: Bool = true,
        onlyVideoMessageID: String? = nil
    ) async throws -> AutoReplyCapture {
        AutomationStepLog.record(root: chatStore.rootDirectory, uid: uid, step: "capture-started")
        let staged = useInbox ? try pendingInboxEntries(includeReceiptRecovery: true).first(where: { $0.uid == uid }) : nil
        var needsLiveMedia = onlyVideoMessageID != nil
        if let staged, enrichAttachments {
            let combined = PDDVerifiedCaptureInbox.merging(try chatStore.loadAXFirst(uid: uid), staged.messages)
            let timeline = try AutoReplyTimeline.make(messages: combined)
            let prefix = Array(combined.prefix((combined.lastIndex { $0.sender == .service }).map { $0 + 1 } ?? 0))
            let serviceCursor = try AutoReplyTimeline.make(messages: prefix).cursor
            let start = !baselinedUIDs.contains(uid) && cursor == .empty ? serviceCursor : cursor
            let mediaBatch: FrozenCustomerBatch?
            do { mediaBatch = try timeline.freeze(after: start) }
            catch AutoReplyTimelineError.invalidPrefix {
                // Match the capture cursor recovery below; never skip media
                // merely because the old cursor is no longer a valid prefix.
                guard let recovered = timeline.prefixCursor(at: min(start.count, serviceCursor.count)) else { throw AutoReplyTimelineError.invalidPrefix }
                mediaBatch = try timeline.freeze(after: recovered)
            }
            needsLiveMedia = needsLiveMedia || mediaBatch?.events.contains { $0.kind == .image || $0.kind == .video } == true
        }
        var openedTree: PDDAXSemanticTree
        if let staged, !needsLiveMedia {
            let canonical = try identities.canonicalUID(uid)
            guard canonical == uid else { throw PDDAXConversationDriverError.identityRedirect(uid, canonical) }
            guard isAllowed(uid) else { throw PDDAXConversationDriverError.uidNotAllowed(uid) }
            openedTree = .init(rootSnapshot: staged.snapshot.replay, nodes: [])
            if staged.unread { unreadUIDs.insert(uid) }
            discoveryLog("capture-using-verified-inbox", uid: uid, detail: "no chat selection; live send verification remains required")
        } else {
            openedTree = try await openAndResolve(uid: uid)
        }
        let record = PDDAXIncomingTransfer.incomingRecord(in: openedTree.rootSnapshot)
        if uid.hasPrefix("PDD-"), isReadableChatSurface(openedTree) {
            try identities.remember(uid: uid, messageIDs: customerIDs(in: openedTree),
                stableID: try refreshedLocator(in: openedTree)?.normalizedIdentifier, boundary: record?.identityBoundaryKey)
        }
        let hasUnreadEvidence = unreadUIDs.contains(uid)
        var capturedAt = Date()
        var evidence = authoritativeEvidence(in: openedTree, capturedAt: capturedAt)
        if let staged {
            let live = evidence.isStructurallyValid ? evidence.messages : []
            let messages = PDDVerifiedCaptureInbox.merging(staged.messages, live)
            evidence = .init(messageNodeCount: messages.count, messages: messages, diagnostics: [],
                fingerprint: PDDAXVisibleMessageEvidence.extract(root: staged.snapshot.replay).fingerprint,
                isStructurallyValid: !messages.isEmpty)
        }
        let existingAXFirst = try chatStore.loadAXFirst(uid: uid)
        let existingIDs = Set(existingAXFirst.map(\.id))
        handledHandoffsByUID.removeValue(forKey: uid)
        if let record {
            let closed = try await CustomerTransferPolicyStore.shared.closedMessageIDs(root: chatStore.rootDirectory, uid: uid)
            if record.hasServiceReply || closed.contains(FrozenCustomerBatch.incomingHandoffPrefix + record.handoff.boundaryKey) {
                handledHandoffsByUID[uid] = record.handoff.boundaryKey
            }
        }
        var provisionalMessage: PDDChatMessage?
        var sourceDiagnostic: String

        sourceLoop: while true {
            if staged != nil, evidence.isStructurallyValid {
                sourceDiagnostic = "AX 权威读取：已验证的持久化消息 \(evidence.messages.count) 条"
                break sourceLoop
            }
            // The trusted platform notice is actionable even when chat history
            // has not loaded; do not wait for OCR to manufacture a customer turn.
            if PDDAXIncomingTransfer.unansweredHandoff(in: openedTree.rootSnapshot) != nil {
                sourceDiagnostic = "AX 平台转入事件：\(evidence.messages.count) 条可见历史消息"
                break sourceLoop
            }
            if handledHandoffsByUID[uid] != nil, evidence.isStructurallyValid,
               evidence.messages.allSatisfy({ existingIDs.contains($0.id) || $0.sender == .service }) {
                sourceDiagnostic = "AX 已确认转入已处理；没有新客户消息"
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

    private func isReadableChatSurface(_ tree: PDDAXSemanticTree) -> Bool {
        (try? PDDAXControlSelection.composer(in: tree.nodes)) != nil
            || PDDAXCaptureSurface.hasReadableMessages(in: tree)
    }

    private func authoritativeEvidence(
        in tree: PDDAXSemanticTree,
        capturedAt: Date
    ) -> PDDAXVisibleMessageEvidence {
        let evidence = PDDAXVisibleMessageEvidence.extract(
            root: tree.rootSnapshot,
            capturedAt: capturedAt
        )
        guard isReadableChatSurface(tree) else {
            return PDDAXVisibleMessageEvidence(
                messageNodeCount: evidence.messageNodeCount,
                messages: evidence.messages,
                diagnostics: evidence.diagnostics + ["可核对聊天消息区域缺失；输入区也不可用"],
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
