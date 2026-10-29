import Foundation

extension OMPSession {
    /// A single user submission creates the goal. Native continuation wins over
    /// an initial ordinary prompt, including a turn that finished before our read.
    /// Missing settlement evidence never grants permission to send another turn.
    func createGoalFromComposer(objective: String, tokenBudget: Int?) async throws -> (goalID: String, runGeneration: Int)? {
        let before = try await readState(timeout: .seconds(5))
        let wasIdle = before["isSettled"]?.bool == true && nativeActivity.canRecycle
        let run = goalRunGeneration
        try await performGoalOperation(.create, objective: objective, tokenBudget: tokenBudget,
            expectedGoalID: goalSnapshot.goal?.id)
        guard let goal = goalSnapshot.goal, goal.status == .active else { return nil }
        let after = try? await readState(timeout: .seconds(5))
        guard wasIdle, goalRunGeneration == run, after?["isSettled"]?.bool == true,
              canStartGoalPrompt(goalID: goal.id, runGeneration: run) else { return nil }
        return (goal.id, run)
    }

    /// Resuming is one explicit user action, just like creating a goal. Offer
    /// one ordinary prompt only when native settlement proves no work was
    /// scheduled or started. A late confirmation never replays this action.
    func resumeGoalFromUser(expectedGoalID: String) async throws -> (goalID: String, runGeneration: Int)? {
        let before = try await readState(timeout: .seconds(5))
        let wasIdle = before["isSettled"]?.bool == true && nativeActivity.canRecycle
        let run = goalRunGeneration
        try await performGoalOperation(.resume, expectedGoalID: expectedGoalID)
        let after = try? await readState(timeout: .seconds(5))
        guard wasIdle, goalRunGeneration == run, after?["isSettled"]?.bool == true,
              canStartGoalPrompt(goalID: expectedGoalID, runGeneration: run) else { return nil }
        return (expectedGoalID, run)
    }

    func canStartGoalPrompt(goalID: String, runGeneration: Int) -> Bool {
        isRunning && !isDraining && nativeActivity.canRecycle && goalRunGeneration == runGeneration
            && goalSnapshot.pending == nil && !goalSnapshot.hasUnrecognizedState
            && goalSnapshot.goal?.id == goalID && goalSnapshot.goal?.status == .active
    }

    /// An on-demand read, shared by visible consumers. It never starts a process
    /// or a model turn and is the only goal capability discovery request.
    func refreshGoal(requiringFreshRead: Bool = false) async throws {
        guard isRunning else { throw ProviderError.notRunning }
        guard capabilities["goal"] != .unsupported else { throw goalUnsupported() }
        if let read = goalRead {
            try await read.task.value
            guard requiringFreshRead else { return }
            // A control must not reuse a read that began before the click.
            // Visible readers still share their normal on-demand request.
            if goalRead?.id == read.id { goalRead = nil }
        }
        let id = UUID()
        let generation = goalGeneration
        let revision = goalSnapshot.revision
        let task = Task { [weak self] in
            guard let self else { throw ProviderError.notRunning }
            do {
                let value = try await rpc.request("goal", fields: ["op": "get"], timeout: .seconds(5))
                guard isRunning, generation == goalGeneration else { throw CancellationError() }
                guard let reply = OMPGoalReply(value) else { throw goalInvalidReply() }
                goalSnapshot.accept(reply, revision: revision)
                goalSnapshot.setError(nil)
                publishGoal()
                if goalNeedsSettlement { _ = try? await readState(timeout: .seconds(5)) }
            } catch {
                guard isRunning, generation == goalGeneration else { throw error }
                goalSnapshot.setError(error.localizedDescription)
                publishGoal()
                throw error
            }
        }
        goalRead = (id, task)
        defer { if goalRead?.id == id { goalRead = nil } }
        try await task.value
    }

    func performGoalOperation(_ operation: OMPGoalOperation, objective: String? = nil, tokenBudget: Int? = nil,
                              expectedGoalID: String?, timeout: Duration = .seconds(30)) async throws {
        guard isRunning else { throw ProviderError.notRunning }
        guard capabilities["goal"] != .unsupported else { throw goalUnsupported() }
        guard !capabilities.goalIsDisabled else {
            throw ProviderError.failed(AppText.localized("Goal mode is disabled in OMP. Enable goal.enabled in OMP, then reconnect this conversation."))
        }
        guard goalSnapshot.pending == nil, contextSnapshot.pendingRequestID == nil,
              !nativeHistoryTransitionInFlight else {
            throw ProviderError.failed(AppText.localized("Wait for OMP to confirm the pending native action."))
        }
        // This is a local stale-view fence. The native API addresses the current
        // goal singleton and exposes no expected-id/atomic compare-and-swap.
        guard goalSnapshot.hasObservation, !goalSnapshot.observationIsStale,
              goalSnapshot.goal?.id == expectedGoalID else {
            throw ProviderError.failed(AppText.localized("The native goal changed. Refresh it before choosing an action."))
        }
        // Re-read immediately before applying a control. This catches native
        // tool changes absent from the visible snapshot; the public API still
        // cannot make the read and mutation an atomic expected-ID operation.
        let generation = goalGeneration
        try await refreshGoal(requiringFreshRead: true)
        guard isRunning, generation == goalGeneration else { throw CancellationError() }
        guard !capabilities.goalIsDisabled else {
            throw ProviderError.failed(AppText.localized("Goal mode is disabled in OMP. Enable goal.enabled in OMP, then reconnect this conversation."))
        }
        guard goalSnapshot.pending == nil, contextSnapshot.pendingRequestID == nil,
              !nativeHistoryTransitionInFlight else {
            throw ProviderError.failed(AppText.localized("Wait for OMP to confirm the pending native action."))
        }
        guard goalSnapshot.hasObservation, !goalSnapshot.observationIsStale,
              goalSnapshot.goal?.id == expectedGoalID else {
            throw ProviderError.failed(AppText.localized("The native goal changed. Refresh it before choosing an action."))
        }
        guard !goalSnapshot.hasUnrecognizedState else {
            throw ProviderError.failed(AppText.localized("OMP reported an unfamiliar goal state. Update OMP GUI before changing this goal."))
        }
        var fields: [String: JSONValue] = ["op": .string(operation.rawValue)]
        if operation == .create {
            let text = objective ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= OMPGoalLimits.inputBytes,
                  tokenBudget == nil || (tokenBudget! > 0 && tokenBudget! <= OMPGoalLimits.maxTokenBudget) else {
                throw ProviderError.failed(AppText.localized("Enter a goal within 128 KiB and an optional positive whole token budget."))
            }
            guard goalSnapshot.goal == nil || goalSnapshot.goal?.status.isTerminal == true else {
                throw ProviderError.failed(AppText.localized("Resume or drop the current goal before creating another."))
            }
            fields["objective"] = .string(text)
            if let tokenBudget { fields["token_budget"] = .int(tokenBudget) }
        } else {
            guard let goal = goalSnapshot.goal, !goal.status.isTerminal else {
                throw ProviderError.failed(AppText.localized("There is no current native goal for this action."))
            }
            if operation == .resume, goal.status != .paused {
                throw ProviderError.failed(AppText.localized("Only a paused native goal can be resumed."))
            }
            if operation == .resume, goal.hasReachedTokenBudget {
                throw ProviderError.failed(AppText.localized("This goal has used its token budget. Drop it and create a new goal with a new budget; usage starts at zero."))
            }
        }
        let id = UUID().uuidString
        stateRevision += 1 // Never reuse a state read started before this mutation.
        goalSnapshot.begin(operation, id: id, expectedGoalID: expectedGoalID)
        goalNeedsSettlement = true
        publishGoal()
        publishActivity()
        do {
            let response = try await rpc.response("goal", fields: fields, id: id, timeout: timeout)
            guard isRunning, generation == goalGeneration else { throw CancellationError() }
            try finishGoalResponse(response, id: id)
            // Goal create/resume may schedule a native turn before agent_start.
            // Ask OMP about settlement; the goal's presence alone proves no work.
            _ = try? await readState(timeout: .seconds(5))
        } catch {
            guard isRunning, generation == goalGeneration else { throw error }
            if goalSnapshot.pending?.requestID == id {
                goalSnapshot.markUnknown(id: id, error: AppText.localized("OMP has not confirmed the goal action. Its outcome is unknown; it will not be sent again automatically."))
                publishGoal()
                publishActivity()
            } else {
                _ = try? await readState(timeout: .seconds(5))
            }
            throw error
        }
    }

    func observeGoalState(_ state: JSONValue, revision: UInt64) {
        guard goalSnapshot.revision == revision,
              sessionFile.isEmpty || state["sessionFile"]?.string == sessionFile else { return }
        let previous = goalSnapshot
        _ = goalSnapshot.observeState(state["goal"])
        if goalSnapshot != previous { publishGoal() }
    }

    func observeGoalFrame(_ frame: JSONValue) {
        if frame["type"]?.string == "session_settled", goalSnapshot.pending == nil { goalNeedsSettlement = false }
        if frame["type"]?.string == "goal_updated" {
            _ = goalSnapshot.observeEvent(frame)
            publishGoal()
        }
        // Timed-out requests no longer have an RPC waiter, but their matching
        // late response still resolves the operation. It never starts another.
        if frame["type"]?.string == "response", frame["command"]?.string == "goal",
           let pending = goalSnapshot.pending, frame["id"]?.string == pending.requestID {
            _ = try? finishGoalResponse(frame, id: pending.requestID)
            Task { [weak self] in _ = try? await self?.readState(timeout: .seconds(5)) }
        }
    }

    func resetGoalObservation() {
        goalGeneration = UUID()
        goalRead?.task.cancel()
        goalRead = nil
        goalSnapshot = OMPGoalSnapshot()
        goalNeedsSettlement = false
        publishGoal()
    }

    func disconnectGoalObservation() {
        goalGeneration = UUID()
        goalRead?.task.cancel()
        goalRead = nil
        goalSnapshot.disconnect()
        goalNeedsSettlement = false
        publishGoal()
    }

    private func finishGoalResponse(_ response: JSONValue, id: String) throws {
        guard goalSnapshot.pending?.requestID == id else { return }
        guard let succeeded = response["success"]?.bool else { throw goalInvalidReply() }
        guard succeeded else {
            let nativeError = response["error"]?.string
            let message = nativeError == "Goal mode is disabled (goal.enabled)."
                ? AppText.localized("Goal mode is disabled in OMP. Enable goal.enabled in OMP, then reconnect this conversation.")
                : nativeError ?? AppText.localized("OMP rejected the goal action.")
            let error = TextCleanup.utf8Prefix(message,
                maximumBytes: OMPGoalLimits.errorBytes)
            goalSnapshot.finish(id: id, reply: nil, error: error)
            publishGoal()
            publishActivity()
            throw ProviderError.failed(error)
        }
        guard let reply = OMPGoalReply(response["data"] ?? .null) else { throw goalInvalidReply() }
        if let pending = goalSnapshot.pending, pending.operation != .create,
           let actualID = reply.state?.goal.id, actualID != pending.expectedGoalID {
            let message = AppText.localized("The native goal changed. Refresh it before choosing an action.")
            goalSnapshot.finish(id: id, reply: reply, error: message)
            publishGoal()
            publishActivity()
            throw ProviderError.failed(message)
        }
        goalSnapshot.finish(id: id, reply: reply)
        publishGoal()
        publishActivity()
    }

    private func publishGoal() { onEvent?(.ompGoal(goalSnapshot)) }
    private func goalUnsupported() -> ProviderError {
        .failed(AppText.localized("This OMP process does not support native goal controls."))
    }
    private func goalInvalidReply() -> ProviderError {
        .failed(AppText.localized("OMP did not report a valid native goal state."))
    }
}
