import XCTest
@testable import PDDAXReader

@MainActor
final class PDDAXImagePreviewTests: XCTestCase {

    func testDownloadControlPolicyRecognizesLabelAndDOMClass() {
        XCTAssertTrue(PDDImagePreviewControlPolicy.isDownloadControl(
            role: "AXButton", labels: ["下载"], domMetadata: ""
        ))
        XCTAssertTrue(PDDImagePreviewControlPolicy.isDownloadControl(
            role: "AXGroup", labels: [], domMetadata: "MacPreview_downloadButton"
        ))
        XCTAssertFalse(PDDImagePreviewControlPolicy.isDownloadControl(
            role: "AXButton", labels: ["1:1"], domMetadata: "preview-scale"
        ))
    }

    func testSaveSheetPolicyDistinguishesFilenameAndActionControls() {
        XCTAssertTrue(PDDImageSaveSheetPolicy.isFilenameField(
            role: "AXTextField", labels: ["图片"]
        ))
        XCTAssertFalse(PDDImageSaveSheetPolicy.isFilenameField(
            role: "AXTextField", labels: ["标签编辑器"]
        ))
        XCTAssertTrue(PDDImageSaveSheetPolicy.isButton(
            role: "AXButton", labels: ["保存"], names: ["保存", "save"]
        ))
        XCTAssertTrue(PDDImageSaveSheetPolicy.isButton(
            role: "AXButton", labels: ["Cancel"], names: ["取消", "cancel"]
        ))
    }

    func testDownloadRegionFallbackTargetsRightSideOfLowerToolbar() {
        let point = PDDImagePreviewControlPolicy.fallbackDownloadPoint(
            in: CGRect(x: 0, y: 0, width: 1_200, height: 1_200)
        )
        XCTAssertEqual(point.x, 732, accuracy: 0.1)
        XCTAssertEqual(point.y, 1_056, accuracy: 0.1)
    }

    func testDownloadMonitorReturnsOnlyStableNewFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-download-monitor-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing.jpeg")
        try Data([1]).write(to: existing)
        let monitor = PDDDownloadedImageMonitor(directory: root)
        monitor.begin()

        XCTAssertNil(monitor.stableNewFile())
        let downloaded = root.appendingPathComponent("customer.jpeg")
        try Data([1, 2, 3]).write(to: downloaded)
        XCTAssertNil(monitor.stableNewFile())
        XCTAssertEqual(monitor.stableNewFile(), downloaded.standardizedFileURL)
    }

    func testOriginalImageURLPolicyIgnoresPreviewPageAndSelectsMainImage() {
        XCTAssertNil(PDDPreviewImageURLPolicy.originalImageURL(
            role: "AXWebArea",
            domClasses: [],
            rawURL: "https://mms.pinduoduo.com/mac-workbench/preview/image"
        ))

        XCTAssertEqual(
            PDDPreviewImageURLPolicy.originalImageURL(
                role: "AXImage",
                domClasses: ["MacPreview_imgContent__2xVkx"],
                rawURL: "https://chat-img.pddugc.com/chat-pic-mall-user-v1/2026-09-01/customer.jpeg"
            )?.absoluteString,
            "https://chat-img.pddugc.com/chat-pic-mall-user-v1/2026-09-01/customer.jpeg"
        )
    }

    func testDoubleClicksFrameCenterAndReturnsHTTPPreviewURL() async throws {
        let clicker = PreviewClickerSpy()
        let reader = PreviewReaderStub(result: .success(
            URL(string: "https://chat-img.pddugc.com/original.jpeg")!
        ))
        let resolver = PDDAXImagePreviewResolver(clicker: clicker, reader: reader)
        let registry = UIOperationLeaseRegistry()
        let lease = registry.acquire(uid: "GZC-000001")
        let candidate = PDDCustomerImageCandidate(
            messageID: "m1", frame: CGRect(x: 20, y: 30, width: 100, height: 60)
        )

        let url = try await resolver.resolve(candidate: candidate, lease: lease)

        XCTAssertEqual(clicker.points, [CGPoint(x: 70, y: 60)])
        XCTAssertEqual(url.absoluteString, "https://chat-img.pddugc.com/original.jpeg")
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testResolverSuspendsOuterDeadlineOnlyWhileOpenedPreviewWaitsForURL() async throws {
        let registry = UIOperationLeaseRegistry()
        let lease = registry.acquire(uid: "GZC-000001")
        let reader = DeadlineObservingPreviewReader(
            lease: lease,
            result: URL(string: "https://chat-img.pddugc.com/original.jpeg")!
        )
        let resolver = PDDAXImagePreviewResolver(
            clicker: PreviewClickerSpy(), reader: reader
        )

        _ = try await resolver.resolve(
            candidate: PDDCustomerImageCandidate(
                messageID: "m1", frame: CGRect(x: 20, y: 30, width: 100, height: 60)
            ),
            lease: lease
        )

        XCTAssertTrue(reader.deadlineWasSuspendedDuringWait)
        XCTAssertFalse(lease.isDeadlineSuspended)
    }

    func testRejectsNonHTTPURLAndStillClosesPreview() async throws {
        let reader = PreviewReaderStub(result: .success(URL(fileURLWithPath: "/tmp/not-remote")))
        let resolver = PDDAXImagePreviewResolver(clicker: PreviewClickerSpy(), reader: reader)
        let lease = UIOperationLeaseRegistry().acquire(uid: "GZC-000001")

        do {
            _ = try await resolver.resolve(
                candidate: PDDCustomerImageCandidate(messageID: "m1", frame: CGRect(x: 1, y: 1, width: 2, height: 2)),
                lease: lease
            )
            XCTFail("expected invalid URL")
        } catch {
            XCTAssertEqual(error as? PDDCustomerImageError, .invalidPreviewURL)
        }
        XCTAssertEqual(reader.closeCount, 1)
    }

    func testLivePreviewReaderDownloadsCurrentPDDMainImageWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PDD_LIVE_IMAGE_PREVIEW"] == "1" else {
            throw XCTSkip("set PDD_LIVE_IMAGE_PREVIEW=1 with a PDD image preview open")
        }
        let reader = LivePDDImagePreviewReader(previewOpenTimeout: 5)
        defer { reader.closePreview() }
        let sourceURL = try await reader.waitForOriginalURL()
        XCTAssertTrue(sourceURL.isFileURL || sourceURL.host == "chat-img.pddugc.com")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-live-image-preview-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let attachment = try await PDDCustomerImageDownloader().download(
            sourceURL: sourceURL,
            destinationDirectory: root,
            messageID: "live-preview"
        )

        XCTAssertTrue(["image/jpeg", "image/png"].contains(attachment.mimeType))
        XCTAssertGreaterThan(attachment.byteCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.localURL.path))
    }

    func testMissingPreviewFailsAfterOpenConfirmationDeadlineWithoutWaitingForURL() async throws {
        var elapsed: TimeInterval = 0
        let reader = LivePDDImagePreviewReader(
            previewOpenTimeout: 2,
            pollInterval: 0.2,
            now: { Date(timeIntervalSince1970: elapsed) },
            sleep: { seconds in elapsed += seconds },
            previewProbeProvider: { .absent }
        )

        do {
            _ = try await reader.waitForOriginalURL()
            XCTFail("expected previewNotFound")
        } catch {
            XCTAssertEqual(error as? PDDCustomerImageError, .previewNotFound)
        }
        XCTAssertGreaterThanOrEqual(elapsed, 1.99)
        XCTAssertLessThan(elapsed, 2.3)
    }

    func testOpenPreviewKeepsPollingWithoutURLDeadline() async throws {
        var elapsed: TimeInterval = 0
        let expected = URL(string: "https://chat-img.pddugc.com/second-image.jpeg")!
        let reader = LivePDDImagePreviewReader(
            previewOpenTimeout: 2,
            pollInterval: 0.2,
            now: { Date(timeIntervalSince1970: elapsed) },
            sleep: { seconds in elapsed += seconds },
            previewProbeProvider: {
                .open(url: elapsed >= 120 ? expected : nil)
            }
        )

        let result = try await reader.waitForOriginalURL()

        XCTAssertEqual(result, expected)
        XCTAssertGreaterThanOrEqual(elapsed, 120)
    }
}

@MainActor
private final class PreviewClickerSpy: PDDImageDoubleClicking {
    var points: [CGPoint] = []
    func doubleClick(at point: CGPoint) throws { points.append(point) }
}

@MainActor
private final class PreviewReaderStub: PDDImagePreviewReading {
    let result: Result<URL, Error>
    var closeCount = 0
    init(result: Result<URL, Error>) { self.result = result }
    func waitForOriginalURL() async throws -> URL { try result.get() }
    func closePreview() { closeCount += 1 }
}

@MainActor
private final class DeadlineObservingPreviewReader: PDDImagePreviewReading {
    let lease: UIOperationLease
    let result: URL
    var deadlineWasSuspendedDuringWait = false

    init(lease: UIOperationLease, result: URL) {
        self.lease = lease
        self.result = result
    }

    func waitForOriginalURL() async throws -> URL { result }

    func waitForOriginalURL(onPreviewOpen: @escaping @MainActor () -> Void) async throws -> URL {
        onPreviewOpen()
        deadlineWasSuspendedDuringWait = lease.isDeadlineSuspended
        return result
    }

    func closePreview() {}
}
