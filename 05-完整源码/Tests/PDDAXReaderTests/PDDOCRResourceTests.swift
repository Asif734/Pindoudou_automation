import XCTest
@testable import PDDAXReader

final class PDDOCRResourceTests: XCTestCase {
    func testResolverRejectsTraversalAndMapsKnownMIMETypes() throws {
        let root = URL(fileURLWithPath: "/tmp/pdd-ocr-root", isDirectory: true)
        let resolver = PDDOCRStaticResourceResolver(root: root)
        XCTAssertThrowsError(try resolver.fileURL(for: "/../secret"))
        XCTAssertEqual(PDDOCRStaticResourceResolver.mimeType(forExtension: "wasm"), "application/wasm")
        XCTAssertEqual(try resolver.fileURL(for: "/models/a.tar").path, "/tmp/pdd-ocr-root/models/a.tar")
    }

    func testDevelopmentResourcesContainBothVerifiedPaddleModels() {
        let root = PDDOCRResourceRoot.development(projectRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("models/PP-OCRv5_mobile_det_onnx_infer.tar").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("models/PP-OCRv5_mobile_rec_onnx_infer.tar").path))
    }

    @MainActor
    func testEngineWaitsForModuleBootstrapAfterNavigationFinishes() {
        let script = PDDPaddleOCREngine.readinessJavaScript
        XCTAssertTrue(script.contains("window.qianniuOCR"))
        XCTAssertTrue(script.contains("window.__qianniuBootState?.error"))
        XCTAssertTrue(script.contains("setTimeout(check, 50)"))
        XCTAssertTrue(script.contains("Date.now() + 30000"))
    }
}
