import Speech
import XCTest
@testable import PDDAXReader

final class PDDVideoSpeechPolicyTests: XCTestCase {
    func testDeniedAndRestrictedAuthorizationSkipTranscriptWithoutFailingVideo() {
        XCTAssertEqual(PDDVideoSpeechAuthorizationPolicy.action(for: .denied), .skipTranscript)
        XCTAssertEqual(PDDVideoSpeechAuthorizationPolicy.action(for: .restricted), .skipTranscript)
    }

    func testAuthorizedTranscribesAndUndeterminedRequestsOnce() {
        XCTAssertEqual(PDDVideoSpeechAuthorizationPolicy.action(for: .authorized), .transcribe)
        XCTAssertEqual(PDDVideoSpeechAuthorizationPolicy.action(for: .notDetermined), .requestAuthorization)
    }
}
