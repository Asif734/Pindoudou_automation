import CryptoKit
import Foundation

enum AutoReplyRevisionError: Error, Equatable {
    case invalidDigest
}

struct AutoReplyRevision: Codable, Equatable, Hashable, Sendable {
    let digest: String
    let ordinal: Int

    init(digest: String, ordinal: Int) throws {
        guard digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw AutoReplyRevisionError.invalidDigest
        }
        self.digest = digest
        self.ordinal = max(1, ordinal)
    }

    static func derived(from capture: AutoReplyCapture, legacyOrdinal: Int) throws -> Self {
        let cursorDigest = capture.batch?.endCursor.digest ?? capture.customerCursor.digest
        let digest = capture.batch?.incomingHandoffKey.map { key in
            SHA256.hash(data: Data("\(cursorDigest)\n\(key)".utf8))
                .map { String(format: "%02x", $0) }.joined()
        } ?? cursorDigest
        return try Self(
            digest: digest,
            ordinal: legacyOrdinal
        )
    }
}
