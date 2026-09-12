# 拼多多全自动客服任务隔离候选版设计

## 目标

在不覆盖现有 `拼多多全自动客服.app`、Bundle ID 和运行记录的前提下，构建独立的“拼多多全自动客服-任务隔离候选版”。候选版保留当前 PDD 的红点检测、OCR 正文、AX 路由与发送、每用户 Codex 会话、V2 Top-12 知识检索和进度 UI，同时移植千牛任务隔离候选版已经验证的阶段 deadline、可撤销 UI lease、任务局部失败、发送提交持久化和故障注入不变量。

## 范围

本次包含：

- 独立候选 App、Bundle ID、可执行身份和数据目录。
- 发现、捕获、客户图片下载、生成、发送和确认六阶段任务模型。
- 所有 PDD UI 操作的 deadline 与可撤销 lease。
- 单任务失败放队尾/停放，不阻塞全局扫描。
- 冻结客户消息范围和发送调用前持久化。
- 客户原图下载并作为 Codex CLI 图片附件输入。
- 自动化测试、故障注入 soak、真实 PDD 验收和交付校验清单。

本次不包含：

- 自动向客户发送知识库图片或视频。
- 多店铺、多拼多多进程的统一总控。
- 替换或迁移现有正式版运行状态。
- 修改拼多多网络接口、DOM 或应用资源。

## 交付身份与隔离

候选版使用独立显示名 `拼多多全自动客服-任务隔离候选版`，独立 Bundle ID 和独立数据根目录。构建脚本只写新的候选输出路径；如果目标路径已经存在，先移动到带时间戳的 `previous-builds`，不直接覆盖。现有正式版和候选版可以同时安装，但启动检查必须阻止两者同时自动运行，因为两个数据目录不会共享 answered cursor，同时运行会重复处理同一红点。

候选版默认停止。用户显式点击开始后才扫描和发送。干运行选项继续保留。

## 架构

采用“保留 PDD 适配层、替换调度权威核心”的方式：

1. PDD 适配层继续负责截图红点、AX 会话行与 UID、OCR 聊天气泡、AX 图片证据、输入框和发送按钮。
2. 新任务隔离调度器是唯一决定下一阶段和 UI 操作顺序的组件。
3. Codex 生成在不同 UID 之间并发，同一 UID/客户消息版本串行。
4. PDD UI 始终串行；任何时刻最多存在一个有效 UI lease。
5. 每次状态变化先原子持久化，再允许下一项不可逆动作。

候选版不直接复制千牛 UI 选择器。只复用平台无关的任务隔离概念，并为 PDD 当前接口编写适配和回归测试。

## 任务与状态

一个任务由 `uid + revision + frozen batch` 唯一标识。任务保存：

- 稳定任务 ID 和 FIFO sequence；
- UID、客户消息 revision、`startCursor` 与 `endCursor`；
- 当前 stage、stage attempt、失败次数和下次运行时间；
- 已下载客户图片的路径、来源 URL、SHA-256、MIME 和尺寸；
- 生成回复及 Codex 诊断；
- UI operation ID、lease epoch、`sendWasInvoked`；
- delivery outcome 和终态证据。

状态覆盖 discovered、capturing、queued、generating、ready、sending、completed、parked 和 failed。`completed + uncertain` 表示发送动作已经可能发生但无法确认；它是终态，不能自动重发。

客户在旧任务生成或发送期间新增的消息形成后续 revision 和新的冻结范围，不修改旧任务的回复所有权。

## UI lease 与 deadline

所有会改变 PDD 界面的操作都必须携带 `UIOperationLease`：会话发现中需要滚动或点击的动作、打开客户、OCR 前置前台与定位、图片预览、发送和确认。lease 注册表同步维护 epoch；获取新 lease、停止程序或 deadline 超时会撤销旧 lease。

每次 await 之后、每次点击/写入之前都重新验证 lease 和 UID。旧调用即使不响应 Swift task cancellation 并在超时后返回，也只能产生丢弃结果，不能继续操作 UI。

生产 deadline 初始值：

- 发现：8 秒；
- 捕获（AX 定位、截图和 OCR）：75 秒；
- 客户图片预览与下载：30 秒/张；
- 发送前复核：75 秒；
- 发送与确认：25 秒；
- Codex CLI：沿用当前 180 秒进程 deadline，由生成阶段独立管理。

这些值通过依赖注入进入测试，测试使用毫秒级 deadline。

## 调度与失败隔离

调度器以短 tick 分发有界子任务，不再让全局 pump 直接等待一个可能永不返回的 UI 调用。UI 工作未终结时不分发第二个 UI 工作；后台 Codex 生成可以继续。

同一任务的可重试 UI 阶段第一次失败时放到队尾并记录阶段证据；第二次失败时进入 parked。parked 只冻结该 revision，不阻止其他 UID，也不阻止同一 UID 后续新 revision。发现阶段的坏 AX 行、空节点或无法确认身份的红点只作为观察记录，不伪造 UID。

OCR、图片、检索、Codex、发送或确认错误均不得停止全局调度。只有调度状态无法读取或无法原子写入时停止程序，避免在失去幂等证据的情况下继续发送。

## 客户图片输入

PDD 缩略图的 AX 节点通常没有 URL。候选版按以下流程获取客户原图：

1. 通过客户消息 ID、sender、`image-msg` class 和非零可见 AX frame 选择目标图片。
2. 在持有有效 lease 且 UID 仍匹配时双击图片 frame 中心，打开标题为“图片预览”的窗口。
3. 在预览窗口中选择 `MacPreview_imgContent` 主图 AX 节点，读取 HTTP/HTTPS `AXURL`。
4. 下载到候选版该 UID/revision 的图片目录，限制响应大小，验证 MIME、可解码格式、像素尺寸和 SHA-256。
5. 关闭预览，重新确认 PDD 当前 UID，再把绝对本地路径加入 Codex CLI 图片参数。

下载原始 URL 是主路径。预览工具栏的系统保存面板会把 JPEG 重编码为 PNG，只作为诊断备用，不作为原图主路径。

图片及客户文字始终是不可信数据，只能进入 Prompt 数据区。图片内容不能改变系统规则、工具权限或发送策略。

纯图片任务在下载或解析失败后第一次重试，第二次 parked；不得用 `[图片]` 占位直接生成猜测回复。文字和图片混合任务的图片失败同样按任务失败处理，不悄悄丢掉图片后回答。

## 生成与知识检索

保留当前每 UID Codex session、`gpt-5.6-sol`、medium、V2 Top-12、本地知识库版本和并发内存策略。任务生成输入包含完整已存历史、当前冻结客户范围、结构化知识证据和已验证的客户图片绝对路径。

同一 `uid + revision` 只能有一个 live generation。停止自动化不会伪造完成状态；已经启动的 CLI 可以完成清理，但只有仍匹配当前任务 attempt 的结果才能写入 ready。

## 发送、确认与重启恢复

发送事务顺序固定为：

1. 重新捕获并核对 UID、客户 cursor 和可见历史。
2. 如历史已经出现与冻结回复完全一致且未被其他任务占用的客服消息，直接对账为 sent。
3. 原子持久化 `.sending`、operation ID 和 `sendWasInvoked=false`。
4. 再次验证 lease、UID 和 cursor。
5. 在调用会执行发送点击的驱动前，原子持久化 `sendWasInvoked=true`。
6. 只允许一次发送提交。
7. 通过输入框清空或可见客服消息回读确认结果。

重启恢复规则：

- `.sending && sendWasInvoked=false`：回到 ready，可安全重新执行。
- `.sending && sendWasInvoked=true` 或已有 uncertain：终结为 `completed + uncertain`，推进该冻结批次的 operational cursor，不自动重发。
- capturing：回到 discovered。
- generating：回到 queued，清除旧 attempt ID。

这套策略优先保证全局继续和“不重复发送”，符合当前 PDD 对未知发送结果的非阻塞要求。

## 持久化与记录

候选版使用新的 schema 和独立根目录，旧正式版 state 不导入、不修改。状态采用原子替换写入；终态任务保存不可变 JSON 记录和只读回复 sidecar。事件包含 UID、revision、stage、operation ID、deadline、失败处置、下载图片哈希、Codex 延迟、发送提交和确认结果。

进度 UI 只读取内存快照，不触发额外 PDD 扫描。主窗口和浮窗显示当前有效 lease、阶段、剩余/已超时状态、队列、parked 数、CLI 数、最近警告及“扫描仍继续”。

## 测试策略

所有新生产行为严格执行 RED-GREEN-REFACTOR。当前 210 项 Swift 测试必须保持通过。新增测试至少覆盖：

- deadline 在底层不响应 cancellation 时仍及时返回；
- 新 lease 和 stop 同步撤销旧 lease；
- 超时后的旧驱动结果不能点击、写入或发送；
- 任意时刻最多一个 UI lease；
- 第一次任务失败放队尾，第二次 parked；
- parked revision 不阻止其他 UID 或同 UID 新 revision；
- `sendWasInvoked` 在发送调用前已经持久化；
- 重启对未调用/已调用发送使用不同恢复规则；
- 每任务最多一次发送提交；
- PDD 图片选择只接受当前客户的可见 customer image；
- 预览主图 URL 校验、原图下载、哈希和 Codex 图片参数；
- 图片 URL 缺失、超时、过大、格式错误和 UID 改变；
- 现有 OCR、红点、游标、Prompt、V2、会话和发送行为无回归。

故障注入 soak 随机交错至少包括 AX 空行、发现超时、打开超时、截图/OCR 超时、图片超时、知识检索超时、Codex 超时、点击超时和确认超时。最终报告必须证明：同时最多一个 UI lease、`uid + revision` 生成唯一、每任务最多一次发送提交、故障只影响所属任务。

## 真实 PDD 验收

候选版先以 stopped/dry-run 启动，验证独立数据目录和权限。随后使用当前已登录的 PDD 测试会话依次验证：

1. 红点和当前会话兜底发现；
2. 文字消息 OCR、冻结、Codex 和发送；
3. 客户图片 AX 定位、双击预览、原图 URL 下载、Codex 图片理解；
4. AX/OCR/图片阶段人为超时后继续下一个客户；
5. 发送前停止、发送调用后中断和重启恢复；
6. 新增客户消息进入下一冻结范围；
7. 不重复发送且旧正式版未被启动或修改。

真实测试记录保存时间、UID、任务 ID、阶段结果和文件哈希，不保存密码、Cookie、Token 或 Codex 凭证。

## 交付物与完成标准

交付包含：

- 独立候选 `.app`；
- 当前完整 PDD 源码及候选变更；
- Swift、Python/故障注入、打包测试报告；
- 真实 PDD 验收记录；
- App、可执行文件、知识库和关键运行资源 SHA-256 清单；
- 回滚说明和禁止双开说明。

完成标准：自动化测试无失败，故障注入不变量全部通过，候选 App 可独立启动，真实 PDD 文字与客户图片流程成功，任一任务故障不会停止全局扫描，且不存在自动重复发送证据。

## 工程约束

当前工作目录没有 Git 元数据，因此不能创建真实分支、提交或标签。实施期间通过独立候选身份、独立输出、独立运行目录、构建前备份和 SHA-256 清单保护旧版本；交付材料不得声称不存在的 Git 提交。
