import XCTest
@testable import PDDAXReader

final class PDDBackgroundVideoModelsTests: XCTestCase {
    func testTransferKeySeparatesSameMessageAcrossCustomers() {
        let first = PDDVideoTransferKey(uid: "PDD-one", messageID: "video-7")
        let second = PDDVideoTransferKey(uid: "PDD-two", messageID: "video-7")

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.customerHash, second.customerHash)
        XCTAssertEqual(first.messageHash, second.messageHash)
    }

    func testLegacyCaptureDefaultsPendingVideoIDsToEmpty() throws {
        let data = Data(#"{"uid":"PDD-one","fullHistory":[],"customerCursor":{"count":0,"digest":"0000000000000000000000000000000000000000000000000000000000000000"},"unexpectedServiceMessageIDs":[]}"#.utf8)

        let capture = try JSONDecoder().decode(AutoReplyCapture.self, from: data)

        XCTAssertEqual(capture.pendingVideoMessageIDs, [])
    }

    func testLegacyVideoAttachmentDefaultsEvidenceURLsToNil() throws {
        let data = Data(#"{"messageID":"v1","localURL":"file:///tmp/v1.mp4","sha256":"abc","byteCount":1,"durationSeconds":1,"width":1,"height":1,"videoCodec":"h264","frames":[]}"#.utf8)

        let attachment = try JSONDecoder().decode(AutoReplyVideoAttachment.self, from: data)

        XCTAssertNil(attachment.audioLocalURL)
        XCTAssertNil(attachment.manifestLocalURL)
    }

    func testLegacyStateDefaultsPendingVideoBatchesToEmpty() throws {
        let state = try JSONDecoder().decode(
            AutoReplyPersistentState.self,
            from: Data(#"{"schemaVersion":6}"#.utf8)
        )

        XCTAssertEqual(state.pendingVideoBatches, [])
    }
}
