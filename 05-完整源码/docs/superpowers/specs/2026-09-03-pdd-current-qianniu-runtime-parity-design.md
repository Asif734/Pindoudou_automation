# PDD 对齐当前千牛调度与视频恢复设计

## 基线与目标

本设计以 2026-09-03 当前任务“检查已打开的千牛（完整千牛）”实际使用的工作树为唯一千牛基线，不引用千牛旧版行为。

目标是在保留 PDD 平台适配层的前提下，移植当前千牛仍然更成熟的七项行为：ready 回复优先、失败会话可重新发现、缩短发送链路、图片副作用一次性保护、75 秒采集保险、持久视频恢复，以及每轮 UI 前的状态文件校验。

以下能力已经对齐，不在本次重复实现：

- 同一 UID 队首串行、不同 UID 并行；
- 执行状态冲突自动修复；
- `video:` / `video-analysis:` 归一化判重；
- 同一客户按 MP4 真实 SHA-256 内容判重；
- 最多 20 帧、音轨导出、语音转写及一次 Codex 提交；
- 每客户独立 Codex 会话及增量历史；
- 三次连续发送后强制发现与动态生成并发。

## 总体原则

PDD 继续拥有平台边界：`PDD-NAME-*` 身份、会话 locator、AX-first/OCR 尾部补采、CEF 视频地址捕获、PDD 域名白名单和现有 AX 发送器。千牛只作为调度与恢复语义的参考，不能把千牛日志路径、`messageType=105` 或窗口选择器复制进 PDD。

同一客户可以有任意数量等待任务，但任何时刻只有一个采集、生成或发送任务执行。普通 AX/OCR/单客户失败不得停止全局；只有无法证明状态完整性的持久化错误才停止自动 UI 与发送。

## 1. Ready 回复优先

调度顺序改为：

1. 校验持久状态；
2. 补充 Codex 生成槽位；
3. 连续发送达到 3 次时先发现；
4. 发送非延迟的 ready 队首任务；
5. 第一次补充采集；
6. 第一次普通采集；
7. 补充采集重试；
8. 普通采集重试；
9. 延迟的安全发送重试；
10. 发现红点。

已经冻结并生成的 A 回复不能被后来 B/C 的补充采集阻挡或改写。A 先发送，B/C 作为同 UID 后续批次排队。三次 ready 发送后仍强制执行一次发现，避免新客户饥饿。

## 2. 采集失败后的重新发现

一次红点发现创建一条持久 `discovered` 任务。首次定位/采集失败后，该任务退到全局队尾并在 1 秒后重试；第二次失败后只把这一次任务置为 `parked`，保留失败原因。

不得维护“红点仍存在就永久屏蔽 UID”的集合。parked 任务不算活动任务；下一次发现扫描再次看见同一 UID 的红点时，可以创建新的 discovered 任务。终态任务设置 0.5 秒 rearm，防止 200 ms 循环自旋，同时保证持续红点能够重新尝试。

新任务仍须遵守同 UID 队首规则。旧 parked 记录只用于诊断，不能阻塞新任务。

## 3. 缩短发送链路

删除 scheduler 的 `driver.preflight(uid:after:)` 整轮聊天采集。发送路径直接从持久 ready 状态进入 durable sending 标记，再调用 `PDDAXReplySender.send`。

发送器继续负责所有最终安全检查：

- 打开目标 locator 并核对完整 UID；
- 检查输入框状态；
- 写入并回读回复；
- 点击前再次核对 UID；
- 返回 sent、failedBeforeSend 或 uncertain。

`failedBeforeSend` 必须保留原 reply 和冻结输入，不重新调用 Codex。它使用 2、4、8、16、30 秒上限的指数退避，先让发现、新采集和其他 UID 的 ready 回复通过；一次发现完成后即可再次尝试。已经调用发送后抛错仍按 uncertain 完成，禁止自动重发。

移除 preflight 后，追加 B/C 只能由红点发现和补充采集进入下一任务，不能依靠发送前偷读聊天产生任务。

## 4. 图片操作一次性保护

为持久任务/采集请求增加 `imageCaptureAttempted`，旧状态缺失时默认为 false。

调用可能打开、复制或下载图片的 capture 前，先把该字段置 true 并持久化。普通错误、整体超时或图片之后的视频步骤失败时，重试调用 capture 必须传入 `includeImages=false`，不得再次点击同一图片。

只有驱动明确抛出 `captureFailedBeforeMedia`，证明尚未开始任何媒体操作时，才把标记恢复为 false。新红点创建的新任务拥有新的 false 标记；该保护只约束一次任务，不永久屏蔽客户图片。

## 5. 75 秒采集保险

调度器外层 deadline 使用当前千牛值：

- discovery：8 秒；
- ordinary capture：75 秒；
- supplement capture：75 秒；
- delivery：25 秒。

PDD 驱动内部仍保留更细的打开会话、AX 重采样和 OCR 单步保护，但外层不得再用 25 秒截断包含 AX 重采样、OCR 与媒体登记的完整 capture。删除或停止使用未接线的 `outerFuseSeconds` 双重配置，保证生产代码与测试读取同一个权威 deadline。

视频下载和证据处理不持有 capture lease，不计入 75 秒。

## 6. PDD 视频下载可靠性 V2

### 6.1 保留的 PDD 特性

检测到视频时立即持久化 `PDDPendingVideoBatch`，为该客户占住原始消息顺序；CEF 基线必须在点击前建立。打开、启动后台传输并关闭预览后立即释放 UI。

临时视频 URL 只存在内存，永不写入状态、日志、Prompt 或诊断。真实 MP4 内容 SHA-256 判重及现有抽帧/音轨/转写保持不变。

### 6.2 持久状态机

新增 schema 化的 durable transfer store，每条记录以 `customerHash + messageHash` 为键，至少包含：

`discovered → opening → addressCaptured → downloading → validating → downloaded → preparingEvidence → readyForGeneration → admitted → completed`

可恢复失败进入 `waitingForRetry`，永久无效或预算耗尽进入 `terminalFailure`。记录保存尝试次数、通用失败分类、下次时间、稳定文件名和是否已经提交失败提示；不得保存签名 URL。

### 6.3 单次下载与恢复

对齐当前千牛的恢复语义，而不是旧版永久 15 秒失败：

- 系统线路连接保护 5 秒、单次资源保护 15 秒；
- 一次即时处理总预算 30 秒；
- 系统线路出现可恢复错误后尝试通过 DNS 解析得到的、仍满足 PDD HTTPS/域名策略的备用地址；
- 即时线路均失败时只为该视频提交一次诚实的简短失败提示；
- 后台约 60、180、600 秒重新取得该消息的新地址并重试；
- 后来成功仍继续真实内容哈希、证据准备和 `video-analysis`，先前失败提示不算视频分析完成。

停止自动客服会取消当前网络任务，但 durable 状态保留为可恢复；重新启动后继续。孤立 partial 不能视为成功，重试前删除。稳定 MP4 必须通过 HTTP、ISO BMFF、时长和视频轨道检查后原子落盘。

若 PDD CDN 无法安全构造备用地址，则跳过备用线路并进入持久重试，不能放宽域名或 TLS 校验。

### 6.4 与 PDD 批次队列衔接

即时成功时，原 `PDDPendingVideoBatch` 收齐所有视频终态后在原位置生成一条综合任务，保留 PDD“同批多个视频只回复一次”的能力。

即时失败提示解除该视频对原批次的等待，避免同一客户永久堵塞；同批文字/图片仍正常生成。之后恢复成功的视频以独立 `video-analysis:<contentSHA256>` 任务加入该 UID 队尾。失败提示 revision 与分析 revision 分离并分别判重。

下载/证据失败不能停止全局，也不能回退到图片复制。证据准备失败两次后生成一次诚实澄清任务；不能声称已经看见或听见视频。

## 7. 每轮 UI 前验证状态文件

首次创建全新运行目录时允许初始化状态文件；已经存在的运行目录如果缺少、损坏、被替换或外部修改 `state.json`，必须在下一轮 discovery/capture/send 之前发现。

校验使用缓存的文件 identity/checkpoint token，不要求每轮完整解码归档。失败后撤销 UI lease，停止自动调度并显示持久化错误，禁止继续发送。用户数据目录不得自动清空或用空状态覆盖。

执行任务重叠不属于文件损坏，继续使用现有 `repairOverlappingExecutions` 自动整理，不得因此停机。普通日志、UI 状态或可读归档写入失败也不得冒充核心 checkpoint 损坏。

## 数据迁移与兼容

- 调度状态 schema 升级时保留所有 jobs、answered cursors、locators、PDD-NAME 身份、图片/视频附件和 Codex session。
- 旧 pending capture 缺少 `imageCaptureAttempted` 时默认 false。
- 旧 pending video batch 转换为 durable transfer record：稳定 MP4 存在则从 validating/evidence 恢复；只有 partial 则删除 partial 并进入 waitingForRetry；两者都没有则请求精确 UID/message 重新打开。
- 迁移前状态先原子备份；不得删除 Application Support 或桌面聊天记录。

## 测试要求

每项生产修改严格执行 RED → GREEN：

1. ready 回复在首次 supplement capture 前发送；三次发送后仍先发现。
2. 同一 UID 第二次 capture 失败进入 parked；持续红点经过 rearm 后产生新任务并成功。
3. delivery 不调用完整 preflight；发送器 UID 检查仍运行。
4. capture 后半段失败的重试参数为 `includeImages=false`；`captureFailedBeforeMedia` 重试仍为 true。
5. hanging capture 在 75 秒外层终止，25/35 秒时不得被 scheduler 取消。
6. 视频系统线路超时后尝试备用线路；即时失败只提交一次提示；60/180/600 重试；后来成功仍提交分析。
7. 重启恢复 waiting/downloading/downloaded/preparing 状态；partial 不算成功；签名 URL 不落盘。
8. 原 PDD 视频顺序占位、同批多视频合并、真实内容 SHA 判重继续通过。
9. state.json 删除、替换、损坏时，下一次 UI 调用计数保持不变且调度停止；执行冲突仍自动修复并继续。
10. 现有完整 Swift 测试、release 构建、签名校验和一轮新视频真机链路通过。

## 明确不做

- 不改变 PDD AX/OCR 消息解析算法、红点像素规则或 PDD-NAME 身份算法。
- 不重新实现已经存在的内容哈希、抽帧、音轨、转写或 Codex 增量会话。
- 不把 MP4/M4A 当作 Codex `--image` 参数。
- 不使用 OCR 判断下载进度，不保存签名 URL，不注入 PDD 进程。
- 不因为普通客户、AX、OCR、Codex 或视频错误停止其他客户；核心状态完整性错误除外。

