# 拼多多纯 AX 客服千牛能力等价迁移 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有拼多多纯 AX 全自动客服中接入千牛生产版完整客服 Prompt、V2 Top-12 知识检索、Codex 登录/诊断、不可变证据归档和长期运行状态，同时保持所有单任务错误非阻塞且暂不处理图片。

**Architecture:** 保留现有 `PDDLiveAutoReplyDriver → AutoReplyScheduler → PDDAXReplySender` 平台链路，在 `AutoReplyCodexGenerator` 前增加独立的知识资源、V2 检索和 Prompt 证据层，并把每轮检索/Codex/发送诊断随任务原子持久化。拼多多 UI 操作继续全局串行；V2 检索由 actor 串行加载本地模型；Codex 生成按现有内存策略跨 UID 并发。

**Tech Stack:** Swift 5.9、SwiftUI/AppKit、macOS Accessibility API、Foundation `Process`、CryptoKit、Python 3.12、FastEmbed/ONNX V2 检索、Codex CLI JSONL、XCTest。

**Spec:** `docs/superpowers/specs/2026-08-28-pdd-qianniu-feature-parity-design.md`

## Global Constraints

- 拼多多读取、发现、切换、写入、发送和确认只能使用 macOS Accessibility API。
- 禁止 OCR、截图、坐标、键盘事件、剪贴板、DOM 注入和拼多多网络接口。
- 固定 `gpt-5.6-sol`、`medium`、`approval=never` 和只读沙箱。
- 只接受本机 ChatGPT Codex 登录；每次 Codex 调用移除 `OPENAI_API_KEY` 与 `CODEX_API_KEY`。
- 每 UID 使用独立、精确的 Codex thread ID；禁止 `--last`。
- 图片只作为历史占位，不触发生成、不传给 Codex、不发送。
- 不引入阻塞式 `human_review`、`uncertain` 隔离或未知草稿门禁。
- 单任务 AX、检索、Codex 或发送错误不得停止全局客服；持久化失败是唯一允许停止的运行错误。
- 不修改千牛项目、千牛知识库原件或千牛运行状态。
- 当前工作目录没有 `.git`；不得擅自初始化仓库。每个任务用测试输出和文件清单作为检查点，跳过 Git commit。

---

## File Structure

- `Sources/PDDAXReader/KnowledgeModels.swift`: 检索输入、结果、模式和诊断值类型。
- `Sources/PDDAXReader/KnowledgeResourceLocator.swift`: 应用包、本机配置和旧 ZIP 路径解析。
- `Sources/PDDAXReader/KnowledgeBaseVersioner.swift`: 带元数据缓存的 SHA-256 版本计算。
- `Sources/PDDAXReader/V2KnowledgeRetriever.swift`: 串行本地 Python V2 Top-12 调用和输出校验。
- `Sources/PDDAXReader/KnowledgeEvidenceService.swift`: 聚焦历史、V2 调用、完整 ZIP 回退和统一诊断。
- `Sources/PDDAXReader/CustomerServicePrompt.swift`: 从千牛生产资源冻结的客服规则文本。
- `Sources/PDDAXReader/CodexInstallation.swift`: 本机 CLI 定位与 ChatGPT 登录状态。
- `Sources/PDDAXReader/CodexLoginCache.swift`: 登录成功短时缓存，失败不缓存。
- `Sources/PDDAXReader/AutoReplyDiagnostics.swift`: 检索、Codex、资源与发送阶段诊断。
- `Sources/PDDAXReader/RuntimeResourceMonitor.swift`: 内存、CLI 数、排队数和延迟快照。
- `Resources/CustomerService/customer-reply-prompt.md`: 千牛生产客服 Prompt 的拼多多平台版本。
- `Resources/V2Knowledge/`: 千牛已验证的检索脚本、依赖和只读种子缓存。
- `Resources/KnowledgeBase/Grozziie-China-KB-2026-08-24.zip`: 构建时复制的只读知识库。
- `Tests/PDDAXReaderTests/Knowledge*Tests.swift`: 资源、版本、检索和回退测试。
- `Tests/PDDAXReaderTests/CodexInstallationTests.swift`: CLI 和登录缓存测试。
- `Tests/PDDAXReaderTests/AutoReplyDiagnosticsTests.swift`: 状态迁移和证据归档测试。
- `Tests/PDDAXReaderTests/HardKnowledgeRegressionTests.swift`: 不发送的高难知识题测试入口。

### Task 1: Freeze the Customer-Service and Knowledge Contracts

**Files:**
- Create: `Sources/PDDAXReader/KnowledgeModels.swift`
- Create: `Sources/PDDAXReader/CustomerServicePrompt.swift`
- Create: `Resources/CustomerService/customer-reply-prompt.md`
- Modify: `Sources/PDDAXReader/AutoReplyModels.swift`
- Modify: `Sources/PDDAXReader/AutoReplyPromptBuilder.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyPromptBuilderTests.swift`
- Create: `Tests/PDDAXReaderTests/KnowledgeModelsTests.swift`

**Interfaces:**
- Produces: `KnowledgeRetrievalMode`, `RetrievedKnowledge`, `KnowledgeRetrievalDiagnostic`, `KnowledgeEvidence`.
- Produces: `CustomerServicePrompt.load(bundle:) throws -> String`.
- Changes: `AutoReplyCapture` gains an optional `knowledgeEvidence` with a decoding default of `nil` for old state.
- Consumes: existing `AutoReplyCapture`, `FrozenCustomerBatch`, `PDDChatMessage`.

- [ ] **Step 1: Add failing contract tests**

Add tests that construct an old capture without evidence and assert it decodes, then assert the new Prompt contains the exact frozen batch, full history, retrieved knowledge, `HTTP 或 HTTPS`, and no image attachment section:

```swift
func testPromptUsesRetrievedEvidenceAndKeepsFrozenBatchSeparate() throws {
    let evidence = KnowledgeEvidence(
        mode: .v2Top12,
        version: "v2-top12",
        documents: ["m880.md"],
        context: "原文：http://cloud.video.taobao.com/example.mp4",
        diagnostic: .fixture
    )
    let capture = Fixtures.capture(evidence: evidence)
    let prompt = try AutoReplyPromptBuilder.build(capture: capture, bundle: .module)
    XCTAssertTrue(prompt.contains("<untrusted_retrieved_knowledge>"))
    XCTAssertTrue(prompt.contains(capture.batch!.targetCustomerJSONL))
    XCTAssertTrue(prompt.contains("HTTP 或 HTTPS"))
    XCTAssertFalse(prompt.contains("chat_image_attachments"))
}
```

- [ ] **Step 2: Run the target tests and verify RED**

Run:

```bash
swift test --filter 'AutoReplyPromptBuilderTests|KnowledgeModelsTests'
```

Expected: compile failure because the knowledge types and resource-backed Prompt do not exist.

- [ ] **Step 3: Add the minimal knowledge value types**

Implement exact public-in-module shapes:

```swift
enum KnowledgeRetrievalMode: String, Codable, Sendable {
    case v2Top12 = "v2-top12"
    case fullZipFallback = "full-zip-fallback"
}

struct RetrievedKnowledge: Codable, Equatable, Sendable {
    let version: String
    let documents: [String]
    let context: String
}

struct KnowledgeRetrievalDiagnostic: Codable, Equatable, Sendable {
    let mode: KnowledgeRetrievalMode
    let knowledgeBaseSHA256: String?
    let selectedDocuments: [String]
    let contextSHA256: String?
    let durationMilliseconds: Int
    let error: String?
}

struct KnowledgeEvidence: Codable, Equatable, Sendable {
    let mode: KnowledgeRetrievalMode
    let version: String
    let documents: [String]
    let context: String
    let diagnostic: KnowledgeRetrievalDiagnostic
}
```

Use custom decoding only where needed to keep schema-1 state readable.

- [ ] **Step 4: Freeze the Prompt resource and builder**

Copy the verified customer-service rules from the current千牛 production resource, then adapt only platform words and approved image exclusions. `AutoReplyPromptBuilder.build` must take the selected resource text, frozen target JSONL, full history JSONL and optional trusted retrieved context. Put all chat data inside `<untrusted_chat_data>` and all retrieved source text inside `<untrusted_retrieved_knowledge>`.

- [ ] **Step 5: Run focused and existing Prompt tests**

Run:

```bash
swift test --filter 'AutoReplyPromptBuilderTests|CustomerReplyPromptBuilderTests|KnowledgeModelsTests'
```

Expected: all selected tests pass and no existing plain-reply schema changes.

- [ ] **Step 6: Record Task 1 checkpoint**

Record the passing command and changed files in `evidence/pdd-qianniu-parity-task-checkpoints.md`. Do not initialize Git.

### Task 2: Package and Resolve Verified Knowledge Resources

**Files:**
- Create: `Sources/PDDAXReader/KnowledgeResourceLocator.swift`
- Create: `Sources/PDDAXReader/KnowledgeBaseVersioner.swift`
- Create: `Tests/PDDAXReaderTests/KnowledgeResourceLocatorTests.swift`
- Create: `Tests/PDDAXReaderTests/KnowledgeBaseVersionerTests.swift`
- Modify: `scripts/build_app.sh`
- Modify: `Tests/PDDAXReaderTests/AutoReplyPackagingTests.swift`
- Create mechanically: `Resources/V2Knowledge/`
- Create mechanically: `Resources/KnowledgeBase/Grozziie-China-KB-2026-08-24.zip`

**Interfaces:**
- Produces: `KnowledgeResources(knowledgeBaseURL:scriptURL:pythonURL:sitePackagesURL:seedCacheURL:writableCacheURL:)`.
- Produces: `KnowledgeResourceLocator.resolve(bundle:environment:fileManager:) -> KnowledgeResources?`.
- Produces: `KnowledgeBaseVersioner.version(url:) async throws -> String`.
- Consumes: resource files from the verified千牛 build and the approved desktop ZIP without modifying their source bytes.

- [ ] **Step 1: Write failing resource precedence and hashing tests**

Cover bundle-first precedence, explicit environment fallback, legacy desktop ZIP fallback, missing V2 returning `nil`, writable cache under Application Support, hash reuse when size/date are unchanged, and invalidation after content change:

```swift
func testBundledKnowledgeWinsOverLegacyDesktopPath() throws {
    let result = KnowledgeResourceLocator.resolve(
        bundle: fixtureBundle,
        environment: ["PDD_KNOWLEDGE_ZIP": legacy.path],
        fileManager: .default
    )
    XCTAssertEqual(result?.knowledgeBaseURL, bundledZIP)
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --filter 'KnowledgeResourceLocatorTests|KnowledgeBaseVersionerTests|AutoReplyPackagingTests'
```

Expected: compile failure for the missing locator/versioner and packaging assertions.

- [ ] **Step 3: Copy verified resources with byte-level evidence**

Mechanically copy the latest verified `Resources/V2Knowledge` tree from the千牛 production worktree into this project and copy the approved knowledge ZIP into `Resources/KnowledgeBase`. Before and after copying, compute SHA-256 manifests:

```bash
find Resources/V2Knowledge -type f -print0 | sort -z | xargs -0 shasum -a 256 > evidence/pdd-v2-resource-sha256.txt
shasum -a 256 Resources/KnowledgeBase/Grozziie-China-KB-2026-08-24.zip > evidence/pdd-knowledge-zip-sha256.txt
```

The manifest itself is evidence; do not edit the copied V2 algorithms during this task.

- [ ] **Step 4: Implement locator and cached SHA-256 versioner**

Resolve the following resource layout exactly:

```text
Contents/Resources/V2Knowledge/retrieve_top12.py
Contents/Resources/V2Knowledge/site-packages/
Contents/Resources/V2Knowledge/cache/
Contents/Resources/KnowledgeBase/Grozziie-China-KB-2026-08-24.zip
```

Use `CryptoKit.SHA256`; cache digest by path, byte size and modification date.

- [ ] **Step 5: Update package construction**

Make `scripts/build_app.sh` copy `CustomerService`, `V2Knowledge` and `KnowledgeBase` into only `拼多多全自动客服.app`. Add a path guard for every destination. Build must fail if required production resources are absent or their copied SHA differs from the source.

- [ ] **Step 6: Run resource and packaging tests**

Run:

```bash
swift test --filter 'KnowledgeResourceLocatorTests|KnowledgeBaseVersionerTests|AutoReplyPackagingTests'
```

Expected: all pass.

- [ ] **Step 7: Record Task 2 checkpoint**

Append the passing command, resource manifest paths and changed files to `evidence/pdd-qianniu-parity-task-checkpoints.md`.

### Task 3: Port the Serialized V2 Top-12 Retriever

**Files:**
- Create: `Sources/PDDAXReader/V2KnowledgeRetriever.swift`
- Create: `Sources/PDDAXReader/KnowledgeEvidenceService.swift`
- Create: `Tests/PDDAXReaderTests/V2KnowledgeRetrieverTests.swift`
- Create: `Tests/PDDAXReaderTests/KnowledgeEvidenceServiceTests.swift`

**Interfaces:**
- Produces protocol: `KnowledgeContextRetrieving.retrieve(historyJSONL:knowledgeBaseURLs:) async throws -> RetrievedKnowledge`.
- Produces actor: `V2KnowledgeRetriever` with the six resource URLs from Task 2.
- Produces: `KnowledgeEvidencePreparing.prepare(capture:) async -> KnowledgeEvidence`.
- `KnowledgeEvidenceService` consumes `KnowledgeContextRetrieving`, `KnowledgeBaseVersioner`, knowledge URLs and a monotonic clock.

- [ ] **Step 1: Write failing request/output tests**

Use a fake executable script to assert request JSON keys, UTF-8 preservation, seed/writable cache paths, `PYTHONPATH`, serialized actor calls, stderr truncation, nonzero exit and invalid version rejection. Test `focusedHistoryJSONL` with 40 old-product lines plus a new frozen batch:

```swift
func testFocusedHistoryKeepsTargetAndDropsOldProductNoise() {
    let focused = V2KnowledgeRetriever.focusedHistoryJSONL(
        fullHistoryJSONL: Fixtures.longHistory,
        targetCustomerJSONL: Fixtures.m880Target,
        recentLineLimit: 24
    )
    XCTAssertTrue(focused.contains("M880停电后不开机"))
    XCTAssertFalse(focused.contains("old-TP732-01"))
}
```

- [ ] **Step 2: Write failing fallback tests**

Assert that missing resources, thrown retriever errors, empty context and invalid `version` all return `.fullZipFallback`, preserve the ZIP path/version hash and contain a diagnostic error without throwing to the scheduler.

- [ ] **Step 3: Verify RED**

Run:

```bash
swift test --filter 'V2KnowledgeRetrieverTests|KnowledgeEvidenceServiceTests'
```

Expected: compile failure because the retriever and service are absent.

- [ ] **Step 4: Implement the retriever actor**

Port the verified千牛 process contract exactly:

```swift
protocol KnowledgeContextRetrieving: Sendable {
    func retrieve(historyJSONL: String, knowledgeBaseURLs: [URL]) async throws -> RetrievedKnowledge
}

protocol KnowledgeEvidencePreparing: Sendable {
    func prepare(capture: AutoReplyCapture) async -> KnowledgeEvidence
}
```

Write request/result/stderr into a unique temporary directory, set `TOKENIZERS_PARALLELISM=false`, invoke Python with `--request` and `--output`, require exit 0, `version == "v2-top12"`, a nonempty context, and always remove the temporary directory.

- [ ] **Step 5: Implement non-throwing evidence preparation**

`prepare(capture:)` must always return `KnowledgeEvidence`. On success include selected files, context SHA and duration. On any failure return `.fullZipFallback` with empty retrieved context, knowledge ZIP SHA, duration and exact error text.

- [ ] **Step 6: Run retriever tests and the copied Python regression**

Run:

```bash
swift test --filter 'V2KnowledgeRetrieverTests|KnowledgeEvidenceServiceTests'
python3 -m unittest discover -s Tests/V2KnowledgePythonTests -p 'test_*.py' -v
```

If the Python tests live only in the verified source tree, first copy the exact regression fixtures and test scripts into `Tests/V2KnowledgePythonTests/` with their hashes.

Expected: all Swift and Python retrieval tests pass.

- [ ] **Step 7: Record Task 3 checkpoint**

Append test outputs and file hashes to the checkpoint document.

### Task 4: Add Codex Installation, Login Cache and Execution Diagnostics

**Files:**
- Create: `Sources/PDDAXReader/CodexInstallation.swift`
- Create: `Sources/PDDAXReader/CodexLoginCache.swift`
- Create: `Sources/PDDAXReader/AutoReplyDiagnostics.swift`
- Modify: `Sources/PDDAXReader/CodexProcessRunner.swift`
- Modify: `Sources/PDDAXReader/AutoReplyCodexGenerator.swift`
- Modify: `Sources/PDDAXReader/AutoReplyModels.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyCodexGeneratorTests.swift`
- Create: `Tests/PDDAXReaderTests/CodexInstallationTests.swift`
- Create: `Tests/PDDAXReaderTests/CodexLoginCacheTests.swift`

**Interfaces:**
- Produces: `CodexInstallation.resolve(fileManager:environment:) -> URL?`.
- Produces: `CodexLoginChecking.check(executable:) async throws -> CodexLoginStatus`.
- Produces actor: `CodexLoginCache.status(executable:now:) async throws -> CodexLoginStatus` with 60-second success TTL and no failure cache.
- Changes: `CodexProcessResult` gains structured `events: [CodexExecutionEvent]` and `durationMilliseconds`.
- Changes: `CodexReplyResult` and `AutoReplyJob` carry `AutoReplyGenerationDiagnostic`.
- Consumes: `KnowledgeEvidencePreparing` from Task 3.

- [ ] **Step 1: Write failing CLI discovery/login tests**

Assert precedence for explicit `PDD_CODEX_PATH`, ChatGPT.app, Codex.app, Homebrew and PATH. Assert that only output equivalent to `Logged in using ChatGPT` is accepted. Failure and API-key login are not accepted.

- [ ] **Step 2: Write failing generator diagnostic tests**

Use fake retriever and fake runner to assert ordering `prepare evidence → build Prompt → run Codex`, exact V2 context in stdin, no image arguments, API environment stripping, event capture, duration, thread ID persistence, fallback diagnostic and no cross-UID session reuse.

- [ ] **Step 3: Verify RED**

Run:

```bash
swift test --filter 'CodexInstallationTests|CodexLoginCacheTests|AutoReplyCodexGeneratorTests'
```

Expected: compile/test failures for new installation, login and diagnostic contracts.

- [ ] **Step 4: Implement installation and login cache**

Search only executable candidates; never read or copy `~/.codex/auth.json`. Run `codex login status` through the same environment-stripping process boundary. Cache only a confirmed ChatGPT login for 60 seconds.

- [ ] **Step 5: Integrate evidence into generation**

Change generator construction to require a `KnowledgeEvidencePreparing`. Build a copy of the capture containing returned evidence, then build the Prompt. Keep schema `{ "reply": string }`, 1000-character validation, exact `thread.started` and `turn.completed` requirements.

- [ ] **Step 6: Run Codex-focused tests**

Run:

```bash
swift test --filter 'CodexInstallationTests|CodexLoginCacheTests|AutoReplyCodexGeneratorTests|CodexReplyServiceTests|CodexSessionRegistryTests'
```

Expected: all pass.

- [ ] **Step 7: Record Task 4 checkpoint**

Append test evidence and new interface names to the checkpoint document.

### Task 5: Upgrade Durable State and Immutable Evidence Archives

**Files:**
- Modify: `Sources/PDDAXReader/AutoReplyModels.swift`
- Modify: `Sources/PDDAXReader/AutoReplyStore.swift`
- Modify: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyStoreTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`
- Create: `Tests/PDDAXReaderTests/AutoReplyDiagnosticsTests.swift`

**Interfaces:**
- Changes: `AutoReplyPersistentState.schemaVersion` becomes 2.
- Produces: `AutoReplyArchiveRecord` containing frozen cursors, history/batch hashes, knowledge diagnostic, Codex diagnostic, reply and delivery evidence.
- Produces: `AutoReplyStore.archive(record:)` writing one immutable JSON record and one read-only reply sidecar.
- Consumes: Task 4 generation diagnostics and existing delivery result/message ID.

- [ ] **Step 1: Write failing schema migration tests**

Create raw schema-1 JSON fixtures covering completed, generating, sending, uncertain and quarantined jobs. Assert schema-2 loading preserves completed work, requeues generation, converts interrupted/legacy blocking states to failed non-blocking records, advances the approved processing cursor, and never recreates a sendable ready task.

- [ ] **Step 2: Write failing archive tests**

Assert record JSON includes all required hashes and timings; sidecar contains job ID, UID, reply and conservative delivery text; a second archive call cannot overwrite different bytes for the same job ID.

- [ ] **Step 3: Verify RED**

Run:

```bash
swift test --filter 'AutoReplyStoreTests|AutoReplyDiagnosticsTests|AutoReplySchedulerTests'
```

Expected: failures for schema 2 and the richer immutable archive.

- [ ] **Step 4: Implement schema-1 to schema-2 migration**

Decode schema number first. Convert old captures/jobs with default diagnostic fields. Before replacing `state.json`, write `state.schema1-backup-<timestamp>.json` once and use atomic replacement for schema 2.

- [ ] **Step 5: Build and archive the evidence record at terminal transition**

Only the scheduler constructs `AutoReplyArchiveRecord`, using the already frozen batch/history plus generator and delivery diagnostics. Archive after state persistence succeeds. Archive failure becomes a durable event and retryable side effect; it must not cause message re-send.

- [ ] **Step 6: Run state and scheduler tests**

Run:

```bash
swift test --filter 'AutoReplyStoreTests|AutoReplyDiagnosticsTests|AutoReplySchedulerTests|AutoReplyTimelineTests'
```

Expected: all pass, including existing “failure continues” cases.

- [ ] **Step 7: Record Task 5 checkpoint**

Append migration fixture names and test output to the checkpoint document.

### Task 6: Add Runtime Health and Resource Telemetry Without New Gates

**Files:**
- Create: `Sources/PDDAXReader/RuntimeResourceMonitor.swift`
- Modify: `Sources/PDDAXReader/AutoReplyScheduler.swift`
- Modify: `Sources/PDDAXReader/AdaptiveConcurrencyPolicy.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyCodexGeneratorTests.swift`
- Create: `Tests/PDDAXReaderTests/RuntimeResourceMonitorTests.swift`

**Interfaces:**
- Produces: `RuntimeResourceSnapshot(date:availableMemoryBytes:activeCLI:queueDepth:lastLatencyMilliseconds:)`.
- Produces: `RuntimeResourceMonitoring.snapshot(activeCLI:queueDepth:lastLatencyMilliseconds:) -> RuntimeResourceSnapshot`.
- Adds scheduler read-only properties: `latestResourceSnapshot`, `lastRuntimeIssue`, `knowledgeStatus`.
- Consumes: existing `AdaptiveConcurrencyPolicy`; does not create an additional scheduler or timer.

- [ ] **Step 1: Write failing health tests**

Cover memory pressure reducing only new generation capacity, active tasks finishing, AX discovery continuing, repeated identical error coalescing, a later success clearing the warning, and persistence failure remaining the sole global stop.

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --filter 'RuntimeResourceMonitorTests|AutoReplySchedulerTests|AutoReplyCodexGeneratorTests'
```

Expected: failures for missing telemetry and health status.

- [ ] **Step 3: Implement resource snapshots and scheduler health publication**

Sample only during existing scheduler ticks or state changes. Do not add a high-frequency timer. Preserve the current concurrency formula and hard ceiling; publish the input/output values used to choose capacity.

Use this exact protocol so tests can inject memory values without touching system state:

```swift
protocol RuntimeResourceMonitoring: Sendable {
    func snapshot(
        activeCLI: Int,
        queueDepth: Int,
        lastLatencyMilliseconds: Int?
    ) -> RuntimeResourceSnapshot
}
```

- [ ] **Step 4: Prove no new blocking gate exists**

Add assertions that `uncertain`, retrieval fallback, login failure, Codex failure, sender preflight failure and send-confirmation timeout all leave `isRunning == true` when persistence remains healthy.

- [ ] **Step 5: Run runtime tests**

Run:

```bash
swift test --filter 'RuntimeResourceMonitorTests|AdaptiveConcurrencyPolicy|AutoReplySchedulerTests'
```

Expected: all pass.

- [ ] **Step 6: Record Task 6 checkpoint**

Append test results and the absence of new timers/processes to the checkpoint document.

### Task 7: Surface Knowledge, Codex and Recovery State in the UI

**Files:**
- Modify: `Sources/PDDAXReader/AutoReplyViewModel.swift`
- Modify: `Sources/PDDAXReader/AutoReplyView.swift`
- Modify: `Sources/PDDAXReader/AutoReplyFloatingProgress.swift`
- Modify: `Sources/PDDAXReader/AutoReplyProgressPresentation.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyViewModelTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyFloatingProgressTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplyProgressPresentationTests.swift`

**Interfaces:**
- `AutoReplyRunning` exposes CLI path/login, knowledge version/mode, latest resource snapshot and latest retrieval summary.
- `AutoReplyViewModel` publishes those values without starting extra AX scans.
- Progress presentation adds deterministic labels for retrieval, fallback and recovery states.

- [ ] **Step 1: Write failing view-model and presentation tests**

Assert the UI shows actual CLI path, `gpt-5.6-sol · medium`, knowledge SHA prefix, `V2 Top-12` or `完整 ZIP 回退`, retrieved document count/time, resource snapshot and “错误后继续扫描”. Assert warnings never become the active headline when no active job exists.

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --filter 'AutoReplyViewModelTests|AutoReplyFloatingProgressTests|AutoReplyProgressPresentationTests'
```

Expected: failures for the missing published fields and labels.

- [ ] **Step 3: Wire read-only state to the existing windows**

Add a compact environment/status group to the main window and retrieval stages to the floating panel. Add `NSWorkspace.shared.open(rootDirectory)` behind an “打开记录目录” button. Keep the progress panel movable, resizable and closable while automation is running.

- [ ] **Step 4: Run UI contract tests**

Run:

```bash
swift test --filter 'AutoReplyViewModelTests|AutoReplyFloatingProgressTests|AutoReplyProgressPresentationTests'
```

Expected: all pass and no UI method invokes `discover`, `capture` or any AX read.

- [ ] **Step 5: Record Task 7 checkpoint**

Append UI test output and changed view files to the checkpoint document.

### Task 8: Add Hard Knowledge Regressions and Full Non-Sending Integration Tests

**Files:**
- Create: `Tests/PDDAXReaderTests/HardKnowledgeRegressionTests.swift`
- Create: `Tests/V2KnowledgePythonTests/` from verified fixtures
- Modify: `Tests/PDDAXReaderTests/AutoReplyCodexGeneratorTests.swift`
- Modify: `Tests/PDDAXReaderTests/AutoReplySchedulerTests.swift`
- Create: `evidence/pdd-hard-knowledge-report.json` during verification

**Interfaces:**
- Consumes: real bundled V2 resources and knowledge ZIP.
- Produces: an opt-in environment-gated test `PDD_RUN_REAL_CODEX_KB_TESTS=1` that never constructs a sender or touches拼多多.
- Produces: deterministic retrieval-only tests that run by default.

- [ ] **Step 1: Add deterministic retrieval regression cases**

Freeze at least these query classes with expected document names, required tokens/links and forbidden mismatched links: old-model history then M880, TD630G on Mac Wi-Fi, AK890 iPhone/Bluetooth/Wi-Fi, third-party attendance card groups, Windows unknown USB descriptor, continued ribbon troubleshooting, overlapping overnight shifts and two questions in one batch.

- [ ] **Step 2: Run retrieval-only cases**

Run:

```bash
swift test --filter HardKnowledgeRegressionTests
python3 -m unittest discover -s Tests/V2KnowledgePythonTests -p 'test_*.py' -v
```

Expected: all retrieval cases pass without Codex or AX access.

- [ ] **Step 3: Add opt-in real Codex evaluator**

The test creates `AutoReplyCodexGenerator` with real resources, a fake/no-op automation driver, delivery disabled and eight frozen captures. It records question, selected documents, reply, retrieval time and Codex time to the JSON report. It must fail if a reply invents a forbidden link or omits required facts, but it must not require one exact wording.

- [ ] **Step 4: Run the real model suite**

Run:

```bash
PDD_RUN_REAL_CODEX_KB_TESTS=1 swift test --filter HardKnowledgeRegressionTests/testRealCodexKnowledgeAnswers
```

Expected: all eight cases meet their semantic assertions; report contains no send attempt.

- [ ] **Step 5: Run global non-blocking integration cases**

Use fake driver/generator/sender cases for three UIDs where A retrieval fails and falls back, B Codex fails, and C sends successfully. Assert the scheduler stays running and C completes. Add a send-confirmation timeout case followed by another UID completion.

- [ ] **Step 6: Record Task 8 checkpoint**

Append retrieval/model reports and test commands to the checkpoint document.

### Task 9: Build, Sign and Perform Safe Live Validation

**Files:**
- Modify: `README.md`
- Modify: `evidence/pdd-auto-reply-live-validation-2026-08-28.md`
- Modify: `evidence/pdd-qianniu-parity-task-checkpoints.md`
- Build output: `outputs/拼多多全自动客服.app`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: signed release app containing verified Prompt, V2 and knowledge resources.
- Does not install over another app outside `outputs/` and does not alter千牛.

- [ ] **Step 1: Run the complete automated suite from a clean build**

Run:

```bash
swift package clean
swift test
```

Expected: every test passes, including all pre-existing pure AX and scheduling tests.

- [ ] **Step 2: Build all three apps and verify package contents**

Run:

```bash
scripts/build_app.sh
codesign --verify --deep --strict --verbose=2 outputs/拼多多全自动客服.app
test -f outputs/拼多多全自动客服.app/Contents/Resources/V2Knowledge/retrieve_top12.py
test -f outputs/拼多多全自动客服.app/Contents/Resources/KnowledgeBase/Grozziie-China-KB-2026-08-24.zip
test -f outputs/拼多多全自动客服.app/Contents/Resources/CustomerService/customer-reply-prompt.md
```

Expected: build succeeds, signature is valid and all required files exist.

- [ ] **Step 3: Verify resource byte parity and banned payloads**

Compare source/bundle SHA-256 manifests. Search the app for `auth.json`, `.codex`, API keys,千牛 histories, OCR model names and ScreenCaptureKit symbols. Expected: resources match and no banned payload exists.

- [ ] **Step 4: Launch in dry-run mode and inspect UI**

Open the new output app, enable dry run before live discovery if needed, and verify from the UI: CLI path/login, model/reasoning, V2 mode, knowledge version, retrieval progress, movable/closable panel and continuing status. Do not send.

- [ ] **Step 5: Perform one controlled real-text validation**

With the approved拼多多 test UID, send one unique customer text that requires knowledge retrieval. Verify: AX red dot discovery, UID match, frozen batch, V2 documents, Codex reply, AX write, AXPress send, new service message ID and terminal archive. Do not use an image or modify order controls.

- [ ] **Step 6: Validate failure continuation**

Induce one safe pre-send failure (for example temporarily unavailable test input control), restore the UI, and verify the warning moves to history while a later customer observation is processed. Never induce a duplicate real send.

- [ ] **Step 7: Update documentation and final evidence**

Document exact test counts, real validation UID/message IDs, resource hashes, build signature result, fallback behavior and any remaining limitations. State explicitly that images remain unsupported and千牛 was untouched.

- [ ] **Step 8: Final verification-before-completion pass**

Re-run:

```bash
swift test
codesign --verify --deep --strict --verbose=2 outputs/拼多多全自动客服.app
```

Expected: fresh success immediately before claiming completion.
