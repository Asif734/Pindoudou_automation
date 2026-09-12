import Foundation
import XCTest
@testable import PDDAXReader

final class PDDSenseVoiceTranscriberTests: XCTestCase {
    func testPrepareLoadsWorkerOnceAndTranscriptionReturnsWorkerText() async throws {
        let worker = SenseVoiceWorkerFake(
            ready: #"{"type":"ready","version":"sensevoice-small-int8"}"#,
            response: #"{"ok":true,"text":"M880没电的时候能不能用啊"}"#
        )
        let transcriber = PDDSenseVoiceTranscriber(
            worker: worker,
            waveConverter: { source in source }
        )

        try await transcriber.prepare()
        try await transcriber.prepare()
        let result = await transcriber.transcribe(URL(fileURLWithPath: "/tmp/test.wav"))

        XCTAssertEqual(result.map(\.text), ["M880没电的时候能不能用啊"])
        let snapshot = await worker.snapshot()
        XCTAssertEqual(snapshot.startCount, 1)
        XCTAssertEqual(snapshot.requestCount, 1)
    }

    func testMalformedWorkerResponseDegradesToNoTranscript() async {
        let worker = SenseVoiceWorkerFake(
            ready: #"{"type":"ready","version":"sensevoice-small-int8"}"#,
            response: #"{"ok":false,"text":null}"#
        )
        let transcriber = PDDSenseVoiceTranscriber(
            worker: worker,
            waveConverter: { source in source }
        )

        let result = await transcriber.transcribe(URL(fileURLWithPath: "/tmp/test.wav"))

        XCTAssertTrue(result.isEmpty)
    }
}

private actor SenseVoiceWorkerFake: PDDSenseVoiceWorking {
    let ready: String
    let response: String
    private var starts = 0
    private var requests = 0

    init(ready: String, response: String) {
        self.ready = ready
        self.response = response
    }

    func start() async throws -> Data {
        starts += 1
        return Data(ready.utf8)
    }

    func request(_ data: Data) async throws -> Data {
        requests += 1
        return Data(response.utf8)
    }

    func snapshot() -> (startCount: Int, requestCount: Int) { (starts, requests) }
}
