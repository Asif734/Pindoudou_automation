import Foundation
import XCTest
@testable import PDDAXReader

final class PDDVideoSpeechFallbackTests: XCTestCase {
    func testAppleResultWinsWithoutUsingSenseVoice() async {
        let speech = PDDAppleThenFallbackVideoSpeechTranscriber(
            primary: FixedSpeechTranscriber(text: "客户说 M880 没电"),
            fallback: FixedSpeechTranscriber(text: "不应返回的兜底结果")
        )

        let result = await speech.transcribe(URL(fileURLWithPath: "/tmp/audio.m4a"))

        XCTAssertEqual(result.map(\.text), ["客户说 M880 没电"])
    }

    func testEmptyAppleResultUsesSenseVoice() async {
        let speech = PDDAppleThenFallbackVideoSpeechTranscriber(
            primary: FixedSpeechTranscriber(text: nil),
            fallback: FixedSpeechTranscriber(text: "桌子上有红色物品")
        )

        let result = await speech.transcribe(URL(fileURLWithPath: "/tmp/audio.m4a"))

        XCTAssertEqual(result.map(\.text), ["桌子上有红色物品"])
    }

    func testApple1110ArtifactUsesSenseVoice() async {
        let speech = PDDAppleThenFallbackVideoSpeechTranscriber(
            primary: FixedSpeechTranscriber(text: " 1110。 "),
            fallback: FixedSpeechTranscriber(text: "能不能用啊")
        )

        let result = await speech.transcribe(URL(fileURLWithPath: "/tmp/audio.m4a"))

        XCTAssertEqual(result.map(\.text), ["能不能用啊"])
    }
}

private struct FixedSpeechTranscriber: PDDVideoSpeechTranscribing {
    let text: String?

    func transcribe(_ mediaURL: URL) async -> [PDDVideoTranscriptSegment] {
        guard let text else { return [] }
        return [.init(startSeconds: 0, durationSeconds: 0, text: text)]
    }
}
