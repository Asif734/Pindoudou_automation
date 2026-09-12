import AppKit
import Foundation
import WebKit

enum PDDOCRError: LocalizedError {
    case screenRecordingPermission
    case windowNotFound
    case capture(String)
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermission: return "需要屏幕录制权限才能执行 OCR；AX 自动回复会继续运行"
        case .windowNotFound: return "没有找到当前拼多多商家工作台窗口"
        case .capture(let detail): return "OCR 截图失败：\(detail)"
        case .engine(let detail): return "OCR 引擎失败：\(detail)"
        }
    }
}

@MainActor
protocol PDDOCRRecognizing: AnyObject {
    func recognize(_ image: CGImage) async throws -> [PDDOCRLine]
}

private struct PDDWebOCRPayload: Decodable { let lines: [PDDWebOCRLine] }
private struct PDDWebOCRLine: Decodable {
    let text: String
    let confidence: Double
    let box: CGRect

    private enum CodingKeys: String, CodingKey { case text, confidence, box }
    private struct Box: Decodable { let x: CGFloat; let y: CGFloat; let width: CGFloat; let height: CGFloat }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        confidence = try container.decode(Double.self, forKey: .confidence)
        let value = try container.decode(Box.self, forKey: .box)
        box = CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }
}

@MainActor
final class PDDPaddleOCREngine: NSObject, PDDOCRRecognizing, WKNavigationDelegate {
    static let readinessJavaScript = """
        return await new Promise((resolve, reject) => {
          const deadline = Date.now() + 30000;
          const check = () => {
            if (window.qianniuOCR) return resolve(true);
            if (window.__qianniuBootState?.error) {
              return reject(new Error(window.__qianniuBootState.error));
            }
            if (Date.now() >= deadline) {
              const scripts = Array.from(document.scripts).map((script) => ({
                src: script.src,
                type: script.type,
                readyState: script.readyState || null
              }));
              return reject(new Error("等待 OCR 脚本加载超时 " + JSON.stringify({
                baseURI: document.baseURI,
                readyState: document.readyState,
                scripts
              })));
            }
            setTimeout(check, 50);
          };
          check();
        });
        """

    private let server: PDDLocalResourceServer
    private let webView: WKWebView
    private var readyTask: Task<Void, Error>?
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    override init() {
        server = PDDLocalResourceServer(root: PDDOCRResourceRoot.resolve())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func recognize(_ image: CGImage) async throws -> [PDDOCRLine] {
        try await ensureReady()
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw PDDOCRError.engine("截图无法编码为 PNG")
        }
        let dataURL = "data:image/png;base64,\(data.base64EncodedString())"
        do {
            let value = try await webView.callAsyncJavaScript(
                "return JSON.stringify(await window.qianniuOCR.recognize(imageDataURL));",
                arguments: ["imageDataURL": dataURL], in: nil, contentWorld: .page
            )
            guard let json = value as? String else { throw PDDOCRError.engine("返回值不是 JSON") }
            return try JSONDecoder().decode(PDDWebOCRPayload.self, from: Data(json.utf8)).lines.map {
                PDDOCRLine(text: $0.text, box: $0.box, confidence: $0.confidence)
            }
        } catch let error as PDDOCRError { throw error }
        catch { throw PDDOCRError.engine(Self.describe(error)) }
    }

    func prewarm() async throws {
        try await ensureReady()
    }

    private func ensureReady() async throws {
        if let readyTask { return try await readyTask.value }
        let task = Task { @MainActor [server, webView] in
            let url = try await server.start()
            try await withCheckedThrowingContinuation { continuation in
                navigationContinuation = continuation
                webView.load(URLRequest(url: url))
            }
            _ = try await webView.callAsyncJavaScript(
                Self.readinessJavaScript,
                arguments: [:], in: nil, contentWorld: .page
            )
            _ = try await webView.callAsyncJavaScript(
                "return JSON.stringify(await window.qianniuOCR.ready());",
                arguments: [:], in: nil, contentWorld: .page
            )
        }
        readyTask = task
        do { try await task.value }
        catch { readyTask = nil; throw PDDOCRError.engine(Self.describe(error)) }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(String(reflecting: error)) [\(nsError.domain) \(nsError.code)] \(nsError.userInfo)"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationContinuation?.resume(); navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error); navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationContinuation?.resume(throwing: error); navigationContinuation = nil
    }
}
