# PDD 一比一复刻千牛 Codex/V2 运行内核 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用千牛当前生产结构替换 PDD 独立的 V2、Prompt、Codex CLI、流式交付和增量 session 实现，消除 Codex 自行搜索磁盘造成的 35–62 秒异常。

**Architecture:** PDD 的页面采集、任务调度和发送保持不变；在 `AutoReplyCapture` 与千牛生成内核之间增加薄适配。知识侧统一 `sender + v` 协议并复用千牛常驻 V2 worker；生成侧复用千牛 invocation、history continuation、stream/handoff 和 bounded process，仅在输入输出边界映射 PDD 类型。

**Tech Stack:** Swift 5.9、Swift Concurrency、Foundation `Process`、Python 3.12、JSONL、XCTest、macOS 14 Accessibility。

**Spec:** `docs/superpowers/specs/2026-09-01-pdd-qianniu-codex-runtime-exact-parity-design.md`

## Global Constraints

- 唯一参考实现是 `/Users/scy/Documents/Codex/2026-08-08/q-2/work/qianniu-b-source-baseline/.worktrees/conversation-node-classifier`。
- PDD 保留 OCR/AX、红点、UID、调度、图片下载和 AXPress 发送。
- 模型固定 `gpt-5.6-sol`，reasoning effort 固定 `medium`。
- CLI 必须禁用 `shell_tool`；不得用 prompt 代替参数级禁用。
- 正常 V2 证据必须包含非空原文章节；只有候选文件名不算成功。
- 第一份合法回复先交付，CLI 后台收尾不得撤销或重复回复。
- 目录不是 Git 仓库；每个任务以测试证据作为检查点，不执行无法成立的 commit 步骤。

---

### Task 1: 对齐 V2 消息协议与原文证据校验

**Files:**
- Modify: `Sources/PDDAXReader/KnowledgeEvidenceService.swift`
- Modify: `Sources/PDDAXReader/KnowledgeModels.swift`
- Modify: `Sources/PDDAXReader/V2KnowledgeRetriever.swift`
- Test: `Tests/PDDAXReaderTests/KnowledgeEvidenceServiceTests.swift`
- Test: `Tests/PDDAXReaderTests/V2KnowledgeRetrieverTests.swift`

**Interfaces:**
- Consumes: `[PDDChatMessage]`、`AutoReplyCapture.batch.targetCustomerJSONL`。
- Produces: `KnowledgeEvidenceService.v2HistoryJSONL(messages:targetCustomerJSONL:) -> String` 和 `RetrievedKnowledge.hasOriginalSections: Bool`。

- [ ] **Step 1: 写入失败的协议测试**

在 `KnowledgeEvidenceServiceTests` 的 recording retriever 中记录收到的 `historyJSONL`，新增断言：

```swift
let lines = try XCTUnwrap(await retriever.recordedHistoryJSONL)
let object = try XCTUnwrap(
    JSONSerialization.jsonObject(with: Data(lines.split(separator: "\n").last!))
        as? [String: String]
)
XCTAssertEqual(object["sender"], "customer")
XCTAssertEqual(object["v"], "M880停电后不开机")
XCTAssertNil(object["content"])
```

- [ ] **Step 2: 运行单测并确认 RED**

Run:

```bash
swift test --filter KnowledgeEvidenceServiceTests/testPreparationUsesQianniuSenderValueProtocol
```

Expected: FAIL，因为当前编码字段为 `content`。

- [ ] **Step 3: 最小实现千牛协议适配**

在 `KnowledgeEvidenceService` 内显式构造：

```swift
private struct V2Message: Encodable {
    let sender: String
    let v: String
    let kind: String
    let id: String
}
```

客户和客服分别映射为 `customer/service`；target JSONL 解码后补齐 `sender=customer`，正文从 `content` 或 `v` 读取，最终统一输出 `v`。

- [ ] **Step 4: 写入只有候选文件名必须失败的测试**

构造：

```swift
RetrievedKnowledge(
    version: "v2-top12",
    documents: ["a.md"],
    context: "<retrieved_document_candidates>\n- a.md\n</retrieved_document_candidates>"
)
```

断言 `KnowledgeEvidenceService.prepare` 返回 `.unavailable`，错误包含“缺少原文章节”。

- [ ] **Step 5: 运行并确认 RED，然后实现原文章节校验**

Run:

```bash
swift test --filter KnowledgeEvidenceServiceTests/testCandidateNamesWithoutOriginalSectionsAreUnavailable
```

在 `RetrievedKnowledge` 增加只读计算属性，验证 `<most_relevant_original_sections>` 开闭标签之间存在非空内容；`V2KnowledgeRetriever` 和 service 均使用该属性。

- [ ] **Step 6: 运行 Task 1 测试并确认 GREEN**

Run:

```bash
swift test --filter KnowledgeEvidenceServiceTests
swift test --filter V2KnowledgeRetrieverTests
```

Expected: 两组测试全部通过。

### Task 2: 移植千牛常驻 V2 worker 与真实 TP732 回归

**Files:**
- Create: `Sources/PDDAXReader/PersistentJSONLWorker.swift`
- Modify: `Sources/PDDAXReader/V2KnowledgeRetriever.swift`
- Modify: `Resources/V2Knowledge/retrieve_top12.py`
- Add/replace from Qianniu: `Resources/V2Knowledge/serve_top12.py`
- Test: `Tests/PDDAXReaderTests/PersistentV2WorkerTests.swift`
- Test: `Tests/PDDAXReaderTests/V2KnowledgeRetrieverTests.swift`
- Test: `Tests/V2KnowledgePythonTests/test_serve_top12.py`

**Interfaces:**
- Consumes: `historyJSONL`、知识库 ZIP、seed cache 和 writable index root。
- Produces: 千牛同构的 `prepare(knowledgeBaseURLs:)` 与 `retrieve(historyJSONL:knowledgeBaseURLs:)` 常驻请求路径。

- [ ] **Step 1: 写真实检索 RED 测试**

使用 bundle 中的知识库 fixture/运行时 ZIP，输入：

```json
{"sender":"customer","v":"tp732是否兼容mac","kind":"text","id":"A"}
```

断言返回 context 同时包含 `most_relevant_original_sections`、`TP732` 和 `macOS`，而不仅是 pinned 文档名。

- [ ] **Step 2: 运行 Swift/Python 定向测试并确认 RED**

Run:

```bash
swift test --filter V2KnowledgeRetrieverTests/testTP732MacQueryReturnsOriginalSection
python3 -m unittest Tests/V2KnowledgePythonTests/test_serve_top12.py
```

Expected: Swift 测试因当前 worker 每轮重建或证据为空失败；缺失的 Python 测试/worker 行为也先失败。

- [ ] **Step 3: 从千牛原样移植 worker 文件**

复制千牛 `PersistentJSONLWorker.swift`、`serve_top12.py` 及当前 `retrieve_top12.py` 的 `RetrieverEngine`、lexical-only 回退、ready/version 协议；只修改模块可见性和 PDD resource locator 所需路径类型。

- [ ] **Step 4: 切换 V2KnowledgeRetriever 到 prepare/query 生命周期**

初始化 worker 时固定：startup 120 秒、query 5 秒；同一 worker 多次 query 不重建 index。请求只包含：

```json
{"id":"UUID","history_jsonl":"..."}
```

响应 ID 必须匹配；超时或协议错误时停止 worker，重试一次并重建。

- [ ] **Step 5: 运行 Task 2 测试并确认 GREEN**

Run:

```bash
swift test --filter PersistentV2WorkerTests
swift test --filter V2KnowledgeRetrieverTests
python3 -m unittest discover -s Tests/V2KnowledgePythonTests
```

Expected: 全部通过，TP732 测试得到真实原文章节。

### Task 3: 对齐千牛 Prompt 和 CodexInvocation

**Files:**
- Modify: `Sources/PDDAXReader/AutoReplyPromptBuilder.swift`
- Modify: `Sources/PDDAXReader/CustomerServicePrompt.swift`
- Modify: `Resources/CustomerService/customer-reply-prompt.md`
- Modify: `Sources/PDDAXReader/CodexInvocation.swift`
- Create: `Tests/PDDAXReaderTests/CodexInvocationTests.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyPromptBuilderTests.swift`

**Interfaces:**
- Consumes: initial/continuation history submission、knowledge context、图片路径。
- Produces: 千牛顺序的 `[String]` CLI 参数和禁止自行检索的 PDD prompt。

- [ ] **Step 1: 写 CLI 参数完全相等测试**

新会话 expected fixture：

```swift
[
  "-a", "never", "--disable", "shell_tool", "exec",
  "--json", "--ignore-user-config", "--ignore-rules",
  "-m", "gpt-5.6-sol", "-c", "model_reasoning_effort=\"medium\"",
  "--skip-git-repo-check", "-s", "read-only",
  "--output-schema", schema.path, "-o", result.path, "-"
]
```

恢复会话另测 `exec resume ... sessionID -`，并确保没有 `--last`。

- [ ] **Step 2: 运行并确认 RED**

Run:

```bash
swift test --filter CodexInvocationTests
```

Expected: FAIL，因为当前没有 `--disable shell_tool` 且图片参数为 `--image`。

- [ ] **Step 3: 从千牛移植 CodexTurnMode/CodexInvocation**

保留千牛参数顺序和 `-i` 图片参数；PDD generator 通过 `.create/.resume(sessionID:)` 调用，不再用可空 session ID 推断模式。

- [ ] **Step 4: 写 Prompt RED 测试**

断言 initial 和 continuation 均：

```swift
XCTAssertTrue(prompt.contains("V2 知识库检索已经完成"))
XCTAssertTrue(prompt.contains("不得运行命令、读取 Skill、搜索文件、打开知识库文件或重新检索"))
XCTAssertFalse(prompt.contains("回答前充分检索并阅读知识库"))
```

- [ ] **Step 5: 运行并确认 RED，再移植 PromptBuilder 双路径**

Run:

```bash
swift test --filter AutoReplyPromptBuilderTests
```

实现 `buildInitial` 和 `buildContinuation`，平台文字只替换为拼多多；客服合同 markdown 同步为单一规则源。

- [ ] **Step 6: 运行 Task 3 测试并确认 GREEN**

Run:

```bash
swift test --filter CodexInvocationTests
swift test --filter AutoReplyPromptBuilderTests
```

Expected: 全部通过。

### Task 4: 移植 HistoryContinuation 与千牛 session 状态机

**Files:**
- Create: `Sources/PDDAXReader/HistoryContinuation.swift`
- Modify: `Sources/PDDAXReader/CodexHistoryCheckpoint.swift`
- Modify: `Sources/PDDAXReader/CodexSessionRegistry.swift`
- Modify: `Sources/PDDAXReader/AutoReplyCodexGenerator.swift`
- Test: `Tests/PDDAXReaderTests/CodexSessionRegistryTests.swift`
- Create: `Tests/PDDAXReaderTests/HistoryContinuationTests.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyCodexGeneratorTests.swift`

**Interfaces:**
- Consumes: 当前完整 history JSONL、图片 SHA 集合、旧 binding checkpoint。
- Produces: `HistorySubmission(mode: .full|.delta, historyJSONL:imagePaths:checkpoint:)` 与 `new/resumed/rehydrated/recovered` 运行路径。

- [ ] **Step 1: 写增量历史 RED 测试**

先以 A 建 checkpoint，再输入 A+B，断言 submission 只含 B；修改 A 内容时断言返回 full/rehydrate；新增图片只提交新 SHA 对应附件。

- [ ] **Step 2: 运行并确认 RED**

Run:

```bash
swift test --filter HistoryContinuationTests
```

Expected: FAIL，因为类型尚不存在。

- [ ] **Step 3: 从千牛移植 HistoryContinuation 和 checkpoint 计算**

稳定前缀按 UTF-8 byte count + SHA-256 校验，图片按 message ID/SHA 记录。不得用单纯数组数量判断增量。

- [ ] **Step 4: 写 session 模式 RED 测试**

覆盖：无 binding→new；匹配前缀→resumed；binding 存在但必须 full→rehydrated；resume runner 报错一次→recovered 新建；返回错误 thread ID→失效并 recovered。

- [ ] **Step 5: 移植千牛 generateWithSession/createAndCommit 状态机**

session commit 仅在合法 reply 和正确 thread ID 后执行；recovered 只允许一次。prompt/knowledge 版本变化使 binding 失效。

- [ ] **Step 6: 运行 Task 4 测试并确认 GREEN**

Run:

```bash
swift test --filter HistoryContinuationTests
swift test --filter CodexSessionRegistryTests
swift test --filter AutoReplyCodexGeneratorTests
```

Expected: 全部通过。

### Task 5: 移植流式 CLIReplyStream、提前 Handoff 与 bounded process

**Files:**
- Create: `Sources/PDDAXReader/CLIReplyStream.swift`
- Create: `Sources/PDDAXReader/CLIReplyHandoff.swift`
- Create: `Sources/PDDAXReader/BoundedProcess.swift`
- Modify: `Sources/PDDAXReader/AutoReplyCodexGenerator.swift`
- Modify: `Sources/PDDAXReader/CodexProcessRunner.swift`
- Create: `Tests/PDDAXReaderTests/CLIReplyStreamTests.swift`
- Create: `Tests/PDDAXReaderTests/CLIReplyHandoffTests.swift`
- Test: `Tests/PDDAXReaderTests/AutoReplyCodexGeneratorTests.swift`

**Interfaces:**
- Consumes: Codex JSONL stdout chunks、stderr、soft/hard deadline。
- Produces: 第一份 `ReplyDocument + threadID` 的单次异步 handoff 和独立 `cleanupTask`。

- [ ] **Step 1: 写 stream RED 测试**

分块输入 `thread.started`、`turn.started`、reasoning item、final agent message、`turn.completed`；断言只有完整 JSON reply、正确 thread、无 running item 时 ready。错误 thread、commentary phase 和重复 final 不得发布。

- [ ] **Step 2: 写 handoff RED 测试**

模拟 reply 在 20ms 到达、process 在 500ms 退出，断言 `generate` 在 200ms 内返回；后台 exit error 不产生第二次结果。

- [ ] **Step 3: 运行并确认 RED**

Run:

```bash
swift test --filter CLIReplyStreamTests
swift test --filter CLIReplyHandoffTests
```

Expected: FAIL，因为相关类型尚不存在。

- [ ] **Step 4: 从千牛原样移植 stream/handoff/bounded process**

保留进程组、stdout/stderr 并发 drain、SIGTERM/SIGKILL、输出上限、soft/hard deadline 和临时目录后台删除。PDD 仅替换 reply envelope 到 `decision/risk_level/reply_text/reason` 的解码与 routing。

- [ ] **Step 5: 修正事件诊断 subtype**

`CodexExecutionEvent` 保存顶层 type 和嵌套 `item.type`；污染判断检查 `CommandExecution/MCPToolCall/WebSearch` 等 subtype。该检查是诊断后备，不替代 `--disable shell_tool`。

- [ ] **Step 6: 运行 Task 5 测试并确认 GREEN**

Run:

```bash
swift test --filter CLIReplyStreamTests
swift test --filter CLIReplyHandoffTests
swift test --filter AutoReplyCodexGeneratorTests
```

Expected: 全部通过，提前交付测试证明返回早于 process exit。

### Task 6: 集成、构建与真实耗时对照

**Files:**
- Modify: `Sources/PDDAXReader/ReaderWorkflow.swift`
- Modify: `Sources/PDDAXReader/AutoReplyViewModel.swift`
- Modify: `Tests/PDDAXReaderTests/LiveAutoReplyCodexSmokeTests.swift`
- Modify: `scripts/build_app.sh`
- Verify with: `scripts/verify_task_isolation_candidate.sh`
- Update: `docs/PDD全自动客服-代码级架构与调试交接手册.md`

**Interfaces:**
- Consumes: 以上五个任务的千牛同构内核。
- Produces: 可运行的 `outputs/拼多多全自动客服-任务隔离候选版.app` 和可审计的真实验证记录。

- [ ] **Step 1: 写 live smoke 断言**

同一文本问题要求：knowledge context 有原文章节、`events` 中无 command/tool/MCP/web subtype、reply 非空、session ID 存在。第二轮同 UID 断言使用 resumed 和 delta prompt。

- [ ] **Step 2: 运行完整测试套件**

Run:

```bash
swift test
python3 -m unittest discover -s Tests/V2KnowledgePythonTests
```

Expected: 0 failures；需要真实账号的测试只能按既有环境开关 skip，不能吞掉普通失败。

- [ ] **Step 3: 构建 release candidate**

Run:

```bash
zsh scripts/build_app.sh --task-isolation-candidate
zsh scripts/verify_task_isolation_candidate.sh
codesign --verify --deep --strict outputs/拼多多全自动客服-任务隔离候选版.app
```

Expected: build exit 0，codesign exit 0。

- [ ] **Step 4: 运行三次真实 PDD 内核文本验证**

使用三条无图片问题，其中至少一条为 `tp732是否兼容mac`。逐次记录：V2 ms、首个合法 reply ms、CLI exit ms、session mode、工具事件数、reply。通过条件：三次工具事件均为 0；TP732 context 含原文；不存在全盘搜索命令；三次均产生非空合法回复。

- [ ] **Step 5: 对照千牛基线并更新交接文档**

将 PDD 实测与现有千牛 8 次基线（12.09–24.46 秒，中位数 16.49 秒）并列记录。说明早交付时间与进程退出时间的区别，并列出调试入口和日志路径。

- [ ] **Step 6: 最终新鲜验证**

再次运行：

```bash
swift test
python3 -m unittest discover -s Tests/V2KnowledgePythonTests
codesign --verify --deep --strict outputs/拼多多全自动客服-任务隔离候选版.app
```

Expected: 所有命令 exit 0，才能报告完成。
