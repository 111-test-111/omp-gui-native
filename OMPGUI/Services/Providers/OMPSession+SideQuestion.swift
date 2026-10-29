import Foundation

extension OMPSession {
    var sideQuestionSnapshot: OMPSideQuestionSnapshot { sideQuestions.snapshot }
    var isDraining: Bool { rpc.isDraining }

    func askSideQuestion(_ text: String, continuing: Bool, requestID: String) async throws {
        guard !nativeHistoryTransitionInFlight, contextSnapshot.pendingRequestID == nil else {
            throw ProviderError.failed(AppText.localized("Wait for the native session change before asking a side question."))
        }
        try await sideQuestions.ask(text, continuing: continuing, requestID: requestID)
    }

    func cancelSideQuestion() async throws {
        try await sideQuestions.cancel()
    }

    /// Automatic recycling alone uses stdin EOF. Explicit Stop keeps its forceful semantics.
    func beginSideQuestionDrain() -> Bool {
        guard nativeActivity.canRecycle else { return false }
        return sideQuestions.beginDrain()
    }
}
