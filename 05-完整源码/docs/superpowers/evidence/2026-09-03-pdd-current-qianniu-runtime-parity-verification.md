# PDD 与当前千牛运行语义对齐验证（2026-09-03）

## 本次范围

只迁移已确认的七项运行语义，不修改拼多多专属的红点、身份、OCR/AX 消息解析、媒体识别或视频打开算法：

1. ready 回复优先于补充采集；
2. 连续采集失败只丢弃本次请求，红点持续存在时允许新请求重新进入；
3. 删除调度器的重复发送 preflight，最终 UID/游标校验留在发送器；
4. 持久化 `imageCaptureAttempted`，同一任务重试不再次打开图片；
5. capture 与 supplement 的外层总超时统一为 75 秒；
6. 视频使用持久状态、有限单次下载、可信备用线路、60/180/600 秒后台重试、一次固定提示与恢复后继续分析；
7. 每次 UI 操作前校验状态文件，删除、替换或损坏才停止全局调度。

## 自动验证

- `swift test`
  - 446 tests executed
  - 7 tests skipped（需要显式启用的真机/环境测试）
  - 0 failures
  - 原基线 428；新增 18 项测试
- `zsh Scripts/build_app.sh --task-isolation-candidate`
  - release build 成功
- `zsh Scripts/verify_task_isolation_candidate.sh`
  - 候选版验证通过
- `zsh Tests/PackagingTests/auto_reply_resources_test.sh`
  - 资源复制与包内容验证通过
- `codesign --verify --deep --strict --verbose=2 outputs/拼多多全自动客服-任务隔离候选版.app`
  - valid on disk
  - satisfies its Designated Requirement

## 代码审计

- 新运行路径不存在 `.greatestFiniteMagnitude` 下载超时。
- 不存在 `suppressedOrdinaryCaptureUIDs` 永久 UID 屏蔽。
- `AutoReplyScheduler.deliverJob` 不调用 `preflight`；协议中的同名方法只保留兼容性。
- 视频持久状态文件不包含临时签名 URL 字段。
- 备用下载只接受 HTTPS 与既有 `PDDVideoHostPolicy` 可信域名，且保留原域名与 TLS 校验。
- 固定视频失败提示为：`亲，视频暂时无法加载，麻烦您先简单描述一下需要我们查看的问题。`

## 产物

- App：`outputs/拼多多全自动客服-任务隔离候选版.app`
- 可执行文件 SHA-256：`6029f1601151b3ec313418aa60e233bce86a1746c84ffe2c0c85f3047b923cd8`
- 构建时间：`2026-09-03 04:47:39`
- 旧候选版已由构建脚本移动至 `outputs/backups/`，未删除。
- 新版进程已重新启动；原有 `desiredRunning=false` 被保留，没有擅自开启自动发送。
