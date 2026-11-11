import Foundation

/// Repairs work records using exact message/boundary proofs, never a folder-wide name merge.
enum PDDConversationIdentityRecovery {
    static func currentThreadCapture(canonicalUID: String, after cursor: AutoReplyCursor,
                                     jobs: [AutoReplyJob], root: URL, covered: Set<String> = []) throws -> AutoReplyCapture? {
        let history = try PerUserChatStore(rootDirectory: root).loadAXFirst(uid: canonicalUID)
        let ids = Set(history.filter { $0.sender == .customer }.map(\.id))
        let proof = try PDDConversationIdentityStore(root: root).repairProof(uid: canonicalUID)
        guard !proof.isEmpty, proof.isSubset(of: ids),
              jobs.allSatisfy({ $0.capture.batch?.incomingHandoffKey == nil }) else { return nil }
        let timeline = try AutoReplyTimeline.make(messages: history)
        guard timeline.validatesPrefix(cursor), let batch = try timeline.freeze(after: cursor) else { return nil }
        let targets = jobs.reduce(into: Set<String>()) {
            $0.formUnion($1.capture.batch?.customerMessageIDs ?? [])
            $0.formUnion($1.pendingSupplement?.batch?.customerMessageIDs ?? [])
        }
        guard targets.subtracting(covered).isSubset(of: batch.customerMessageIDs) else { return nil }
        let events = batch.events.filter { !covered.contains($0.messageID) }
        guard !events.isEmpty else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let filtered = FrozenCustomerBatch(startCursor: batch.startCursor, endCursor: batch.endCursor, events: events,
            targetCustomerJSONL: try events.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n"))
        let captures = jobs.flatMap { [$0.capture] + ($0.pendingSupplement.map { [$0] } ?? []) }
        let images = captures.flatMap(\.imageAttachments).reduce(into: [String: AutoReplyImageAttachment]()) { $0[$1.messageID] = $1 }
        let videos = captures.flatMap(\.videoAttachments).reduce(into: [String: AutoReplyVideoAttachment]()) { $0[$1.messageID] = $1 }
        return .init(uid: canonicalUID, fullHistory: history, batch: filtered, customerCursor: timeline.cursor,
            unexpectedServiceMessageIDs: [],
            ocrDiagnostic: "身份恢复：使用当前已核对会话的完整上下文及全部未回复消息重新生成",
            imageAttachments: images.values.filter { filtered.customerMessageIDs.contains($0.messageID) }.sorted { $0.messageID < $1.messageID },
            videoAttachments: videos.values.filter { filtered.customerMessageIDs.contains($0.messageID) }.sorted { $0.messageID < $1.messageID },
            pendingVideoMessageIDs: Array(Set(captures.flatMap(\.pendingVideoMessageIDs)).intersection(filtered.customerMessageIDs)).sorted())
    }

    @discardableResult
    static func retireSupersededHandoffs(in state: inout AutoReplyPersistentState, root: URL, at date: Date) -> Bool {
        var changed = false
        for index in state.jobs.indices {
            let job = state.jobs[index]
            guard [.queued, .ready].contains(job.state), !job.sendWasInvoked,
                  let boundary = job.capture.batch?.incomingHandoffKey,
                  let proof = state.jobs.first(where: {
                      $0.id != job.id && $0.capture.batch?.incomingHandoffKey == boundary
                          && (($0.state == .completed && $0.deliveryOutcome == .sent)
                              || ($0.state == .failed && $0.lastError?.contains("转入会话已回复或转接边界已变化") == true))
                  }) else { continue }
            state.jobs[index].state = .failed
            state.jobs[index].deliveryOutcome = .notSent
            state.jobs[index].nextAttemptAt = nil
            state.jobs[index].durableAttemptOperationID = nil
            state.jobs[index].lastError = "同一平台转入事件已回复或已失效；重复身份任务已关闭，未发送"
            state.jobs[index].supplementCapturePending = false
            state.pendingCaptureRequests.removeAll {
                $0.uid == job.uid && ($0.sourceJobID == job.id || $0.baseCursor == job.capture.batch?.endCursor)
            }
            let detail = "job=\(job.id) proof_job=\(proof.id) boundary=\(boundary) not_sent=true"
            state.events.append(.init(id: UUID(), timestamp: date, uid: job.uid, kind: "identity-duplicate-handoff-closed", detail: detail))
            AutomationStepLog.record(root: root, uid: job.uid, step: "identity-duplicate-handoff-closed", detail: detail)
            changed = true
        }
        return changed
    }

    static func capture(_ source: AutoReplyCapture, canonicalUID: String, root: URL) throws -> AutoReplyCapture? {
        guard let original = source.batch else { return nil }
        let store = PerUserChatStore(rootDirectory: root)
        // Add only the proven target messages, never the old visitor folder's history.
        let targets = source.fullHistory.filter { original.customerMessageIDs.contains($0.id) }
        let history = try store.mergeAXFirst(uid: canonicalUID, messages: targets).history
        let timeline = try AutoReplyTimeline.make(messages: history)
        if let boundary = original.incomingHandoffKey {
            return .init(uid: canonicalUID, fullHistory: history,
                batch: .incomingHandoff(key: boundary, cursor: timeline.cursor), customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
        }
        let events = timeline.events.filter { original.customerMessageIDs.contains($0.messageID) }
        guard events.count == original.customerMessageIDs.count else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let jsonl = try events.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n")
        return .init(uid: canonicalUID, fullHistory: history,
            batch: .init(startCursor: .empty, endCursor: timeline.cursor, events: events, targetCustomerJSONL: jsonl),
            customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [],
            imageAttachments: source.imageAttachments, videoAttachments: source.videoAttachments,
            pendingVideoMessageIDs: source.pendingVideoMessageIDs)
    }
}
