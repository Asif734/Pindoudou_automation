# 拼多多红点驱动 OCR 自动回复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 AX 红点或 AX 变化事件立即触发当前会话 OCR，空闲时仅每 10 秒进行一次低频 OCR 兜底。

**Architecture:** `PDDAXConversationDriver` 继续负责红点发现、会话点击、UID 核对与 AX/OCR 合并。`AutoReplyScheduler` 根据 `hasUnreadEvidence` 决定是否立即捕获，并为无红点的当前会话维护 10 秒兜底节流；AX 通知允许一次立即捕获，但后续快速红点重试不重复启动 OCR。单次发现、OCR 或 AX 错误仍只记警告并进入下一轮。

**Tech Stack:** Swift 5.9、Swift Concurrency、XCTest、macOS Accessibility、ScreenCaptureKit/PaddleOCR

**Spec:** `docs/superpowers/specs/2026-08-29-pdd-ax-ocr-hybrid-design.md`

## Global Constraints

- 暂不处理图片。
- OCR/截图错误不能停止调度器。
- 红点优先，不连续对无变化的当前会话运行 OCR。
- 发送、输入、会话点击继续使用 AX。

---

### Task 1: 红点优先与低频兜底调度

**Files:**
- Modify: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`

**Interfaces:**
- Consumes: `AutoReplyDiscovery(uid:hasUnreadEvidence:)`、`requestAXRefresh()`、`driver.capture(uid:after:)`
- Produces: `AutoReplyScheduler` 的红点立即捕获、10 秒无红点兜底和单次 AX 通知捕获行为

- [x] **Step 1: Write the failing tests**

新增行为测试，分别证明：重复的无红点发现不会在 10 秒内再次 OCR；10 秒后会兜底捕获；红点不受节流；一次 AX 通知只放行一次无红点捕获。

- [x] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AutoReplySchedulerTests`

Expected: 新增测试因当前每次发现都会 `enqueueCapture` 而失败。

- [x] **Step 3: Write minimal implementation**

在调度器中增加每 UID 的最近被动捕获时间、10 秒间隔，以及一个可消费的 AX 通知捕获标志。发现结果为红点时立即入队；无红点时只在首次、间隔到期或通知标志尚未消费时入队。

- [x] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AutoReplySchedulerTests`

Expected: 该测试套件 0 failures。

### Task 2: 进度文案与完整验证

**Files:**
- Modify: `Sources/PDDAXReader/AutoReplyProgressPresentation.swift`
- Modify: `Sources/PDDAXReader/AutoReplyView.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyProgressPresentationTests.swift`

**Interfaces:**
- Consumes: `currentUIOwner` 与空闲状态
- Produces: 明确显示“AX 红点驱动 + OCR 读取 + 10 秒兜底”的运行状态

- [x] **Step 1: Write the failing presentation tests**

把空闲和捕获期的期望文案改为红点驱动 OCR 的真实语义。

- [x] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AutoReplyProgressPresentationTests`

Expected: 旧文案与新期望不一致。

- [x] **Step 3: Implement the presentation wording**

更新浮窗标题、主窗口范围文字和最近解析分组标题，不改变任何发送逻辑。

- [x] **Step 4: Run focused and full verification**

Run: `swift test`

Run: `./scripts/build_app.sh`

Run: `codesign --verify --deep --strict outputs/拼多多全自动客服.app`

Expected: 测试 0 failures，Release 构建与签名验证退出码均为 0。
