import Foundation
import Observation

enum OMPRequestResolution: Sendable { case delivered, cancelled, timedOut, disconnected }

struct OMPRequestIdentity: Equatable, Sendable {
    var threadID: UUID
    var generation: Int
    var sessionID: String?
    var nativeID: String
    var instanceID: UUID
}

/// One live request shared by windows displaying its conversation.
/// No responses or drafts are persisted or replayed into another native process.
@MainActor @Observable
final class OMPInteraction: Identifiable {
    enum State: Sendable { case waiting, submitting, delivered, deliveryUnknown, cancelled, timedOut, disconnected }
    private(set) var identity: OMPRequestIdentity
    var id: UUID { identity.instanceID }
    let question: QuestionRequest?
    let approval: ApprovalRequest?
    private(set) var state: State = .waiting
    var draft: QuestionDraft

    init(identity: OMPRequestIdentity, question: QuestionRequest? = nil, approval: ApprovalRequest? = nil) {
        self.identity = identity
        self.question = question
        self.approval = approval
        draft = QuestionDraft(question ?? QuestionRequest(id: identity.nativeID, questions: []))
    }

    var deadline: Date? { question?.deadline ?? approval?.deadline }
    var canSubmit: Bool { state == .waiting && deadline.map { $0 > .now } != false }
    var isActive: Bool { state == .waiting || state == .submitting || state == .deliveryUnknown }

    /// Startup dialogs may precede the first native identity snapshot. Only an
    /// unidentified request in the same live generation may adopt that identity.
    func bindNativeSessionIfUnknown(_ sessionID: String) {
        guard isActive, identity.sessionID == nil, !sessionID.isEmpty else { return }
        identity.sessionID = sessionID
    }

    @discardableResult func beginSubmission() -> Bool {
        guard canSubmit else {
            if state == .waiting { resolve(.timedOut) }
            return false
        }
        state = .submitting
        return true
    }

    func reportDelivery(_ delivered: Bool) {
        guard state == .submitting else { return }
        if delivered { resolve(.delivered) }
        else { state = .deliveryUnknown; draft.isSubmitting = false }
    }

    func resolve(_ reason: OMPRequestResolution) {
        guard isActive else { return }
        switch reason {
        case .delivered: state = .delivered; draft.clearSubmittedValues()
        case .cancelled: state = .cancelled
        case .timedOut: state = .timedOut
        case .disconnected: state = .disconnected
        }
        draft.isSubmitting = false
    }
}
