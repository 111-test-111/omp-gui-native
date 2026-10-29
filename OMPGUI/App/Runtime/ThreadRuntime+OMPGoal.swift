import Foundation

struct OMPGoalComposerSubmission {
    let draft: ComposerDraft
    let budget: String
    var requestID: String?
}

extension ComposerDraft {
    /// /goal is a GUI input mode backed by Goal RPC, never a TUI command prompt.
    var ompGoalBody: ComposerDraft? {
        var body = self
        if command?.name == "goal" {
            body.command = nil
            return body
        }
        guard command == nil, text.hasPrefix("/goal") else { return nil }
        let remainder = text.dropFirst(5)
        guard remainder.isEmpty || remainder.first?.isWhitespace == true else { return nil }
        body.text = remainder.isEmpty ? "" : String(remainder.dropFirst())
        return body
    }
    var ompGoalObjective: String? { ompGoalBody?.outgoingText }
}

extension ThreadRuntime {
    static var goalDraftCommand: DraftCommand {
        DraftCommand(name: "goal", detail: "Use your next message as a native goal", isBuiltIn: true)
    }
    var supportsOMPGoalComposer: Bool { thread?.provider == .omp && thread?.hydra?.kind != .native }
    var isOMPGoalComposerMode: Bool { supportsOMPGoalComposer && draft.command?.name == "goal" }
    var canSuggestOMPGoalComposer: Bool {
        supportsOMPGoalComposer && ompCapabilities["goal"] != .unsupported && !ompCapabilities.goalIsDisabled
    }
    var ompGoalSummary: OMPGoal? { ompGoal.goal ?? ompGoal.completedGoal }
    var showsOMPGoalEntry: Bool {
        supportsOMPGoalComposer && (isOMPGoalComposerMode || ompGoalSummary != nil || ompGoal.pending != nil || ompGoalComposerWorking)
    }
    var isOMPGoalConnected: Bool { activeOMPSession != nil }
    var canChangeOMPGoal: Bool {
        isOMPGoalConnected && ompCapabilities["goal"] != .unsupported && !ompCapabilities.goalIsDisabled && ompGoal.pending == nil
            && !ompGoalControlWorking && !ompGoalComposerWorking && !ompGoal.hasUnrecognizedState
            && ompGoal.hasObservation && !ompGoal.observationIsStale && ompContext.pendingCommand == nil
    }

    func activateOMPGoalComposerMode() {
        guard supportsOMPGoalComposer else { return }
        draft.command = Self.goalDraftCommand
        ompGoalComposerError = nil
    }

    /// True means this input belongs to Goal, even when validation preserves it.
    /// Every normal send/steer/queue chord reaches this before native admission.
    @discardableResult
    func submitOMPGoalDraftIfNeeded() -> Bool {
        guard supportsOMPGoalComposer, let body = draft.ompGoalBody else { return false }
        if draft.command == nil {
            draft.text = body.text
            activateOMPGoalComposerMode()
        }
        let objective = body.outgoingText
        if objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.text = ""
            activateOMPGoalComposerMode()
            return true
        }
        guard !ompGoalComposerWorking, !ompGoalControlWorking, ompGoalComposerSubmission == nil, ompGoal.pending == nil else { return true }
        guard !ompCapabilities.goalIsDisabled else {
            ompGoalComposerError = Chrome.localized("Goal mode is disabled in OMP. Enable goal.enabled in OMP, then reconnect this conversation.")
            return true
        }
        guard draft.attachments.isEmpty else {
            ompGoalComposerError = Chrome.localized("Remove attachments before sending a goal.")
            return true
        }
        guard objective.utf8.count <= OMPGoalLimits.inputBytes else {
            ompGoalComposerError = Chrome.localized("Enter a goal within 128 KiB and an optional positive whole token budget.")
            return true
        }
        let budgetText = ompGoalBudgetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let budget = budgetText.isEmpty ? nil : OMPGoalLimits.tokenBudget(budgetText)
        guard budgetText.isEmpty || budget != nil else {
            ompGoalComposerError = Chrome.localized("Enter a positive whole token budget, or leave it empty.")
            return true
        }
        let submitted = draft
        ompGoalComposerSubmission = OMPGoalComposerSubmission(draft: submitted, budget: budgetText)
        ompGoalComposerWorking = true
        ompGoalComposerError = nil
        Task { [weak self] in
            guard let self else { return }
            defer { ompGoalComposerWorking = false }
            do {
                try await withOMPGoalSubmissionSession { native in
                    try await native.refreshGoal()
                    let initial = try await native.createGoalFromComposer(objective: objective, tokenBudget: budget)
                    if let initial {
                        submitOMPGoalPrompt(ComposerDraft(text: objective), native: native,
                            goalID: initial.goalID, runGeneration: initial.runGeneration)
                    }
                }
            } catch {
                // Snapshot-owned uncertainty can be cleared by its late reply;
                // it must not survive as a second local error or resend trigger.
                if ompGoal.pending == nil {
                    ompGoalComposerError = ompGoal.error == nil
                        ? TextCleanup.utf8Prefix(error.localizedDescription, maximumBytes: OMPGoalLimits.errorBytes) : nil
                    ompGoalComposerSubmission = nil
                }
            }
        }
        return true
    }

    func observeOMPGoalConfirmation(_ value: OMPGoalSnapshot, previous: OMPGoalSnapshot) {
        guard var submission = ompGoalComposerSubmission else { return }
        if submission.requestID == nil, value.pending?.operation == .create {
            submission.requestID = value.pending?.requestID
            ompGoalComposerSubmission = submission
        }
        guard let requestID = submission.requestID, previous.pending?.requestID == requestID,
              value.pending == nil else { return }
        if value.error == nil, !value.observationIsStale {
            if draft == submission.draft { draft = ComposerDraft() }
            if ompGoalBudgetDraft.trimmingCharacters(in: .whitespacesAndNewlines) == submission.budget { ompGoalBudgetDraft = "" }
            ompGoalComposerError = nil
        }
        ompGoalComposerSubmission = nil
    }

    func refreshOMPGoal() async throws {
        try await withActiveOMPSession { try await $0.refreshGoal() }
    }

    func changeOMPGoal(_ operation: OMPGoalOperation, expectedGoalID: String) async throws {
        guard !ompGoalControlWorking else {
            throw ProviderError.failed(Chrome.localized("Wait for OMP to confirm the pending native action."))
        }
        ompGoalControlWorking = true
        defer { ompGoalControlWorking = false }
        try await withActiveOMPSession { native in
            if operation == .resume {
                if let resumed = try await native.resumeGoalFromUser(expectedGoalID: expectedGoalID) {
                    submitOMPGoalPrompt(ComposerDraft(text: Chrome.localized("Continue working on the current goal.")), native: native,
                        goalID: resumed.goalID, runGeneration: resumed.runGeneration)
                }
            } else {
                try await native.performGoalOperation(operation, expectedGoalID: expectedGoalID)
            }
        }
    }
}
