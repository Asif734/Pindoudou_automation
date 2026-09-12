# PDD 一比一复刻千牛 Codex/V2 运行内核：设计规格

**日期：** 2026-09-01  
**状态：** 设计已获用户批准，待规格复核  
**工程：** `/Users/scy/Documents/Codex/2026-08-27/ax-ax-ax`

## 1. 目标与边界

PDD 不再维护独立的 Codex 生成与知识检索实现。除平台名称、图片附件来源和最终发送接口外，PDD 的知识检索、提示词、每用户增量会话、CLI 参数、流式解析、合法回复提前交付、后台收尾和诊断结构均以当前千牛候选版为唯一基准。

保留 PDD 的 OCR/AX 混合采集、红点发现、`GZC-数字` UID、任务调度、原图下载和 PDD AXPress 发送。此次不改页面识别与发送控件实现。

成功标准：

- PDD 不允许 Codex 调用 shell、MCP、web 或其他工具；
- V2 收到与千牛相同的 `sender + v` 消息协议；
- 正常 V2 结果必须含真实原文章节，不能只有候选文件名；
- 新会话和恢复会话的命令参数顺序与千牛一致；
- 第一份完整、合法、属于当前 turn 的结构化回复立即交给 scheduler；
- CLI 退出、清理和追踪在后台完成，不能延迟已经合法的回复；
- 每用户 session 只提交稳定前缀之后的增量历史和新增图片；
- 同一组回归输入下，PDD 与千牛生成内核具有相同的 session 模式、知识证据形态和工具禁用行为。

## 2. 唯一参考实现

参考根目录：

```text
/Users/scy/Documents/Codex/2026-08-08/q-2/work/qianniu-b-source-baseline/.worktrees/conversation-node-classifier
```

直接对齐的千牛组件：

- `components/batch-source/Sources/CustomerReplyBatchAppSupport/CodexInvocation.swift`
- `components/batch-source/Sources/CustomerReplyBatchAppSupport/CodexReplyGenerator.swift`
- `components/batch-source/Sources/CustomerReplyBatchAppSupport/CLIReplyHandoff.swift`
- `components/batch-source/Sources/CustomerReplyBatchAppSupport/CLIReplyStream.swift`
- `components/batch-source/Sources/CustomerReplyBatchAppSupport/PromptBuilder.swift`
- `components/batch-source/Sources/CustomerReplyBatchAppSupport/CodexSessionRegistry.swift`
- `components/batch-source/Sources/CustomerReplyBatchAppSupport/HistoryContinuation.swift`
- `components/batch-source/Sources/CustomerReplyBatchAppSupport/V2KnowledgeRetriever.swift`
- `components/batch-source/Sources/CustomerReplyBatchAppSupport/PersistentJSONLWorker.swift`
- `components/batch-source/Sources/CustomerReplyBatchAppSupport/BoundedProcess.swift`
- `Resources/V2Knowledge/retrieve_top12.py`
- `Resources/V2Knowledge/serve_top12.py`

PDD 只允许添加薄适配器，把 `PDDChatMessage`、`AutoReplyCapture`、`KnowledgeEvidence` 和 `CodexReplyResult` 映射到千牛内核输入输出。不得复制后再形成另一套行为分支。

## 3. 知识检索数据合同

传给 V2 的每条聊天消息统一为：

```json
{"sender":"customer|service","v":"消息正文","kind":"text|image","id":"稳定消息ID"}
```

`KnowledgeEvidenceService` 不再把 `PDDChatMessage` 的默认 Codable JSON 直接传给 V2。它必须显式生成以上协议。冻结批次中的 target 消息也必须带 `sender=customer` 和 `v`；拼接时沿用千牛的最近 24 行加 target 去重规则。

V2 返回值保持：

```json
{
  "version": "v2-top12",
  "documents": ["文档名"],
  "context": "<retrieved_document_candidates>...</retrieved_document_candidates>\n\n<most_relevant_original_sections>真实原文</most_relevant_original_sections>"
}
```

生产校验要求 `context` 含非空的 `<most_relevant_original_sections>`。只有候选文件名属于无效检索结果，不得标记为成功的 `v2-top12`。

PDD 使用千牛的常驻 worker 生命周期：启动时构建/加载索引，查询只发送 request ID 与 history JSONL；查询硬超时后销毁并重建 worker。不得在每轮查询重新构建 lexical/semantic index。

## 4. Prompt 合同

PDD 使用千牛 `PromptBuilder` 的 initial/continuation 双路径和合同版本。核心规则逐字保持：

- V2 检索已经完成；
- 给出的片段是本轮允许使用的全部知识资料；
- 不得运行命令、读取 Skill、搜索文件、打开知识库文件或重新检索；
- 完整历史仅作上下文，只回答冻结 batch；
- 一条回复覆盖 batch 内全部未回答问题；
- batch 后新增消息不能取消、替换或改写当前回复；
- 本地聊天记录是送达事实的唯一依据。

只替换千牛/天猫平台措辞为拼多多，并保留 PDD 已批准的 `decision=auto_send` 输出语义与图片附件说明。不得保留当前 PDD 中“回答前充分检索并阅读知识库”的矛盾指令。

## 5. Codex CLI 调用

参数构造从千牛实现移植，关键前缀固定为：

```text
-a never --disable shell_tool exec
```

随后保持千牛顺序：

```text
[resume]
--json --ignore-user-config --ignore-rules
-m gpt-5.6-sol
-c model_reasoning_effort="medium"
--skip-git-repo-check
[-C 受控工作目录]
[-s read-only，仅新会话]
--output-schema <schema>
-o <result>
[-i <图片> ...]
[sessionID]
-
```

PDD 不再使用只禁止审批但保留 shell 的 `-a never exec`。工具禁用必须由参数测试验证，不能只依赖 prompt。

## 6. 流式回复与后台收尾

PDD 当前 `CodexProcessRunner` 等待整个进程退出后才解析 stdout，予以替换。新流程与千牛一致：

1. 并发持续读取 stdout/stderr；
2. `CLIReplyStream` 按 JSONL 增量解析事件；
3. 只接受当前 thread/turn、没有未结束 item、通过 schema 和 routing policy 的完整回复；
4. `CLIReplyHandoff` 只发布第一份合法回复；
5. scheduler 立即进入 ready/发送；
6. process exit、trace、临时目录删除和 process-group 清理继续在后台执行；
7. 后台失败不得撤销或重复发布已经交付的回复。

新建会话必须取得 thread ID 后才能提交 session binding。恢复会话返回其他 thread ID 时视为身份错误，失效旧 binding 并按千牛恢复策略新建一次。

## 7. 每用户增量 Session

PDD 采用千牛 `HistoryContinuation` 和 session registry 语义：

- `new`：没有兼容 binding，提交完整历史；
- `resumed`：稳定历史前缀匹配，只提交 appended history 和新增图片；
- `rehydrated`：binding 存在但只能提交 full，先失效再新建；
- `recovered`：resume 失败后失效并完整新建一次。

兼容性键至少包含 UID、prompt contract version、knowledge version/hash 和历史 checkpoint。PDD 现有 turn count、累计 bytes 和过期阈值可以保留为外层轮换条件，但不能改变千牛的增量历史判定。

当工具已经从 CLI 层禁用后，不再依赖 PDD 当前不可靠的顶层事件名污染检测。诊断仍需保存实际 item subtype；若未来出现 command/MCP/web/tool subtype，必须标记 session contaminated，下一轮新建。

## 8. 错误与降级

- V2 字段协议错误、空查询或只有候选文件名：记为检索失败；不得让 Codex自行搜索磁盘。
- 没有可信正文：仍按产品原则生成非空客服回复，但 prompt 明确说明本轮无可信证据；不得附带知识库文件路径。
- CLI 普通失败：沿用 scheduler 的任务级重试，不停止全局运行。
- 已交付合法 reply 后的 CLI 退出错误：仅记录诊断，不撤销发送。
- session identity 错误：只允许一次 `recovered` 新建，避免同一任务无限重复生成。

## 9. 测试策略

严格按 TDD 逐项实施：

1. V2 协议测试先证明当前 `content` 不能形成查询，再要求输出 `v`；
2. V2 证据测试要求 TP732 查询返回含 TP732/macOS 原文的 section，而不是只有两个 pinned 文档名；
3. CLI 参数测试要求 `--disable shell_tool` 且参数顺序与千牛 fixture 完全一致；
4. Prompt 测试要求包含“检索已经完成/不得重新检索”，并拒绝旧的“充分检索”指令；
5. stream/handoff 测试模拟合法回复先到、进程稍后退出，证明 reply 在退出前完成交付且只交付一次；
6. session 测试覆盖 new、resumed、rehydrated、recovered 和增量图片；
7. contamination 测试使用嵌套 item subtype，证明不会再漏掉 CommandExecution；
8. 全量 Swift 与 Python 测试；
9. release App 构建与签名检查；
10. 使用相同无图片客服问题分别运行千牛/PDD 内核，记录 V2 耗时、首个合法 reply、CLI exit、工具事件数和总耗时。

真实验证通过标准：PDD 工具事件数为 0；V2 context 包含原文 section；回复在 CLI exit 前可交付；不存在全盘 `rg --files /`；连续三次正常文本请求没有 35–62 秒的工具搜索型异常。

## 10. 不在本次范围

- 不把千牛页面 AX/OCR 定位移植到 PDD；
- 不改变红点算法、图片下载方式或 PDD 发送按钮；
- 不更换模型或降低 reasoning effort 来掩盖结构问题；
- 不新增 OCR、营销、订单或人工接管功能；
- 不以简单缩短 timeout 代替禁用工具和修复检索协议。

