# 拼多多 AX 聊天解析与 Codex 建议回复设计

## 目标

在现有“拼多多 AX 读取器”中增加纯 AX 聊天解析和 Codex CLI 建议回复：用户点击一次后，程序保存完整 AX、解析当前 `GZC-*` 用户的聊天历史、按用户维护独立 Codex 会话，并仅在本软件 UI 中显示建议回复。

## 不可突破的边界

- 读取来源只能是 macOS Accessibility API 获取的 `AXNodeSnapshot`，不使用截图、OCR、浏览器注入或拼多多内部接口。
- 每次成功识别用户后，始终先原子保存完整 `ax.txt`；解析或 Codex 失败不得丢失原始 AX。
- 绝不查找、聚焦、填写、点击或发送拼多多聊天输入控件。
- Codex 输出只显示在本软件 UI，用户自行检查；不得自动发送。
- 每个 `GZC-*` 用户的数据和 Codex 会话完全隔离。
- 复用“检查已打开的千牛”任务中的 Grozziie/Jiapuwei 客服知识和回复约束，但拼多多消息采集必须使用新的纯 AX 解析器。

## 单次点击的数据流

1. `AXTreeReader` 读取 `com.pinduoduo.merchantMac` 的完整 AX 树。
2. `PDDCustomerIdentity` 要求树中只有一个规范 `GZC-[0-9]+` 用户 ID；否则停止后续步骤并在 UI 显示原因。
3. `AXDumpFormatter` 生成完整文本，`PerUserAXStore` 原子写入 `~/Desktop/拼多多AX记录/用户/<UID>/ax.txt`。
4. `PDDChatParser` 只遍历 DOM class 含 `onemsg` 的节点，并解析其消息 ID、发送方、正文、时间和内容类型。
5. `PerUserChatStore` 将解析结果按消息 ID 去重追加到同目录 `history.jsonl`；当 ID 缺失时使用规范化字段哈希作为稳定后备 ID。页面滚动导致本次快照变少时，不删除已有历史。
6. 若合并后最后一条有效消息来自客户，则 `CodexReplyService` 为该 UID 调用 Codex CLI；若最后一条来自客服，则 UI 显示“当前无需回复”，不调用 CLI。
7. UI 的“完整 AX”“解析聊天”“Codex 建议回复”三个标签展示结果和阶段状态。

## AX 聊天解析规则

- 消息外层：`AXDOMClassList` 包含 `onemsg`。
- 首选消息 ID：外层 `AXDOMIdentifier` 中的 `middlePanel_list_*`。
- 客户消息：消息子树的 `AXDOMClassList` 包含 `buyer-item`。
- 客服消息：消息子树的 `AXDOMClassList` 包含 `cs-item`；`isread` 等附加类不影响识别。
- 正文：只从该消息内 class 含 `msg-content` 或 `msg-content-box` 的内容子树提取可见 `AXValue`/`AXTitle`/`AXDescription`，去重并保持树顺序。
- 时间：从 class 含 `message-time` 的子树提取。
- 图片：正文区域 class 含 `image-msg` 时记录内容 `[图片]`，不读取图片字节且不做 OCR。
- 链接：只允许从正文内容子树中提取 URL；头像 class `avatar` 和消息外其他 URL 一律忽略。
- 发送方缺失或同时出现客户、客服标记时，该节点列入解析诊断但不写入历史。
- 空文本、无图片、无正文链接的消息不写入历史。

## 本地文件格式

用户目录固定为：

```text
~/Desktop/拼多多AX记录/用户/<GZC-ID>/
  ax.txt
  history.jsonl
  codex-session.json
```

`history.jsonl` 每行是一个 UTF-8 JSON 对象，字段为 `id`、`sender`（`customer`/`service`）、`content`、可空 `displayTime`、`kind`（`text`/`image`/`link`）和 `capturedAt`。写入采用临时文件加原子替换，已有 ID 不重复，已有历史不因当前 AX 快照缩短而删除。

`codex-session.json` 保存 UID、Codex thread ID 和最后成功使用时间。绑定必须匹配当前 UID；有效期为一小时。

## Codex CLI 集成

- 可执行文件优先使用应用包内配置的路径，开发/测试时可注入；正式环境使用 `/Applications/ChatGPT.app/Contents/Resources/codex`，不存在时给出可操作错误。
- 通过标准输入传入完整客服提示和本地聊天历史，不把大量内容拼进命令行参数。
- 新会话使用 `codex -a never exec`；一小时内的同一 UID 使用 `codex -a never exec resume <exact-thread-id>`，禁止 `--last`。
- 新会话固定 `-s read-only`；`exec resume` 不支持 `-s` 参数，因此恢复精确的既有只读会话并沿用其沙箱。两种模式均固定 `--json`、`--output-schema`、`-o <temporary-result-file>`、`--skip-git-repo-check`，模型 `gpt-5.6-sol`，推理强度 `medium`。
- 输出 schema 只接受 `{ "reply": "非空字符串" }`。进程必须正常退出、事件流包含完成事件、结果符合 schema，才算成功。
- 新会话从事件流的 `thread.started.thread_id` 获取精确 thread ID。
- resume 失败时仅使当前 UID 的会话绑定失效，并用完整历史创建新会话重试一次；其他错误不循环重试。
- 调用超时或取消时终止子进程，关闭管道并保留已有历史和 AX。
- 提示词复用千牛版本的 Grozziie/Jiapuwei 知识与约束，要求仅生成一条可直接供客服检查的中文回复，不执行工具、不声称已经发送。

## UI

- 主按钮文案改为“读取、解析并生成建议”。执行期间禁用，阶段状态依次显示读取 AX、保存、解析、合并历史、生成建议。
- 使用 `TabView` 展示三个标签：
  - “完整 AX”：继续使用高性能 `AXDumpTextView`，完整显示多 MB 文本。
  - “解析聊天”：显示 UID、历史条数、客户/客服、时间、类型和正文，并显示被跳过节点的诊断。
  - “Codex 建议回复”：显示建议文本，支持选择和复制；最后一条为客服时显示“当前无需回复”。
- 任一后续阶段失败时，“完整 AX”仍可查看；错误状态明确指出失败阶段。

## 错误恢复

- 无辅助功能权限、拼多多未运行：停止读取并给出系统设置或启动应用提示。
- UID 缺失或冲突：不创建错误用户目录，不解析、不调用 Codex。
- 原始 AX 保存失败：停止后续流程，避免出现无法审计的派生数据。
- 单条消息歧义：跳过该条并保留诊断；其他确定消息继续处理。
- 历史文件损坏：不覆盖原文件，显示具体路径和错误。
- Codex 未登录、可执行文件缺失、超时或 schema 错误：保留 AX 和历史，在建议标签显示错误；不接触拼多多输入区。

## 验证

- 单元测试用真实结构化特征构造 AX fixture，覆盖客户/客服文本、图片、正文链接、头像 URL 过滤、无关商品/侧栏、歧义发送方和后备 ID。
- 存储测试覆盖追加、去重、滚动后不删除、用户隔离、损坏文件不覆盖和路径安全。
- 使用假的 Codex 可执行程序做集成测试，核对新建/resume 参数、stdin、结构化结果、thread ID、超时和失败后单次重建。
- ViewModel 测试核对最后一条为客服时不调用 Codex，后续失败仍保留 AX 输出。
- 运行全部 `swift test`、release 构建和签名检查。
- 使用当前已打开的拼多多页面做真实冒烟测试：读取、保存、解析、调用真实 Codex、在三个标签检查结果，并确认拼多多输入框内容和页面状态完全未改变。
