import CryptoKit
import Foundation
import ImageIO

struct PDDImageDataResponse: Sendable {
    let data: Data
    let statusCode: Int
    let mimeType: String?
    let finalURL: URL
}

protocol PDDImageDataLoading: Sendable {
    func load(_ url: URL, maximumBytes: Int) async throws -> PDDImageDataResponse
}

final class URLSessionPDDImageDataLoader: PDDImageDataLoading, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func load(_ url: URL, maximumBytes: Int) async throws -> PDDImageDataResponse {
        let (data, response) = try await session.data(from: url)
        if data.count > maximumBytes { throw PDDCustomerImageError.tooLarge }
        guard let http = response as? HTTPURLResponse else {
            throw PDDCustomerImageError.invalidHTTPStatus(0)
        }
        return PDDImageDataResponse(
            data: data,
            statusCode: http.statusCode,
            mimeType: http.mimeType,
            finalURL: http.url ?? url
        )
    }
}

struct PDDCustomerImageDownloader: PDDCustomerImageDownloading, Sendable {
    private let loader: any PDDImageDataLoading
    private let maximumBytes: Int

    init(
        loader: any PDDImageDataLoading = URLSessionPDDImageDataLoader(),
        maximumBytes: Int = 20 * 1024 * 1024
    ) {
        self.loader = loader
        self.maximumBytes = maximumBytes
    }

    func download(
        sourceURL: URL,
        destinationDirectory: URL,
        messageID: String
    ) async throws -> AutoReplyImageAttachment {
        let response: PDDImageDataResponse
        if sourceURL.isFileURL {
            let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw PDDCustomerImageError.invalidImageData }
            if let size = values.fileSize, size > maximumBytes { throw PDDCustomerImageError.tooLarge }
            let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
            if data.count > maximumBytes { throw PDDCustomerImageError.tooLarge }
            response = PDDImageDataResponse(
                data: data, statusCode: 200, mimeType: nil, finalURL: sourceURL
            )
        } else {
            guard let scheme = sourceURL.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                throw PDDCustomerImageError.invalidPreviewURL
            }
            response = try await loader.load(sourceURL, maximumBytes: maximumBytes)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw PDDCustomerImageError.invalidHTTPStatus(response.statusCode)
        }
        guard let normalized = PDDImageNormalizer.normalize(
            data: response.data, maximumBytes: maximumBytes
        ) else {
            if response.data.count > maximumBytes { throw PDDCustomerImageError.tooLarge }
            throw PDDCustomerImageError.invalidImageData
        }

        let digest = SHA256.hash(data: normalized.data).map { String(format: "%02x", $0) }.joined()
        let safeID = messageID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        let filename = "\(String(safeID))-\(digest.prefix(12)).\(normalized.extensionName)"
        try FileManager.default.createDirectory(
            at: destinationDirectory, withIntermediateDirectories: true
        )
        let destination = destinationDirectory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: destination.path) {
            let temporary = destinationDirectory.appendingPathComponent(".tmp-\(UUID().uuidString)")
            do {
                try normalized.data.write(to: temporary, options: .atomic)
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
        return AutoReplyImageAttachment(
            messageID: messageID,
            sourceURL: response.finalURL,
            localURL: destination,
            mimeType: normalized.mimeType,
            byteCount: normalized.data.count,
            sha256: digest
        )
    }
}
