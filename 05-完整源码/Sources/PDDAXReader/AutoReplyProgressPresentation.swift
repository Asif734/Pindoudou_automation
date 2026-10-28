import Foundation

enum AutoReplyProgressPresentation {
    static func messageSourceLabel(_ message: PDDChatMessage) -> String {
        if message.kind == .image { return BilingualText.lines("AX图片", "AX image") }
        if message.kind == .video { return BilingualText.lines("AX视频", "AX video") }
        return message.id.hasPrefix("ocr-provisional-")
            ? BilingualText.lines("OCR临时", "Temporary OCR")
            : BilingualText.lines("AX", "AX")
    }

    static func progressValue(
        currentUIOwner: String?,
        jobs: [AutoReplyJob]
    ) -> Double? {
        if let owner = currentUIOwner {
            if owner.hasPrefix("send:") { return 0.90 }
            if owner.hasPrefix("preflight:") { return 0.80 }
            if owner.hasPrefix("capture:") { return 0.20 }
            if owner.hasPrefix("reconcile:") { return 0.95 }
            if owner.hasPrefix("transfer:") { return 0.97 }
            if owner.hasPrefix("discover") { return nil }
        }
        guard let active = jobs
            .filter({ ![.completed, .failed, .uncertain, .quarantined].contains($0.state) })
            .min(by: { priority($0.state) == priority($1.state)
                ? $0.sequence < $1.sequence
                : priority($0.state) < priority($1.state) }) else { return nil }
        switch active.state {
        case .discovered: return 0.10
        case .capturing: return 0.20
        case .queued: return 0.40
        case .generating: return 0.55
        case .ready: return 0.75
        case .sending: return 0.90
        case .completed: return 1.0
        case .failed, .uncertain, .quarantined: return nil
        }
    }

    static func headline(
        isRunning: Bool,
        currentUIOwner: String?,
        jobs: [AutoReplyJob],
        liveGenerationCount: Int,
        lastRuntimeIssue: String? = nil,
        latestVideoStatus: PDDVideoProgressStatus? = nil
    ) -> String {
        guard isRunning else { return BilingualText.lines("自动客服已停止", "Automatic customer service is stopped") }
        if let latestVideoStatus,
           [.waitingForAddress, .downloading, .downloaded].contains(latestVideoStatus.phase) {
            let stage = BilingualText.split(videoStageName(latestVideoStatus.phase))
            return BilingualText.lines(
                "\(latestVideoStatus.uid) · \(stage.chinese)",
                "\(latestVideoStatus.uid) · \(stage.english)"
            )
        }
        if let owner = currentUIOwner {
            return ownerHeadline(owner)
        }
        if let active = jobs
            .filter({ ![.completed, .failed, .uncertain, .quarantined].contains($0.state) })
            .min(by: { priority($0.state) == priority($1.state)
                ? $0.sequence < $1.sequence
                : priority($0.state) < priority($1.state) }) {
            let stage = BilingualText.split(stageName(active.state))
            if active.state == .generating {
                return BilingualText.lines(
                    "\(active.uid) · \(stage.chinese) · CLI \(liveGenerationCount)",
                    "\(active.uid) · \(stage.english) · CLI \(liveGenerationCount)"
                )
            }
            return BilingualText.lines(
                "\(active.uid) · \(stage.chinese)",
                "\(active.uid) · \(stage.english)"
            )
        }
        if liveGenerationCount > 0 { return BilingualText.lines("Codex 后台处理中 · CLI \(liveGenerationCount)", "Codex is processing in the background · CLI \(liveGenerationCount)") }
        if let lastRuntimeIssue, !lastRuntimeIssue.isEmpty {
            return BilingualText.lines("错误后继续扫描 · \(lastRuntimeIssue)", "Continuing to scan after an error · \(lastRuntimeIssue)")
        }
        return BilingualText.lines("等待截图红点；无红点不读取正文、不生成、不发送", "Waiting for a screenshot red dot; without one, no text is read, generated, or sent")
    }

    static func knowledgeSummary(_ diagnostic: KnowledgeRetrievalDiagnostic) -> String {
        let base: String
        switch diagnostic.mode {
        case .directLocal:
            base = BilingualText.lines("Codex 直接读取本地知识库", "Codex reads the local knowledge folder directly")
        case .folderHybrid:
            base = BilingualText.lines("主要目录混合检索 · \(diagnostic.selectedDocuments.count)份资料 · \(diagnostic.durationMilliseconds)ms", "Primary-folder hybrid search · \(diagnostic.selectedDocuments.count) documents · \(diagnostic.durationMilliseconds)ms")
        case .semanticOnly:
            base = BilingualText.lines("第二次独立纯语义检索 · \(diagnostic.selectedDocuments.count)份资料 · \(diagnostic.durationMilliseconds)ms", "Standalone semantic-only retry · \(diagnostic.selectedDocuments.count) documents · \(diagnostic.durationMilliseconds)ms")
        case .v2Top12:
            base = BilingualText.lines("V2 Top-12 · \(diagnostic.selectedDocuments.count)份资料 · \(diagnostic.durationMilliseconds)ms", "V2 Top-12 · \(diagnostic.selectedDocuments.count) documents · \(diagnostic.durationMilliseconds)ms")
        case .fullZipFallback:
            base = BilingualText.lines("完整 ZIP 回退 · \(diagnostic.durationMilliseconds)ms", "Full-ZIP fallback · \(diagnostic.durationMilliseconds)ms")
        case .unavailable:
            base = BilingualText.lines("V2 暂不可用（无完整 ZIP 回退）· \(diagnostic.durationMilliseconds)ms", "V2 unavailable (no full-ZIP fallback) · \(diagnostic.durationMilliseconds)ms")
        }
        guard let error = diagnostic.error, !error.isEmpty else { return base }
        let split = BilingualText.split(base)
        return BilingualText.lines("\(split.chinese) · \(error)", "\(split.english) · \(error)")
    }

    static func stageName(_ state: AutoReplyJobState) -> String {
        switch state {
        case .discovered: return BilingualText.lines("已发现客户消息", "Customer message discovered")
        case .capturing: return BilingualText.lines("AX 正在读取；失效时才启用尾部 OCR", "Reading with AX; tail OCR is used only if AX fails")
        case .queued: return BilingualText.lines("等待 Codex 空位", "Waiting for Codex capacity")
        case .generating: return BilingualText.lines("Codex 正在生成回复", "Codex is generating a reply")
        case .ready: return BilingualText.lines("回复就绪，等待发送", "Reply ready; waiting to send")
        case .sending: return BilingualText.lines("正在发送并回读确认", "Sending and reading back for confirmation")
        case .completed: return BilingualText.lines("已完成", "Completed")
        case .failed: return BilingualText.lines("失败", "Failed")
        case .uncertain: return BilingualText.lines("发送结果待核对", "Send result requires verification")
        case .quarantined: return BilingualText.lines("当前 revision 已停放", "Current revision parked")
        }
    }

    static func jobStageName(_ job: AutoReplyJob) -> String {
        if job.state == .completed, job.deliveryOutcome == .uncertain {
            return BilingualText.lines("已完成 · 发送结果不确定（不会自动重发）", "Completed · send result uncertain (will not resend automatically)")
        }
        if job.state == .quarantined {
            return BilingualText.lines("revision \(job.customerRevision) 已停放（第 \(job.stageAttempt) 次失败，不阻塞其他用户）", "Revision \(job.customerRevision) parked (failure \(job.stageAttempt); other users are not blocked)")
        }
        if job.stageAttempt == 1, job.state == .ready {
            let stage = BilingualText.split(stageName(job.state))
            return BilingualText.lines("\(stage.chinese) · 第一次失败后已排到队尾", "\(stage.english) · moved to the back after the first failure")
        }
        return stageName(job.state)
    }

    private static func ownerHeadline(_ owner: String) -> String {
        if owner.hasPrefix("discover") { return BilingualText.lines("AX 定位会话 · 截图检测红点", "AX conversation location · screenshot red-dot detection") }
        let parts = owner.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return owner }
        let stage: String
        switch parts[0] {
        case "capture": stage = BilingualText.lines("AX 正在读取；失效时才启用尾部 OCR", "Reading with AX; tail OCR is used only if AX fails")
        case "preflight": stage = BilingualText.lines("发送前 AX 复查", "Pre-send AX check")
        case "send": stage = BilingualText.lines("正在发送并回读确认", "Sending and reading back for confirmation")
        case "reconcile": stage = BilingualText.lines("只读核对发送结果", "Read-only send-result verification")
        case "image": stage = BilingualText.lines("正在从 AX 图片预览下载客户原图", "Downloading the original customer image from AX preview")
        case "transfer": stage = BilingualText.lines("正在无原因直接转人工", "Transferring directly to a human without a reason")
        default: stage = BilingualText.lines(parts[0], parts[0])
        }
        let split = BilingualText.split(stage)
        return BilingualText.lines("\(parts[1]) · \(split.chinese)", "\(parts[1]) · \(split.english)")
    }

    private static func priority(_ state: AutoReplyJobState) -> Int {
        switch state {
        case .sending: return 0
        case .ready: return 1
        case .capturing: return 2
        case .discovered: return 3
        case .generating: return 4
        case .queued: return 5
        case .completed, .failed, .uncertain, .quarantined: return 6
        }
    }

    static func videoStageName(_ phase: PDDVideoTransferPhase) -> String {
        switch phase {
        case .armed: return BilingualText.lines("已识别客户视频", "Customer video detected")
        case .waitingForAddress: return BilingualText.lines("视频已打开，后台等待地址", "Video opened; waiting for its address in the background")
        case .downloading: return BilingualText.lines("视频后台下载中", "Downloading video in the background")
        case .downloaded: return BilingualText.lines("视频下载完成", "Video download completed")
        case .preparingEvidence: return BilingualText.lines("视频正在抽帧、导出音轨和转写", "Extracting frames, exporting audio, and transcribing the video")
        case .readyForGeneration: return BilingualText.lines("视频证据已准备，等待 Codex", "Video evidence ready; waiting for Codex")
        case .admitted: return BilingualText.lines("视频已提交 Codex", "Video submitted to Codex")
        case .completed: return BilingualText.lines("视频回复已完成", "Video reply completed")
        case .duplicate: return BilingualText.lines("重复视频已跳过", "Duplicate video skipped")
        case .failed: return BilingualText.lines("视频处理失败，继续客服流程", "Video processing failed; customer-service flow continues")
        case .waitingForRetry: return BilingualText.lines("视频下载等待后台重试", "Video download is waiting for a background retry")
        case .fallbackRequired: return BilingualText.lines("视频暂不可用，已进入回复队列", "Video is temporarily unavailable and has entered the reply queue")
        }
    }
}
