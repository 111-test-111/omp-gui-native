import Foundation

extension OMPSession {
    /// Opening Usage reuses a completed read until native context changes.
    func refreshContextIfNeeded() async throws {
        guard isRunning else { throw ProviderError.notRunning }
        guard contextRefreshedRevision != contextSnapshot.revision else { return }
        try await refreshContext()
    }

    /// Opening two usage surfaces shares the same reads and never launches OMP.
    func refreshContext() async throws {
        guard isRunning else { throw ProviderError.notRunning }
        // Native maintenance serializes ordinary RPC commands. Do not enqueue a
        // five-second read behind a handoff that can legitimately take minutes.
        guard contextSnapshot.pendingCommand == nil else { return }
        if let read = contextRead { return try await read.task.value }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self, isRunning else { throw ProviderError.notRunning }
            do {
                // Occupancy and controls need not wait for statistics or history.
                let state = try await readState(timeout: .seconds(5))
                let revision = contextSnapshot.revision
                let file = sessionFile
                if capabilities["get_session_stats"] != .unsupported {
                    let stats = try await rpc.request("get_session_stats", timeout: .seconds(5))
                    guard isRunning, sessionFile == file,
                          contextSnapshot.acceptStats(stats, revision: revision) else { return }
                    publishContext()
                }
                if contextHistoryNeedsRefresh, nativeActivity.canRecycle, capabilities["get_entries"] != .unsupported,
                   let sessionID = state["sessionId"]?.string {
                    let data = try await rpc.request("get_entries", timeout: .seconds(5))
                    guard isRunning, sessionFile == file, contextSnapshot.revision == revision else { return }
                    let history = try await Task.detached(priority: .userInitiated) {
                        try OMPHistorySnapshot(data, sessionFile: file, sessionID: sessionID)
                    }.value
                    guard isRunning, sessionFile == file, contextSnapshot.revision == revision else { return }
                    let previous = contextSnapshot
                    try contextSnapshot.restoreHandoff(history)
                    contextHistoryNeedsRefresh = false
                    if contextSnapshot != previous { publishContext() }
                }
                contextRefreshedRevision = revision
            } catch is CancellationError {
                throw ProviderError.failed(AppText.localized("OMP did not respond to the context refresh. Refresh again after its current work finishes."))
            }
        }
        contextRead = (id, task)
        defer { if contextRead?.id == id { contextRead = nil } }
        try await task.value
    }

    func compactContext(customInstructions: String?) async throws -> OMPCompactionResult {
        let value = try await contextRequest("compact", fields: instructions(customInstructions), timeout: .seconds(120))
        _ = try? await readState(timeout: .seconds(5))
        guard let result = OMPCompactionResult(value) else {
            throw ProviderError.failed(AppText.localized("OMP did not report a compaction result."))
        }
        return result
    }

    /// OMP implements this public RPC as a session override, without changing
    /// the machine's active profile or config.yml.
    func setAutoCompaction(_ enabled: Bool) async throws {
        _ = try await contextRequest("set_auto_compaction", fields: ["enabled": .bool(enabled)])
        _ = try await readState(timeout: .seconds(5))
    }

    func handoffContext(customInstructions: String?) async throws -> OMPHandoffResult {
        let value = try await contextRequest("handoff", fields: instructions(customInstructions), timeout: .seconds(120))
        try? await refreshContext()
        guard value.isNull || value.object != nil else {
            throw ProviderError.failed(AppText.localized("OMP did not report a handoff result."))
        }
        return contextSnapshot.lastHandoff ?? OMPHandoffResult(value)
    }

    func exportContextHTML(to path: String) async throws -> String {
        let value = try await contextRequest("export_html", fields: ["outputPath": .string(path)])
        guard let output = value["path"]?.string, !output.isEmpty else {
            throw ProviderError.failed(AppText.localized("OMP did not report the exported file path."))
        }
        return output
    }

    func observeContextState(_ state: JSONValue, publishes: Bool = true) {
        contextSnapshot.observeState(state)
        if publishes { publishContext() }
    }

    func observeContextFrame(_ frame: JSONValue) {
        if ["auto_compaction_end", "manual_compaction_end"].contains(frame["type"]?.string ?? "") { contextHistoryNeedsRefresh = true }
        if contextSnapshot.observeFrame(frame) { publishContext() }
        // A timed-out mutation stays in flight. Only its actual late response
        // (or process teardown) releases it; get_state.isSettled alone excludes
        // neither manual handoff nor every native maintenance operation.
        if frame["type"]?.string == "response",
           let id = contextSnapshot.pendingRequestID,
           frame["id"]?.string == id,
           let command = contextSnapshot.pendingCommand,
           frame["command"]?.string == command,
           let succeeded = frame["success"]?.bool {
            contextSnapshot.finish(command, data: frame["data"], error: succeeded ? nil : frame["error"]?.string ?? AppText.localized("OMP rejected the request."))
            activity.endPrompt(id)
            publishActivity()
            publishContext()
            if succeeded { confirmContextRewrite(command, data: frame["data"] ?? .null) }
            Task { [weak self] in try? await self?.refreshContext() }
        }
    }

    private func publishContext() { onEvent?(.ompContext(contextSnapshot)) }

    private func confirmContextRewrite(_ command: String, data: JSONValue) {
        if command == "compact" || (command == "handoff" && !data.isNull) {
            contextHistoryNeedsRefresh = true
            onEvent?(.ompContextRewritten)
        }
    }

    private func instructions(_ text: String?) -> [String: JSONValue] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        return ["customInstructions": .string(text)]
    }

    private func contextRequest(_ command: String, fields: [String: JSONValue], timeout: Duration = .seconds(30)) async throws -> JSONValue {
        // Finish an already admitted read before starting a serial mutation.
        if let read = contextRead { try await read.task.value }
        try Task.checkCancellation()
        guard isRunning else { throw ProviderError.notRunning }
        guard capabilities[command] != .unsupported else {
            throw ProviderError.failed(AppText.localized("This OMP process does not support this context action."))
        }
        guard contextSnapshot.pendingRequestID == nil, nativeActivity.canRecycle else {
            throw ProviderError.failed(AppText.localized("Wait until OMP has finished its current work before managing context."))
        }
        let id = UUID().uuidString
        contextSnapshot.begin(command, id: id)
        activity.beginPrompt(id)
        publishActivity()
        publishContext()
        do {
            let value = try await rpc.request(command, fields: fields, id: id, timeout: timeout)
            contextSnapshot.finish(command, data: value)
            activity.endPrompt(id)
            publishActivity()
            publishContext()
            confirmContextRewrite(command, data: value)
            if command == "export_html" { _ = try? await readState(timeout: .seconds(5)) }
            return value
        } catch {
            if error is CancellationError, isRunning {
                contextSnapshot.markUnknown()
                publishContext()
                throw ProviderError.failed(AppText.localized("OMP has not confirmed the context action. Its outcome is unknown; do not repeat it while confirmation is pending."))
            }
            contextSnapshot.finish(command, data: nil, error: error.localizedDescription)
            activity.endPrompt(id)
            publishActivity()
            publishContext()
            _ = try? await readState(timeout: .seconds(5))
            throw error
        }
    }
}
