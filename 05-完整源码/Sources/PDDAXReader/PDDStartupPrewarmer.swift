import Foundation

struct PDDStartupPrewarmer: Sendable {
    let warmOCR: @Sendable () async throws -> Void
    let warmKnowledge: @Sendable () async throws -> Void
    let warmSenseVoice: @Sendable () async throws -> Void
    let checkCodex: @Sendable () async throws -> Void

    func prepare() async throws {
        try await warmOCR()
        try await warmKnowledge()
        try await warmSenseVoice()
        try await checkCodex()
    }
}
