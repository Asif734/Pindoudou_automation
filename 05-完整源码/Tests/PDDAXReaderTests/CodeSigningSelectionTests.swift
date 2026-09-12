import Foundation
import XCTest

final class CodeSigningSelectionTests: XCTestCase {
    func testPrefersExplicitThenDeveloperIDThenAppleDevelopmentThenPersistentLocalIdentityThenAdHoc() throws {
        XCTAssertEqual(try select(explicit: "Explicit Cert", identities: ""), "Explicit Cert")
        XCTAssertEqual(try select(explicit: nil, identities: "1) AAA \"Apple Development: Dev\"\n2) BBB \"Developer ID Application: Company\""), "Developer ID Application: Company")
        XCTAssertEqual(try select(explicit: nil, identities: "1) AAA \"Apple Development: Dev\""), "Apple Development: Dev")
        XCTAssertEqual(
            try select(
                explicit: nil,
                identities: "1) AAA \"Qianniu AutoReply Local Signing\""
            ),
            "Qianniu AutoReply Local Signing"
        )
        XCTAssertEqual(try select(explicit: nil, identities: "0 valid identities found"), "-")
    }

    private func select(explicit: String?, identities: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/select_codesign_identity.sh")
        var environment = ProcessInfo.processInfo.environment
        environment["PDD_CODESIGN_IDENTITIES_TEXT"] = identities
        if let explicit { environment["PDD_AX_SIGNING_IDENTITY"] = explicit }
        else { environment.removeValue(forKey: "PDD_AX_SIGNING_IDENTITY") }
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
