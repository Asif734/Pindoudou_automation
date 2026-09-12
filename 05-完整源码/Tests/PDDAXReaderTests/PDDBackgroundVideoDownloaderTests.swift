import XCTest
@testable import PDDAXReader

final class PDDBackgroundVideoDownloaderTests: XCTestCase {
    func testAlternateRouteRejectsNonHTTPSAndUntrustedHostsBeforeNetworking() async {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        for source in [
            URL(string: "http://video.pinduoduo.com/file.mp4")!,
            URL(string: "https://example.com/file.mp4")!
        ] {
            do {
                _ = try await PDDAlternateVideoDownloadClient().download(
                    from: source, to: destination
                )
                XCTFail("不可信视频地址不应进入备用下载线路")
            } catch let error as PDDCustomerVideoError {
                XCTAssertEqual(error, .downloadRejected)
            } catch {
                XCTFail("错误类型不符合预期：\(error)")
            }
        }
    }

    func testSessionPolicyUsesCurrentQianniuBoundedAttemptWithoutBrowserState() {
        let configuration = PDDUnlimitedVideoDownloadSessionPolicy.makeConfiguration()

        XCTAssertEqual(configuration.timeoutIntervalForRequest, 5)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 15)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
    }

    func testPolicyDoesNotRejectFilesAboveLegacyTwoHundredMiBLimit() {
        let size = Int64(201 * 1024 * 1024)

        XCTAssertTrue(PDDUnlimitedVideoDownloadPolicy.accepts(byteCount: size))
    }
}
