import XCTest
@testable import PDDAXReader

@MainActor
final class PDDVideoHoldingNoticeTests: XCTestCase {
    func testNoticeWithoutCapturedTargetCannotBlockAnotherCustomersDueNotice() async throws {
        let f = try Fixture(pending: true); defer { f.clean() }
        await f.scheduler.receiveVideoTransferEvent(.init(uid: "missing-customer", messageID: "missing-video", phase: .waitingForAddress))
        await f.capture(); f.clock.value += 10
        await f.ticks(3)
        XCTAssertEqual(f.driver.sentUIDs, ["customer"])
    }

    func testHoldingMessageAlsoSendsWhileModelIsGenerating() async throws {
        let f = try Fixture(pending: false); defer { f.clean() }
        await f.generator.setSlow()
        await f.capture(); await f.ticks(2)
        XCTAssertEqual(f.scheduler.jobs.first?.state, .generating)
        f.clock.value += 10; await f.ticks(2)
        XCTAssertEqual(f.driver.sent.count, 1)
        XCTAssertTrue(PDDVideoHoldingNotice.messages.contains(f.driver.sent[0]))
        XCTAssertEqual(f.scheduler.jobs.first?.state, .generating)
        XCTAssertNil(try CustomerMessageReceipts(root: f.root).receipts(uid: "customer")["video"]?.replySentAt)
    }
    func testTenSecondChineseNoticeDoesNotCompleteVideoAndFinalReplyStillSends() async throws {
        let f = try Fixture(pending: true); defer { f.clean() }
        await f.capture()
        f.clock.value += 9.99; await f.ticks(3)
        XCTAssertTrue(f.driver.sent.isEmpty)
        f.clock.value += 0.01; await f.ticks(3)
        XCTAssertEqual(f.driver.sent.count, 1)
        XCTAssertTrue(PDDVideoHoldingNotice.messages.contains(f.driver.sent[0]))
        let receipt = try CustomerMessageReceipts(root: f.root).receipts(uid: "customer")["video"]
        XCTAssertNil(receipt?.replySentAt); XCTAssertNil(receipt?.submittedAt)
        XCTAssertEqual(f.scheduler.pendingVideoBatchesSnapshot.count, 1)
        f.clock.value += 20; await f.ticks(5)
        XCTAssertEqual(f.driver.sent.count, 1)
        await f.scheduler.receiveVideoTransferEvent(.init(uid: "customer", messageID: "video", phase: .readyForGeneration, attachment: holdAttachment()))
        await f.ticks(15)
        XCTAssertEqual(f.driver.sent.count, 2)
        XCTAssertEqual(f.driver.sent.last, "实际答复")
        XCTAssertNotNil(try CustomerMessageReceipts(root: f.root).receipts(uid: "customer")["video"]?.replySentAt)
    }

    func testFastFinalReplyCancelsHoldAndStopAndDryRunDoNotSend() async throws {
        let f = try Fixture(pending: false); defer { f.clean() }
        await f.capture(); await f.ticks(15)
        XCTAssertEqual(f.driver.sent, ["实际答复"])
        f.clock.value += 20; await f.ticks(5)
        XCTAssertEqual(f.driver.sent, ["实际答复"])
        let dry = try Fixture(pending: true); defer { dry.clean() }
        await dry.capture(); dry.scheduler.setDeliveryEnabled(false)
        dry.clock.value += 11; await dry.ticks(5)
        XCTAssertTrue(dry.driver.sent.isEmpty)
        dry.scheduler.stop(); dry.scheduler.setDeliveryEnabled(true); await dry.ticks(3)
        XCTAssertTrue(dry.driver.sent.isEmpty)
    }

    func testAttemptSurvivesRestartAndUncertainHoldDoesNotRepeatOrBlockAnotherCustomer() async throws {
        let f = try Fixture(pending: true); defer { f.clean() }
        await f.capture(); f.driver.result = .uncertain("confirmation unavailable")
        f.clock.value += 10; await f.ticks(3)
        XCTAssertEqual(f.driver.sent.count, 1)
        f.scheduler.stop()
        let restored = try AutoReplyScheduler(driver: f.driver, generator: f.generator, store: AutoReplyStore(rootDirectory: f.root), now: { f.clock.value })
        restored.start(); f.clock.value += 20
        await restored.tick(); await restored.tick()
        XCTAssertEqual(f.driver.sent.count, 1)
        f.driver.result = nil
        f.driver.captures["other"] = try holdCapture(uid: "other", messages: [holdMessage("other-text", .text, "hello")])
        f.driver.discoveries = [.init(uid: "other", hasUnreadEvidence: true)]
        restored.requestAXRefresh()
        for _ in 0..<20 { await restored.tick(); try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(f.driver.sentUIDs.contains("other"))
        restored.stop()
    }

    func testTextFollowingVideoWaitsAndJoinsOneActualReply() async throws {
        let f = try Fixture(pending: true); defer { f.clean() }
        await f.capture()
        f.driver.captures["customer"] = try holdCapture(messages: [holdMessage("video", .video, "[视频]"), holdMessage("text", .text, "check this")], targetIDs: ["text"])
        f.driver.discoveries = [.init(uid: "customer", hasUnreadEvidence: true)]
        f.scheduler.requestAXRefresh()
        await f.ticks(6)
        let before = await f.generator.captures
        XCTAssertTrue(before.isEmpty, "Text must not generate an unavailable-video reply while evidence is pending")
        await f.scheduler.receiveVideoTransferEvent(.init(uid: "customer", messageID: "video", phase: .readyForGeneration, attachment: holdAttachment()))
        await f.ticks(15)
        let captures = await f.generator.captures
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.batch?.events.map(\.messageID), ["video", "text"])
        XCTAssertEqual(captures.first?.videoAttachments.count, 1)
        XCTAssertEqual(f.driver.sent, ["实际答复"])
    }

    func testQueuedVideoAndTextCoalesceWithoutDroppingReceipts() async throws {
        let f = try Fixture(pending: false); defer { f.clean() }
        var state = AutoReplyPersistentState()
        let video = try holdCapture(messages: [holdMessage("video", .video, "[视频]")], ready: true)
        let text = try holdCapture(messages: [holdMessage("video", .video, "[视频]"), holdMessage("text", .text, "check this")], targetIDs: ["text"])
        state.jobs = [video, text].enumerated().map { offset, capture in
            AutoReplyJob(id: UUID(), uid: "customer", sequence: offset + 1, state: .queued, capture: capture,
                reply: nil, deliveryOutcome: nil, confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil, lastError: nil)
        }
        state.nextSequence = 2; f.scheduler.stop()
        try AutoReplyStore(rootDirectory: f.root).save(state)
        let restored = try AutoReplyScheduler(driver: f.driver, generator: f.generator, store: AutoReplyStore(rootDirectory: f.root))
        restored.start()
        for _ in 0..<12 { await restored.tick(); try await Task.sleep(for: .milliseconds(2)) }
        let captures = await f.generator.captures
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.batch?.customerMessageIDs, ["video", "text"])
        XCTAssertEqual(f.driver.sent, ["实际答复"])
        restored.stop()
    }

    private final class Clock: @unchecked Sendable { var value = Date(timeIntervalSince1970: 100) }
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let clock = Clock(); let driver = Driver(); let generator = Generator()
        let scheduler: AutoReplyScheduler
        init(pending: Bool) throws {
            driver.captures["customer"] = try holdCapture(messages: [holdMessage("video", .video, "[视频]")], pending: pending, ready: !pending)
            driver.discoveries = [.init(uid: "customer", hasUnreadEvidence: true)]
            let clock = clock
            scheduler = try AutoReplyScheduler(driver: driver, generator: generator, store: AutoReplyStore(rootDirectory: root), now: { clock.value })
            scheduler.start()
        }
        func capture() async { await ticks(2) }
        func ticks(_ count: Int) async { for _ in 0..<count { await scheduler.tick(); try? await Task.sleep(for: .milliseconds(2)) } }
        func clean() { scheduler.stop(); try? FileManager.default.removeItem(at: root) }
    }
    private final class Driver: AutoReplyAutomationDriver {
        var captures: [String: AutoReplyCapture] = [:]; var discoveries: [AutoReplyDiscovery] = []
        var sent: [String] = []; var sentUIDs: [String] = []; var result: AutoReplyDeliveryResult?
        func discover() async throws -> [AutoReplyDiscovery] { defer { discoveries = [] }; return discoveries }
        func capture(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture {
            guard let capture = captures.removeValue(forKey: uid) else { return .init(uid: uid, fullHistory: [], batch: nil, customerCursor: cursor, unexpectedServiceMessageIDs: []) }
            return capture
        }
        func preflight(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture? { nil }
        func send(uid: String, text: String, expectedCustomerCursor: AutoReplyCursor) async throws -> AutoReplyDeliveryResult {
            sent.append(text); sentUIDs.append(uid); return result ?? .sent(serviceMessageID: "service-\(sent.count)")
        }
    }
    private actor Generator: AutoReplyGenerating {
        var captures: [AutoReplyCapture] = []
        var slow = false
        func setSlow() { slow = true }
        func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult {
            captures.append(capture)
            if slow { try await Task.sleep(for: .seconds(30)) }
            return .init(reply: "实际答复", threadID: "test")
        }
    }
}

private func holdMessage(_ id: String, _ kind: ChatContentKind, _ content: String) -> PDDChatMessage {
        .init(id: id, sender: .customer, content: content, displayTime: nil, kind: kind, capturedAt: Date())
    }
private func holdAttachment() -> AutoReplyVideoAttachment {
        .init(messageID: "video", localURL: URL(fileURLWithPath: "/tmp/video.mp4"), sha256: "hash", byteCount: 1,
              durationSeconds: 5, width: 1, height: 1, videoCodec: "H.264", audioCodec: nil, frames: [], transcript: nil, diagnostic: nil)
    }
private func holdCapture(uid: String = "customer", messages: [PDDChatMessage], targetIDs: Set<String>? = nil, pending: Bool = false, ready: Bool = false) throws -> AutoReplyCapture {
        let timeline = try AutoReplyTimeline.make(messages: messages)
        let whole = try XCTUnwrap(timeline.freeze(after: .empty))
        let events = whole.events.filter { targetIDs?.contains($0.messageID) ?? true }
        let jsonl = try events.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n")
        return .init(uid: uid, fullHistory: messages, batch: .init(startCursor: .empty, endCursor: timeline.cursor, events: events, targetCustomerJSONL: jsonl),
                     customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [], videoAttachments: ready ? [holdAttachment()] : [], pendingVideoMessageIDs: pending ? ["video"] : [])
    }

