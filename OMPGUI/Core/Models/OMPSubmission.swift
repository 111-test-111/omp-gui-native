import Foundation

/// Delivery is selected by the user; OMP owns when admitted messages execute.
enum OMPMessageDelivery: String, Codable, Hashable, Sendable {
    case prompt, steer, followUp, stopAndSend

    var title: String {
        switch self {
        case .prompt: "Send"
        case .steer: "Supplement current task"
        case .followUp: "After current task"
        case .stopAndSend: "Stop and send"
        }
    }

    var command: String {
        switch self {
        case .prompt: "prompt"
        case .steer: "steer"
        case .followUp: "follow_up"
        case .stopAndSend: "abort_and_prompt"
        }
    }
}

/// Consumed means OMP emitted the user message, rather than successful model work.
enum OMPSubmissionState: String, Codable, Hashable, Sendable {
    case draft, submitting, accepted, consumed, finished, failed, unknown

    var isEditable: Bool { self == .draft || self == .failed }
    /// Native completion can be confirmed even when templates changed the text.
    var isTerminal: Bool { self == .consumed || self == .finished }
    var title: String {
        switch self {
        case .draft: "Not submitted"
        case .submitting: "Submitting to OMP…"
        case .accepted: "Accepted by OMP"
        case .consumed: "Consumed by OMP"
        case .finished: "Finished by OMP"
        case .failed: "Submission failed"
        case .unknown: "Delivery unknown"
        }
    }
}
