import Foundation

enum CodexInstallation {
    static let productionCandidates = defaultAppCandidates(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )

    static func defaultAppCandidates(homeDirectory: URL) -> [URL] {
        let userApplications = homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        return [
            userApplications.appendingPathComponent("ChatGPT.app/Contents/Resources/codex"),
            userApplications.appendingPathComponent("Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appCandidates: [URL] = productionCandidates,
        pathExecutableName: String = "codex",
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates: [URL] = []
        if let explicit = environment["PDD_CODEX_PATH"], !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        candidates.append(contentsOf: appCandidates)
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent(pathExecutableName)
            })
        }
        // Finder-launched apps do not inherit VS Code's PATH. Discover the
        // installed extension CLI as a fallback so the Applications copy works.
        let extensions = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".vscode/extensions", isDirectory: true)
        let installed = (try? fileManager.contentsOfDirectory(
            at: extensions, includingPropertiesForKeys: nil
        )) ?? []
        candidates.append(contentsOf: installed
            .filter { $0.lastPathComponent.hasPrefix("openai.chatgpt-") }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin/macos-aarch64/codex") })
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }
}
