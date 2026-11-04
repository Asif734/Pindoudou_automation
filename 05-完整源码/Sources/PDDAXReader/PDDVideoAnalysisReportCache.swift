import CryptoKit
import Foundation

/// Observations about media only; never a saved customer reply or a product-policy answer.
struct PDDVideoAnalysisReport: Codable, Equatable, Sendable {
    let sha256: String
    let observations: String
    let limitations: String
}

struct PDDReusedVideoAnalysis: Equatable, Sendable {
    let video: AutoReplyVideoAttachment
    let report: PDDVideoAnalysisReport
}

struct PDDVideoAnalysisReportCache {
    private struct Entry: Codable {
        let version: Int
        let uid: String
        let model: String
        let byteCount: Int64
        let durationSeconds: Double
        let width: Int
        let height: Int
        let report: PDDVideoAnalysisReport
    }

    let root: URL

    func reusingReports(in submission: HistorySubmission, uid: String) -> HistorySubmission {
        var result = submission
        result.videoAttachments = submission.videoAttachments.filter { video in
            guard let report = load(uid: uid, video: video) else { return true }
            result.reusedVideoAnalyses.append(.init(video: video, report: report))
            return false
        }
        return result
    }

    func save(_ reports: [PDDVideoAnalysisReport], uid: String, analyzedVideos: [AutoReplyVideoAttachment]) throws {
        for report in reports where valid(report) {
            guard let video = analyzedVideos.first(where: { $0.sha256 == report.sha256 }) else { continue }
            let entry = Entry(version: 1, uid: uid, model: CodexInvocation.model,
                byteCount: video.byteCount, durationSeconds: video.durationSeconds,
                width: video.width, height: video.height, report: report)
            let url = path(uid: uid, sha256: video.sha256)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: url, options: .atomic)
        }
    }

    private func load(uid: String, video: AutoReplyVideoAttachment) -> PDDVideoAnalysisReport? {
        guard !video.sha256.isEmpty,
              let data = try? Data(contentsOf: path(uid: uid, sha256: video.sha256)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == 1, entry.uid == uid, entry.model == CodexInvocation.model,
              entry.report.sha256 == video.sha256, valid(entry.report),
              entry.byteCount == video.byteCount, entry.durationSeconds == video.durationSeconds,
              entry.width == video.width, entry.height == video.height else { return nil }
        return entry.report
    }

    private func valid(_ report: PDDVideoAnalysisReport) -> Bool {
        !report.sha256.isEmpty && !report.observations.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && report.observations.utf8.count <= 12_000 && report.limitations.utf8.count <= 4_000
    }

    private func path(uid: String, sha256: String) -> URL {
        func digest(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return root.appendingPathComponent("video-analysis-reports", isDirectory: true)
            .appendingPathComponent(digest(uid), isDirectory: true)
            .appendingPathComponent(digest(sha256) + ".json")
    }
}
