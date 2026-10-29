import Foundation

extension ThreadRuntime {
    var canAskOMPSideQuestion: Bool {
        thread?.provider == .omp && thread?.hydra?.kind != .native && !historyRecoveryBlocked
            && !isReverting && !isLoadingHistory && ompContext.pendingCommand == nil
            && activeOMPSession?.isRunning == true && activeOMPSession?.isDraining == false
            && ompCapabilities["btw"] != .unsupported && !ompSideQuestion.hasLiveWork
    }

    func submitOMPSideQuestion(continuing: Bool) {
        guard canAskOMPSideQuestion, !continuing || ompSideQuestion.canFollowUp,
              sideQuestionSubmission == nil else { return }
        let text = sideQuestionDraft.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= OMPSideQuestionSnapshot.maximumInputBytes else {
            sideQuestionDraft.error = Chrome.localized("Enter a side question of at most 128 KiB.")
            return
        }
        let id = UUID().uuidString
        sideQuestionSubmission = (id, text)
        sideQuestionDraft.error = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await withActiveOMPSession { native in
                    try await native.askSideQuestion(text, continuing: continuing, requestID: id)
                }
            } catch {
                if sideQuestionSubmission?.id == id {
                    if ompSideQuestion.pendingRequestID != id {
                        if ompSideQuestion.error == nil {
                            sideQuestionDraft.error = OMPSideQuestionSnapshot.suffix(error.localizedDescription, bytes: 8 * 1_024)
                        }
                        sideQuestionSubmission = nil
                    }
                }
            }
        }
    }

    func cancelOMPSideQuestion() {
        guard activeOMPSession?.isDraining == false, ompSideQuestion.hasLiveWork,
              ompSideQuestion.pendingCancellationID == nil else { return }
        sideQuestionDraft.error = nil
        Task { [weak self] in
            guard let self else { return }
            do { try await withActiveOMPSession { try await $0.cancelSideQuestion() } }
            catch {
                if ompSideQuestion.pendingCancellationID == nil && ompSideQuestion.error == nil {
                    sideQuestionDraft.error = OMPSideQuestionSnapshot.suffix(error.localizedDescription, bytes: 8 * 1_024)
                }
            }
        }
    }

    func installOMPSideQuestion(_ value: OMPSideQuestionSnapshot) {
        ompSideQuestion = value
        if let submitted = sideQuestionSubmission {
            if value.acceptedRequestID == submitted.id {
                if sideQuestionDraft.text == submitted.text { sideQuestionDraft.text = "" }
                sideQuestionSubmission = nil
                sideQuestionDraft.error = nil
            } else if value.rejectedRequestID == submitted.id {
                sideQuestionSubmission = nil
            }
        }
    }
}

/// Shared by every window showing this runtime; never written to the GUI library.
@MainActor
@Observable
final class OMPSideQuestionDraft {
    var text = ""
    var error: String?
}
