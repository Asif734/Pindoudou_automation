import Foundation
import XCTest

final class PythonRuntimePackagingTests: XCTestCase {
    func testStagerRejectsWrongDigestAndExpandsVerifiedRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/python/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let executable = source.appendingPathComponent("python3")
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path
        )
        let archive = root.appendingPathComponent("runtime.tar.gz")
        try run("/usr/bin/tar", ["-czf", archive.path, "-C", root.appendingPathComponent("source").path, "python"])
        let digest = try output("/usr/bin/shasum", ["-a", "256", archive.path])
            .split(separator: " ").first.map(String.init) ?? ""
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/stage_python_runtime.sh")
        let destination = root.appendingPathComponent("destination", isDirectory: true)

        XCTAssertThrowsError(try run(script.path, [archive.path, String(repeating: "0", count: 64), destination.path]))
        try run(script.path, [archive.path, digest, destination.path])

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("python/bin/python3")),
            Data("fixture".utf8)
        )
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            )
            throw NSError(
                domain: "PythonRuntimePackagingTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func output(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "PythonRuntimePackagingTests", code: Int(process.terminationStatus))
        }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
