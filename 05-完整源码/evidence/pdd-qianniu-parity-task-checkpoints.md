# 拼多多千牛能力等价迁移检查点

日期：2026-08-28

## 基线

- 命令：`swift test`
- 结果：131 项测试，0 失败。
- 工作目录不是 Git 仓库；未初始化 Git，按计划使用测试与文件清单作为检查点。

## Task 1：客服 Prompt 与知识证据合同

- RED：缺少 `KnowledgeRetrievalMode`、`KnowledgeEvidence` 和 `AutoReplyCapture.knowledgeEvidence`，目标测试按预期编译失败。
- GREEN：`swift test --filter 'AutoReplyPromptBuilderTests|KnowledgeModelsTests|CustomerReplyPromptBuilderTests'`
- 结果：8 项测试，0 失败。
- 新增：`KnowledgeModels.swift`、`CustomerServicePrompt.swift`、客服 Prompt 资源和知识合同测试。
- 修改：`AutoReplyCapture` 兼容可选知识证据；Prompt 分离完整历史、冻结批次和不可信检索证据。

## Task 2：知识资源与打包

- RED：打包测试构建出的自动客服 `Contents/Resources` 为空，按预期失败。
- GREEN：`swift test --filter 'KnowledgeResourceLocatorTests|KnowledgeBaseVersionerTests'`，4 项通过。
- GREEN：`zsh Tests/PackagingTests/auto_reply_resources_test.sh` 通过，签名验证成功。
- V2 资源：275 MB；`retrieve_top12.py` SHA-256 `521bf97682496e9426bb0f3e99c2ae38b9e7b00287a5e6f07aeccd0461b9b718`。
- 知识库：84 MB；SHA-256 `e5a6a57a6c0e904bc631d4aa2e9a24f200d57d2dcb689bd54271b5c56c1825c6`。

## Task 3：V2 Top-12 检索与完整 ZIP 回退

- RED/GREEN：补齐进程请求、UTF-8 历史、结果校验和失败回退测试，4 项通过。
- Python 真实知识库回归：2 项通过；验证视频问题能取回淘宝原始 MP4 链接，context 小于 45,000 字符。

## Task 4：Codex 定位、ChatGPT 登录与诊断

- Codex 定位顺序：显式环境、ChatGPT/Codex App、Homebrew/PATH。
- 登录检查只接受 `Logged in using ChatGPT`，成功缓存 60 秒，失败不缓存。
- 生成记录知识诊断、耗时与 Codex JSONL 事件；相关测试 15 项通过。
- 真实冒烟：`PDD_LIVE_CODEX_SMOKE=1 swift test --filter LiveAutoReplyCodexSmokeTests`，1 项通过，真实耗时 108.681 秒。

## Task 5：状态迁移与不可变归档

- 持久状态升级到 schema 2；schema 1 自动迁移并保留时间戳备份。
- 同 job ID 的归档若内容不同会拒绝覆盖；生成诊断可往返持久化与归档。
- Store、Timeline、Scheduler 相关测试通过。

## Task 6：资源监控与错误后继续

- 每 tick 发布可用内存、活动 CLI、队列深度与最近生成耗时。
- AX/调度异常只显示最近警告，运行状态保持开启，下一次成功扫描会清除警告。

## Task 7：主窗口与浮动进度

- 显示 Codex 路径、固定模型、V2/回退状态、知识 SHA、内存、队列、CLI 和最近警告。
- 浮窗继续支持拖动、缩放与关闭；展示快照不会增加 AX 调用。
- ViewModel、Presentation、FloatingProgress 共 14 项测试通过。

## Task 8：全局不阻塞硬回归

- Codex 连续失败超过上限时推进该批游标并继续；另一 UID 同时完成，未被失败 UID 阻塞。
- 调度器 23 项测试通过，包括 AX 通知快速扫描、发送不确定、未知草稿旧状态迁移、人工客服消息、双 UID 并发和 UI 串行。

## Task 9：干净构建、签名与本机 UI 验收

- `swift package clean` 后运行 `swift test`：160 项，1 项显式 live 测试默认跳过，0 失败。
- 真实 V2 Python 回归：2 项，0 失败。
- `scripts/build_app.sh`：release 构建成功，生成三个应用。
- `Tests/PackagingTests/auto_reply_resources_test.sh`：通过；并修正该验收脚本的可执行位。
- 三个应用均通过 `codesign --verify --deep --strict`。
- 成品中的 V2 脚本和知识 ZIP 与源码逐字节一致，SHA-256 分别为 `521bf97682496e9426bb0f3e99c2ae38b9e7b00287a5e6f07aeccd0461b9b718` 和 `e5a6a57a6c0e904bc631d4aa2e9a24f200d57d2dcb689bd54271b5c56c1825c6`。
- Computer Use 打开最新签名成品，确认主窗口显示 Codex 路径、模型、知识状态、内存、队列、CLI、纯 AX 解析和本地记录按钮；点击进度浮窗控制按钮正常。
- 拼多多当前 AX 树无 `GZC-数字` 用户 ID 且无未回复红点，因此本轮 live UI 验收没有构造或发送测试客户消息；成品保持真实自动运行，等待符合条件的新 AX 客户消息。
