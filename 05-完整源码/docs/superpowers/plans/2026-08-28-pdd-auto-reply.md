# 拼多多纯 AX 全自动客服 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个默认停止、纯 macOS AX、按每用户冻结批次可靠生成并确认发送文字回复的独立拼多多全自动客服应用。

**Architecture:** 在现有 `PDDAXReader` 可执行目标内增加独立 bundle 模式。核心层负责可执行客户事件、游标、冻结批次、持久状态和调度；Codex 层只生成冻结批次；AX 层串行完成发现、切换、三次 UID 核对、输入和回读确认；SwiftUI 层只控制开始/停止和展示状态。

**Tech Stack:** Swift 5.9、SwiftUI、ApplicationServices AXUIElement/AXObserver、Foundation/CryptoKit、XCTest、SwiftPM、macOS 13+

**Spec:** `docs/superpowers/specs/2026-08-28-pdd-auto-reply-design.md`

## Global Constraints

- 拼多多读取和操作只能使用 AX API；禁止 OCR、截图、坐标、键鼠事件、剪贴板、脚本注入和网络接口。
- 自动回复 app 的 bundle ID 固定为 `com.scy.pdd-auto-reply`，启动后默认停止。
- 第一阶段只允许 `GZC-000001`；全用户模式必须由独立验收开关解锁。
- 图片可写入完整历史，但不进入可执行事件、游标、Prompt、附件或发送触发条件。
- 每个 UID 只有一个活动批次；同 UID FIFO，不同 UID 可并行生成，拼多多 UI 操作全局串行。
- 只有新增客服 AX 消息的 UID、消息 ID 和完整文本都验证成功才返回 `sent`。
- `failedBeforeSend` 可重试；发送动作后未确认必须进入 `uncertain`，不得自动重发或推进游标。
- Codex 固定 `/Applications/ChatGPT.app/Contents/Resources/codex`、`gpt-5.6-sol`、`medium`、`read-only`、`approval=never`。
- 知识库固定只读 `/Users/scy/Desktop/AI客服记录/知识库/Grozziie-China-KB-2026-08-24.zip`。
- 当前目录不是 Git 仓库；每个任务用测试输出和文件清单做检查点，不初始化 Git、不伪造 commit。

---

### Task 1: 可执行客户事件、游标与冻结批次

**Files:**
- Create: `Sources/PDDAXReader/AutoReplyTimeline.swift`
- Modify: `Sources/PDDAXReader/PDDChatMessage.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyTimelineTests.swift`

**Interfaces:**
- Consumes: `[PDDChatMessage]`。
- Produces: `ActionableCustomerEvent`, `AutoReplyCursor`, `FrozenCustomerBatch`, `AutoReplyTimeline.make(messages:)`, `AutoReplyTimeline.freeze(after:)`。

- [ ] **Step 1: 写图片排除与文字/链接游标的失败测试**

```swift
func testTimelineExcludesImagesButPreservesTextAndLinksInOrder() throws {
    let messages = [
        message("m1", .customer, .image, "[图片]"),
        message("m2", .customer, .text, "怎么安装"),
        message("m3", .customer, .link, "https://example.test/manual"),
        message("m4", .service, .text, "旧回复")
    ]
    let timeline = AutoReplyTimeline.make(messages: messages)
    XCTAssertEqual(timeline.events.map(\.messageID), ["m2", "m3"])
    XCTAssertEqual(timeline.cursor.count, 2)
    XCTAssertEqual(timeline.freeze(after: .empty)?.events.map(\.messageID), ["m2", "m3"])
}
```

- [ ] **Step 2: 运行测试并确认 RED**

Run: `swift test --filter AutoReplyTimelineTests`

Expected: 编译失败，提示 `AutoReplyTimeline`、`AutoReplyCursor` 尚未定义。

- [ ] **Step 3: 实现稳定事件和链式摘要**

```swift
struct ActionableCustomerEvent: Codable, Equatable, Sendable {
    let messageID: String
    let kind: ChatContentKind
    let content: String
    let displayTime: String?
}

struct AutoReplyCursor: Codable, Equatable, Hashable, Sendable {
    let count: Int
    let digest: String
    static let empty = AutoReplyCursor(count: 0, digest: String(repeating: "0", count: 64))
}

struct FrozenCustomerBatch: Codable, Equatable, Sendable {
    let startCursor: AutoReplyCursor
    let endCursor: AutoReplyCursor
    let events: [ActionableCustomerEvent]
    let targetCustomerJSONL: String
}
```

`make` 只收 `sender == .customer && kind != .image`。每一步摘要为 `SHA256(previousDigest + canonicalEventJSON)`；`freeze(after:)` 先验证传入游标是合法前缀，再返回尾部，不合法则抛 `AutoReplyTimelineError.invalidPrefix`。

同时给只包含值类型的 `ChatSender`、`ChatContentKind`、`PDDChatMessage` 增加 `Sendable`，供冻结批次跨生成任务传递；不得改变其 Codable 字段。

- [ ] **Step 4: 增加重复文字和非法前缀测试并跑 GREEN**

```swift
func testRepeatedTextWithDifferentMessageIDsRemainsTwoEvents() {
    let timeline = AutoReplyTimeline.make(messages: [message("m1", .customer, .text, "重复"), message("m2", .customer, .text, "重复")])
    XCTAssertEqual(timeline.events.map(\.messageID), ["m1", "m2"])
    XCTAssertEqual(timeline.cursor.count, 2)
}
func testFreezeRejectsCursorWhoseDigestIsNotCurrentPrefix() {
    let timeline = AutoReplyTimeline.make(messages: [message("m1", .customer, .text, "A")])
    XCTAssertThrowsError(try timeline.freeze(after: .init(count: 1, digest: String(repeating: "f", count: 64))))
}
func testImageOnlyTimelineHasNoFrozenBatch() throws {
    let timeline = AutoReplyTimeline.make(messages: [message("img", .customer, .image, "[图片]")])
    XCTAssertNil(try timeline.freeze(after: .empty))
}
private func message(_ id: String, _ sender: ChatSender, _ kind: ChatContentKind, _ content: String) -> PDDChatMessage {
    PDDChatMessage(id: id, sender: sender, content: content, displayTime: "10:00", kind: kind,
                   capturedAt: Date(timeIntervalSince1970: 1_777_000_000))
}
```

Run: `swift test --filter AutoReplyTimelineTests`

Expected: 所有 `AutoReplyTimelineTests` 通过。

- [ ] **Step 5: 检查点**

Run: `swift test`

Record: Task 1 文件清单和测试总数；必须保持原 50 项测试全部通过。

---

### Task 2: 自动回复持久状态、原子存储与恢复

**Files:**
- Create: `Sources/PDDAXReader/AutoReplyModels.swift`
- Create: `Sources/PDDAXReader/AutoReplyStore.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyStoreTests.swift`

**Interfaces:**
- Consumes: `AutoReplyCursor`, `FrozenCustomerBatch`。
- Produces: `AutoReplyJobState`, `AutoReplyDeliveryOutcome`, `AutoReplyCapture`, `AutoReplyJob`, `AutoReplyPersistentState`, `AutoReplyStore.load()`, `save(_:)`, `archive(_:)`。

- [ ] **Step 1: 写原子 round-trip 与恢复语义失败测试**

```swift
func testStoreRoundTripsAnsweredCursorAndFrozenReply() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = AutoReplyStore(rootDirectory: root)
    let digestA = String(repeating: "a", count: 64)
    var state = AutoReplyPersistentState.empty
    state.answeredCursors["GZC-000001"] = AutoReplyCursor(count: 1, digest: digestA)
    state.jobs = [AutoReplyJob(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        uid: "GZC-000001", sequence: 1, state: .ready,
        capture: fixtureCapture(endDigest: digestA), reply: "请重新插拔电源",
        deliveryOutcome: nil, confirmedServiceMessageID: nil,
        retries: 0, nextAttemptAt: nil, lastError: nil
    )]
    try store.save(state)
    XCTAssertEqual(try store.load(), state)
}

func testInterruptedSendingRecoversAsUncertainWithoutAdvancingCursor() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = AutoReplyStore(rootDirectory: root)
    var state = AutoReplyPersistentState.empty
    state.jobs = [AutoReplyJob(
        id: UUID(), uid: "GZC-000001", sequence: 1, state: .sending,
        capture: fixtureCapture(endDigest: String(repeating: "a", count: 64)), reply: "回复",
        deliveryOutcome: nil, confirmedServiceMessageID: nil,
        retries: 0, nextAttemptAt: nil, lastError: nil
    )]
    try store.save(state)
    let recovered = try store.loadRecoveringInterruptedWork(now: Date(timeIntervalSince1970: 1_777_000_000))
    XCTAssertEqual(recovered.jobs[0].state, .uncertain)
    XCTAssertEqual(recovered.answeredCursors["GZC-000001"], .empty)
}
```

测试文件内的 `fixtureCapture(endDigest:)` 必须返回一个 UID 为 `GZC-000001`、单文字事件、空 `unexpectedServiceMessageIDs` 的完整 `AutoReplyCapture` 字面量；每个测试使用独立临时目录并在 `defer` 中删除。

- [ ] **Step 2: 运行测试并确认 RED**

Run: `swift test --filter AutoReplyStoreTests`

Expected: 编译失败，缺少状态和存储类型。

- [ ] **Step 3: 实现 schema 1 状态与安全路径**

```swift
enum AutoReplyJobState: String, Codable, Sendable {
    case discovered, capturing, queued, generating, ready, sending
    case completed, failed, uncertain, quarantined
}
enum AutoReplyDeliveryOutcome: String, Codable, Sendable { case sent, notSent, uncertain }
struct AutoReplyCapture: Codable, Equatable, Sendable {
    let uid: String
    let fullHistory: [PDDChatMessage]
    let batch: FrozenCustomerBatch?
    let customerCursor: AutoReplyCursor
    let unexpectedServiceMessageIDs: [String]
}
struct AutoReplyJob: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let uid: String
    let sequence: Int
    var state: AutoReplyJobState
    let capture: AutoReplyCapture
    var reply: String?
    var deliveryOutcome: AutoReplyDeliveryOutcome?
    var confirmedServiceMessageID: String?
    var retries: Int
    var nextAttemptAt: Date?
    var lastError: String?
}
struct AutoReplyPersistentState: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var nextSequence = 0
    var jobs: [AutoReplyJob] = []
    var answeredCursors: [String: AutoReplyCursor] = [:]
    var baselinedUIDs: Set<String> = []
    var knownServiceMessageIDsByUID: [String: Set<String>] = [:]
    var confirmedAutoReplyMessageIDsByUID: [String: Set<String>] = [:]
    var events: [AutoReplyEvent] = []
    static let empty = AutoReplyPersistentState()
}
```

`AutoReplyEvent` 是 Codable/Equatable/Sendable 的审计记录，固定字段为 `id: UUID`、`timestamp: Date`、`uid: String?`、`kind: String`、`detail: String`。默认根目录为 `~/Desktop/拼多多AX记录/自动回复`。保存写临时文件后原子替换；解析损坏时抛错且保留原文件。归档写 `archive/records/<job-id>.json` 和 `archive/replies/<job-id>.txt`。`loadRecoveringInterruptedWork(now:)` 将启动时的 `.sending` 改为 `.uncertain`，但不改变 answered cursor。

- [ ] **Step 4: 增加损坏文件、路径隔离和终态归档测试**

Run: `swift test --filter AutoReplyStoreTests`

Expected: round-trip、恢复、损坏保护、归档四类测试全部通过。

- [ ] **Step 5: 检查点**

Run: `swift test`

Record: 完整测试结果；禁止修改现有 `PerUserChatStore` 数据格式。

---

### Task 3: 冻结批次调度器与千牛一致的 FIFO 语义

**Files:**
- Create: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`

**Interfaces:**
- Consumes: Task 1/2 类型。
- Produces: `AutoReplyAutomationDriver`, `AutoReplyGenerating`, `AutoReplyScheduler.start()`, `stop()`, `tick()`。

```swift
@MainActor protocol AutoReplyAutomationDriver: AnyObject {
    func discover() async throws -> [AutoReplyDiscovery]
    func capture(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture
    func send(uid: String, text: String, expectedCustomerCursor: AutoReplyCursor) async throws -> AutoReplyDeliveryResult
}
protocol AutoReplyGenerating: Sendable {
    func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult
}
enum AutoReplyDeliveryResult: Equatable, Sendable {
    case sent(serviceMessageID: String)
    case failedBeforeSend(String)
    case uncertain(String)
}
struct AutoReplyDiscovery: Equatable, Sendable {
    let uid: String
    let hasUnreadEvidence: Bool
}
```

- [ ] **Step 1: 写 A→B+C→D 和图片跳过失败测试**

```swift
func testCustomerSupplementsBecomeNextFrozenBatchWithoutNewUnreadDot() async throws {
    let f = try SchedulerFixture(captureEventIDs: [["A"], ["B", "C"]])
    f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: true)]
    f.driver.deliveryResults = [.sent(serviceMessageID: "s1"), .sent(serviceMessageID: "s2")]
    await f.runUntilCompletedJobs(2)
    XCTAssertEqual(f.generator.targetIDs, [["A"], ["B", "C"]])
    XCTAssertEqual(f.driver.sentTexts.count, 2)
}

func testImageOnlyDiscoveryProducesNoJob() async throws {
    let f = try SchedulerFixture(captureEventIDs: [[]])
    f.driver.discoveries = [.init(uid: "GZC-000001", hasUnreadEvidence: true)]
    await f.runTicks(4)
    XCTAssertTrue(f.scheduler.jobs.isEmpty)
    XCTAssertTrue(f.generator.targetIDs.isEmpty)
}
func testUnexpectedHumanServiceMessageQuarantinesOnlyThatUID() async throws {
    let f = try SchedulerFixture(captureEventIDs: [["A"]])
    f.driver.unexpectedServiceMessageIDs = ["human-service-1"]
    await f.runTicks(4)
    XCTAssertEqual(f.scheduler.jobs.first?.state, .quarantined)
    XCTAssertTrue(f.driver.sentTexts.isEmpty)
    XCTAssertEqual(f.scheduler.answeredCursor("GZC-000001"), .empty)
}
```

测试文件内定义 `SchedulerFixture`、`ControlledAutoReplyDriver`、`ControlledReplyGenerator`。`captureEventIDs` 必须逐项构造字面量 `AutoReplyCapture`；`runTicks(_:)` 逐次调用 `scheduler.tick()`；`runUntilCompletedJobs(_:)` 最多 100 tick，未达到数量即 `XCTFail`。替身记录 `targetIDs`、`sentTexts`、`operations` 和同时 UI 调用数。

- [ ] **Step 2: 运行测试并确认 RED**

Run: `swift test --filter AutoReplySchedulerTests`

Expected: 编译失败，缺少调度器协议与类型。

- [ ] **Step 3: 移植最小状态机**

实现优先级：`ready send` → `discovered capture` → `queued generate` → `discover`。UI await 由 `pumping` 串行锁保护；生成任务保存在按 UID 去重的 `liveGenerations`。运行循环每 200ms tick，发现器自身最多每 1.0 秒调用一次。

只有 `.sent` 在一次 `store.save` 提交中完成任务、推进 `answeredCursors[uid]` 并归档。`.uncertain` 终止该 UID 自动发送；`.failedBeforeSend` 按 1、2、4、8、16 秒指数退避，最多 5 次。

捕获返回非空 `unexpectedServiceMessageIDs` 时，不生成、不发送并只把该 UID 的活动任务置为 `.quarantined`；其他 UID 继续。生成并发必须移植千牛的 `AdaptiveConcurrencyPolicy`：预留 4 GiB；剩余每 1 GiB 一个槽；物理内存默认上限 `min(24, max(6, physicalGiB / 2))`；显式 backpressure 后 60 秒容量减半；配置上限再取最小值。

- [ ] **Step 4: 添加停止、崩溃、并发和不推进游标测试**

```swift
func testStopPreventsDiscoveryAndDeliveryButKeepsReadyReply() async throws {
    let f = try SchedulerFixture(captureEventIDs: [["A"]]); f.scheduler.stop(); await f.runTicks(3)
    XCTAssertEqual(f.driver.discoverCallCount, 0); XCTAssertTrue(f.driver.sentTexts.isEmpty)
}
func testUncertainDeliveryNeverRetriesOrAdvancesCursor() async throws {
    let f = try SchedulerFixture(captureEventIDs: [["A"]]); f.driver.deliveryResults = [.uncertain("timeout")]
    await f.runTicks(20)
    XCTAssertEqual(f.driver.sendCallCount, 1); XCTAssertEqual(f.scheduler.answeredCursor("GZC-000001"), .empty)
}
func testTwoUIDsGenerateConcurrentlyButSendSerially() async throws {
    let f = try SchedulerFixture(capturesByUID: ["GZC-000001": ["A"], "GZC-000002": ["B"]])
    await f.runUntilCompletedJobs(2)
    XCTAssertGreaterThanOrEqual(f.generator.maximumConcurrentCalls, 2); XCTAssertEqual(f.driver.maximumConcurrentUICalls, 1)
}
func testReadyReplySendsBeforeCapturingNewUID() async throws {
    let f = try SchedulerFixture(readyUID: "GZC-000001", discoveredUID: "GZC-000002"); await f.runTicks(1)
    XCTAssertEqual(f.driver.operations.first, "send:GZC-000001")
}
func testAdaptiveGenerationCapacityMatchesQianniuMemoryPolicy() {
    let policy = AdaptiveConcurrencyPolicy(physicalMemoryBytes: 16 << 30, emergencyCeiling: nil)
    XCTAssertEqual(policy.limit(queueDepth: 20, availableMemoryBytes: 10 << 30, activeCleanup: 0, now: now), 6)
    policy.recordBackpressure(now: now)
    XCTAssertEqual(policy.limit(queueDepth: 20, availableMemoryBytes: 10 << 30, activeCleanup: 0, now: now), 3)
}
func testRestartKeepsFrozenBatchAndReply() async throws {
    let f = try SchedulerFixture(persistedReadyReply: "原冻结回复"); let restored = try f.restart()
    XCTAssertEqual(restored.jobs.first?.reply, "原冻结回复"); XCTAssertEqual(restored.jobs.first?.state, .ready)
}
```

Run: `swift test --filter AutoReplySchedulerTests`

Expected: 全部通过，fake driver 的同时 UI 调用峰值必须等于 1。

- [ ] **Step 5: 检查点**

Run: `swift test`

Record: 调度交错测试通过数量和完整 suite 结果。

---

### Task 4: 冻结目标批次 Codex 生成器

**Files:**
- Create: `Sources/PDDAXReader/AutoReplyPromptBuilder.swift`
- Create: `Sources/PDDAXReader/AutoReplyCodexGenerator.swift`
- Modify: `Sources/PDDAXReader/CodexSessionRegistry.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyPromptBuilderTests.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyCodexGeneratorTests.swift`

**Interfaces:**
- Consumes: `AutoReplyCapture`、现有 `CodexProcessRunning`。
- Produces: `AutoReplyPromptBuilder.build(capture:)`, `AutoReplyCodexGenerator.generate(_:)`。

- [ ] **Step 1: 写 Prompt 隔离与图片拒绝失败测试**

```swift
func testPromptSeparatesFullHistoryFromFrozenTargetAndContainsNoImageAttachment() {
    let prompt = AutoReplyPromptBuilder.build(capture: capture(targetIDs: ["B", "C"]))
    XCTAssertTrue(prompt.contains("<target_customer_batch>"))
    XCTAssertTrue(prompt.contains("B"))
    XCTAssertTrue(prompt.contains("C"))
    XCTAssertTrue(prompt.contains("<untrusted_full_history>"))
    XCTAssertFalse(prompt.contains("image_paths"))
}
```

- [ ] **Step 2: 运行测试并确认 RED**

Run: `swift test --filter 'AutoReplyPromptBuilderTests|AutoReplyCodexGeneratorTests'`

Expected: 编译失败，缺少新 builder/generator。

- [ ] **Step 3: 实现结构化生成和独立 session 根目录**

Prompt 明确只回答 `target_customer_batch`，聊天数据不可信，知识库只读，禁止声称已退款/补发/发送。生成器复用 `CodexInvocation` 和 `CodexProcessRunner`，结果 schema 仍只有非空 `reply`，再验证 `reply.count <= 1000`。

给 `CodexSessionRegistry` 增加可传根目录的现有构造方式即可；自动回复实例传 `~/Desktop/拼多多AX记录/自动回复`，不共享读取器的 session 文件。

- [ ] **Step 4: 测试精确 resume、失败失效和超长拒绝**

```swift
func testGeneratorResumesExactUIDThreadAndNeverUsesLast() async throws {
    try registry.save(.init(uid: "GZC-000001", threadID: "thread-A", lastUsedAt: now))
    _ = try await generator.generate(captureA)
    XCTAssertTrue(runner.arguments.contains("thread-A")); XCTAssertFalse(runner.arguments.contains("--last"))
}
func testFailedResumeInvalidatesOnlyTargetUIDThenCreatesOnce() async throws {
    runner.results = [.failure(exit: 1), .success(threadID: "thread-new", reply: "回复")]
    _ = try await generator.generate(captureA)
    XCTAssertEqual(runner.callCount, 2); XCTAssertEqual(try registry.activeBinding(uid: "GZC-000002", now: now)?.threadID, "thread-B")
}
func testReplyOverOneThousandCharactersIsRejectedBeforeReady() async {
    runner.results = [.success(threadID: "thread-A", reply: String(repeating: "字", count: 1001))]
    do { _ = try await generator.generate(captureA); XCTFail("超长回复必须拒绝") } catch { }
}
```

Run: `swift test --filter 'AutoReplyPromptBuilderTests|AutoReplyCodexGeneratorTests'`

Expected: 全部通过。

- [ ] **Step 5: 检查点**

Run: `swift test`

Record: Prompt/CLI tests and full suite output。

---

### Task 5: 可测试的纯 AX 控件语义选择

**Files:**
- Create: `Sources/PDDAXReader/PDDAXSemanticNode.swift`
- Create: `Sources/PDDAXReader/PDDAXControlSelection.swift`
- Test: `Tests/PDDAXReaderTests/PDDAXControlSelectionTests.swift`

**Interfaces:**
- Produces: `PDDAXSemanticNode<ID>`, `PDDConversationCandidate<ID>`, `PDDAXControlSelection`。

```swift
struct PDDAXSemanticNode<ID: Hashable>: Equatable {
    let id: ID
    let parentID: ID?
    let role: String
    let value: String?
    let title: String?
    let domIdentifier: String?
    let domClasses: Set<String>
    let actionNames: Set<String>
    let isSettable: Bool
}
struct PDDConversationCandidate<ID: Hashable>: Equatable {
    let rowID: ID
    let visibleLabel: String
    let unreadCount: Int
}
struct PDDAXControlSelection<ID: Hashable> {
    static func conversationCandidates(in nodes: [PDDAXSemanticNode<ID>]) throws -> [PDDConversationCandidate<ID>]
    static func composer(in nodes: [PDDAXSemanticNode<ID>]) throws -> ID
    static func sendControl(in nodes: [PDDAXSemanticNode<ID>]) throws -> ID
}
```

- [ ] **Step 1: 写基于脱敏真实结构的选择失败测试**

覆盖当前实机证据：左侧 `AXList` 行含昵称和未读数字，当前 UID 位于资料区，composer 是唯一 settable `AXTextArea`，发送控件文本为“发送”且必须暴露 `AXPress`。

```swift
func testSelectsOnlyComposerUnderChatToolbar() throws {
    XCTAssertEqual(try PDDAXControlSelection.composer(in: fixtureNodes), "composer")
}
func testSelectsUnreadConversationRowWithoutTreatingOrderListAsConversation() throws {
    XCTAssertEqual(try PDDAXControlSelection.conversationCandidates(in: fixtureNodes).map(\.rowID), ["conversation-row"])
}
func testRejectsTwoSendControlsInsteadOfGuessing() {
    XCTAssertThrowsError(try PDDAXControlSelection.sendControl(in: fixtureNodes + [secondSendNode]))
}
func testRejectsSendControlWithoutAXPress() {
    XCTAssertThrowsError(try PDDAXControlSelection.sendControl(in: fixtureNodes.map(removingPressFromSend)))
}
```

- [ ] **Step 2: 运行测试并确认 RED**

Run: `swift test --filter PDDAXControlSelectionTests`

Expected: 编译失败，缺少语义节点与选择器。

- [ ] **Step 3: 实现结构约束选择器**

选择器必须联合使用祖先关系、DOM class/identifier、角色、settable 状态和动作，不允许只凭全页文字“发送”。返回 0 个或多个候选都抛 `PDDAXSelectionError.missing/ambiguous`。

- [ ] **Step 4: 增加主聊天区、订单区和侧栏同名噪声 fixtures 并跑 GREEN**

Run: `swift test --filter PDDAXControlSelectionTests`

Expected: 唯一选择测试通过，所有歧义测试明确失败。

- [ ] **Step 5: 检查点**

Run: `swift test`

Record: fixture 列表和完整 suite 结果。

---

### Task 6: AX 会话发现、切换和捕获驱动

**Files:**
- Create: `Sources/PDDAXReader/PDDAXBackend.swift`
- Create: `Sources/PDDAXReader/PDDAXConversationDriver.swift`
- Create: `Sources/PDDAXReader/AXNotificationWakeup.swift`
- Test: `Tests/PDDAXReaderTests/PDDAXConversationDriverTests.swift`

**Interfaces:**
- Consumes: Task 1/5 和现有 `AXTreeReader`, `PDDChatParser`, `PDDCustomerIdentity`。
- Produces: `PDDAXBackend`, `LivePDDAXBackend`, `PDDAXConversationDriver.discover()`, `capture(uid:after:)`。

```swift
struct AXElementToken: Hashable, Sendable {
    let rawValue: Int
}
struct PDDAXSemanticTree<ID: Hashable> {
    let rootSnapshot: AXNodeSnapshot
    let nodes: [PDDAXSemanticNode<ID>]
}
@MainActor protocol PDDAXBackend: AnyObject {
    func readSemanticTree() throws -> PDDAXSemanticTree<AXElementToken>
    func performPress(_ id: AXElementToken) throws
    func setValue(_ text: String, on id: AXElementToken) throws
    func value(of id: AXElementToken) throws -> String
}
```

- [ ] **Step 1: 写 UID 路由和首次基线失败测试**

```swift
func testDiscoverPressesUnreadRowThenReturnsResolvedUID() async throws {
    backend.trees = [conversationListTree, openedChatTree(uid: "GZC-000001")]
    XCTAssertEqual(try await driver.discover().map(\.uid), ["GZC-000001"]); XCTAssertEqual(backend.pressedIDs, ["conversation-row"])
}
func testUIDMismatchAfterRowPressProducesNoDiscovery() async throws {
    backend.trees = [conversationListTree, openedChatTree(uid: "GZC-999999")]
    XCTAssertTrue(try await driver.discover().isEmpty)
}
func testNoUnreadConversationCreatesBaselineWithoutJob() async throws {
    backend.trees = [conversationListWithoutUnread, openedChatTree(uid: "GZC-000001")]
    let capture = try await driver.capture(uid: "GZC-000001", after: .empty)
    XCTAssertNil(capture.batch); XCTAssertEqual(capture.customerCursor.count, 3)
}
func testUnreadFirstRunFreezesOnlyCustomerTailAfterLastService() async throws {
    backend.trees = [openedChatTree(messages: [customer("A"), service("S"), customer("B"), customer("C")])]
    let capture = try await driver.captureInitialUnread(uid: "GZC-000001")
    XCTAssertEqual(capture.batch?.events.map(\.messageID), ["B", "C"])
}
```

- [ ] **Step 2: 运行测试并确认 RED**

Run: `swift test --filter PDDAXConversationDriverTests`

Expected: 编译失败，缺少 backend/driver。

- [ ] **Step 3: 实现批量 AX live backend 和捕获**

`LivePDDAXBackend` 延续 `CFEqual` 元素身份、`AXChildrenInNavigationOrder`、批量属性读取和只设置一次 `AXEnhancedUserInterface`。按 `ElementID` 保存本次快照内的 `AXUIElement`；任何下一次读取都会使旧 ID 失效，动作前必须重新选择。

`PDDAXConversationDriver` 额外暴露 `openAndResolve(uid:) async throws -> PDDAXSemanticTree<AXElementToken>`：从最新快照唯一定位会话行、执行 `AXPress`、重新读取并要求资料区唯一 UID 精确一致。`capture` 用该方法打开 UID 后解析 `rootSnapshot`、合并历史、构建 `AutoReplyTimeline`，并使用 answered cursor 冻结尾部。图片保留历史但不进入 batch。它还比较 `knownServiceMessageIDsByUID`；首次基线只记录已有客服 ID，之后若发现既不在已知集合、也不在 `confirmedAutoReplyMessageIDsByUID` 的客服消息，则写入 `unexpectedServiceMessageIDs`，交给调度器隔离该 UID。

- [ ] **Step 4: 实现 AXObserver 仅作提前唤醒**

`AXNotificationWakeup` 尝试注册 children/value/layout/live-region 变化；不支持的通知记录诊断，不阻止 1.0 秒轮询。回调只触发 scheduler wake，不直接读取或操作 UI。

- [ ] **Step 5: 跑驱动和全量测试**

Run: `swift test --filter PDDAXConversationDriverTests && swift test`

Expected: fake backend 操作序列可预测；完整 suite 通过。

---

### Task 7: 三次 UID 核对、纯 AX 发送与回读确认

**Files:**
- Create: `Sources/PDDAXReader/PDDAXReplySender.swift`
- Test: `Tests/PDDAXReaderTests/PDDAXReplySenderTests.swift`

**Interfaces:**
- Consumes: `PDDAXBackend`, `PDDAXConversationDriver`, `PDDAXControlSelection`, `PDDChatParser`。
- Produces: `PDDAXReplySender.send(uid:text:expectedCustomerCursor:) -> AutoReplyDeliveryResult`。

```swift
struct PDDServiceMessageObservation: Equatable, Sendable {
    let id: String
    let content: String
}
```

- [ ] **Step 1: 写成功事务的失败测试**

```swift
func testSendChecksUIDBeforeWriteAfterWriteAndBeforePressThenConfirmsNewServiceMessage() async throws {
    let result = try await sender.send(uid: "GZC-000001", text: "请重新插拔电源", expectedCustomerCursor: cursorA)
    XCTAssertEqual(result, .sent(serviceMessageID: "middlePanel_list_201"))
    XCTAssertEqual(backend.operations, [
        "open:GZC-000001", "uid", "composerValue", "set:请重新插拔电源",
        "composerValue", "uid", "pressSend", "uid", "scanMessages"
    ])
}
```

- [ ] **Step 2: 运行测试并确认 RED**

Run: `swift test --filter PDDAXReplySenderTests`

Expected: 编译失败，缺少 sender。

- [ ] **Step 3: 实现事务和 3.0 秒确认窗口**

先通过 `openAndResolve(uid:)` 打开会话。写入前必须 composer 为空，并重新解析客户 timeline，要求其 cursor 等于 `expectedCustomerCursor`；写入后必须完整一致；三次 UID 检查均为唯一 `GZC-` 值。发送前保存客服消息 ID 集合；AXPress 后以 AX 通知提前唤醒、70–100ms 快照轮询，最多 3.0 秒。只有新 ID、同 UID、同文本的 service 消息返回 sent；返回的 ID 在调度器同一次原子保存中写入 `confirmedServiceMessageID` 和 `confirmedAutoReplyMessageIDsByUID[uid]`。

- [ ] **Step 4: 添加所有拒绝和不确定测试**

```swift
func testUnknownDraftFailsBeforeWriteWithoutClearingIt() async throws {
    backend.composerValue = "人工草稿"; let result = try await sender.send(uid: uid, text: reply, expectedCustomerCursor: cursorA)
    XCTAssertEqual(result, .failedBeforeSend("输入区存在未知草稿")); XCTAssertEqual(backend.setValues, [])
}
func testUIDChangesAfterWriteFailsBeforeSendAndLeavesEvidence() async throws {
    backend.uidReads = [uid, "GZC-000002"]; _ = try await sender.send(uid: uid, text: reply, expectedCustomerCursor: cursorA)
    XCTAssertEqual(backend.pressSendCount, 0); XCTAssertEqual(backend.composerValue, reply)
}
func testComposerReadbackMismatchNeverPressesSend() async throws {
    backend.readbackOverride = "被截断"; _ = try await sender.send(uid: uid, text: reply, expectedCustomerCursor: cursorA)
    XCTAssertEqual(backend.pressSendCount, 0)
}
func testMissingOrAmbiguousSendControlNeverPressesAnything() async throws {
    backend.sendControlCount = 2; _ = try await sender.send(uid: uid, text: reply, expectedCustomerCursor: cursorA)
    XCTAssertEqual(backend.pressSendCount, 0)
}
func testNoConfirmationAfterPressReturnsUncertainAndPressesOnlyOnce() async throws {
    backend.confirmationSnapshots = []; let result = try await sender.send(uid: uid, text: reply, expectedCustomerCursor: cursorA)
    XCTAssertEqual(result, .uncertain("发送后 3.0 秒内未获得 AX 回读确认")); XCTAssertEqual(backend.pressSendCount, 1)
}
func testMatchingOldServiceTextDoesNotConfirmNewSend() async throws {
    backend.existingServiceMessages = [.init(id: "old", content: reply)]; backend.confirmationSnapshots = [[.init(id: "old", content: reply)]]
    let result = try await sender.send(uid: uid, text: reply, expectedCustomerCursor: cursorA)
    XCTAssertEqual(result, .uncertain("发送后 3.0 秒内未获得 AX 回读确认"))
}
```

Run: `swift test --filter PDDAXReplySenderTests`

Expected: 全部通过；所有发送后超时测试的 `pressSend` 次数必须严格等于 1。

- [ ] **Step 5: 检查点**

Run: `swift test`

Record: sender tests 和完整 suite 结果。

---

### Task 8: 独立应用模式、运行锁和状态 UI

**Files:**
- Create: `Sources/PDDAXReader/PDDAppMode.swift`
- Create: `Sources/PDDAXReader/AutoReplyViewModel.swift`
- Create: `Sources/PDDAXReader/AutoReplyView.swift`
- Create: `Sources/PDDAXReader/AutoReplySessionLock.swift`
- Modify: `Sources/PDDAXReader/PDDAXReaderApp.swift`
- Test: `Tests/PDDAXReaderTests/PDDAppModeTests.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyViewModelTests.swift`

**Interfaces:**
- Consumes: Tasks 2–7。
- Produces: `.reader/.singleParse/.autoReply` bundle routing and operator controls。

- [ ] **Step 1: 写 bundle 路由和默认停止失败测试**

```swift
func testBundleIdentifiersRouteToThreeIndependentModes() {
    XCTAssertEqual(PDDAppMode(bundleIdentifier: "com.scy.pdd-auto-reply"), .autoReply)
}
@MainActor func testAutoReplyModelStartsStoppedInTestUIDMode() throws {
    let model = try AutoReplyViewModel(fixture: fixture)
    XCTAssertFalse(model.isRunning)
    XCTAssertEqual(model.scope, .testUID("GZC-000001"))
}
```

- [ ] **Step 2: 运行测试并确认 RED**

Run: `swift test --filter 'PDDAppModeTests|AutoReplyViewModelTests'`

Expected: 编译失败，缺少 app mode/view model。

- [ ] **Step 3: 实现模式路由、锁和 UI**

`PDDAXReaderApp` 根据 `PDDAppMode` 显示现有 `ContentView`、`SingleAXParseView` 或 `AutoReplyView`。自动 UI 包含开始/停止、干运行、测试 UID/全用户（锁定）、任务列表、游标、当前 UI owner、事件和 uncertain 警告。

`AutoReplySessionLock` 对 `~/Desktop/拼多多AX记录/自动回复/session.lock` 使用非阻塞 `flock`；第二实例显示错误且不能启动 scheduler。

- [ ] **Step 4: 添加权限、停止和 uncertain 展示测试**

Run: `swift test --filter 'PDDAppModeTests|AutoReplyViewModelTests'`

Expected: 默认停止、权限不足、锁冲突、干运行、uncertain 状态全部通过。

- [ ] **Step 5: 检查点**

Run: `swift test`

Record: UI model tests 和完整 suite 结果。

---

### Task 9: 独立 bundle 打包与自动验证

**Files:**
- Create: `Resources/AutoReplyInfo.plist`
- Modify: `scripts/build_app.sh`
- Modify: `README.md`
- Test: `Tests/PDDAXReaderTests/AutoReplyPackagingTests.swift`

**Interfaces:**
- Produces: `outputs/拼多多全自动客服.app`，不改变两个现有 bundle。

- [ ] **Step 1: 写打包契约失败测试**

```swift
func testAutoReplyInfoHasIndependentBundleAndExecutable() throws {
    let plist = try loadPlist("Resources/AutoReplyInfo.plist")
    XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "com.scy.pdd-auto-reply")
    XCTAssertEqual(plist["CFBundleExecutable"] as? String, "PDDAutoReply")
}
private func loadPlist(_ relativePath: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(relativePath))
    return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}
```

- [ ] **Step 2: 运行测试并确认 RED**

Run: `swift test --filter AutoReplyPackagingTests`

Expected: FAIL，`AutoReplyInfo.plist` 不存在。

- [ ] **Step 3: 添加第三个安全打包目标**

`build_app.sh` 对第三个 app 使用与现有两个 app 相同的明确路径白名单、Release 二进制复制和签名身份。不得删除 outputs 之外路径；不得改变现有 bundle ID。

- [ ] **Step 4: 构建和签名验证**

Run:

```bash
swift test
scripts/build_app.sh
plutil -lint Resources/AutoReplyInfo.plist
codesign --verify --deep --strict --verbose=2 'outputs/拼多多AX读取器.app'
codesign --verify --deep --strict --verbose=2 'outputs/拼多多AX单次解析测试器.app'
codesign --verify --deep --strict --verbose=2 'outputs/拼多多全自动客服.app'
```

Expected: 全部 exit 0，三个 app 都满足 designated requirement。

- [ ] **Step 5: 检查点**

Record: build output、三个 bundle ID、签名输出和最终文件清单。

---

### Task 10: 真实 AX 干运行、受控发送与最终回归

**Files:**
- Create: `evidence/pdd-auto-reply-live-validation-2026-08-28.md`
- Modify only if a test exposes a defect: corresponding source plus its regression test

**Interfaces:**
- Consumes: 完整应用。
- Produces: 测试 UID 的可审计实机证据和最终验收结论。

- [ ] **Step 1: 最终自动验证**

Run: `swift test && scripts/build_app.sh`

Expected: 0 failures，Release 构建成功。

- [ ] **Step 2: 用 Computer Use 启动独立 app 并验证默认停止**

读取 `com.scy.pdd-auto-reply` UI；确认 scheduler stopped、scope 为 `GZC-000001`、拼多多未被操作。所有 UI 操作用 `node_repl + @oai/sky`。

- [ ] **Step 3: 干运行验证发现、切换、UID 和冻结批次**

开启 dry-run；只允许 GZC-000001。记录发现 UID、AX 节点数、客户 cursor、冻结 target IDs 和 Codex 结果；断言发送控件 press 次数为 0。

- [ ] **Step 4: 输入但不发送验证**

通过 app 的测试事务让 sender AX 写入一段明确测试文本、回读一致后清空；不执行 AXPress。确认未知草稿保护和三次 UID 核对日志。

- [ ] **Step 5: 受控真实文字发送验证**

仅在 GZC-000001 测试会话执行一条普通低风险测试回复。记录发送前 service IDs、唯一 AXPress、发送后新增 service ID、完整文本和确认耗时。若确认超时，必须进入 uncertain，停止此 UID，禁止第二次 press。

- [ ] **Step 6: A/B/C 与图片规则验证**

用测试端依次制造：A；A 生成中 B/C；单独图片；图片加文字。验收：发送批次严格 `[A]`、`[B,C]`、`[图片后的文字]`；单独图片不生成、不发送。

- [ ] **Step 7: 重启恢复验证**

分别在 generating、ready 和 sending 测试夹具状态重启。generating 回到 queued，ready 保留原回复，sending 变 uncertain 且不自动重发。

- [ ] **Step 8: 写证据并重跑最终门禁**

`evidence/pdd-auto-reply-live-validation-2026-08-28.md` 记录每个场景的 UID、任务 ID、游标、发送结论和截图之外的 AX 文本证据，不写客户敏感内容全文。

Run:

```bash
swift test
scripts/build_app.sh
codesign --verify --deep --strict --verbose=2 'outputs/拼多多全自动客服.app'
```

Expected: 全部通过；只有测试 UID 模式开放，全用户模式仍锁定。
