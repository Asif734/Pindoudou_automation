import AppKit
import SwiftUI

@MainActor
final class AutoReplyFloatingProgressPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "实时进度 / Live progress"
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 480, height: 280)
        isMovable = true
        isMovableByWindowBackground = true
        ignoresMouseEvents = false
        setFrameAutosaveName("PDDAutoReplyProgressFloat")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setAutomationActive(_ active: Bool) {
        // Keep the progress panel draggable and closable even while automation
        // runs. It never performs AX actions itself, so interaction is safe.
        ignoresMouseEvents = false
    }
}

@MainActor
final class AutoReplyProgressLayout: ObservableObject {
    @Published var collapsed = false
}

@MainActor
final class AutoReplyProgressPanelController: NSObject, ObservableObject, NSWindowDelegate {
    private let model: AutoReplyViewModel
    private let layout = AutoReplyProgressLayout()
    private var panel: AutoReplyFloatingProgressPanel?

    init(model: AutoReplyViewModel) { self.model = model }

    func show() {
        if panel == nil {
            let window = AutoReplyFloatingProgressPanel()
            window.delegate = self
            let hosting = NSHostingView(rootView: AutoReplyProgressPanelView(model: model, layout: layout))
            hosting.sizingOptions = []
            window.contentView = hosting
            if !window.setFrameUsingName("PDDAutoReplyProgressFloat"),
               let frame = NSScreen.main?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: frame.maxX - 500, y: frame.maxY - 650))
            }
            var frame = window.frame
            frame.size.width = max(frame.size.width, window.minSize.width)
            frame.size.height = max(frame.size.height, window.minSize.height)
            window.setFrame(frame, display: false)
            panel = window
        }
        updateInteraction()
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    func toggleCollapsed() {
        guard panel != nil else { show(); return }
        layout.collapsed.toggle()
        guard let panel else { return }
        var frame = panel.frame
        let height: CGFloat = layout.collapsed ? 300 : 620
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: false)
        panel.orderFrontRegardless()
    }

    func updateInteraction() { panel?.setAutomationActive(model.isRunning) }

    func windowWillClose(_ notification: Notification) { panel = nil }
}

private struct AutoReplyProgressPanelView: View {
    @ObservedObject var model: AutoReplyViewModel
    @ObservedObject var layout: AutoReplyProgressLayout
    @State private var phaseStartedAt = Date()
    @State private var previousHeadline = ""

    private var headline: String {
        AutoReplyProgressPresentation.headline(
            isRunning: model.isRunning,
            currentUIOwner: model.currentUIOwner,
            jobs: model.jobs,
            liveGenerationCount: model.liveGenerationCount,
            lastRuntimeIssue: model.lastRuntimeIssue,
            latestVideoStatus: model.latestVideoStatus
        )
    }

    private var progress: Double? {
        AutoReplyProgressPresentation.progressValue(
            currentUIOwner: model.currentUIOwner,
            jobs: model.jobs
        )
    }

    private var displayedJobs: [AutoReplyJob] {
        Array(model.jobs.sorted { $0.sequence > $1.sequence }.prefix(12))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle()
                        .fill(model.isRunning ? Color.blue : Color.gray)
                        .frame(width: 8, height: 8)
                    BilingualProgressText(BilingualText.lines("全链路进度", "End-to-end progress")).font(.headline)
                    Spacer()
                    BilingualProgressText(BilingualText.lines("Codex 任务 \(model.liveGenerationCount)", "Codex tasks \(model.liveGenerationCount)"))
                        .font(.caption.monospacedDigit())
                }

                BilingualProgressText(headline).font(.system(size: 13, weight: .medium))
                if let progress {
                    ProgressView(value: progress).tint(.blue)
                } else if model.isRunning {
                    ProgressView().controlSize(.small)
                }
                BilingualProgressText(BilingualText.lines("本阶段 \(elapsed(context.date)) 秒 · 可拖动、缩放和关闭", "Current stage: \(elapsed(context.date)) seconds · draggable, resizable, and closable"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)

                if !layout.collapsed {
                    Divider()
                    if let wake = model.lastAXWakeAt {
                        let time = wake.formatted(date: .omitted, time: .standard)
                        BilingualProgressText(BilingualText.lines("最近 AX 通知：\(time)", "Latest AX notification: \(time)"))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if let video = model.latestVideoStatus {
                        let stage = BilingualText.split(AutoReplyProgressPresentation.videoStageName(video.phase))
                        BilingualProgressText(BilingualText.lines(
                            "最近视频记录 \(video.messageID) · \(stage.chinese)",
                            "Latest video \(video.messageID) · \(stage.english)"
                        ))
                            .font(.caption.monospaced()).foregroundStyle(.blue)
                    }
                    if let diagnostic = model.latestKnowledgeDiagnostic {
                        BilingualProgressText(AutoReplyProgressPresentation.knowledgeSummary(diagnostic))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if let snapshot = model.latestResourceSnapshot {
                        let memory = byteCount(snapshot.availableMemoryBytes)
                        BilingualProgressText(BilingualText.lines("可用内存 \(memory) · 队列 \(snapshot.queueDepth) · CLI \(snapshot.activeCLI)", "Available memory \(memory) · queue \(snapshot.queueDepth) · CLI \(snapshot.activeCLI)"))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Group {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(displayedJobs) { job in
                                AutoReplyProgressJobCard(job: job)
                            }
                            if displayedJobs.isEmpty {
                                BilingualProgressText(model.isRunning
                                    ? BilingualText.lines("等待截图红点或 OCR 发现客户消息。", "Waiting for a screenshot red dot or OCR to find a customer message.")
                                    : BilingualText.lines("当前没有任务。", "There are currently no tasks."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    BilingualProgressText(BilingualText.lines("只读显示 · 不会为了进度条额外扫描拼多多", "Read-only display · no extra Pinduoduo scans are performed for this progress view"))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            previousHeadline = headline
            phaseStartedAt = Date()
        }
        .onChange(of: headline) { _, newValue in
            guard newValue != previousHeadline else { return }
            previousHeadline = newValue
            phaseStartedAt = Date()
        }
    }

    private func elapsed(_ now: Date) -> String {
        String(format: "%.1f", max(0, now.timeIntervalSince(phaseStartedAt)))
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
}

private struct BilingualProgressText: View {
    let value: String

    init(_ value: String) { self.value = value }

    var body: some View {
        let parts = BilingualText.split(value)
        VStack(alignment: .leading, spacing: 2) {
            Text(parts.chinese)
            if parts.english != parts.chinese {
                Text(parts.english)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AutoReplyProgressJobCard: View {
    let job: AutoReplyJob

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(job.uid).font(.subheadline.bold())
                    Spacer()
                    Text("#\(job.sequence)").font(.caption.monospacedDigit())
                }
                BilingualProgressText(AutoReplyProgressPresentation.jobStageName(job))
                    .font(.caption).foregroundStyle(color)
                if let error = job.lastError {
                    BilingualProgressText(BilingualText.lines("错误：\(error)", "Error: \(error)")).font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var color: Color {
        switch job.state {
        case .completed: return .green
        case .failed, .uncertain: return .red
        case .quarantined: return .orange
        default: return .blue
        }
    }
}
