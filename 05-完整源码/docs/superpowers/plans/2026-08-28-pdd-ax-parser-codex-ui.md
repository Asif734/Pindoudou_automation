# 拼多多 AX 聊天解析与 Codex 建议回复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一次点击保存当前用户完整 AX、解析聊天历史、按用户调用独立 Codex CLI 会话，并且只在本软件 UI 显示建议回复。

**Architecture:** 保留现有纯 AX 读取与原始文件存储，在不可变 `AXNodeSnapshot` 上增加消息解析器和追加式 JSONL 历史存储。Codex 层使用可注入进程运行器、精确 thread ID 和一小时会话租约，ViewModel 串联各阶段，SwiftUI 只展示而不包含任何拼多多写操作。

**Tech Stack:** Swift 5.9、SwiftUI/AppKit、macOS Accessibility API、Foundation `Process`/JSON、Swift Testing via XCTest、Codex CLI non-interactive mode

**Spec:** `docs/superpowers/specs/2026-08-28-pdd-ax-parser-codex-ui-design.md`

## Global Constraints

- macOS 最低版本保持 13。
- 拼多多读取来源只能是 Accessibility API 和 `AXNodeSnapshot`。
- 绝不查找、聚焦、填写、点击或发送拼多多聊天输入控件。
- Codex 只使用 `-a never`；新会话用 `-s read-only`，resume 沿用该只读会话（CLI 的 resume 子命令不接受 `-s`），回复只显示在本软件 UI。
- 每个 `GZC-[0-9]+` 用户的数据和精确 Codex thread ID 必须隔离。
- 原始 `ax.txt` 必须先于解析、历史合并和 Codex 调用成功保存。
- 目录不是 Git 仓库；每个任务保留测试检查点，不执行提交命令。

---

### Task 1: AX 消息领域模型和纯解析器

**Files:**
- Modify: `Sources/PDDAXReader/AXNodeSnapshot.swift`
- Create: `Sources/PDDAXReader/PDDChatMessage.swift`
- Create: `Sources/PDDAXReader/PDDChatParser.swift`
- Test: `Tests/PDDAXReaderTests/PDDChatParserTests.swift`

**Interfaces:**
- Produces: `AXNodeSnapshot.attribute(named:) -> String?`、`AXNodeSnapshot.domClasses: Set<String>`、`PDDChatMessage: Codable, Equatable`、`PDDChatParseResult`、`PDDChatParser.parse(root:capturedAt:) -> PDDChatParseResult`。
- `PDDChatMessage` 字段固定为 `id: String`、`sender: ChatSender`、`content: String`、`displayTime: String?`、`kind: ChatContentKind`、`capturedAt: Date`。

- [ ] **Step 1: 写失败测试**

构造包含 `onemsg`、`middlePanel_list_123`、`buyer-item`、`msg-content-box`、`message-time` 的树，断言得到一条 `.customer/.text` 消息；再构造 `cs-item`、`image-msg`、正文链接、头像链接和无关商品树，断言发送方、`[图片]`、正文 URL 以及过滤规则正确。增加发送方冲突、空消息、ID 缺失后备哈希的断言。

- [ ] **Step 2: 运行解析器测试确认失败**

Run: `swift test --filter PDDChatParserTests`

Expected: FAIL，提示 `PDDChatParser`/`PDDChatMessage` 未定义。

- [ ] **Step 3: 实现最小模型和遍历解析**

实现按完整 class token 匹配的 DFS：只有 `onemsg` 外层可以产出消息；发送方从该消息子树的 `buyer-item`/`cs-item` 判定；正文只在 `msg-content`/`msg-content-box` 子树读取；`message-time` 单独读取；URL 必须位于正文区域。后备 ID 对 `sender|kind|displayTime|content` 的 UTF-8 做稳定 SHA-256；为避免新依赖，使用 CryptoKit。

- [ ] **Step 4: 运行解析器测试确认通过**

Run: `swift test --filter PDDChatParserTests`

Expected: PASS，所有解析和过滤测试通过。

### Task 2: 每用户追加式 JSONL 历史

**Files:**
- Create: `Sources/PDDAXReader/PerUserChatStore.swift`
- Test: `Tests/PDDAXReaderTests/PerUserChatStoreTests.swift`

**Interfaces:**
- Consumes: `PDDChatMessage`、`PerUserAXStore.validUID(_:)`。
- Produces: `ChatMergeResult(history: [PDDChatMessage], insertedCount: Int, fileURL: URL)`、`PerUserChatStore.merge(uid:messages:) throws -> ChatMergeResult`、`load(uid:) throws -> [PDDChatMessage]`。

- [ ] **Step 1: 写失败测试**

在临时根目录合并 `[m1, m2]`，再合并 `[m2, m3]`，断言顺序为 `m1,m2,m3`、插入数分别为 2 和 1；用只含 `m3` 的滚动后快照再次合并，断言历史不删除；再覆盖用户隔离、非法 UID、损坏 JSONL 保留原字节且抛出带路径错误。

- [ ] **Step 2: 运行存储测试确认失败**

Run: `swift test --filter PerUserChatStoreTests`

Expected: FAIL，提示 `PerUserChatStore` 未定义。

- [ ] **Step 3: 实现安全目录和原子合并**

复用与 `PerUserAXStore` 相同的根目录和路径边界校验。逐行 `JSONDecoder` 解码，按 `id` 保留首次出现的历史，再按解析顺序追加新 ID；编码为一行一个 JSON，通过同目录临时文件和 `.atomic` 写入 `history.jsonl`。任何旧行损坏时先抛错，不写目标文件。

- [ ] **Step 4: 运行存储测试确认通过**

Run: `swift test --filter PerUserChatStoreTests`

Expected: PASS。

### Task 3: UID 独立 Codex 会话注册表

**Files:**
- Create: `Sources/PDDAXReader/CodexSessionRegistry.swift`
- Test: `Tests/PDDAXReaderTests/CodexSessionRegistryTests.swift`

**Interfaces:**
- Produces: `CodexSessionBinding(uid: String, threadID: String, lastUsedAt: Date)`、`CodexSessionRegistry.activeBinding(uid:now:) throws -> CodexSessionBinding?`、`save(_:now:) throws`、`invalidate(uid:) throws`，默认租约 3600 秒。

- [ ] **Step 1: 写失败测试**

断言同 UID 在 3599 秒时返回绑定、3601 秒时返回 nil；不同 UID 不能读取彼此 thread ID；文件 UID 与目录 UID 不一致时拒绝；invalidate 只移除目标用户绑定。

- [ ] **Step 2: 运行注册表测试确认失败**

Run: `swift test --filter CodexSessionRegistryTests`

Expected: FAIL，提示注册表类型未定义。

- [ ] **Step 3: 实现租约和安全持久化**

每个用户目录保存 `codex-session.json`，用 ISO-8601 JSON 日期、原子写入和同一 UID/path 校验；过期绑定返回 nil，但不影响历史文件。

- [ ] **Step 4: 运行注册表测试确认通过**

Run: `swift test --filter CodexSessionRegistryTests`

Expected: PASS。

### Task 4: Codex CLI 参数、提示和结构化输出

**Files:**
- Create: `Sources/PDDAXReader/CustomerReplyPromptBuilder.swift`
- Create: `Sources/PDDAXReader/CodexInvocation.swift`
- Create: `Sources/PDDAXReader/CodexProcessRunner.swift`
- Create: `Sources/PDDAXReader/CodexReplyService.swift`
- Test: `Tests/PDDAXReaderTests/CustomerReplyPromptBuilderTests.swift`
- Test: `Tests/PDDAXReaderTests/CodexReplyServiceTests.swift`
- Test fixture: `Tests/PDDAXReaderTests/Fixtures/fake-codex.sh`

**Interfaces:**
- Consumes: `[PDDChatMessage]` 和 `CodexSessionRegistry`。
- Produces: `CustomerReplyPromptBuilder.build(uid:history:) -> String`、`CodexInvocation.arguments(sessionID:schemaURL:resultURL:) -> [String]`、`CodexProcessRunning.run(executable:arguments:stdin:timeout:) async throws -> CodexProcessResult`、`CodexReplyService.generate(uid:history:) async throws -> CodexReplyResult(reply: String, threadID: String)`。

- [ ] **Step 1: 写提示词和调用参数失败测试**

断言提示包含 Grozziie/Jiapuwei 身份、只输出一条中文客服建议、不得声称已发送、完整按角色标注的聊天历史。断言新会话参数含 `-a never exec --json -s read-only --output-schema ... -o ... -`；resume 参数含唯一精确 ID、不含 `--last` 且不传 resume 不支持的 `-s`；模型为 `gpt-5.6-sol`、reasoning 为 `medium`。

- [ ] **Step 2: 运行测试确认失败**

Run: `swift test --filter CustomerReplyPromptBuilderTests`

Expected: FAIL，提示构建器未定义。

- [ ] **Step 3: 实现提示构建和纯参数构造**

把客服知识和行为边界写为固定系统说明，把 JSONL 历史转成清晰的“客户/客服”时间顺序文本。schema 固定要求对象仅含非空 `reply` 字符串。参数使用 stdin 标记 `-`，禁止把聊天内容放入参数。

- [ ] **Step 4: 写假的 CLI 集成失败测试**

fixture 根据环境变量记录 argv/stdin；新会话向 stdout 写 `thread.started` 和 `turn.completed` JSONL，并向 `-o` 文件写 `{\"reply\":\"建议回复\"}`。测试验证精确 thread ID 被保存、第二次使用 resume；模拟 resume 非零退出，断言只失效该 UID 并完整历史重建一次；模拟缺少完成事件、空 reply、超时，断言分别失败且不重复调用。

- [ ] **Step 5: 运行服务测试确认失败**

Run: `swift test --filter CodexReplyServiceTests`

Expected: FAIL，提示进程运行器或服务未定义。

- [ ] **Step 6: 实现无阻塞进程运行和单次恢复**

用 `Process`、`Pipe` 和 readability handler 持续排空 stdout/stderr，避免管道满导致死锁；在后台等待退出，超时后 terminate。解析 JSONL 事件，要求 `turn.completed`；读取临时结果文件并校验非空 reply。resume 失败时 invalidate 后只创建一次新会话，成功后写入精确 thread ID。

- [ ] **Step 7: 运行 Codex 层测试确认通过**

Run: `swift test --filter 'CustomerReplyPromptBuilderTests|CodexReplyServiceTests'`

Expected: PASS。

### Task 5: 串联读取、保存、解析、历史和建议状态

**Files:**
- Modify: `Sources/PDDAXReader/ReaderViewModel.swift`
- Test: `Tests/PDDAXReaderTests/ReaderViewModelTests.swift`

**Interfaces:**
- Consumes: `AXTreeReader`、`PerUserAXStore`、`PDDChatParser`、`PerUserChatStore`、`CodexReplyService`。
- Produces: `fullAXOutput`、`parsedChatOutput`、`replyOutput`、`selectedTab`、`status`、`isReading`，以及 `readParseAndSuggest()`。

- [ ] **Step 1: 为可测试依赖增加协议并写失败测试**

用 fake reader/store/parser/reply service 驱动流程，断言调用顺序必须为读取 → 保存 AX → 解析 → 合并 → Codex。断言 AX 保存失败时不解析；解析或 Codex 失败时 `fullAXOutput` 仍保留；最后一条为 `.service` 时 Codex fake 调用数为 0 且 reply 为“当前无需回复”。

- [ ] **Step 2: 运行 ViewModel 测试确认失败**

Run: `swift test --filter ReaderViewModelTests`

Expected: FAIL，现有 ViewModel 不具备注入接口或新状态。

- [ ] **Step 3: 实现阶段化异步管线**

把阻塞 AX 读取和文件操作放到后台 task，把发布状态留在 MainActor；每阶段更新中文状态。只有合并后历史非空且末条为客户时生成建议。错误格式包含阶段名，`defer` 确保恢复按钮状态。

- [ ] **Step 4: 运行 ViewModel 测试确认通过**

Run: `swift test --filter ReaderViewModelTests`

Expected: PASS。

### Task 6: 三标签检查 UI

**Files:**
- Modify: `Sources/PDDAXReader/ContentView.swift`
- Modify: `Sources/PDDAXReader/AXDumpViewer.swift`
- Test: `Tests/PDDAXReaderTests/AXDumpViewerTests.swift`

**Interfaces:**
- Consumes: Task 5 的 ViewModel 发布属性和方法。
- Produces: “完整 AX”“解析聊天”“Codex 建议回复”三个可检查标签；所有文本可选择复制。

- [ ] **Step 1: 扩展 viewer 失败测试**

断言通用只读 viewer 对多 MB AX 和中文回复均完整保留、不可编辑、可选择、无自动换行；断言重复内容不会重设滚动位置。

- [ ] **Step 2: 运行 viewer 测试确认当前差距**

Run: `swift test --filter AXDumpViewerTests`

Expected: 新增断言 FAIL，尚无可观察的内容更新计数或滚动保持接口。

- [ ] **Step 3: 实现三标签 SwiftUI**

主按钮改成“读取、解析并生成建议”，使用 `TabView(selection:)`。三个标签分别绑定 `fullAXOutput`、`parsedChatOutput`、`replyOutput`，继续使用 AppKit viewer 避免大文本高 CPU；不添加任何拼多多发送按钮或 AX 写操作。

- [ ] **Step 4: 运行 UI 相关测试确认通过**

Run: `swift test --filter AXDumpViewerTests`

Expected: PASS。

### Task 7: 全量验证、打包和真实页面冒烟测试

**Files:**
- Modify: `README.md`
- Modify: `scripts/build_app.sh`（仅当新运行时资源需要打包）
- Rebuild: `outputs/拼多多AX读取器.app`

**Interfaces:**
- Consumes: 前六个任务的完整应用。
- Produces: 可签名运行的 `.app` 和记录清楚的使用说明。

- [ ] **Step 1: 更新说明**

README 明确列出 `ax.txt`、`history.jsonl`、`codex-session.json`，说明需要辅助功能权限和 ChatGPT Codex 登录；强调“建议只显示、不自动发送”，并写明无未回复客户消息时不调用 Codex。

- [ ] **Step 2: 运行全部单元和集成测试**

Run: `swift test`

Expected: 所有测试 PASS，0 failures。

- [ ] **Step 3: release 构建与签名检查**

Run: `scripts/build_app.sh && codesign --verify --deep --strict --verbose=2 outputs/拼多多AX读取器.app && spctl -a -t exec -vv outputs/拼多多AX读取器.app`

Expected: build 成功、`codesign` 验证通过；`spctl` 输出记录实际本地开发签名判定。

- [ ] **Step 4: 当前拼多多页面真实冒烟**

启动新 app，点击一次，确认状态完成且三个标签分别出现：完整 AX、含当前 `GZC-*` 用户消息的解析历史、非空 Codex 建议或“当前无需回复”。记录当前拼多多输入框 AXValue（若存在），操作前后比较完全相同；同时确认页面当前会话、焦点和消息数量未被本软件改变。

- [ ] **Step 5: 性能与文件核验**

空闲 10 秒后用 `ps` 检查 app CPU 接近 0；核对目标用户目录只包含预期三个文件，`history.jsonl` 可逐行解码且无重复 ID；再次点击验证同一历史不重复、同 UID 在租约内 resume 精确 session。
