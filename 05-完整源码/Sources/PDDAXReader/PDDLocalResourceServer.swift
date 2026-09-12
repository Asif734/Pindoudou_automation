import Foundation
import Network

enum PDDOCRStaticResourceError: Error {
    case invalidPath
}

struct PDDOCRStaticResourceResolver {
    let root: URL

    func fileURL(for requestTarget: String) throws -> URL {
        let path = requestTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        guard let decoded = path.removingPercentEncoding else { throw PDDOCRStaticResourceError.invalidPath }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(".."), !components.contains(".") else {
            throw PDDOCRStaticResourceError.invalidPath
        }
        let relative = components.isEmpty ? "index.html" : components.joined(separator: "/")
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw PDDOCRStaticResourceError.invalidPath
        }
        return candidate
    }

    static func mimeType(forExtension value: String) -> String {
        switch value.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "wasm": return "application/wasm"
        case "tar": return "application/x-tar"
        default: return "application/octet-stream"
        }
    }
}

enum PDDOCRResourceRoot {
    static func installed(executablePath: String = CommandLine.arguments[0]) -> URL {
        URL(fileURLWithPath: executablePath).standardizedFileURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/WebOCR", isDirectory: true)
    }

    static func development(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent("Resources/WebOCR", isDirectory: true)
    }

    static func resolve(fileManager: FileManager = .default) -> URL {
        let packaged = installed()
        if fileManager.fileExists(atPath: packaged.appendingPathComponent("index.html").path) {
            return packaged
        }
        return development(projectRoot: URL(fileURLWithPath: fileManager.currentDirectoryPath))
    }
}

final class PDDLocalResourceServer: @unchecked Sendable {
    private let resolver: PDDOCRStaticResourceResolver
    private let queue = DispatchQueue(label: "PDDOCR.LocalResourceServer")
    private var listener: NWListener?

    init(root: URL) { resolver = PDDOCRStaticResourceResolver(root: root) }

    func start() async throws -> URL {
        if let port = listener?.port { return URL(string: "http://127.0.0.1:\(port.rawValue)/index.html")! }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port {
                        continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/index.html")!)
                    } else {
                        continuation.resume(throwing: PDDOCRError.engine("本地 OCR 端口不可用"))
                    }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data,
                  let request = String(data: data, encoding: .utf8),
                  let first = request.split(separator: "\r\n").first else {
                connection.cancel(); return
            }
            let parts = first.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET",
                  let url = try? self.resolver.fileURL(for: String(parts[1])),
                  let body = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                self.send(status: "404 Not Found", body: Data(), mime: "text/plain", connection: connection)
                return
            }
            self.send(
                status: "200 OK", body: body,
                mime: PDDOCRStaticResourceResolver.mimeType(forExtension: url.pathExtension),
                connection: connection
            )
        }
    }

    private func send(status: String, body: Data, mime: String, connection: NWConnection) {
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
