import XCTest
@testable import PDDAXReader

final class StableAXTreeReaderTests: XCTestCase {
    func testSamplesTwiceAndKeepsSnapshotWithNewestMessageID() throws {
        let recorder = StableReadRecorder(results: [
            result(messageID: "middlePanel_list_1787846765327", value: "旧客服消息"),
            result(messageID: "middlePanel_list_1787847000000", value: "刚到的客户消息")
        ])
        let pauses = LockedIntervals()
        let reader = StableAXTreeReader(
            sampleCount: 2,
            interval: 0.01,
            readOnce: { try recorder.next() },
            pause: { pauses.append($0) }
        )

        let selected = try reader.read()

        XCTAssertEqual(recorder.readCount, 2)
        XCTAssertEqual(pauses.values, [0.01])
        XCTAssertEqual(PDDAXSnapshotOrder.newestMessageOrdinal(in: selected.root), 1_787_847_000_000)
    }

    func testDoesNotReplaceNewerFirstSnapshotWithOlderVirtualizedSnapshot() throws {
        let recorder = StableReadRecorder(results: [
            result(messageID: "middlePanel_list_200", value: "新消息"),
            result(messageID: "middlePanel_list_100", value: "旧消息")
        ])
        let reader = StableAXTreeReader(
            sampleCount: 2,
            interval: 0,
            readOnce: { try recorder.next() },
            pause: { _ in }
        )

        let selected = try reader.read()

        XCTAssertEqual(PDDAXSnapshotOrder.newestMessageOrdinal(in: selected.root), 200)
    }

    private func result(messageID: String, value: String) -> AXReadResult {
        AXReadResult(
            root: AXNodeSnapshot(
                role: "AXWindow",
                children: [
                    AXNodeSnapshot(
                        role: "AXGroup",
                        attributes: [
                            ("AXDOMClassList", "[clearfix, onemsg]"),
                            ("AXDOMIdentifier", messageID),
                            ("AXValue", value)
                        ]
                    )
                ]
            ),
            nodeCount: 2,
            elapsedSeconds: 0.1,
            applicationName: "拼多多"
        )
    }
}

private final class LockedIntervals: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []

    func append(_ value: TimeInterval) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class StableReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [AXReadResult]
    private(set) var readCount = 0

    init(results: [AXReadResult]) {
        self.results = results
    }

    func next() throws -> AXReadResult {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        guard !results.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return results.removeFirst()
    }
}
