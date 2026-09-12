import XCTest
@testable import PDDAXReader

final class PDDVideoAnalysisInboxTests: XCTestCase {
    func testSameCustomerAndContentWithDifferentMessageIDsIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let inbox = PDDVideoAnalysisInbox(stateURL: fixture.stateURL)

        let first = try await inbox.claim(fixture.receipt(uid: "PDD-one", messageID: "video-a"))
        let second = try await inbox.claim(fixture.receipt(uid: "PDD-one", messageID: "video-b"))
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testSameContentFromDifferentCustomersIsAccepted() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let inbox = PDDVideoAnalysisInbox(stateURL: fixture.stateURL)

        let first = try await inbox.claim(fixture.receipt(uid: "PDD-one", messageID: "video-a"))
        let second = try await inbox.claim(fixture.receipt(uid: "PDD-two", messageID: "video-b"))
        XCTAssertTrue(first)
        XCTAssertTrue(second)
    }

    func testClaimSurvivesInboxRecreation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try await PDDVideoAnalysisInbox(stateURL: fixture.stateURL)
            .claim(fixture.receipt(uid: "PDD-one", messageID: "video-a"))

        let second = try await PDDVideoAnalysisInbox(stateURL: fixture.stateURL)
            .claim(fixture.receipt(uid: "PDD-one", messageID: "video-b"))
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testExactMessageCanResumeAfterRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let receipt = fixture.receipt(uid: "PDD-one", messageID: "video-a")
        let initial = try await PDDVideoAnalysisInbox(stateURL: fixture.stateURL).claim(receipt)
        let resumed = try await PDDVideoAnalysisInbox(stateURL: fixture.stateURL).claim(receipt)
        XCTAssertTrue(initial)
        XCTAssertTrue(resumed)
    }

    func testLegacySchedulerAttachmentSeedsContentDeduplication() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var state = AutoReplyPersistentState.empty
        let old = fixture.receipt(uid: "PDD-one", messageID: "legacy-message")
        state.jobs = [fixture.job(uid: "PDD-one", attachment: AutoReplyVideoAttachment(
            messageID: old.messageID,
            localURL: old.fileURL,
            sha256: old.summary.sha256,
            byteCount: old.summary.byteCount,
            durationSeconds: old.summary.durationSeconds,
            width: old.summary.width,
            height: old.summary.height,
            videoCodec: old.summary.videoCodec,
            audioCodec: old.summary.audioCodec,
            frames: [], transcript: nil, diagnostic: nil
        ))]
        try AutoReplyStore(rootDirectory: fixture.root).save(state)
        let inbox = PDDVideoAnalysisInbox(
            stateURL: fixture.stateURL, legacySchedulerRoot: fixture.root
        )

        let accepted = try await inbox.claim(
            fixture.receipt(uid: "PDD-one", messageID: "new-message")
        )

        XCTAssertFalse(accepted)
    }
}

private extension PDDVideoAnalysisInboxTests {
    struct Fixture {
        let root: URL
        let stateURL: URL
        let videoURL: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pdd-video-inbox-tests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            stateURL = root.appendingPathComponent("content-hashes.json")
            videoURL = root.appendingPathComponent("same.mp4")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("identical-video-bytes".utf8).write(to: videoURL)
        }

        func receipt(uid: String, messageID: String) -> PDDDownloadedCustomerVideo {
            PDDDownloadedCustomerVideo(
                uid: uid,
                messageID: messageID,
                key: PDDVideoTransferKey(uid: uid, messageID: messageID),
                fileURL: videoURL,
                summary: PDDVideoFileSummary(
                    byteCount: 21,
                    sha256: "same-real-content-sha256",
                    durationSeconds: 1,
                    width: 10,
                    height: 10,
                    videoCodec: "H.264",
                    audioCodec: nil
                )
            )
        }

        func job(uid: String, attachment: AutoReplyVideoAttachment) -> AutoReplyJob {
            AutoReplyJob(
                id: UUID(), uid: uid, sequence: 1, state: .completed,
                capture: AutoReplyCapture(
                    uid: uid, fullHistory: [], batch: nil,
                    customerCursor: .empty, unexpectedServiceMessageIDs: []
                ),
                reply: "已回复", deliveryOutcome: .sent,
                confirmedServiceMessageID: nil, retries: 0,
                nextAttemptAt: nil, lastError: nil,
                videoAttachments: [attachment]
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
