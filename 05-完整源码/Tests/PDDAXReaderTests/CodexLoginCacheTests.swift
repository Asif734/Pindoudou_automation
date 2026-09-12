import XCTest
@testable import PDDAXReader

final class CodexLoginCacheTests: XCTestCase {
    func testSuccessfulChatGPTLoginIsCachedForSixtySeconds() async throws {
        let checker = CountingLoginChecker(results: [.chatGPT, .notLoggedIn])
        let cache = CodexLoginCache(checker: checker, successTTL: 60)
        let executable = URL(fileURLWithPath: "/bin/echo")

        let first = try await cache.status(executable: executable, now: Date(timeIntervalSince1970: 100))
        let cached = try await cache.status(executable: executable, now: Date(timeIntervalSince1970: 159))
        let refreshed = try await cache.status(executable: executable, now: Date(timeIntervalSince1970: 161))

        XCTAssertEqual(first, .chatGPT)
        XCTAssertEqual(cached, .chatGPT)
        XCTAssertEqual(refreshed, .notLoggedIn)
        let calls = await checker.callCount
        XCTAssertEqual(calls, 2)
    }

    func testFailureIsNeverCached() async throws {
        let checker = CountingLoginChecker(results: [.notLoggedIn, .chatGPT])
        let cache = CodexLoginCache(checker: checker, successTTL: 60)
        let executable = URL(fileURLWithPath: "/bin/echo")

        let first = try await cache.status(executable: executable, now: Date(timeIntervalSince1970: 100))
        let second = try await cache.status(executable: executable, now: Date(timeIntervalSince1970: 101))
        XCTAssertEqual(first, .notLoggedIn)
        XCTAssertEqual(second, .chatGPT)
        let calls = await checker.callCount
        XCTAssertEqual(calls, 2)
    }
}

private actor CountingLoginChecker: CodexLoginChecking {
    private var results: [CodexLoginStatus]
    private(set) var callCount = 0
    init(results: [CodexLoginStatus]) { self.results = results }
    func check(executable: URL) async throws -> CodexLoginStatus {
        callCount += 1
        return results.removeFirst()
    }
}
