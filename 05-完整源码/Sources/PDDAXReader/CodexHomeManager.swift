import Foundation

struct CodexRuntimeEnvironment: Equatable, Sendable {
    let homeURL: URL
    let values: [String: String]
}

struct CodexHomeManager: Sendable {
    let dataRoot: URL
    let sourceHome: URL

    init(
        dataRoot: URL,
        sourceHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    ) {
        self.dataRoot = dataRoot
        self.sourceHome = sourceHome
    }

    func prepare() throws -> CodexRuntimeEnvironment {
        let manager = FileManager.default
        let home = dataRoot.appendingPathComponent("codex-home", isDirectory: true)
        try manager.createDirectory(at: home, withIntermediateDirectories: true)

        // Authentication is the only ambient Codex material admitted into the
        // isolated runtime. Skills, rules, config and history are intentionally excluded.
        let sourceAuth = sourceHome.appendingPathComponent("auth.json")
        let destinationAuth = home.appendingPathComponent("auth.json")
        if manager.fileExists(atPath: sourceAuth.path) {
            let sourceData = try Data(contentsOf: sourceAuth)
            if !manager.fileExists(atPath: destinationAuth.path)
                || (try? Data(contentsOf: destinationAuth)) != sourceData {
                try sourceData.write(to: destinationAuth, options: [.atomic])
                try manager.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: destinationAuth.path
                )
            }
        }

        var values = ProcessInfo.processInfo.environment
        values["CODEX_HOME"] = home.path
        values.removeValue(forKey: "OPENAI_API_KEY")
        values.removeValue(forKey: "CODEX_API_KEY")
        return CodexRuntimeEnvironment(homeURL: home, values: values)
    }
}
