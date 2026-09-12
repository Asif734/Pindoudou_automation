# 拼多多视频自动回复验证记录

日期：2026-09-02

## 自动测试与构建

- `swift test`：378 项执行，5 项可选测试跳过，0 失败。
- `swift build -c release --product PDDAXReader`：退出码 0。
- `zsh scripts/build_app.sh --task-isolation-candidate`：构建、资源复制和代码签名成功。
- 候选 App：`outputs/拼多多全自动客服-任务隔离候选版.app`。

## 真实媒体验证

- 使用本机先前由拼多多 CEF 临时地址下载的真实 MP4。
- `PDDVideoFileInspector` 成功读取 8.2 秒、720×1280、H.264/AAC 视频。
- `PDDVideoFrameExtractor` 成功生成 6 张 JPEG 关键帧；每张均通过 JPEG 文件头检查。
- 真实 Codex CLI 视频冒烟测试耗时 7.928 秒，收到 `turn.completed`。
- Codex 生成的测试回复：`您好，请问视频里具体是什么问题呢？`
- CLI 参数测试确认只提交 JPEG 关键帧，不把 MP4 作为 `-i` 附件。

## 实时拼多多状态

- 拼多多商家版当前存在一个待回复红点会话 `S***`。
- 当前聊天尾部由 AX 暴露出 `00:08` 和视频缩略图，符合已实现的宽松视频选择规则。
- 候选 App 已打开；干运行关闭，保存的运行意图为停止。

## 尚待人工动作

点击候选 App 的“开始”会开启真实自动发送。代码、下载、关键帧和 Codex 生成已验证；真实对客发送需要在动作发生前确认。
