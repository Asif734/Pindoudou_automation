import Foundation

struct PDDAppleThenFallbackVideoSpeechTranscriber: PDDVideoSpeechTranscribing {
    let primary: any PDDVideoSpeechTranscribing
    let fallback: any PDDVideoSpeechTranscribing

    func transcribe(_ mediaURL: URL) async -> [PDDVideoTranscriptSegment] {
        let primaryResult = await primary.transcribe(mediaURL)
        guard Self.requiresFallback(primaryResult) else { return primaryResult }
        return await fallback.transcribe(mediaURL)
    }

    static func requiresFallback(_ segments: [PDDVideoTranscriptSegment]) -> Bool {
        let text = segments.map(\.text).joined()
        let normalized = text.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(String.init).joined()
        return normalized.isEmpty || normalized == "1110"
    }
}
