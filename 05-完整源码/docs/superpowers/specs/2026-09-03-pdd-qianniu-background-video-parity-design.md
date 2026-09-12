# PDD 与千牛一致的后台视频处理设计

## 状态与目标

本设计取代 `2026-09-02-pdd-video-auto-reply-design.md` 中“在一次 capture 内同步解析、下载和抽帧”的方案。

目标是把千牛通用自适应版当前实际运行的视频状态机原样迁移到 PDD：前台 UI 只负责为具体客户、具体消息建立监听并点开视频；链接等待、下载、校验、抽帧、音轨导出、语音识别和 Codex 生成均在后台运行，不占用红点扫描和其他客户的 UI 队列。

## 权威参考实现

实现时以以下千牛源码为行为基准，而不是凭描述重新发明：

- `QianniuVideoTransfer.swift` 中的 `BestEffortVideoDownloadJob`、`BestEffortArmedVideoTransfer`、`QianniuBestEffortVideoTransferArmer`
- `QianniuVideoProbeCore/Module.swift` 中的 `ArmedVideoCandidateWatcher`、`VideoDownloadSessionPolicy`、`VideoDownloadClient`
- `VideoDownloadMonitor.swift`
- `CustomerVideoEvidence.swift`
- `AppleVideoSpeechTranscriber.swift`
- `VideoAnalysisInbox.swift`、`VideoAnalysisCoordinator`
- `VideoAnalysisSnapshotFactory.swift`

平台差异只允许存在于“临时地址从哪里取得”：千牛监听 MessageSDK 日志，PDD 监听 CEF `Cache_Data` 增量元数据。其余状态、并发和完成回调语义保持一致。

## 端到端状态机

```text
红点发现客户视频
  → 用 uid + messageID 建立 PDD CEF 增量监听基线
  → 自动点击视频缩略图
  → 启动独立后台 transfer
  → 关闭预览窗口并释放 UI 租约
  → 主调度器继续扫描其他客户

后台 transfer
  → 不限时等待完整临时地址
  → 不限时下载到临时文件
  → 验证并原子移动到稳定 MP4
  → UI 显示下载完成
  → 自适应抽帧 + 导出 audio.m4a + 苹果语音识别
  → 持久化 manifest
  → 以同一 uid 的独立 video-analysis revision 加入 Codex 队列
  → 全部帧一次性通过 --image 提交，转写文字写入 prompt
  → 生成一条回复并走现有 AX 发送器
```

同一视频的原始 `[视频]` 占位批次只负责登记后台任务，不得在证据未完成时提前生成“请补充说明”回复。真正可生成的任务由后台完成事件创建。这样不会先回复一次占位内容、下载完成后再重复回复一次。

登记成功后，scheduler 持久化该 `uid + messageID` 的 `awaitingVideoEvidence` 收据并推进普通聊天 cursor；该收据不会进入 `.queued/.generating`。后台 evidence 回注使用独立 revision，因此推进 cursor 不会吞掉完成事件。若同批还有文字或图片，则这些内容与视频 evidence 合并为一个等待中的媒体批次，不能提前单独回复后再对视频重复回复。

## 前台打开与后台隔离

PDD 新增与千牛 `VideoTransferArming` 对应的两阶段接口：

- `arm(uid:messageID:candidate:)` 在点击前捕获所有 PDD CEF profile 的缓存基线，并返回一次性 armed transfer。
- `start()` 只启动一个 utility 优先级后台任务，重复调用无效。
- 前台点击成功后调用 `start()`，随后立即关闭预览并释放 `UIOperationLease`。
- 后台任务不得继续持有或调用 AX、鼠标、键盘，也不得在完成时切换 PDD 会话。

需要修正 `PDDLiveAutoReplyDriver` 当前 lease 重载的反向调用：live `capture` 必须调用 `conversationDriver.capture`，live `preflight` 必须调用 `conversationDriver.preflight`。否则正式运行时附件捕获会被错误地当成 preflight 跳过。

## 地址监听与下载语义

PDD CEF watcher 增加无 deadline 的 `wait()`：

- 只读取 arm 之后新增或发生变化的缓存记录。
- 元数据正在写入时每 0.2 秒重新读取，直到出现完整 HTTPS 视频地址。
- 临时签名地址只存在内存，不写日志、状态文件或 UI。
- 候选地址继续执行 PDD 域名、HTTPS、视频 MIME/MP4 证据及重定向校验。

下载配置与千牛 `VideoDownloadSessionPolicy` 一致：

- `timeoutIntervalForRequest = .greatestFiniteMagnitude`
- `timeoutIntervalForResource = .greatestFiniteMagnitude`
- `waitsForConnectivity = true`
- `URLSessionConfiguration.ephemeral`
- 禁用 URL cache 和 cookie storage
- 允许 constrained/expensive network
- 不设置最大字节数，不因文件较大主动取消

“无限时”只适用于地址等待和网络下载。用户停止自动客服或进程退出时，所属后台 Task 必须取消；取消不是下载失败，也不得触发重试发送。

千牛参考实现中的语音识别 45 秒保护和 evidence 准备 90 秒保护继续保留；它们发生在 MP4 已完整下载之后，不会取消下载，也不占用 PDD UI。这里删除的是 PDD 现有的 12 秒视频窗口、60 秒缓存等待、25 秒 capture 竞争和 200 MiB 大小门禁。

下载先写 `.<messageHash>.<UUID>.partial.mp4`，成功后验证 HTTP 200/206、ISO BMFF 文件头、有效时长和视频轨道，再原子移动为 `<messageHash>.mp4`。异常退出留下的 partial 在恢复流程中清理。最终文件已存在时按同一消息判重，不重复下载。

## 身份、持久化与恢复

每个 transfer 使用：

- `customerUID`：现行 `PDD-NAME-*` 会话标识
- `messageID`：AX 消息 DOM identifier
- `messageHash = SHA256(messageID)`
- 唯一键：`SHA256(customerUID) + messageHash`

持久化 inbox 至运行目录，阶段包括：

- `armed`
- `waitingForAddress`
- `downloading`
- `downloaded`
- `preparingEvidence`
- `readyForGeneration`
- `admitted`
- `completed`
- `failed`

地址本身永不持久化。应用重启后：稳定 MP4 已存在的任务从 evidence 阶段恢复；只有 partial、没有可恢复地址的任务回到“等待该消息下次重新打开”，不能拿其他客户后来产生的缓存地址续接。

## 抽帧算法

完全采用千牛 `CustomerVideoEvidencePreparer.sampleTimes`：

- 时长无效或没有视频轨道：证据准备失败。
- `< 2 秒`：最多 3 帧。
- `2–10 秒`：`min(20, max(4, ceil(duration)))` 帧。
- `10–30 秒`：`min(20, max(4, ceil(duration / 2) + 1))` 帧。
- `> 30 秒`：20 帧。
- 起点为 `min(0.20, duration × 0.1)`。
- 终点为 `duration - min(0.20, duration × 0.1)`。
- 在起点和终点之间均匀采样，相邻时间差小于 0.04 秒时合并。
- 不做相似度计算，不删除重复画面。

帧输出为 JPEG，质量 0.82，文件名包含顺序和真实时间点；每帧记录 SHA-256。抽帧使用可取消的 AVFoundation 异步接口，不阻塞 MainActor。

## 音轨与语音内容

若视频存在音轨，使用 `AVAssetExportPresetAppleM4A` 导出 `audio.m4a`；没有音轨不视为失败。语音识别采用 `SFSpeechRecognizer`，语言 `zh-CN`，优先设备端识别。识别结果保存为带 `startSeconds`、`durationSeconds`、`text` 的时间轴片段。

Codex CLI 当前只有 `--image`，没有音频附件参数，因此：

- 所有视频帧一次性通过 `--image` 传入同一轮 Codex。
- `audio.m4a` 保存在证据目录，不伪装成图片参数。
- 音频内容通过苹果语音识别后的时间轴文字进入 prompt。
- 识别不可用或无结果时明确写“没有可靠语音转写”，但画面分析仍继续。

## Codex 入队与去重

新增后台完成事件桥接器，解决 runtime 构造时 downloader 与 scheduler 的循环依赖。桥接器先缓存完成事件，scheduler 创建后安装 handler。

完成事件生成一个 `video-analysis:<messageHash>` revision：

- UID 必须等于下载启动时冻结的 `customerUID`。
- history/target 中只有一条客户 `video_evidence` 消息，描述帧时间点及语音转写。
- `videoAttachments` 包含稳定 MP4、帧、音轨路径和 manifest；Codex 只接收帧和转写。
- `AutoReplyVideoAttachment` 增加可选 `audioLocalURL` 与 `manifestLocalURL`；Codable 解码必须兼容旧状态中没有这两个字段的记录。
- scheduler 通过公开的、持久化的 external capture admission 入口入队。
- 同一 `uid + revision` 已存在、已完成或已归档时返回 already-present，不再生成或发送。
- 不依赖新红点，不重新打开会话，不重新 OCR。

发送前 preflight 仍只检查是否出现更新的客户消息，不重复下载或抽帧。最终发送沿用现有 per-UID 队列、Codex session、cursor 核对和 AX sender。

## UI

UI 使用独立视频状态，不覆盖红点扫描主状态：

- `视频已识别：<用户>`
- `已打开视频并启动后台下载`
- `视频后台下载中：<消息ID>`
- `视频下载完成：<消息ID> · <大小> · <耗时>`
- `正在抽帧和处理音轨`
- `已提取 N 帧 · 音轨已保存/无音轨 · 转写 N 段`
- `已提交 Codex`

开始、完成状态写入本地 monitor；pending 记录没有超时、没有失败门禁，也无权暂停扫描。失败只影响该视频 revision，UI 显示原因后继续服务其他客户。

## 错误与优先原则

- 单个视频地址迟到、下载慢、抽帧失败或语音识别失败都不能卡住扫描器。
- 网络下载不按时间或大小主动终止；真实网络错误可记录失败。
- 图片继续走原图片流程，绝不为了等待视频类型统一延迟 8–12 秒。
- 视频 evidence 失败时，才为该 video-analysis revision 生成“无法读取视频内容”的简短追问；不能让整个用户或全局队列停住。
- 签名 URL、cookie、原始 CEF 日志不得进入状态、prompt 或诊断。

## 测试与验收

自动测试必须覆盖：

1. arm 发生在点击前，start 后前台立即返回。
2. 后台地址等待和下载没有时间/大小上限。
3. 停止应用会取消后台任务。
4. 两个用户、两个视频并发时 UID/messageID/文件/回复不串线。
5. partial 不会被当成成功，稳定 MP4 只在校验后出现。
6. 应用重启后 downloaded/evidence 阶段可恢复且不重复回复。
7. 抽帧时间点与千牛算法逐项一致，不做重复帧过滤。
8. 有音轨生成 `audio.m4a`；无音轨仍可完成。
9. 全部帧一次性进入 Codex `--image`；MP4/M4A 不进入 image 参数。
10. transcript 带时间轴进入 prompt。
11. preflight 不打开、不下载、不抽帧。
12. live lease capture/preflight 路由方向正确。
13. 下载完成 UI 状态持久显示，不被一帧内覆盖。
14. 全量 Swift 测试、release 构建、codesign 校验通过。

真机验收使用新发 PDD 视频，确认：自动打开后迅速关窗；主扫描继续；慢速下载不会在 12/15/25 秒被取消；完成后出现 UI 提示；稳定 MP4、关键帧、`audio.m4a` 和 manifest 落盘；Codex 收到所有帧与语音转写并只生成一条回复。
