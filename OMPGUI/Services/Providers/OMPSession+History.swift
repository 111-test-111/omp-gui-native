import Foundation

extension OMPSession {
    func nativeHistory() async throws -> OMPHistorySnapshot {
        guard isRunning else { throw ProviderError.notRunning }
        let revision = stateRevision
        let before = try await readState()
        try requireHistoryIdle(before)
        let identity = try historyIdentity(before)
        let activityRevision = activity.eventRevision
        let data = try await historyRequest("get_entries")
        guard activity.eventRevision == activityRevision else { throw OMPHistoryError.staleCursor }
        let after = try await readState()
        guard revision == stateRevision, activity.eventRevision == activityRevision, try historyIdentity(after) == identity,
              before["messageCount"] == after["messageCount"] else { throw OMPHistoryError.staleCursor }
        try requireHistoryIdle(after)
        let snapshot = try await Task.detached(priority: .userInitiated) {
            try OMPHistorySnapshot(data, sessionFile: identity.file, sessionID: identity.id)
        }.value
        guard revision == stateRevision, activity.eventRevision == activityRevision else { throw OMPHistoryError.staleCursor }
        return snapshot
    }

    func branchHistory(entryID: String) async throws -> OMPHistoryBranchResult {
        guard isRunning else { throw ProviderError.notRunning }
        let before = try await readState()
        try requireHistoryIdle(before)
        let previous = try historyIdentity(before)
        let history = try await nativeHistory()
        guard let selected = history.activeUserEntries.first(where: { $0.id == entryID }),
              let message = selected.message else { throw OMPHistoryError.invalidBranchEntry }
        guard contextSnapshot.pendingRequestID == nil, nativeActivity.canRecycle, !nativeHistoryTransitionInFlight,
              history.sessionFile == previous.file, history.sessionID == previous.id else { throw OMPHistoryError.sessionBusy }
        nativeHistoryTransitionInFlight = true
        defer { nativeHistoryTransitionInFlight = false }
        let requestID = UUID().uuidString
        activity.beginPrompt(requestID)
        publishActivity()
        let reply: JSONValue
        do {
            reply = try await rpc.response("branch", fields: ["entryId": .string(entryID)], id: requestID, timeout: .seconds(120))
        } catch {
            // A missing reply is not evidence that the mutation failed. Never
            // resend, or continue writing through a possibly replaced identity.
            stop()
            throw OMPHistoryError.branchOutcomeUnknown
        }
        guard reply["success"]?.bool == true else {
            activity.endPrompt(requestID)
            publishActivity()
            do {
                guard try historyIdentity(await readState(timeout: .seconds(5))) == previous else {
                    stop()
                    throw OMPHistoryError.branchFailedAfterChange
                }
            } catch {
                stop()
                throw OMPHistoryError.branchFailedAfterChange
            }
            throw ProviderError.failed(reply["error"]?.string ?? AppText.localized("OMP rejected the request."))
        }
        let response = reply["data"] ?? .null
        guard let cancelled = response["cancelled"]?.bool else {
            stop()
            throw OMPHistoryError.branchOutcomeUnknown
        }
        if cancelled {
            activity.endPrompt(requestID)
            publishActivity()
            do {
                guard try historyIdentity(await readState(timeout: .seconds(5))) == previous else {
                    stop()
                    throw OMPHistoryError.branchFailedAfterChange
                }
            } catch {
                stop()
                throw OMPHistoryError.branchFailedAfterChange
            }
            return OMPHistoryBranchResult(cancelled: true, sessionFile: previous.file, sessionID: previous.id,
                                          editorText: response["text"]?.string ?? message.text, images: message.images)
        }
        do {
            let state = try await readState()
            let next = try historyIdentity(state)
            guard next.file != previous.file, next.id != previous.id else { throw OMPHistoryError.identityUnavailable }
            await resetNativeSessionState(state)
            return OMPHistoryBranchResult(cancelled: false, sessionFile: next.file, sessionID: next.id,
                                          editorText: response["text"]?.string ?? message.text, images: message.images)
        } catch {
            // Never leave the GUI bound to the old journal while its live process
            // actually writes to a new one. The old file remains resumable.
            stop()
            throw OMPHistoryError.identityUnavailable
        }
    }

    private func historyIdentity(_ state: JSONValue) throws -> (file: String, id: String) {
        guard let file = state["sessionFile"]?.string, !file.isEmpty,
              let id = state["sessionId"]?.string, !id.isEmpty else { throw OMPHistoryError.invalidHistory }
        return (file, id)
    }

    private func requireHistoryIdle(_ state: JSONValue) throws {
        // Older releases must explicitly report safe quiescence as well. A reply
        // ending while native queue/background work continues is not sufficient.
        guard state["isStreaming"]?.bool == false, state["isCompacting"]?.bool == false,
              state["isSettled"]?.bool == true,
              state["queuedMessageCount"]?.int == 0, state["hasPendingAsyncWork"]?.bool == false,
              nativeActivity.canRecycle, contextSnapshot.pendingRequestID == nil, !nativeHistoryTransitionInFlight else {
            throw OMPHistoryError.sessionBusy
        }
    }

    private func historyRequest(_ command: String, fields: [String: JSONValue] = [:], timeout: Duration = .seconds(30)) async throws -> JSONValue {
        let response = try await rpc.response(command, fields: fields, timeout: timeout)
        guard response["success"]?.bool == true else {
            switch response["code"]?.string {
            case "stale_cursor", "unknown_since": throw OMPHistoryError.staleCursor
            case "session_busy": throw OMPHistoryError.sessionBusy
            default: throw ProviderError.failed(response["error"]?.string ?? AppText.localized("OMP rejected the request."))
            }
        }
        return response["data"] ?? .null
    }
}
