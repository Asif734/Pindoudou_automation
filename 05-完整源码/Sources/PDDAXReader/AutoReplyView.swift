import SwiftUI

struct AutoReplyView: View {
    @StateObject private var model: AutoReplyViewModel
    @StateObject private var progressPanel: AutoReplyProgressPanelController

    @MainActor
    init() {
        let model = AutoReplyViewModel()
        _model = StateObject(wrappedValue: model)
        _progressPanel = StateObject(wrappedValue: AutoReplyProgressPanelController(model: model))
    }

    @MainActor
    init(model: AutoReplyViewModel) {
        _model = StateObject(wrappedValue: model)
        _progressPanel = StateObject(wrappedValue: AutoReplyProgressPanelController(model: model))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    model.isRunning ? model.stop() : model.start()
                } label: {
                    toolbarLabel(model.isRunning ? "停止" : "开始", model.isRunning ? "Stop" : "Start")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isRunning && !model.canStart)

                Button { progressPanel.toggleCollapsed() } label: {
                    toolbarLabel("收起／展开进度浮窗", "Collapse / expand progress")
                }

                Button { model.openRecordsDirectory() } label: {
                    toolbarLabel("打开本地记录", "Open local records")
                }

                Button { model.openRequiredPermissionSettings() } label: {
                    toolbarLabel("打开权限设置", "Open permission settings")
                }

                Toggle(BilingualText.lines("干运行（不发送）", "Dry run (do not send)"), isOn: Binding(
                    get: { model.isDryRun },
                    set: { model.setDryRun($0) }
                ))
                .disabled(model.isRunning)
                .fixedSize()

                Spacer(minLength: 0)
            }

                Text(BilingualText.lines(
                    "范围：截图红点触发 · AX 权威读取正文 · AX 失效才用尾部 OCR · AX 点击和发送",
                    "Scope: screenshot red-dot trigger · AX authoritative text · tail OCR only if AX fails · AX click and send"
                ))
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)

            Text(model.status)
                .font(.headline)
            Text(BilingualText.lines(
                "当前 UI owner：\(model.currentUIOwner ?? "空闲")",
                "Current UI owner: \(model.currentUIOwner ?? "Idle")"
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let video = model.latestVideoStatus {
                let stage = BilingualText.split(AutoReplyProgressPresentation.videoStageName(video.phase))
                Text(BilingualText.lines(
                    "最近视频记录：\(video.messageID) · \(stage.chinese)",
                    "Latest video: \(video.messageID) · \(stage.english)"
                ))
                    .font(.caption.monospaced())
                    .foregroundStyle(.blue)
            }

            GroupBox(BilingualText.lines("运行环境与健康状态", "Environment and health")) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button {
                            Task { await model.runCompatibilityCheck() }
                        } label: {
                            toolbarLabel("兼容性检查", "Compatibility check")
                        }
                        if model.compatibilityReport != nil {
                            Button { model.saveCompatibilityReport() } label: {
                                toolbarLabel("导出脱敏报告", "Export redacted report")
                            }
                        }
                        Button { Task { await model.checkUnreadOnly() } } label: {
                            toolbarLabel("只检查未读", "Check unread only")
                        }
                        .disabled(model.isRunning)
                    }
                    if let report = model.compatibilityReport {
                        Text(report.summary)
                            .foregroundStyle(report.overallStatus == .fail ? .red : .orange)
                        ForEach(Array(report.items.enumerated()), id: \.offset) { _, item in
                            let detail = BilingualText.split(item.detail)
                            Text(BilingualText.lines(
                                "\(item.status.chineseLabel) · \(item.kind.chineseLabel)：\(detail.chinese)",
                                "\(item.status.englishLabel) · \(item.kind.englishLabel): \(detail.english)"
                            ))
                        }
                    }
                    Text(BilingualText.lines("Codex：\(model.codexExecutablePath ?? "不可用")", "Codex: \(model.codexExecutablePath ?? "Unavailable")"))
                    Text(BilingualText.lines("模型：gpt-5.6-sol · medium · 每位用户独立 session", "Model: gpt-5.6-sol · medium · separate session for each user"))
                    if let diagnostic = model.latestKnowledgeDiagnostic {
                        let summary = BilingualText.split(AutoReplyProgressPresentation.knowledgeSummary(diagnostic))
                        Text(BilingualText.lines("知识：\(summary.chinese)", "Knowledge: \(summary.english)"))
                        if let sha = diagnostic.knowledgeBaseSHA256 {
                            Text(BilingualText.lines("知识库 SHA-256：\(sha)", "Knowledge-base SHA-256: \(sha)"))
                        }
                    } else {
                        Text(BilingualText.lines("知识：Codex 直接只读阅读本地数据库", "Knowledge: Codex reads the local database directly"))
                    }
                    if let snapshot = model.latestResourceSnapshot {
                        let memory = ByteCountFormatter.string(fromByteCount: Int64(clamping: snapshot.availableMemoryBytes), countStyle: .memory)
                        Text(BilingualText.lines("资源：可用内存 \(memory) · 队列 \(snapshot.queueDepth) · CLI \(snapshot.activeCLI)", "Resources: available memory \(memory) · queue \(snapshot.queueDepth) · CLI \(snapshot.activeCLI)"))
                    }
                    if let issue = model.lastRuntimeIssue {
                        Text(BilingualText.lines("最近警告（会继续运行）：\(issue)", "Latest warning (operation continues): \(issue)")).foregroundStyle(.orange)
                    }
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(BilingualText.lines("最近一次 AX／尾部 OCR 解析", "Latest AX / tail-OCR parse")) {
                if let capture = model.latestCapture {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(BilingualText.lines("用户：\(capture.uid) · 消息 \(capture.fullHistory.count) 条 · 客户游标 \(capture.customerCursor.count)", "User: \(capture.uid) · messages \(capture.fullHistory.count) · customer cursor \(capture.customerCursor.count)"))
                            .font(.caption.monospaced())
                        if let diagnostic = capture.ocrDiagnostic {
                            Text(BilingualText.lines("诊断：\(diagnostic)", "Diagnostic: \(diagnostic)"))
                                .font(.caption.monospaced())
                                .foregroundStyle(diagnostic.contains("失败") || diagnostic.contains("需要") ? .orange : .secondary)
                        }
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(capture.fullHistory.suffix(30)), id: \.id) { message in
                                    let chineseSender = message.sender == .customer ? "客户" : "客服"
                                    let englishSender = message.sender == .customer ? "Customer" : "Service"
                                    let time = message.displayTime.map { "[\($0)] " } ?? ""
                                    let source = AutoReplyProgressPresentation.messageSourceLabel(message)
                                    let splitSource = BilingualText.split(source)
                                    Text(BilingualText.lines(
                                        "[\(splitSource.chinese)] \(time)\(chineseSender)：\(message.content)",
                                        "[\(splitSource.english)] \(time)\(englishSender): \(message.content)"
                                    ))
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 150, maxHeight: 260)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(BilingualText.lines("等待红点触发；无红点不会读取正文、生成或发送…", "Waiting for a red-dot trigger; without one, no text is read, generated, or sent…"))
                        .foregroundStyle(.secondary)
                }
            }

            List(model.jobs) { job in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(job.uid).font(.headline)
                        Text(AutoReplyProgressPresentation.jobStageName(job)).font(.caption).foregroundStyle(
                            job.state == .uncertain ? .red : .secondary
                        )
                        Spacer()
                        Text("#\(job.sequence)").font(.caption.monospacedDigit())
                    }
                    Text(BilingualText.lines("客户游标：\(job.capture.customerCursor.count) · \(job.capture.customerCursor.digest.prefix(12))", "Customer cursor: \(job.capture.customerCursor.count) · \(job.capture.customerCursor.digest.prefix(12))"))
                        .font(.caption.monospaced())
                    if let reply = job.reply { Text(reply).lineLimit(3) }
                    if let error = job.lastError { Text(BilingualText.lines("错误：\(error)", "Error: \(error)")).foregroundStyle(.red).font(.caption) }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .frame(minWidth: 1_100, minHeight: 720)
        .onAppear {
            model.viewAppeared()
            progressPanel.show()
            progressPanel.updateInteraction()
        }
        .onChange(of: model.isRunning) { _, _ in progressPanel.updateInteraction() }
        .onDisappear {
            model.viewDisappeared()
        }
    }

    private func toolbarLabel(_ chinese: String, _ english: String) -> some View {
        VStack(spacing: 2) {
            Text(chinese)
            Text(english).font(.caption)
        }
        .fixedSize(horizontal: true, vertical: true)
        .padding(.vertical, 3)
    }
}
