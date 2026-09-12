import Foundation
import Speech

enum PDDVideoSpeechAuthorizationAction: Equatable {
    case transcribe
    case requestAuthorization
    case skipTranscript
}

enum PDDVideoSpeechAuthorizationPolicy {
    static func action(
        for status: SFSpeechRecognizerAuthorizationStatus
    ) -> PDDVideoSpeechAuthorizationAction {
        switch status {
        case .authorized: return .transcribe
        case .notDetermined: return .requestAuthorization
        case .denied, .restricted: return .skipTranscript
        @unknown default: return .skipTranscript
        }
    }
}

private final class PDDVideoSpeechResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<[PDDVideoTranscriptSegment], Never>?
    private var task: SFSpeechRecognitionTask?

    func install(_ continuation: CheckedContinuation<[PDDVideoTranscriptSegment], Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func install(_ task: SFSpeechRecognitionTask) {
        lock.withLock { self.task = task }
    }

    func finish(_ value: [PDDVideoTranscriptSegment]) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let task = self.task
        self.continuation = nil
        self.task = nil
        lock.unlock()
        task?.cancel()
        continuation?.resume(returning: value)
    }
}

struct PDDAppleVideoSpeechTranscriber: PDDVideoSpeechTranscribing {
    let locale: Locale
    let timeout: TimeInterval

    init(locale: Locale = Locale(identifier: "zh-CN"), timeout: TimeInterval = 45) {
        self.locale = locale
        self.timeout = timeout
    }

    private func authorizationGranted() async -> Bool {
        switch PDDVideoSpeechAuthorizationPolicy.action(
            for: SFSpeechRecognizer.authorizationStatus()
        ) {
        case .transcribe:
            return true
        case .requestAuthorization:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization {
                    continuation.resume(returning: $0 == .authorized)
                }
            }
        case .skipTranscript:
            return false
        }
    }

    func transcribe(_ mediaURL: URL) async -> [PDDVideoTranscriptSegment] {
        guard await authorizationGranted(),
              let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable else { return [] }
        let request = SFSpeechURLRecognitionRequest(url: mediaURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let box = PDDVideoSpeechResultBox()
        return await withCheckedContinuation { continuation in
            box.install(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    box.finish(result.bestTranscription.segments.compactMap { segment in
                        let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                        return text.isEmpty ? nil : PDDVideoTranscriptSegment(
                            startSeconds: segment.timestamp,
                            durationSeconds: segment.duration,
                            text: text
                        )
                    })
                } else if error != nil {
                    box.finish([])
                }
            }
            box.install(task)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                box.finish([])
            }
        }
    }
}
