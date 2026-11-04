import Foundation

enum PDDBackgroundVideoRecoveryAction: Equatable, Sendable {
    case prepareEvidence(uid: String, messageID: String, stableURL: URL)
    case reopen(uid: String, messageID: String)
}

enum PDDBackgroundVideoRecovery {
    static func transferDirectory(root: URL, key: PDDVideoTransferKey) -> URL {
        root.appendingPathComponent("transfers", isDirectory: true)
            .appendingPathComponent(key.customerHash, isDirectory: true)
            .appendingPathComponent(key.messageHash, isDirectory: true)
    }

    static func stableVideoURL(root: URL, key: PDDVideoTransferKey) -> URL {
        let directory = transferDirectory(root: root, key: key)
        let legacy = directory.appendingPathComponent("video.mp4")
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        let suffix = "_\(key.messageHash.prefix(12)).mp4"
        let saved = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        let match = saved.filter {
            $0.lastPathComponent.hasPrefix("video_") && $0.lastPathComponent.hasSuffix(suffix)
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }.last
        return match.map { directory.appendingPathComponent($0.lastPathComponent) } ?? legacy
    }

    static func timestampedFileName(key: PDDVideoTransferKey, savedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return "video_\(formatter.string(from: savedAt))_\(key.messageHash.prefix(12)).mp4"
    }

    static func savedVideoURL(root: URL, key: PDDVideoTransferKey, savedAt: Date = Date()) -> URL {
        let existing = stableVideoURL(root: root, key: key)
        if FileManager.default.fileExists(atPath: existing.path) { return existing }
        return transferDirectory(root: root, key: key)
            .appendingPathComponent(timestampedFileName(key: key, savedAt: savedAt))
    }

    static func partialVideoURL(root: URL, key: PDDVideoTransferKey) -> URL {
        transferDirectory(root: root, key: key).appendingPathComponent("video.partial.mp4")
    }

    static func action(
        root: URL, uid: String, messageID: String,
        fileManager: FileManager = .default
    ) -> PDDBackgroundVideoRecoveryAction {
        let key = PDDVideoTransferKey(uid: uid, messageID: messageID)
        let stable = stableVideoURL(root: root, key: key)
        if fileManager.fileExists(atPath: stable.path) {
            return .prepareEvidence(uid: uid, messageID: messageID, stableURL: stable)
        }
        let partial = partialVideoURL(root: root, key: key)
        if fileManager.fileExists(atPath: partial.path) {
            try? fileManager.removeItem(at: partial)
        }
        return .reopen(uid: uid, messageID: messageID)
    }

    static func resumeStableVideo(
        root: URL,
        uid: String,
        messageID: String,
        stableURL: URL,
        analysisInbox: PDDVideoAnalysisInbox,
        speechTranscriber: any PDDVideoSpeechTranscribing = PDDAppleVideoSpeechTranscriber(),
        recovered: Bool = false,
        failureHandler: (@Sendable (Error) async -> Void)? = nil,
        eventHandler: @escaping @Sendable (PDDVideoTransferEvent) async -> Void
    ) async {
        let key = PDDVideoTransferKey(uid: uid, messageID: messageID)
        do {
            let summary = try await PDDVideoFileInspector.inspect(stableURL)
            let receipt = PDDDownloadedCustomerVideo(
                uid: uid, messageID: messageID, key: key,
                fileURL: stableURL, summary: summary
            )
            _ = try await analysisInbox.claim(receipt)
            await eventHandler(.init(uid: uid, messageID: messageID, phase: .downloaded))
            await eventHandler(.init(uid: uid, messageID: messageID, phase: .preparingEvidence))
            let preparer = PDDCustomerVideoEvidencePreparer(
                rootURL: root.appendingPathComponent("evidence", isDirectory: true)
                    .appendingPathComponent(key.customerHash, isDirectory: true),
                transcriber: speechTranscriber
            )
            let attachment = try await withOperationDeadline(
                .seconds(90), stage: "video-evidence"
            ) {
                try await preparer.prepare(download: receipt)
            }
            await eventHandler(.init(
                uid: uid, messageID: messageID, phase: .readyForGeneration,
                attachment: attachment, diagnostic: attachment.diagnostic, recovered: recovered
            ))
        } catch is CancellationError {
            return
        } catch {
            await failureHandler?(error)
            await eventHandler(.init(
                uid: uid, messageID: messageID, phase: .failed,
                diagnostic: error.localizedDescription
            ))
        }
    }
}
