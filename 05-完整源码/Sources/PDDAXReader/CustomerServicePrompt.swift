import CryptoKit
import Foundation

enum CustomerServicePromptError: LocalizedError {
    case emptyResource(String)

    var errorDescription: String? {
        switch self {
        case .emptyResource(let path): return "客服 Prompt 资源为空：\(path)"
        }
    }
}

enum CustomerServicePrompt {
    static func load(from url: URL) throws -> String {
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw CustomerServicePromptError.emptyResource(url.path) }
        return value
    }

    static func loadRuntime() throws -> String {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(
                "CustomerService/customer-reply-prompt.md"
            ),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/CustomerService/customer-reply-prompt.md")
        ].compactMap { $0 }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return try load(from: candidate)
        }
        throw CocoaError(.fileNoSuchFile)
    }

    static func runtimeSHA256() throws -> String {
        SHA256.hash(data: Data(try loadRuntime().utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
