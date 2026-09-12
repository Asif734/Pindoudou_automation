import Foundation

enum PythonRuntimeArchitecture: String, Hashable, Sendable {
    case arm64
    case x86_64
}

enum PythonRuntimeSource: Equatable, Sendable {
    case environment
    case bundled
    case system
    case path
}

struct PythonRuntimeProbe: Equatable, Sendable {
    let version: String
    let architectures: Set<PythonRuntimeArchitecture>
    let executableURL: URL
}

struct PythonRuntimeResolution: Equatable, Sendable {
    let executableURL: URL
    let source: PythonRuntimeSource
    let version: String
}

enum PythonRuntimeResolver {
    typealias Probe = (URL) -> PythonRuntimeProbe?

    static let defaultSystemCandidates = [
        URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12"),
        URL(fileURLWithPath: "/opt/homebrew/bin/python3.12"),
    ]

    static func resolve(
        resourceRootURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        systemCandidates: [URL] = defaultSystemCandidates,
        fileManager: FileManager = .default,
        probe: Probe = liveProbe
    ) -> PythonRuntimeResolution? {
        var candidates: [(URL, PythonRuntimeSource)] = []
        if let configured = environment["PDD_PYTHON_PATH"], !configured.isEmpty {
            candidates.append((URL(fileURLWithPath: configured), .environment))
        }
        candidates.append((
            resourceRootURL.appendingPathComponent("PythonRuntime/python/bin/python3"),
            .bundled
        ))
        candidates.append(contentsOf: systemCandidates.map { ($0, .system) })
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            candidates.append((
                URL(fileURLWithPath: String(directory)).appendingPathComponent("python3.12"),
                .path
            ))
        }

        var seen = Set<String>()
        for (url, source) in candidates where seen.insert(url.standardizedFileURL.path).inserted {
            guard fileManager.isExecutableFile(atPath: url.path),
                  let result = probe(url),
                  result.version == "3.12" || result.version.hasPrefix("3.12."),
                  result.architectures.contains(.arm64) else { continue }
            return PythonRuntimeResolution(
                executableURL: result.executableURL,
                source: source,
                version: result.version
            )
        }
        return nil
    }

    static func liveProbe(_ executableURL: URL) -> PythonRuntimeProbe? {
        let versionProcess = Process()
        let versionPipe = Pipe()
        versionProcess.executableURL = executableURL
        versionProcess.arguments = ["-c", "import platform; print(platform.python_version())"]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        versionProcess.environment = environment
        versionProcess.standardOutput = versionPipe
        versionProcess.standardError = Pipe()
        do {
            try versionProcess.run()
            versionProcess.waitUntilExit()
        } catch {
            return nil
        }
        guard versionProcess.terminationStatus == 0 else { return nil }
        let version = String(
            decoding: versionPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let fileProcess = Process()
        let filePipe = Pipe()
        fileProcess.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        fileProcess.arguments = [executableURL.path]
        fileProcess.standardOutput = filePipe
        fileProcess.standardError = Pipe()
        do {
            try fileProcess.run()
            fileProcess.waitUntilExit()
        } catch {
            return nil
        }
        guard fileProcess.terminationStatus == 0 else { return nil }
        let description = String(
            decoding: filePipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).lowercased()
        var architectures = Set<PythonRuntimeArchitecture>()
        if description.contains("arm64") { architectures.insert(.arm64) }
        if description.contains("x86_64") { architectures.insert(.x86_64) }
        return PythonRuntimeProbe(
            version: version,
            architectures: architectures,
            executableURL: executableURL
        )
    }
}
