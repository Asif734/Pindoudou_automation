# PDD 会话身份：DOM Identifier 优先、昵称兜底设计

**日期：** 2026-09-02  
**状态：** 用户已批准方案方向，等待规格复核后编写实施计划  
**工程：** `/Users/scy/Documents/Codex/2026-08-27/ax-ax-ax`

## 1. 目标与产品原则

取消 PDD 平台对 `GZC-[0-9]+` 的硬编码身份要求。会话身份与重新打开会话时按以下顺序定位：

1. 使用当前 AX 会话行上非空、在本次列表中唯一的 `AXDOMIdentifier`；
2. identifier 缺失、重复、变化或已找不到时，使用会话的完整可见脱敏昵称；
3. 昵称出现多个候选时，不阻断自动回复，选择列表顺序中的第一个最佳真实会话行并记录警告。

最高原则保持为：无法完美核对身份时也继续运行；全局停摆比可能选错候选更差。

## 2. 已确认的现场问题

- 当前 PDD AX 树完整存在，可读取 WebArea、会话列表、聊天正文、输入框和发送控件；不是辅助功能权限或 AX 子树缺失。
- 当前页面只显示脱敏昵称，例如 `S***`、`c*y`、`山**川`，没有读到可验证的真实买家 UID。
- `PDDCustomerIdentity` 只接受 `GZC-[0-9]+`，导致真实页面无法通过身份解析。
- 当前磁盘遗留 `GZC-000001` 的 pending capture，失败后约每 0.32 秒重复进入定位，产生大量相同警告。
- 当前 `conversationRows` 在真实页面把时间、`转移会话` 和列表尾部当作会话行；现场测试从约 3 个真实会话识别出 7 个候选，标签包括 `10:44`、`转移会话`、`已经没有更多了哦~`。
- `AXElementToken` 每次读树都会重新生成，只能用于当前一次 AX 操作，不能作为持久身份。

## 3. 身份模型

新增可编码模型：

```swift
struct PDDConversationLocator: Codable, Equatable, Sendable {
    var domIdentifier: String?
    var nickname: String
}
```

新增内部用户键：

```swift
enum PDDConversationKey {
    static func make(locator: PDDConversationLocator) -> String
}
```

键生成规则：

- identifier 可用时：`PDD-ID-<SHA256(identifier) 前 24 个十六进制字符>`；
- identifier 不可用时：`PDD-NAME-<SHA256(normalizedNickname) 前 24 个十六进制字符>`；
- 文件夹不直接使用昵称，避免 `/`、控制字符、超长 Unicode 和路径穿越；
- UI 同时显示昵称，哈希键只用于本地隔离、Codex session 和持久状态。

“identifier 可用”必须同时满足：

- 非空；
- 不是页面通用容器 ID；
- 属于真实外层会话行；
- 当前会话列表中只出现一次。

## 4. 会话行解析

重写 `PDDAXControlSelection.conversationRows` 的候选构造：

- 只接受会话列表直属或结构上最近的外层会话项；
- 排除嵌套 `AXPress` 控件，例如 `转移会话`；
- 排除时间文本、纯数字未读数、`加载更多`、`已经没有更多了哦~` 等尾部元素；
- 从整行后代文本中提取昵称，不再使用“第一个非空文本”；
- 输出 `rowID`、`domIdentifier`、`nickname`、`frame`；
- 红点检测继续返回同一会话行，而不是其内部按钮。

昵称提取首先使用昵称节点的 DOM class/结构；若当前版本没有稳定 class，则使用排除规则：去掉时间、动作文字、未读数字和消息预览后取得昵称候选。

## 5. 发现、打开和失效回退

### 5.1 红点发现

1. 获取真实未读会话行；
2. 构造 locator；
3. identifier 可用时用 identifier 键，否则用昵称键；
4. 将 `uid -> locator` 写入持久状态；
5. AXPress 当前行；
6. 不再要求打开后的页面包含 `GZC-xxx`；成功读到聊天面板/输入框即视为打开完成。

### 5.2 重新打开

1. 从持久状态读取 locator；
2. identifier 存在时优先精确匹配真实会话行；
3. 找不到 identifier 时按标准化后的昵称精确匹配；
4. 昵称唯一则点击并把新 identifier 回写到 locator，但保持原内部用户键，避免历史和 Codex session 被切断；
5. 昵称有多个候选时，选列表顺序中的第一个真实会话行，记录 `conversation-nickname-ambiguous` 警告并继续；
6. 完全找不到昵称时，如果当前页面已有可用聊天面板，则直接读取当前会话并记录 `conversation-current-fallback`；否则本次请求延后，但不得形成无间隔热循环。

### 5.3 identifier 变化

identifier 失效后通过昵称找回会话时，只更新 locator 的 `domIdentifier`。内部用户键、历史目录、answered cursor 和 Codex session 不迁移、不重建。

## 6. 持久化与迁移

`AutoReplyPersistentState` schema 升级并增加：

```swift
var conversationLocatorsByUID: [String: PDDConversationLocator]
```

迁移规则：

- 旧 terminal jobs 和归档保留，不删除历史证据；
- 旧 `GZC-xxx` answered cursor、历史和 Codex session 保留为 legacy，只读兼容；
- 没有 locator 的旧 `GZC-xxx` pending capture 无法定位真实会话，启动迁移时移出活跃队列并写入 `legacy-locator-dropped` 事件；
- 不把旧 `GZC-000001` 历史自动合并给当前 `S***`，防止把旧用户对话串入新用户；
- 新任务一律使用 `PDD-ID-*` 或 `PDD-NAME-*` 安全键。

`PerUserAXStore.validUID` 改为接受：

- legacy `GZC-[0-9]+`；
- 新的 `PDD-ID-[0-9a-f]{24}`；
- 新的 `PDD-NAME-[0-9a-f]{24}`。

仍拒绝路径分隔符、控制字符、省略号和超长值。

## 7. 调度与失败策略

- `uidNotFound` 不再表示“页面没有 GZC”，只表示 identifier 和昵称都没有候选且当前聊天面板不可用；
- 定位失败必须进入既有有界退避，不能每 0.32 秒持久热循环；
- identifier 失效、昵称多候选、使用当前页兜底均为警告，不停止 scheduler；
- 所有用户继续共享单一 UI lease，避免两个任务同时点击会话；
- 生成中的任务仍按内部用户键隔离 Codex session。

## 8. 测试要求

必须先增加失败测试，再实现：

1. 会话行有唯一 DOM identifier，产生 `PDD-ID-*`；
2. identifier 缺失时按昵称产生 `PDD-NAME-*`；
3. identifier 失效后按昵称重新打开并更新 locator；
4. 两个用户都显示 `S***` 且 identifier 不同，形成两个独立用户键；
5. 两个 `S***` 且 identifier 都缺失，选择第一个并发出歧义警告，不阻塞；
6. `转移会话`、时间和列表尾部不会成为会话候选；
7. 旧 `GZC` pending capture 被迁移出活跃队列；
8. 新 UID 格式通过路径安全校验，非法路径仍被拒绝；
9. 重启后 locator 仍可恢复；
10. 真实 PDD smoke test 打印每条真实会话行的 nickname、DOM identifier、frame，确认 identifier 是否确实独立；
11. 全量单元测试通过；
12. 候选版构建、签名、启动后，现场验证当前 `S***` 能读取且不再出现 `GZC-000001` 定位热循环。

## 9. 不包含的范围

- 不抓取拼多多内部网络接口或 Cookie；
- 不宣称 AXDOMIdentifier 等于真实买家 UID；
- 不加入 OCR 昵称识别，AX 可见昵称已足够作为指定兜底；
- 不在本次实现视频下载或录屏；
- 不重构 Codex、知识库、图片处理或回复内容逻辑。

