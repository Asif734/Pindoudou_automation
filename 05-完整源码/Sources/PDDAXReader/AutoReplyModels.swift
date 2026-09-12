import Foundation

enum AutoReplyJobState: String, Codable, Equatable, Sendable {
    case discovered
    case capturing
    case queued
    case generating
    case ready
    case sending
    case completed
    case failed
    case uncertain
    case quarantined
}

enum AutoReplyDeliveryOutcome: String, Codable, Equatable, Sendable {
    case sent
    case notSent
    case uncertain
}

struct AutoReplyCapture: Codable, Equatable, Sendable {
    let uid: String
    let fullHistory: [PDDChatMessage]
    let batch: FrozenCustomerBatch?
    let customerCursor: AutoReplyCursor
    let unexpectedServiceMessageIDs: [String]
    var knowledgeEvidence: KnowledgeEvidence? = nil
    var ocrDiagnostic: String? = nil
    var imageAttachments: [AutoReplyImageAttachment] = []
    var videoAttachments: [AutoReplyVideoAttachment] = []
    var pendingVideoMessageIDs: [String] = []

    init(
        uid: String,
        fullHistory: [PDDChatMessage],
        batch: FrozenCustomerBatch?,
        customerCursor: AutoReplyCursor,
        unexpectedServiceMessageIDs: [String],
        knowledgeEvidence: KnowledgeEvidence? = nil,
        ocrDiagnostic: String? = nil,
        imageAttachments: [AutoReplyImageAttachment] = [],
        videoAttachments: [AutoReplyVideoAttachment] = [],
        pendingVideoMessageIDs: [String] = []
    ) {
        self.uid = uid
        self.fullHistory = fullHistory
        self.batch = batch
        self.customerCursor = customerCursor
        self.unexpectedServiceMessageIDs = unexpectedServiceMessageIDs
        self.knowledgeEvidence = knowledgeEvidence
        self.ocrDiagnostic = ocrDiagnostic
        self.imageAttachments = imageAttachments
        self.videoAttachments = videoAttachments
        self.pendingVideoMessageIDs = pendingVideoMessageIDs
    }

    private enum CodingKeys: String, CodingKey {
        case uid, fullHistory, batch, customerCursor, unexpectedServiceMessageIDs
        case knowledgeEvidence, ocrDiagnostic, imageAttachments, videoAttachments
        case pendingVideoMessageIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        fullHistory = try container.decode([PDDChatMessage].self, forKey: .fullHistory)
        batch = try container.decodeIfPresent(FrozenCustomerBatch.self, forKey: .batch)
        customerCursor = try container.decode(AutoReplyCursor.self, forKey: .customerCursor)
        unexpectedServiceMessageIDs = try container.decodeIfPresent(
            [String].self, forKey: .unexpectedServiceMessageIDs
        ) ?? []
        knowledgeEvidence = try container.decodeIfPresent(
            KnowledgeEvidence.self, forKey: .knowledgeEvidence
        )
        ocrDiagnostic = try container.decodeIfPresent(String.self, forKey: .ocrDiagnostic)
        imageAttachments = try container.decodeIfPresent(
            [AutoReplyImageAttachment].self, forKey: .imageAttachments
        ) ?? []
        videoAttachments = try container.decodeIfPresent(
            [AutoReplyVideoAttachment].self, forKey: .videoAttachments
        ) ?? []
        pendingVideoMessageIDs = try container.decodeIfPresent(
            [String].self, forKey: .pendingVideoMessageIDs
        ) ?? []
    }
}

struct AutoReplyImageAttachment: Codable, Equatable, Sendable {
    let messageID: String
    let sourceURL: URL
    let localURL: URL
    let mimeType: String
    let byteCount: Int
    let sha256: String
}

struct AutoReplyVideoFrame: Codable, Equatable, Sendable {
    let timestampSeconds: Double
    let localURL: URL
}

struct AutoReplyVideoAttachment: Codable, Equatable, Sendable {
    let messageID: String
    let localURL: URL
    let sha256: String
    let byteCount: Int64
    let durationSeconds: Double
    let width: Int
    let height: Int
    let videoCodec: String
    let audioCodec: String?
    let frames: [AutoReplyVideoFrame]
    let transcript: String?
    let transcriptSegments: [PDDVideoTranscriptSegment]
    let diagnostic: String?
    let audioLocalURL: URL?
    let manifestLocalURL: URL?

    private enum CodingKeys: String, CodingKey {
        case messageID, localURL, sha256, byteCount, durationSeconds, width, height
        case videoCodec, audioCodec, frames, transcript, transcriptSegments, diagnostic
        case audioLocalURL, manifestLocalURL
    }

    init(
        messageID: String,
        localURL: URL,
        sha256: String,
        byteCount: Int64,
        durationSeconds: Double,
        width: Int,
        height: Int,
        videoCodec: String,
        audioCodec: String?,
        frames: [AutoReplyVideoFrame],
        transcript: String?,
        transcriptSegments: [PDDVideoTranscriptSegment] = [],
        diagnostic: String?,
        audioLocalURL: URL? = nil,
        manifestLocalURL: URL? = nil
    ) {
        self.messageID = messageID
        self.localURL = localURL
        self.sha256 = sha256
        self.byteCount = byteCount
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.frames = frames
        self.transcript = transcript
        self.transcriptSegments = transcriptSegments
        self.diagnostic = diagnostic
        self.audioLocalURL = audioLocalURL
        self.manifestLocalURL = manifestLocalURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageID = try container.decode(String.self, forKey: .messageID)
        localURL = try container.decode(URL.self, forKey: .localURL)
        sha256 = try container.decode(String.self, forKey: .sha256)
        byteCount = try container.decode(Int64.self, forKey: .byteCount)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        videoCodec = try container.decode(String.self, forKey: .videoCodec)
        audioCodec = try container.decodeIfPresent(String.self, forKey: .audioCodec)
        frames = try container.decodeIfPresent([AutoReplyVideoFrame].self, forKey: .frames) ?? []
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
        transcriptSegments = try container.decodeIfPresent(
            [PDDVideoTranscriptSegment].self, forKey: .transcriptSegments
        ) ?? []
        diagnostic = try container.decodeIfPresent(String.self, forKey: .diagnostic)
        audioLocalURL = try container.decodeIfPresent(URL.self, forKey: .audioLocalURL)
        manifestLocalURL = try container.decodeIfPresent(URL.self, forKey: .manifestLocalURL)
    }
}

struct AutoReplyJob: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let uid: String
    var sequence: Int
    var state: AutoReplyJobState
    let capture: AutoReplyCapture
    var reply: String?
    var generationDiagnostic: AutoReplyGenerationDiagnostic? = nil
    var deliveryOutcome: AutoReplyDeliveryOutcome?
    var confirmedServiceMessageID: String?
    var retries: Int
    var nextAttemptAt: Date?
    var lastError: String?
    var customerRevision: Int
    var revision: AutoReplyRevision
    var stageAttempt: Int
    var imageAttachments: [AutoReplyImageAttachment]
    var videoAttachments: [AutoReplyVideoAttachment]
    var durableAttemptOperationID: UUID?
    var sendWasInvoked: Bool
    var pendingSupplement: AutoReplyCapture?
    var supplementCapturePending: Bool
    var imageCaptureAttempted: Bool
    var replyAction: CodexReplyAction
    var transferReason: CodexTransferReason

    init(
        id: UUID,
        uid: String,
        sequence: Int,
        state: AutoReplyJobState,
        capture: AutoReplyCapture,
        reply: String?,
        generationDiagnostic: AutoReplyGenerationDiagnostic? = nil,
        deliveryOutcome: AutoReplyDeliveryOutcome?,
        confirmedServiceMessageID: String?,
        retries: Int,
        nextAttemptAt: Date?,
        lastError: String?,
        customerRevision: Int = 1,
        revision: AutoReplyRevision? = nil,
        stageAttempt: Int = 0,
        imageAttachments: [AutoReplyImageAttachment] = [],
        videoAttachments: [AutoReplyVideoAttachment] = [],
        durableAttemptOperationID: UUID? = nil,
        sendWasInvoked: Bool = false,
        pendingSupplement: AutoReplyCapture? = nil,
        supplementCapturePending: Bool = false,
        imageCaptureAttempted: Bool = false,
        replyAction: CodexReplyAction = .reply,
        transferReason: CodexTransferReason = .none
    ) {
        self.id = id
        self.uid = uid
        self.sequence = sequence
        self.state = state
        self.capture = capture
        self.reply = reply
        self.generationDiagnostic = generationDiagnostic
        self.deliveryOutcome = deliveryOutcome
        self.confirmedServiceMessageID = confirmedServiceMessageID
        self.retries = retries
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.customerRevision = customerRevision
        self.revision = revision ?? (try! AutoReplyRevision.derived(
            from: capture, legacyOrdinal: customerRevision
        ))
        self.stageAttempt = stageAttempt
        self.imageAttachments = imageAttachments
        self.videoAttachments = videoAttachments
        self.durableAttemptOperationID = durableAttemptOperationID
        self.sendWasInvoked = sendWasInvoked
        self.pendingSupplement = pendingSupplement
        self.supplementCapturePending = supplementCapturePending
        self.imageCaptureAttempted = imageCaptureAttempted
        self.replyAction = replyAction
        self.transferReason = transferReason
    }

    private enum CodingKeys: String, CodingKey {
        case id, uid, sequence, state, capture, reply, generationDiagnostic
        case deliveryOutcome, confirmedServiceMessageID, retries, nextAttemptAt, lastError
        case customerRevision, stageAttempt, imageAttachments, videoAttachments, durableAttemptOperationID
        case sendWasInvoked, revision, pendingSupplement, supplementCapturePending
        case imageCaptureAttempted
        case replyAction, transferReason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        uid = try container.decode(String.self, forKey: .uid)
        sequence = try container.decode(Int.self, forKey: .sequence)
        state = try container.decode(AutoReplyJobState.self, forKey: .state)
        capture = try container.decode(AutoReplyCapture.self, forKey: .capture)
        reply = try container.decodeIfPresent(String.self, forKey: .reply)
        generationDiagnostic = try container.decodeIfPresent(
            AutoReplyGenerationDiagnostic.self, forKey: .generationDiagnostic
        )
        deliveryOutcome = try container.decodeIfPresent(
            AutoReplyDeliveryOutcome.self, forKey: .deliveryOutcome
        )
        confirmedServiceMessageID = try container.decodeIfPresent(
            String.self, forKey: .confirmedServiceMessageID
        )
        retries = try container.decodeIfPresent(Int.self, forKey: .retries) ?? 0
        nextAttemptAt = try container.decodeIfPresent(Date.self, forKey: .nextAttemptAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        customerRevision = try container.decodeIfPresent(Int.self, forKey: .customerRevision) ?? 1
        revision = try container.decodeIfPresent(AutoReplyRevision.self, forKey: .revision)
            ?? AutoReplyRevision.derived(from: capture, legacyOrdinal: customerRevision)
        stageAttempt = try container.decodeIfPresent(Int.self, forKey: .stageAttempt) ?? 0
        imageAttachments = try container.decodeIfPresent(
            [AutoReplyImageAttachment].self, forKey: .imageAttachments
        ) ?? []
        videoAttachments = try container.decodeIfPresent(
            [AutoReplyVideoAttachment].self, forKey: .videoAttachments
        ) ?? []
        durableAttemptOperationID = try container.decodeIfPresent(
            UUID.self, forKey: .durableAttemptOperationID
        )
        sendWasInvoked = try container.decodeIfPresent(Bool.self, forKey: .sendWasInvoked) ?? false
        pendingSupplement = try container.decodeIfPresent(
            AutoReplyCapture.self, forKey: .pendingSupplement
        )
        supplementCapturePending = try container.decodeIfPresent(
            Bool.self, forKey: .supplementCapturePending
        ) ?? false
        imageCaptureAttempted = try container.decodeIfPresent(
            Bool.self, forKey: .imageCaptureAttempted
        ) ?? false
        replyAction = try container.decodeIfPresent(
            CodexReplyAction.self, forKey: .replyAction
        ) ?? .reply
        transferReason = try container.decodeIfPresent(
            CodexTransferReason.self, forKey: .transferReason
        ) ?? .none
    }
}

enum AutoReplyTransferTaskState: String, Codable, Equatable, Sendable {
    case placeholderPending = "placeholder_pending"
    case pending
    case completed
    case failed
}

struct AutoReplyTransferTask: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let sourceJobID: UUID
    let uid: String
    let revision: AutoReplyRevision
    let reason: CodexTransferReason
    var state: AutoReplyTransferTaskState
    let createdAt: Date
}

struct AutoReplyEvent: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let uid: String?
    let kind: String
    let detail: String
}

enum AutoReplyCaptureRequestKind: String, Codable, Equatable, Sendable {
    case ordinary
    case supplement
    case tail
    case videoRecovery
}

struct AutoReplyCaptureRequest: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let uid: String
    let kind: AutoReplyCaptureRequestKind
    let baseCursor: AutoReplyCursor
    let tailAttempt: Int?
    let sourceJobID: UUID?
    let videoMessageID: String?

    init(
        id: UUID = UUID(),
        uid: String,
        kind: AutoReplyCaptureRequestKind,
        baseCursor: AutoReplyCursor,
        tailAttempt: Int? = nil,
        sourceJobID: UUID? = nil,
        videoMessageID: String? = nil
    ) {
        self.id = id
        self.uid = uid
        self.kind = kind
        self.baseCursor = baseCursor
        self.tailAttempt = tailAttempt
        self.sourceJobID = sourceJobID
        self.videoMessageID = videoMessageID
    }
}

struct PDDProvisionalReceipt: Codable, Equatable, Sendable {
    let provisionalMessageID: String
    let normalizedContent: String
    let firstObservedAt: Date
    var answered: Bool
    var absorbedAXMessageID: String?
}

struct AutoReplyPersistentState: Codable, Equatable, Sendable {
    var schemaVersion = 6
    var nextSequence = 0
    var jobs: [AutoReplyJob] = []
    var answeredCursors: [String: AutoReplyCursor] = [:]
    var baselinedUIDs: Set<String> = []
    var knownServiceMessageIDsByUID: [String: Set<String>] = [:]
    var confirmedAutoReplyMessageIDsByUID: [String: Set<String>] = [:]
    var events: [AutoReplyEvent] = []
    var consecutiveDeliveryCount = 0
    var pendingCaptureRequests: [AutoReplyCaptureRequest] = []
    var conversationLocatorsByUID: [String: PDDConversationLocator] = [:]
    var axFirstBaselinedUIDs: Set<String> = []
    var provisionalReceiptsByUID: [String: [PDDProvisionalReceipt]] = [:]
    var messageSourceSelectorStatesByUID: [String: PDDMessageSourceSelectorState] = [:]
    var pendingVideoBatches: [PDDPendingVideoBatch] = []
    var deferredVideoTransferEvents: [PDDVideoTransferEvent] = []
    var transferTasks: [AutoReplyTransferTask] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, nextSequence, jobs, answeredCursors, baselinedUIDs
        case knownServiceMessageIDsByUID, confirmedAutoReplyMessageIDsByUID, events
        case consecutiveDeliveryCount, pendingCaptureRequests
        case conversationLocatorsByUID
        case axFirstBaselinedUIDs, provisionalReceiptsByUID
        case messageSourceSelectorStatesByUID
        case pendingVideoBatches, deferredVideoTransferEvents
        case transferTasks
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        nextSequence = try container.decodeIfPresent(Int.self, forKey: .nextSequence) ?? 0
        jobs = try container.decodeIfPresent([AutoReplyJob].self, forKey: .jobs) ?? []
        answeredCursors = try container.decodeIfPresent(
            [String: AutoReplyCursor].self, forKey: .answeredCursors
        ) ?? [:]
        baselinedUIDs = try container.decodeIfPresent(Set<String>.self, forKey: .baselinedUIDs) ?? []
        knownServiceMessageIDsByUID = try container.decodeIfPresent(
            [String: Set<String>].self, forKey: .knownServiceMessageIDsByUID
        ) ?? [:]
        confirmedAutoReplyMessageIDsByUID = try container.decodeIfPresent(
            [String: Set<String>].self, forKey: .confirmedAutoReplyMessageIDsByUID
        ) ?? [:]
        events = try container.decodeIfPresent([AutoReplyEvent].self, forKey: .events) ?? []
        consecutiveDeliveryCount = try container.decodeIfPresent(
            Int.self, forKey: .consecutiveDeliveryCount
        ) ?? 0
        pendingCaptureRequests = try container.decodeIfPresent(
            [AutoReplyCaptureRequest].self, forKey: .pendingCaptureRequests
        ) ?? []
        conversationLocatorsByUID = try container.decodeIfPresent(
            [String: PDDConversationLocator].self, forKey: .conversationLocatorsByUID
        ) ?? [:]
        axFirstBaselinedUIDs = try container.decodeIfPresent(
            Set<String>.self, forKey: .axFirstBaselinedUIDs
        ) ?? []
        provisionalReceiptsByUID = try container.decodeIfPresent(
            [String: [PDDProvisionalReceipt]].self, forKey: .provisionalReceiptsByUID
        ) ?? [:]
        messageSourceSelectorStatesByUID = try container.decodeIfPresent(
            [String: PDDMessageSourceSelectorState].self,
            forKey: .messageSourceSelectorStatesByUID
        ) ?? [:]
        pendingVideoBatches = try container.decodeIfPresent(
            [PDDPendingVideoBatch].self, forKey: .pendingVideoBatches
        ) ?? []
        deferredVideoTransferEvents = try container.decodeIfPresent(
            [PDDVideoTransferEvent].self, forKey: .deferredVideoTransferEvents
        ) ?? []
        transferTasks = try container.decodeIfPresent(
            [AutoReplyTransferTask].self, forKey: .transferTasks
        ) ?? []
    }

    static let empty = AutoReplyPersistentState()
}

extension AutoReplyPersistentState {
    /// Repairs an impossible live overlap for one customer without stopping
    /// unrelated customers. Waiting states are deliberately not conflicts.
    mutating func repairOverlappingExecutions(at date: Date) {
        let executing: Set<AutoReplyJobState> = [.capturing, .generating, .sending]
        let uids = Set(jobs.filter {
            ![.completed, .failed, .uncertain, .quarantined].contains($0.state)
        }.map(\.uid))
        for uid in uids {
            var indexes = jobs.indices.filter {
                jobs[$0].uid == uid && executing.contains(jobs[$0].state)
            }
            guard indexes.count > 1 else { continue }

            for index in indexes where jobs[index].state == .sending && jobs[index].sendWasInvoked {
                jobs[index].state = .completed
                jobs[index].deliveryOutcome = .uncertain
                jobs[index].nextAttemptAt = nil
                jobs[index].lastError = "同一客户执行冲突；发送调用已经发生，按结果不确定完成且不重发"
                _ = advanceSourceAndPromoteSupplement(at: index)
            }

            indexes = jobs.indices.filter {
                jobs[$0].uid == uid && executing.contains(jobs[$0].state)
            }
            if indexes.count > 1 {
                let keeper = indexes.min { lhs, rhs in
                    let left = Self.executionPriority(jobs[lhs].state)
                    let right = Self.executionPriority(jobs[rhs].state)
                    return left == right
                        ? jobs[lhs].sequence < jobs[rhs].sequence
                        : left > right
                }
                for index in indexes where index != keeper {
                    switch jobs[index].state {
                    case .sending: jobs[index].state = .ready
                    case .generating: jobs[index].state = .queued
                    case .capturing: jobs[index].state = .discovered
                    default: break
                    }
                    jobs[index].durableAttemptOperationID = nil
                    jobs[index].sendWasInvoked = false
                    jobs[index].nextAttemptAt = date
                    nextSequence += 1
                    jobs[index].sequence = nextSequence
                    jobs[index].lastError = "同一客户执行冲突；已按进度优先级移到队尾"
                }
            }
            events.append(AutoReplyEvent(
                id: UUID(), timestamp: date, uid: uid,
                kind: "execution-conflict-repaired",
                detail: "同一客户重叠执行已自动整理，其他客户继续运行"
            ))
        }
    }

    private static func executionPriority(_ state: AutoReplyJobState) -> Int {
        switch state {
        case .sending: return 3
        case .generating: return 2
        case .capturing: return 1
        default: return 0
        }
    }

    private static func normalizedVideoIdentity(_ value: String) -> String {
        for prefix in ["video-analysis:", "video:"] where value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return value
    }

    private func analyzedVideoIdentities(uid: String) -> Set<String> {
        Set(jobs.filter { $0.uid == uid }.flatMap { job in
            job.videoAttachments.flatMap { attachment in
                [
                    attachment.sha256,
                    Self.normalizedVideoIdentity(attachment.messageID)
                ]
            }
        }.filter { !$0.isEmpty })
    }

    private func removingCoveredVideoMarkers(
        from capture: AutoReplyCapture,
        uid: String
    ) -> AutoReplyCapture? {
        guard let batch = capture.batch else { return capture }
        let analyzed = analyzedVideoIdentities(uid: uid)
        guard !analyzed.isEmpty else { return capture }
        let retained = batch.events.filter { event in
            guard event.kind == .video else { return true }
            return !analyzed.contains(Self.normalizedVideoIdentity(event.messageID))
        }
        guard retained.count != batch.events.count else { return capture }
        guard !retained.isEmpty else { return nil }
        let retainedIDs = Set(retained.map(\.messageID))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let targetJSONL = retained.compactMap { event -> String? in
            guard let data = try? encoder.encode(event) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
        return AutoReplyCapture(
            uid: capture.uid,
            fullHistory: capture.fullHistory,
            batch: FrozenCustomerBatch(
                startCursor: batch.startCursor,
                endCursor: batch.endCursor,
                events: retained,
                targetCustomerJSONL: targetJSONL
            ),
            customerCursor: capture.customerCursor,
            unexpectedServiceMessageIDs: capture.unexpectedServiceMessageIDs,
            knowledgeEvidence: capture.knowledgeEvidence,
            ocrDiagnostic: capture.ocrDiagnostic,
            imageAttachments: capture.imageAttachments.filter {
                retainedIDs.contains($0.messageID)
            },
            videoAttachments: capture.videoAttachments.filter {
                retainedIDs.contains($0.messageID)
            },
            pendingVideoMessageIDs: capture.pendingVideoMessageIDs.filter {
                retainedIDs.contains($0)
            }
        )
    }

    /// Completes the source batch boundary and, when already captured, turns its
    /// durable supplement into the next queued revision. An in-flight supplement
    /// request remains bound to the terminal source job and is promoted when it lands.
    @discardableResult
    mutating func advanceSourceAndPromoteSupplement(at index: Int) -> Bool {
        guard jobs.indices.contains(index) else { return false }
        let source = jobs[index]
        if let end = source.capture.batch?.endCursor,
           end.count > (answeredCursors[source.uid]?.count ?? 0) {
            answeredCursors[source.uid] = end
        }
        guard let pending = source.pendingSupplement, pending.batch != nil else { return false }
        jobs[index].pendingSupplement = nil
        jobs[index].supplementCapturePending = false
        pendingCaptureRequests.removeAll { request in
            guard request.kind == .supplement, request.uid == source.uid else { return false }
            if request.sourceJobID == source.id { return true }
            return request.sourceJobID == nil
                && request.baseCursor == source.capture.batch?.endCursor
        }
        guard let capture = removingCoveredVideoMarkers(from: pending, uid: source.uid) else {
            return false
        }
        if !capture.pendingVideoMessageIDs.isEmpty {
            let alreadyPending = pendingVideoBatches.contains {
                $0.uid == source.uid
                    && $0.capture.batch?.endCursor == capture.batch?.endCursor
            }
            if !alreadyPending {
                pendingVideoBatches.append(PDDPendingVideoBatch(
                    uid: source.uid,
                    capture: capture,
                    expectedMessageIDs: capture.pendingVideoMessageIDs
                ))
            }
            return true
        }
        nextSequence += 1
        jobs.append(AutoReplyJob(
            id: UUID(),
            uid: source.uid,
            sequence: nextSequence,
            state: .queued,
            capture: capture,
            reply: nil,
            deliveryOutcome: nil,
            confirmedServiceMessageID: nil,
            retries: 0,
            nextAttemptAt: nil,
            lastError: nil,
            customerRevision: source.customerRevision + 1,
            imageAttachments: capture.imageAttachments,
            videoAttachments: capture.videoAttachments
        ))
        return true
    }
}
