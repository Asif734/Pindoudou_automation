import Foundation

enum PDDUnlimitedVideoDownloadSessionPolicy {
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return configuration
    }
}

enum PDDUnlimitedVideoDownloadPolicy {
    static func accepts(byteCount: Int64) -> Bool { byteCount > 0 }
}

private final class PDDVideoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              PDDVideoHostPolicy.accepts(url.host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct PDDUnlimitedVideoDownloadClient: Sendable {
    func download(from sourceURL: URL, to partialURL: URL) async throws -> URL {
        try Task.checkCancellation()
        guard sourceURL.scheme?.lowercased() == "https",
              PDDVideoHostPolicy.accepts(sourceURL.host) else {
            throw PDDCustomerVideoError.downloadRejected
        }

        let delegate = PDDVideoRedirectDelegate()
        let session = URLSession(
            configuration: PDDUnlimitedVideoDownloadSessionPolicy.makeConfiguration(),
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        do {
            let (temporary, response) = try await session.download(from: sourceURL)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  PDDVideoDownloadPolicy.accepts(
                    statusCode: http.statusCode,
                    mimeType: response.mimeType
                  ),
                  let finalURL = response.url,
                  finalURL.scheme?.lowercased() == "https",
                  PDDVideoHostPolicy.accepts(finalURL.host) else {
                throw PDDCustomerVideoError.downloadRejected
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard PDDUnlimitedVideoDownloadPolicy.accepts(byteCount: byteCount) else {
                throw PDDCustomerVideoError.invalidMedia
            }
            try FileManager.default.createDirectory(
                at: partialURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: partialURL.path) {
                try FileManager.default.removeItem(at: partialURL)
            }
            try FileManager.default.moveItem(at: temporary, to: partialURL)
            return partialURL
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PDDCustomerVideoError {
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            try? FileManager.default.removeItem(at: partialURL)
            throw PDDCustomerVideoError.downloadFailed
        }
    }
}
