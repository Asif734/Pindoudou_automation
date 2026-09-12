import XCTest
@testable import PDDAXReader

final class AutoReplyStoreTests: XCTestCase {
    func testSchemaFiveMigratesToAXFirstSchemaSixIdempotently() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        var state = AutoReplyPersistentState.empty
        state.schemaVersion = 5
        state.jobs = [
            job(state: .completed, reply: "已完成", digest: String(repeating: "1", count: 64), uid: fixture.uid),
            job(state: .failed, reply: nil, digest: String(repeating: "2", count: 64), uid: fixture.uid),
            job(state: .queued, reply: nil, digest: String(repeating: "3", count: 64), uid: fixture.uid),
            job(state: .generating, reply: nil, digest: String(repeating: "4", count: 64), uid: fixture.uid)
        ]
        state.pendingCaptureRequests = [
            AutoReplyCaptureRequest(uid: fixture.uid, kind: .ordinary, baseCursor: .empty)
        ]
        state.answeredCursors[fixture.uid] = AutoReplyCursor(
            count: 12, digest: String(repeating: "a", count: 64)
        )
        state.baselinedUIDs = [fixture.uid]
        let locator = PDDConversationLocator(domIdentifier: "buyer-1", nickname: "S***")
        state.conversationLocatorsByUID[fixture.uid] = locator
        try JSONEncoder().encode(state).write(
            to: fixture.root.appendingPathComponent("state.json"), options: .atomic
        )

        let migrated = try fixture.store.load()

        XCTAssertEqual(migrated.schemaVersion, 6)
        XCTAssertEqual(migrated.jobs.map(\.state), [.completed, .failed, .failed, .failed])
        XCTAssertTrue(migrated.jobs[2].lastError?.contains("AX-first 迁移") == true)
        XCTAssertTrue(migrated.jobs[3].lastError?.contains("AX-first 迁移") == true)
        XCTAssertTrue(migrated.pendingCaptureRequests.isEmpty)
        XCTAssertTrue(migrated.answeredCursors.isEmpty)
        XCTAssertTrue(migrated.baselinedUIDs.isEmpty)
        XCTAssertTrue(migrated.axFirstBaselinedUIDs.isEmpty)
        XCTAssertTrue(migrated.provisionalReceiptsByUID.isEmpty)
        XCTAssertTrue(migrated.messageSourceSelectorStatesByUID.isEmpty)
        XCTAssertEqual(migrated.conversationLocatorsByUID[fixture.uid], locator)
        let firstBackups = try schemaFiveBackups(in: fixture.root)
        XCTAssertEqual(firstBackups.count, 1)

        let loadedAgain = try fixture.store.load()

        XCTAssertEqual(loadedAgain, migrated)
        XCTAssertEqual(try schemaFiveBackups(in: fixture.root), firstBackups)
    }

    func testSchemaFourDropsUnlocatableLegacyPendingCaptureAndPreservesCompletedJob() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        var state = AutoReplyPersistentState.empty
        state.schemaVersion = 4
        state.jobs = [job(
            state: .completed,
            reply: "历史回复",
            digest: String(repeating: "f", count: 64),
            uid: fixture.uid
        )]
        state.pendingCaptureRequests = [
            AutoReplyCaptureRequest(uid: fixture.uid, kind: .ordinary, baseCursor: .empty)
        ]
        try JSONEncoder().encode(state).write(
            to: fixture.root.appendingPathComponent("state.json"), options: .atomic
        )

        let migrated = try fixture.store.load()

        XCTAssertEqual(migrated.schemaVersion, 6)
        XCTAssertEqual(migrated.jobs.map(\.state), [.completed])
        XCTAssertTrue(migrated.pendingCaptureRequests.isEmpty)
        XCTAssertTrue(migrated.events.contains {
            $0.uid == fixture.uid && $0.kind == "legacy-locator-dropped"
        })
    }

    func testStoreRoundTripsAnsweredCursorAndFrozenReply() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let digest = String(repeating: "a", count: 64)
        var state = AutoReplyPersistentState.empty
        state.answeredCursors[fixture.uid] = AutoReplyCursor(count: 1, digest: digest)
        state.jobs = [job(state: .ready, reply: "请重新插拔电源", digest: digest, uid: fixture.uid)]

        try fixture.store.save(state)

        XCTAssertEqual(try fixture.store.load(), state)
    }

    func testImageCaptureAttemptRoundTripsAndDefaultsFalseForLegacyJSON() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var state = AutoReplyPersistentState.empty
        state.jobs = [job(
            state: .ready, reply: "回复", digest: String(repeating: "a", count: 64),
            uid: fixture.uid
        )]
        state.jobs[0].imageCaptureAttempted = true
        try fixture.store.save(state)
        XCTAssertTrue(try fixture.store.load().jobs[0].imageCaptureAttempted)

        let stateURL = fixture.root.appendingPathComponent("state.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        var jobs = try XCTUnwrap(object["jobs"] as? [[String: Any]])
        jobs[0].removeValue(forKey: "imageCaptureAttempted")
        object["jobs"] = jobs
        try JSONSerialization.data(withJSONObject: object).write(to: stateURL, options: .atomic)

        XCTAssertFalse(try fixture.store.load().jobs[0].imageCaptureAttempted)
        XCTAssertEqual(try fixture.store.load().jobs[0].replyAction, .reply)
        XCTAssertEqual(try fixture.store.load().jobs[0].transferReason, .none)
        XCTAssertTrue(try fixture.store.load().transferTasks.isEmpty)
    }

    func testInterruptedSendingBeforeDriverInvocationRequeuesWithoutAdvancingCursor() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var state = AutoReplyPersistentState.empty
        state.jobs = [job(state: .sending, reply: "回复", digest: String(repeating: "a", count: 64), uid: fixture.uid)]
        state.jobs[0].durableAttemptOperationID = UUID()
        state.jobs[0].sendWasInvoked = false
        try fixture.store.save(state)

        let recovered = try fixture.store.loadRecoveringInterruptedWork(
            now: Date(timeIntervalSince1970: 1_777_000_000)
        )

        XCTAssertEqual(recovered.jobs[0].state, .ready)
        XCTAssertEqual(recovered.jobs[0].deliveryOutcome, .notSent)
        XCTAssertNil(recovered.answeredCursors[fixture.uid])
        XCTAssertNil(recovered.jobs[0].durableAttemptOperationID)
    }

    func testInterruptedSendingAfterDriverInvocationCompletesUncertainAndAdvancesCursor() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var state = AutoReplyPersistentState.empty
        state.jobs = [job(
            state: .sending, reply: "回复", digest: String(repeating: "9", count: 64), uid: fixture.uid
        )]
        let operationID = UUID()
        state.jobs[0].durableAttemptOperationID = operationID
        state.jobs[0].sendWasInvoked = true
        try fixture.store.save(state)

        let recovered = try fixture.store.loadRecoveringInterruptedWork(
            now: Date(timeIntervalSince1970: 1_777_000_000)
        )

        XCTAssertEqual(recovered.jobs[0].state, .completed)
        XCTAssertEqual(recovered.jobs[0].deliveryOutcome, .uncertain)
        XCTAssertEqual(recovered.jobs[0].durableAttemptOperationID, operationID)
        XCTAssertTrue(recovered.jobs[0].sendWasInvoked)
        XCTAssertEqual(recovered.answeredCursors[fixture.uid]?.count, 1)
    }

    func testInterruptedSendingAfterInvocationPromotesDurableSupplement() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var source = job(
            state: .sending, reply: "回复", digest: String(repeating: "9", count: 64), uid: fixture.uid
        )
        source.sendWasInvoked = true
        source.pendingSupplement = capture(
            uid: fixture.uid, digest: String(repeating: "8", count: 64)
        )
        var state = AutoReplyPersistentState.empty
        state.nextSequence = 1
        state.jobs = [source]
        try fixture.store.save(state)

        let recovered = try fixture.store.loadRecoveringInterruptedWork(
            now: Date(timeIntervalSince1970: 1_777_000_000)
        )

        XCTAssertEqual(recovered.jobs.map(\.state), [.completed, .queued])
        XCTAssertNil(recovered.jobs[0].pendingSupplement)
        XCTAssertEqual(recovered.jobs[1].sequence, 2)
    }

    func testCorruptStateIsReportedAndNotOverwritten() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let stateURL = fixture.root.appendingPathComponent("state.json")
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: stateURL)

        XCTAssertThrowsError(try fixture.store.load())
        XCTAssertEqual(try Data(contentsOf: stateURL), corrupt)
    }

    func testArchiveWritesRecordAndReplyInsideConfiguredRoot() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let completed = job(
            state: .completed,
            reply: "归档回复",
            digest: String(repeating: "b", count: 64),
            uid: fixture.uid
        )

        try fixture.store.archive(completed)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent("archive/records/\(completed.id.uuidString).json").path
        ))
        XCTAssertEqual(
            try String(contentsOf: fixture.root.appendingPathComponent("archive/replies/\(completed.id.uuidString).txt")),
            "归档回复"
        )
    }

    func testSchemaOneStateMigratesToSchemaFourAndCreatesBackup() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        var state = AutoReplyPersistentState.empty
        state.jobs = [job(
            state: .ready, reply: "旧版回复", digest: String(repeating: "c", count: 64), uid: fixture.uid
        )]
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        object["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: object).write(
            to: fixture.root.appendingPathComponent("state.json"), options: .atomic
        )

        let migrated = try fixture.store.load()

        XCTAssertEqual(migrated.schemaVersion, 6)
        XCTAssertEqual(migrated.jobs.first?.reply, "旧版回复")
        XCTAssertEqual(migrated.jobs.first?.revision.digest, String(repeating: "c", count: 64))
        let backups = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .filter { $0.hasPrefix("state.schema1-backup-") && $0.hasSuffix(".json") }
        XCTAssertEqual(backups.count, 1)
    }

    func testSchemaTwoStateMigratesNewJobFieldsAndDigestRevisionAndCreatesBackup() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        var state = AutoReplyPersistentState.empty
        state.jobs = [job(
            state: .ready, reply: "旧版回复", digest: String(repeating: "6", count: 64), uid: fixture.uid
        )]
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        object["schemaVersion"] = 2
        var jobs = try XCTUnwrap(object["jobs"] as? [[String: Any]])
        jobs[0].removeValue(forKey: "customerRevision")
        jobs[0].removeValue(forKey: "stageAttempt")
        jobs[0].removeValue(forKey: "imageAttachments")
        jobs[0].removeValue(forKey: "durableAttemptOperationID")
        jobs[0].removeValue(forKey: "sendWasInvoked")
        jobs[0].removeValue(forKey: "pendingSupplement")
        jobs[0].removeValue(forKey: "supplementCapturePending")
        object["jobs"] = jobs
        try JSONSerialization.data(withJSONObject: object).write(
            to: fixture.root.appendingPathComponent("state.json"), options: .atomic
        )

        let migrated = try fixture.store.load()

        XCTAssertEqual(migrated.schemaVersion, 6)
        XCTAssertEqual(migrated.jobs[0].customerRevision, 1)
        XCTAssertEqual(migrated.jobs[0].revision.digest, String(repeating: "6", count: 64))
        XCTAssertEqual(migrated.jobs[0].stageAttempt, 0)
        XCTAssertEqual(migrated.jobs[0].imageAttachments, [])
        XCTAssertNil(migrated.jobs[0].durableAttemptOperationID)
        XCTAssertFalse(migrated.jobs[0].sendWasInvoked)
        XCTAssertNil(migrated.jobs[0].pendingSupplement)
        XCTAssertFalse(migrated.jobs[0].supplementCapturePending)
        let backups = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .filter { $0.hasPrefix("state.schema2-backup-") && $0.hasSuffix(".json") }
        XCTAssertEqual(backups.count, 1)
    }

    func testSchemaThreeJobRevisionMigratesFromFrozenBatchDigest() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let digest = String(repeating: "4", count: 64)
        var state = AutoReplyPersistentState.empty
        state.jobs = [job(state: .ready, reply: "旧版回复", digest: digest, uid: fixture.uid)]
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        )
        object["schemaVersion"] = 3
        var jobs = try XCTUnwrap(object["jobs"] as? [[String: Any]])
        jobs[0].removeValue(forKey: "revision")
        object["jobs"] = jobs
        try JSONSerialization.data(withJSONObject: object).write(
            to: fixture.root.appendingPathComponent("state.json"), options: .atomic
        )

        let migrated = try fixture.store.load()

        XCTAssertEqual(migrated.schemaVersion, 6)
        XCTAssertEqual(migrated.jobs[0].revision.digest, digest)
        XCTAssertEqual(migrated.jobs[0].revision.ordinal, 1)
        let backups = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .filter { $0.hasPrefix("state.schema3-backup-") && $0.hasSuffix(".json") }
        XCTAssertEqual(backups.count, 1)
    }

    func testRoundTripsTwoRevisionsForSameUIDWithoutOverwritingParkedOlderRevision() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var first = job(
            state: .quarantined, reply: nil, digest: String(repeating: "7", count: 64), uid: fixture.uid
        )
        first.customerRevision = 1
        var second = job(
            state: .queued, reply: nil, digest: String(repeating: "8", count: 64), uid: fixture.uid
        )
        second.customerRevision = 2
        second.stageAttempt = 1
        second.durableAttemptOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")
        var state = AutoReplyPersistentState.empty
        state.jobs = [first, second]

        try fixture.store.save(state)
        let loaded = try fixture.store.load()

        XCTAssertEqual(loaded.jobs.map(\.customerRevision), [1, 2])
        XCTAssertEqual(loaded.jobs.map(\.state), [.quarantined, .queued])
        XCTAssertEqual(loaded.jobs[1].stageAttempt, 1)
        XCTAssertEqual(loaded.jobs[1].durableAttemptOperationID, second.durableAttemptOperationID)
    }

    func testArchiveRefusesToOverwriteDifferentEvidenceForSameJobID() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let first = job(
            state: .completed, reply: "第一份证据", digest: String(repeating: "d", count: 64), uid: fixture.uid
        )
        var changed = first
        changed.reply = "不同证据"
        try fixture.store.archive(first)

        XCTAssertThrowsError(try fixture.store.archive(changed))
        XCTAssertEqual(
            try String(contentsOf: fixture.root.appendingPathComponent("archive/replies/\(first.id.uuidString).txt")),
            "第一份证据"
        )
    }

    func testGenerationDiagnosticRoundTripsAndArchivesWithJob() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var completed = job(
            state: .completed, reply: "证据回复", digest: String(repeating: "e", count: 64), uid: fixture.uid
        )
        completed.generationDiagnostic = AutoReplyGenerationDiagnostic(
            knowledge: KnowledgeRetrievalDiagnostic(
                mode: .v2Top12, knowledgeBaseSHA256: "kb", selectedDocuments: ["m880.md"],
                contextSHA256: "ctx", durationMilliseconds: 25, error: nil
            ),
            codexDurationMilliseconds: 500,
            events: [CodexExecutionEvent(type: "turn.completed", threadID: nil)]
        )
        var state = AutoReplyPersistentState.empty
        state.jobs = [completed]

        try fixture.store.save(state)
        try fixture.store.archive(completed)

        XCTAssertEqual(try fixture.store.load().jobs.first?.generationDiagnostic, completed.generationDiagnostic)
        let archived = try JSONDecoder().decode(
            AutoReplyJob.self,
            from: Data(contentsOf: fixture.root.appendingPathComponent("archive/records/\(completed.id.uuidString).json"))
        )
        XCTAssertEqual(archived.generationDiagnostic, completed.generationDiagnostic)
    }

    private func makeFixture() throws -> StoreFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-auto-reply-store-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return StoreFixture(root: root, store: AutoReplyStore(rootDirectory: root), uid: "GZC-000001")
    }

    private func schemaFiveBackups(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("state.schema5-backup-") && $0.hasSuffix(".json") }
            .sorted()
    }

    private func job(
        state: AutoReplyJobState,
        reply: String?,
        digest: String,
        uid: String
    ) -> AutoReplyJob {
        AutoReplyJob(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            uid: uid,
            sequence: 1,
            state: state,
            capture: capture(uid: uid, digest: digest),
            reply: reply,
            deliveryOutcome: nil,
            confirmedServiceMessageID: nil,
            retries: 0,
            nextAttemptAt: nil,
            lastError: nil
        )
    }

    private func capture(uid: String, digest: String) -> AutoReplyCapture {
        let event = ActionableCustomerEvent(
            messageID: "m1",
            kind: .text,
            content: "问题",
            displayTime: "10:00"
        )
        let end = AutoReplyCursor(count: 1, digest: digest)
        return AutoReplyCapture(
            uid: uid,
            fullHistory: [PDDChatMessage(
                id: "m1",
                sender: .customer,
                content: "问题",
                displayTime: "10:00",
                kind: .text,
                capturedAt: Date(timeIntervalSince1970: 1_777_000_000)
            )],
            batch: FrozenCustomerBatch(
                startCursor: .empty,
                endCursor: end,
                events: [event],
                targetCustomerJSONL: "{\"messageID\":\"m1\"}"
            ),
            customerCursor: end,
            unexpectedServiceMessageIDs: []
        )
    }
}

private struct StoreFixture {
    let root: URL
    let store: AutoReplyStore
    let uid: String

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
