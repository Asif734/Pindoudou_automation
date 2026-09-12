# 拼多多千牛同源自动回复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让拼多多自动回复与千牛使用完全相同的 AX、截图像素和 OCR 职责边界。

**Architecture:** AX 树只暴露结构、坐标、UID 和可操作控件；红点检测消费完整窗口截图与 AX 会话行坐标；OCR 消息独立持久化为自动回复历史。发送前由 OCR 驱动器复查游标，发送器只执行 AX UID/输入/按钮事务。

**Tech Stack:** Swift 5.9、Swift Concurrency、XCTest、macOS Accessibility、ScreenCaptureKit、PaddleOCR

**Spec:** `docs/superpowers/specs/2026-08-29-pdd-qianniu-source-parity-design.md`

## Global Constraints

- 暂不处理图片。
- 自动回复不得读取或合并 AX 聊天消息节点。
- OCR/截图失败只影响本轮，调度器必须继续运行。
- 发送按钮每个事务最多点击一次。

---

### Task 1: 截图像素红点发现

**Files:**
- Create: `Sources/PDDAXReader/PDDRedDotDetector.swift`
- Modify: `Sources/PDDAXReader/PDDAXSemanticNode.swift`
- Modify: `Sources/PDDAXReader/PDDAXBackend.swift`
- Modify: `Sources/PDDAXReader/PDDAXConversationDriver.swift`
- Test: `Tests/PDDAXReaderTests/PDDRedDotDetectorTests.swift`
- Test: `Tests/PDDAXReaderTests/PDDAXConversationDriverTests.swift`

**Interfaces:**
- Consumes: `PDDOCRFrame.fullWindowImage`, `PDDAXSemanticNode.frame`, `PDDAXControlSelection.conversationRows`
- Produces: `PDDUnreadEvidenceDetecting.unreadRows(tree:) async throws -> [PDDConversationRow<AXElementToken>]`

- [ ] **Step 1: Write the failing detector and discovery tests**

```swift
func testAXUnreadClassAloneDoesNotCreateUnreadEvidence() async throws {
    let driver = makeDriver(backend: backendWithUnreadClass, unread: FakeUnreadEvidence(rows: []), ocr: ocr)
    XCTAssertFalse(try await driver.discover().first?.hasUnreadEvidence ?? true)
}

func testPixelDotSelectsOnlyMatchingAXRow() {
    XCTAssertEqual(PDDRedDotDetector.targetIndexes(image: image, window: window, rows: rows), [1])
}
```

- [ ] **Step 2: Run tests to verify RED**

Run: `swift test --filter 'PDDRedDotDetectorTests|PDDAXConversationDriverTests'`

Expected: compile/test failure because `PDDUnreadEvidenceDetecting` and `PDDRedDotDetector` do not exist and discovery still trusts DOM unread classes.

- [ ] **Step 3: Implement frame capture and pixel routing**

Add optional `frame: CGRect` to semantic nodes, read `AXPosition`/`AXSize` in `LivePDDAXBackend`, port the tested red connected-component geometry from Qianniu, and inject a live unread detector into `PDDAXConversationDriver`.

- [ ] **Step 4: Run focused tests to verify GREEN**

Run: `swift test --filter 'PDDRedDotDetectorTests|PDDAXConversationDriverTests'`

Expected: selected suites finish with 0 failures.

### Task 2: OCR-only聊天历史

**Files:**
- Modify: `Sources/PDDAXReader/PDDAXConversationDriver.swift`
- Modify: `Sources/PDDAXReader/PerUserChatStore.swift`
- Delete from target: `Sources/PDDAXReader/PDDHybridHistoryReconciler.swift`
- Test: `Tests/PDDAXReaderTests/PDDAXConversationDriverTests.swift`

**Interfaces:**
- Consumes: `PDDOCRSupplementing.messages(uid:)`
- Produces: `capture(uid:after:)` whose `fullHistory` contains only OCR-derived messages

- [ ] **Step 1: Write failing OCR authority tests**

```swift
func testCaptureIgnoresAXMessageNodesAndPersistsOnlyOCR() async throws {
    let capture = try await driver.capture(uid: uid, after: .empty)
    XCTAssertEqual(capture.fullHistory.map(\.id), ["ocr-customer"])
    XCTAssertEqual(try store.load(uid: uid).map(\.id), ["ocr-customer"])
}
```

- [ ] **Step 2: Run test to verify RED**

Run: `swift test --filter PDDAXConversationDriverTests`

Expected: history includes the AX fixture message or OCR remains transient.

- [ ] **Step 3: Implement OCR-only conversion and persistence**

Convert every `PDDOCRMessage` directly to `PDDChatMessage`, merge it into `PerUserChatStore`, remove `PDDChatParser` and `PDDHybridHistoryReconciler` calls from the driver, and throw the OCR error instead of falling back to AX history.

- [ ] **Step 4: Run focused test to verify GREEN**

Run: `swift test --filter PDDAXConversationDriverTests`

Expected: suite finishes with 0 failures.

### Task 3: AX-only发送事务

**Files:**
- Modify: `Sources/PDDAXReader/PDDAXReplySender.swift`
- Modify: `Sources/PDDAXReader/PDDAXConversationDriver.swift`
- Test: `Tests/PDDAXReaderTests/PDDAXReplySenderTests.swift`

**Interfaces:**
- Consumes: pre-delivery OCR capture performed by `PDDLiveAutoReplyDriver.preflight`
- Produces: a sender that reads only UID, composer value and send control; successful clear-composer confirmation returns `.sent(serviceMessageID:)`

- [ ] **Step 1: Write failing sender test with no AX message nodes**

```swift
func testSendSucceedsWithoutAnyAXChatMessages() async throws {
    let backend = ReplyFakeBackend(trees: [controlOnlyTree, controlOnlyTree, controlOnlyTree], composerReadValues: [reply, ""])
    let result = try await sender.send(uid: uid, text: reply, expectedCustomerCursor: cursor)
    XCTAssertEqual(result, .sent(serviceMessageID: "ax-send-<stable digest>"))
    XCTAssertEqual(backend.pressSendCount, 1)
}
```

- [ ] **Step 2: Run test to verify RED**

Run: `swift test --filter PDDAXReplySenderTests`

Expected: current implementation fails because it requires AX customer messages and parses the AX message tree.

- [ ] **Step 3: Implement the minimal Qianniu-style transaction**

Open and verify UID, write and read back composer, reopen tree to verify UID and locate send, click once, then poll only UID and composer emptiness. Remove `PDDChatParser`, message ordinal, duplicate reply and hybrid cursor authorization from sender.

- [ ] **Step 4: Run sender tests to verify GREEN**

Run: `swift test --filter PDDAXReplySenderTests`

Expected: suite finishes with 0 failures and every case records at most one send press.

### Task 4: UI terminology and full verification

**Files:**
- Modify: `Sources/PDDAXReader/AutoReplyProgressPresentation.swift`
- Modify: `Sources/PDDAXReader/AutoReplyFloatingProgress.swift`
- Modify: `Sources/PDDAXReader/AutoReplyView.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyProgressPresentationTests.swift`

**Interfaces:**
- Consumes: OCR diagnostic and scheduler state
- Produces: “截图红点 + OCR 正文 + AX 操作”的准确 UI

- [ ] **Step 1: Change presentation expectations first and verify RED**

Run: `swift test --filter AutoReplyProgressPresentationTests`

Expected: old AX-red-dot wording fails.

- [ ] **Step 2: Update UI copy and verify GREEN**

Run: `swift test --filter AutoReplyProgressPresentationTests`

Expected: 0 failures and no automatic-reply UI labels messages as AX-derived.

- [ ] **Step 3: Run complete verification**

Run: `swift test`

Run: `PDD_LIVE_OCR=1 swift test --filter LivePDDOCRSmokeTests`

Run: `./scripts/build_app.sh`

Run: `codesign --verify --deep --strict outputs/拼多多全自动客服.app`

Expected: automated tests 0 failures, live OCR produces customer/service messages, build and signature checks exit 0.
