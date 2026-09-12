# 2026-08-31 候选版自动化验证报告

## 自动化测试

- 命令：`swift test`
- 结果：242 tests executed，3 skipped，0 failures。
- 用时：3.584 秒测试时间，3.599 秒总时间。
- 覆盖：调度、Lease、外层超时、持久化迁移、发送崩溃恢复、AX/OCR、图片选择、预览 URL 协调、原图验证、Codex `--image`、进度 UI、打包身份。

## 故障压力

- 命令：`python3 Tests/FaultInjection/pdd_task_isolation_soak.py --duration 120 --seed 8312026`
- 结果：120.2 秒，150 轮，全部通过。
- 固定 seed：8312026。
- 不变量：最大有效 UI Lease=1；Lease 撤销后 UI 动作=0；重复发送调用=0；健康 UID 可继续；更新 revision 可继续。

## 构建与签名

- 命令：`zsh scripts/build_app.sh --task-isolation-candidate`
- 产物：`outputs/拼多多全自动客服-任务隔离候选版.app`
- Bundle ID：`com.scy.pdd-auto-reply.task-isolation-candidate`
- 可执行文件：`PDDTaskIsolationCandidate`
- `zsh scripts/verify_task_isolation_candidate.sh`：通过。
- `zsh Tests/PackagingTests/auto_reply_resources_test.sh`：通过。
- 现有读取器、单次解析器和原自动客服没有被构建脚本删除；上一候选版本会移动到 `outputs/backups/<时间戳>/`。

## 真实 UI 状态

候选版真实启动后确认默认停止，干运行开关可用。本轮尚未取得新 Bundle ID 的 macOS 辅助功能权限，因此没有把真实 PDD 文字、真实图片下载或真实发送标记为已验证。详情见 `2026-08-31-live-pdd-validation.md`。

## 结论边界

自动化实现、压力测试、构建和签名验证通过。真实 PDD 端到端验收仍需先授予候选版辅助功能和屏幕录制权限，然后继续执行设计计划 Task 13。
