import Foundation
import XCTest
@testable import PDDAXReader

final class PythonRuntimeResolverTests: XCTestCase {
    func testLiveProbeDisablesPythonBytecodeWrites() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let environmentCapture = root.appendingPathComponent("python-environment.txt")
        let executable = root.appendingPathComponent("python3")
        let script = """
        #!/bin/zsh
        printenv PYTHONDONTWRITEBYTECODE > \(environmentCapture.path)
        print '3.12.14'
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path
        )

        _ = PythonRuntimeResolver.liveProbe(executable)

        XCTAssertEqual(
            try String(contentsOf: environmentCapture, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "1"
        )
    }

    func testEnvironmentCandidateWinsOverBundledAndSystemCandidates() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let explicit = try makeExecutable(root.appendingPathComponent("explicit-python"))
        let bundled = try makeExecutable(root.appendingPathComponent("PythonRuntime/python/bin/python3"))

        let result = PythonRuntimeResolver.resolve(
            resourceRootURL: root,
            environment: ["PDD_PYTHON_PATH": explicit.path, "PATH": ""],
            systemCandidates: [],
            probe: { url in
                PythonRuntimeProbe(version: "3.12.14", architectures: [.arm64], executableURL: url)
            }
        )

        XCTAssertEqual(result?.executableURL, explicit)
        XCTAssertEqual(result?.source, .environment)
        XCTAssertNotEqual(result?.executableURL, bundled)
    }

    func testBundledCandidateWinsOverSystemCandidate() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = try makeExecutable(root.appendingPathComponent("PythonRuntime/python/bin/python3"))
        let system = try makeExecutable(root.appendingPathComponent("system-python"))

        let result = PythonRuntimeResolver.resolve(
            resourceRootURL: root,
            environment: ["PATH": ""],
            systemCandidates: [system],
            probe: { url in
                PythonRuntimeProbe(version: "3.12.14", architectures: [.arm64], executableURL: url)
            }
        )

        XCTAssertEqual(result?.executableURL, bundled)
        XCTAssertEqual(result?.source, .bundled)
    }

    func testRejectsWrongVersionAndNonArmRuntime() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeExecutable(root.appendingPathComponent("PythonRuntime/python/bin/python3"))

        XCTAssertNil(PythonRuntimeResolver.resolve(
            resourceRootURL: root,
            environment: ["PATH": ""],
            systemCandidates: [],
            probe: { url in
                PythonRuntimeProbe(version: "3.11.9", architectures: [.x86_64], executableURL: url)
            }
        ))
    }

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeExecutable(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("#!/bin/zsh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
