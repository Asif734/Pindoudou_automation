# PDD 千牛内核对齐验证记录

日期：2026-09-01（Asia/Dhaka）

## 最终自动测试

- `swift test`
  - 退出码：0
  - 结果：268 tests executed，3 skipped，0 failures
  - 总测试时间：5.792 s（suite wall 5.808 s）
- `PYTHONPATH="$PWD/Resources/V2Knowledge/site-packages:$PWD/Resources/V2Knowledge" /Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12 -m unittest Tests/V2KnowledgePythonTests/test_retrieve_top12.py`
  - 退出码：0
  - 结果：2 tests，OK
- `zsh Tests/PackagingTests/auto_reply_resources_test.sh`
  - 退出码：0
- `./scripts/build_app.sh --task-isolation-candidate`
  - 退出码：0
  - Release product 构建、资源复制、签名成功
- `./scripts/verify_task_isolation_candidate.sh`
  - 退出码：0
  - 输出：候选版验证通过
- `codesign --verify --deep --strict --verbose=2 outputs/拼多多全自动客服-任务隔离候选版.app`
  - 退出码：0
  - valid on disk，satisfies Designated Requirement

## 已验证关键行为

- schema 1/2/3 可备份迁移至 schema 4；revision 使用 64 位小写 SHA-256。
- checkpoint 外部修改拒绝静默覆盖；answered cursor 禁止倒退；事件与终态 UI 历史有界。
- 所有 `try? persist()` 已从调度器移除；发送关键证据写失败暂停真实发送，扫描/生成保持运行。
- generation-first；三次连续发送强制 discovery；公平计数持久化。
- A 生成时追加 B/C 不取消 A；A 先发送，B/C 由持久尾部补采进入下一批。
- 普通 Codex 失败指数重试 20 次；429/资源分配失败触发 60 秒 backpressure；单 UID 不停止全局。
- 图片按内容 SHA 冻结；删除原下载文件后仍可用；纯图片下载失败不再终止任务。
- Prompt 从 bundle markdown 运行时加载；真实图片允许传入；无桌面 ZIP 路径；risk 不作为发送门禁。
- 候选版使用独立 `CODEX_HOME`，仅同步 ChatGPT 登录材料，不复制宿主 skills/rules/config。
- UID session 持久化历史 prefix、图片 SHA、prompt/knowledge hash、轮次、字节数和污染状态；有效 resume 只提交增量。
- V2 Python worker 使用 UUID JSONL 常驻协议；5 秒硬超时后重启；失败时返回 unavailable，不向 Codex 暴露完整 ZIP。
- 显式运行意图持久化；权限、磁盘、锁暂不可用时按指数间隔恢复，不把警告变成全局停止。

## 现场 UI 检查

- 新候选版成功读取 PDD 当前 `GZC-000001` 会话。
- PDD AX 子树短暂缺失时，日志连续记录恢复事件且 scheduler 未全局停机；随后 AX tree 和 OCR 均恢复。
- UI 曾显示“运行中 · 允许 AX 发送”、干运行关闭、队列 0、CLI 0、可用内存约 48 GB。
- 用户随后手动停止；最终保持用户选择的停止状态，不将其归类为程序自动停机。

## 文档完整性

- `docs/PDD全自动客服-代码级架构与调试交接手册.md`
  - 1332 行
  - 55660 bytes
  - 54 个 Markdown fence 标记，数量平衡
  - schema/retry/image/prompt/Codex/V2/preflight 旧描述已更新

说明：当前工作目录不是 Git repository，因此没有 commit/branch 证据，也未初始化 Git。
