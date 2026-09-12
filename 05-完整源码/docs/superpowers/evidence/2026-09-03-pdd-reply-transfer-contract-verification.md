# PDD reply / reply_then_transfer 合同验证（2026-09-03）

## 已实现

- Codex 输出只接受 `action`、`reply_text`、`transfer_reason` 三个字段。
- `action` 只允许 `reply`、`reply_then_transfer`。
- 转人工原因只允许批准的七个枚举值；`reply` 必须配 `none`，`reply_then_transfer` 必须配非 `none`。
- 两种动作都必须生成非空文字，不存在 silent。
- 乱码/意义不明时提示固定自然回复，不引用乱码、不要求重复。
- Prompt 包含严格转人工范围、真人短句语气以及“已有信息 → 文字排查 → 照片 → 必要时才是视频”。
- `reply_then_transfer` 的文字确认发送后，持久化一个绑定 UID、来源任务、客户 revision 与原因的 `placeholder_pending` 任务。
- 占位任务不调用 PDD UI、不参与活跃调度、不重复发送文字。
- 普通 `reply` 不产生任何转人工占位任务。

## 验证

- RED：旧 schema 缺少 action，旧 prompt 仍要求追问，2 项测试按预期失败。
- GREEN：schema 与 prompt 定向测试通过。
- RED：发送后不存在 `transferTasks`，占位任务测试按预期失败。
- GREEN：文字只发送一次，状态文件只生成一个占位任务。
- 全量：`swift test` 执行 450 项，7 项条件跳过，0 失败。
- Release 构建、候选版验证、资源验证、严格 codesign 验证均通过。
- 可执行 SHA-256：`fb925683db28801ffa6645f9164760a33f1d788700f09ee55102444b5a0e282a`。
- 新版候选 App 已启动，保留 `desiredRunning=false`。

## 未实现（按用户要求暂缓）

- 不定位或点击 PDD 转人工按钮。
- 不显示转人工卡片。
- 不执行真实转接或重试转接。
