import Foundation

@MainActor
protocol PDDOCRSupplementing: AnyObject {
    func messages(uid: String) async throws -> [PDDOCRMessage]
}

@MainActor
final class PDDLiveOCRSupplement: PDDOCRSupplementing {
    private let capture: any PDDOCRCapturing
    private let engine: any PDDOCRRecognizing

    init(
        capture: (any PDDOCRCapturing)? = nil,
        engine: (any PDDOCRRecognizing)? = nil
    ) {
        self.capture = capture ?? PDDWindowOCRCapture()
        self.engine = engine ?? PDDPaddleOCREngine()
    }

    func messages(uid: String) async throws -> [PDDOCRMessage] {
        let frame = try await capture.capture()
        let lines = try await engine.recognize(frame.image)
        return PDDOCRChatParser.parse(
            uid: uid,
            lines: lines,
            imageSize: CGSize(width: frame.image.width, height: frame.image.height)
        )
    }
}
