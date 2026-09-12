import Foundation

enum CodexFailureDisposition: Equatable, Sendable {
    case transferImmediately(String)
    case retryOnceThenTransfer(String)
    case ordinaryRetry
    case cancelled
}

enum CodexFailureClassifier {
    static func classify(_ error: Error) -> CodexFailureDisposition {
        if error is CancellationError { return .cancelled }

        if let error = error as? AutoReplyCodexGeneratorError {
            switch error {
            case .chatGPTLoginRequired:
                return .transferImmediately("Codex 登录失效或登录方式不可用")
            case .commandFailed(_, let stderr):
                return classifyCommandFailure(stderr)
            case .missingCompletion:
                return .retryOnceThenTransfer("Codex 未返回完成事件")
            case .missingThreadID:
                return .retryOnceThenTransfer("Codex 会话 ID 失效")
            case .invalidReply(let reason) where containsAny(reason.lowercased(), [
                "content safety", "safety refusal", "policy violation"
            ]):
                return .transferImmediately("Codex 内容安全拒绝")
            case .invalidReply:
                return .retryOnceThenTransfer("Codex 返回内容为空或格式无效")
            case .freshSessionRetryFailed:
                return .transferImmediately("Codex 新会话或新进程重试仍失败")
            case .missingBatch, .invalidImageAttachment:
                return .ordinaryRetry
            }
        }

        if let error = error as? CodexProcessError {
            switch error {
            case .timeout:
                return .retryOnceThenTransfer("Codex CLI 超时")
            case .executableMissing:
                return .retryOnceThenTransfer("Codex CLI 无法启动")
            }
        }

        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .networkConnectionLost, .notConnectedToInternet,
                 .secureConnectionFailed, .cannotLoadFromNetwork:
                return .retryOnceThenTransfer("Codex 网络连接失败")
            default:
                return .ordinaryRetry
            }
        }

        let text = error.localizedDescription.lowercased()
        if containsAny(text, [
            "thread id", "session identity", "wrong session", "resume mismatch",
            "turn.failed", "codex cli"
        ]) {
            return .retryOnceThenTransfer("Codex 会话或进程异常")
        }
        return .ordinaryRetry
    }

    private static func classifyCommandFailure(_ stderr: String) -> CodexFailureDisposition {
        let text = stderr.lowercased()
        if containsHTTPStatus([401, 403, 429, 400, 413, 422], in: text)
            || containsAny(text, [
                "unauthorized", "forbidden", "insufficient_quota", "quota exceeded",
                "usage limit", "billing limit", "context_length_exceeded",
                "context window", "maximum context", "request too large",
                "invalid_request", "unsupported model", "model is not supported",
                "content safety", "safety refusal", "policy violation"
            ]) {
            return .transferImmediately("Codex 请求已确定不可继续")
        }
        if containsHTTPStatus([404, 408, 500, 502, 503, 504], in: text)
            || containsAny(text, [
                "model not found", "rate connection", "connection reset", "connection refused",
                "timed out", "timeout", "dns", "tls", "network is unreachable"
            ]) {
            return .retryOnceThenTransfer("Codex 服务、模型或网络暂时不可用")
        }
        // commandFailed 已经是 Codex CLI 的确定异常退出；重新启动一个进程仅尝试一次。
        return .retryOnceThenTransfer("Codex CLI 异常退出")
    }

    private static func containsHTTPStatus(_ codes: [Int], in text: String) -> Bool {
        codes.contains { code in
            text.range(
                of: #"(?<![0-9])"# + String(code) + #"(?![0-9])"#,
                options: .regularExpression
            ) != nil
        }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains(where: text.contains)
    }
}
