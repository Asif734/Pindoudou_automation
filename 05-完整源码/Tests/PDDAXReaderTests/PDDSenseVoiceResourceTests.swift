import Foundation
import XCTest
@testable import PDDAXReader

final class PDDSenseVoiceResourceTests: XCTestCase {
    func testResolverRequiresWorkerModelTokensAndPythonPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-sensevoice-resources-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sense = root.appendingPathComponent("SenseVoice")
        let model = sense.appendingPathComponent("model")
        let package = sense.appendingPathComponent("site-packages/sherpa_onnx")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data().write(to: sense.appendingPathComponent("serve_sensevoice.py"))
        try Data().write(to: model.appendingPathComponent("model.int8.onnx"))
        try Data().write(to: model.appendingPathComponent("tokens.txt"))

        let resources = try XCTUnwrap(PDDSenseVoiceResourceLocator.resolve(resourceRootURL: root))

        XCTAssertEqual(resources.modelURL.lastPathComponent, "model.int8.onnx")
        XCTAssertEqual(resources.tokensURL.lastPathComponent, "tokens.txt")
        XCTAssertEqual(resources.sitePackagesURL.lastPathComponent, "site-packages")
    }
}
