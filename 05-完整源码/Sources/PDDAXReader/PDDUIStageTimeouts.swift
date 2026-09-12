import Foundation

enum PDDUIStage: String, CaseIterable, Codable, Sendable {
    case discovery
    case openConversation
    case capture
    case ocr
    case preflight
    case send
}

struct PDDUIStageTimeouts: Sendable {
    static let approved = Self()

    func innerSeconds(for stage: PDDUIStage) -> TimeInterval {
        switch stage {
        case .discovery: return 5
        case .openConversation: return 5
        case .capture: return 25
        case .ocr: return 20
        case .preflight: return 8
        case .send: return 15
        }
    }

    func outerFuseSeconds(for stage: PDDUIStage) -> TimeInterval {
        switch stage {
        case .discovery: return 8
        case .openConversation, .ocr: return 75
        case .capture: return 75
        case .preflight, .send: return 25
        }
    }

    func innerSeconds(forOperationNamed name: String) -> TimeInterval {
        let stage: PDDUIStage
        switch name {
        case "discover": stage = .discovery
        case "capture": stage = .capture
        case "preflight": stage = .preflight
        case "send": stage = .send
        default: stage = .ocr
        }
        return innerSeconds(for: stage)
    }

    func outerSeconds(forOperationNamed name: String) -> TimeInterval {
        switch name {
        case "discover": return outerFuseSeconds(for: .discovery)
        case "capture", "supplement": return outerFuseSeconds(for: .capture)
        case "send": return outerFuseSeconds(for: .send)
        default: return outerFuseSeconds(for: .ocr)
        }
    }
}
