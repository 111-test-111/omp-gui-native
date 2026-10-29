import Foundation

extension OMPSession {
    func refreshRunOptions() async throws {
        guard isRunning else { throw ProviderError.notRunning }
        _ = try await readState(timeout: .seconds(5))
    }

    /// Match the model shown by the picker before toggling its native Fast
    /// setting. Only an idle session may adopt a newly selected model.
    func setModelFastMode(_ enabled: Bool, expectedModel: String, effort: String?) async throws {
        guard isRunning, !isDraining, !nativeHistoryTransitionInFlight,
              runOptions.pending == nil, contextSnapshot.pendingRequestID == nil else { throw ProviderError.notRunning }
        let file = sessionFile
        stateRevision += 1
        let revision = stateRevision
        let initial = try await readState(timeout: .seconds(5))
        guard isRunning, !nativeHistoryTransitionInFlight, stateRevision == revision,
              runOptions.pending == nil, sessionFile == file, initial["sessionFile"]?.string == file else { throw CancellationError() }
        if Self.modelSelector(initial["model"]) != expectedModel {
            guard nativeActivity.canRecycle, let slash = expectedModel.firstIndex(of: "/") else {
                throw ProviderError.failed(AppText.localized("Wait for OMP to finish before changing this model's Fast mode."))
            }
            stateRevision += 1
            _ = try await rpc.request("set_model", fields: [
                "provider": .string(String(expectedModel[..<slash])),
                "modelId": .string(String(expectedModel[expectedModel.index(after: slash)...]))
            ])
            if let effort { _ = try await rpc.request("set_thinking_level", fields: ["level": .string(effort)]) }
            let revision = stateRevision
            let selected = try await readState(timeout: .seconds(5))
            guard sessionFile == file, Self.modelSelector(selected["model"]) == expectedModel else { throw CancellationError() }
            await adoptState(selected, revision: revision)
        }
        guard isRunning, sessionFile == file, runOptions.model == expectedModel else { throw CancellationError() }
        try await setRunOption(.fast, enabled: enabled)
    }

    /// Bind a potentially global operation to the model/scope actually shown to
    /// the user. The public RPC has no atomic expected-model argument.
    func setSlowMode(_ enabled: Bool, expectedModel: String, expectedScope: OMPSlowModeScope,
                     timeout: Duration = .seconds(30)) async throws {
        guard isRunning else { throw ProviderError.notRunning }
        // A read already in flight predates this user action and may describe a
        // different native scope. Fence it out of the coalescing key.
        let file = sessionFile
        stateRevision += 1
        let revision = stateRevision
        let state = try await readState(timeout: .seconds(5))
        var verified = OMPRunOptionsSnapshot()
        verified.observeState(state)
        guard isRunning, sessionFile == file, state["sessionFile"]?.string == file,
              stateRevision == revision, verified.slowSupported == true,
              verified.model == expectedModel, verified.slowScope == expectedScope else {
            throw ProviderError.failed(AppText.localized("Reload native Slow support and scope before changing it."))
        }
        try await setRunOption(.slow, enabled: enabled, expectedSlowModel: expectedModel,
                               expectedSlowScope: expectedScope, timeout: timeout)
    }

    func setRunOption(_ option: OMPRunOption, enabled: Bool? = nil, warmingMode: OMPCacheWarmingMode? = nil,
                      expectedSlowModel: String? = nil, expectedSlowScope: OMPSlowModeScope? = nil,
                      timeout: Duration = .seconds(30)) async throws {
        guard isRunning else { throw ProviderError.notRunning }
        guard !nativeHistoryTransitionInFlight, runOptions.pending == nil else {
            throw ProviderError.failed(AppText.localized("OMP is already changing a run option."))
        }
        guard capabilities[option.rawValue] != .unsupported else {
            throw ProviderError.failed(AppText.localized("OMP does not support this run option."))
        }
        guard option == .stopRetry || option == .cacheWarming || enabled != nil else {
            throw ProviderError.failed(AppText.localized("This run option requires an explicit enabled value."))
        }
        guard option != .stopRetry || runOptions.retrying else {
            throw ProviderError.failed(AppText.localized("OMP is not currently retrying."))
        }
        if option == .slow {
            guard runOptions.slowSupported == true, let scope = runOptions.slowScope,
                  let model = runOptions.model, model == expectedSlowModel, scope == expectedSlowScope else {
                throw ProviderError.failed(AppText.localized("Reload native Slow support and scope before changing it."))
            }
        }
        guard option != .cacheWarming || warmingMode != nil else {
            throw ProviderError.failed(AppText.localized("Choose an explicit native cache warming mode."))
        }
        let id = UUID().uuidString
        let file = sessionFile
        stateRevision += 1
        let previous = runOptions
        runOptions.begin(option, id: id, enabled: enabled, warmingMode: warmingMode)
        publishRunOptions(previous: previous)
        publishActivity()
        let fields: [String: JSONValue] = option == .cacheWarming
            ? ["mode": .string(warmingMode!.rawValue)] : enabled.map { ["enabled": .bool($0)] } ?? [:]
        do {
            let response = try await rpc.response(option.rawValue, fields: fields, id: id, timeout: timeout)
            guard isRunning, sessionFile == file, runOptions.pending?.id == id else { throw CancellationError() }
            let previous = runOptions
            let completion = runOptions.finish(response)
            if completion == .invalid {
                runOptions.markUnknown(AppText.localized("OMP returned an invalid run option result. Its outcome is unknown."))
            }
            publishRunOptions(previous: previous)
            publishActivity()
            if completion == .invalid {
                throw ProviderError.failed(runOptions.error ?? AppText.localized("OMP rejected the request."))
            }
            // This mutation invalidated older state reads. Even an explicit
            // rejection must replace a goal's displaced settlement observation.
            // An unresolved result keeps its pending fence and is not replayed.
            let failure = runOptions.error ?? AppText.localized("OMP rejected the request.")
            if completion == .completed, isRunning, sessionFile == file {
                _ = try? await readState(timeout: .seconds(5))
            }
            guard response["success"]?.bool == true else {
                throw ProviderError.failed(failure)
            }
        } catch {
            if sessionFile == file, runOptions.pending?.id == id {
                let previous = runOptions
                if !runOptions.outcomeUnknown {
                    runOptions.markUnknown(AppText.localized("OMP did not confirm the run option. Its outcome is unknown; do not repeat it while confirmation is pending."))
                }
                publishRunOptions(previous: previous)
                publishActivity()
            }
            throw error
        }
    }

    func observeRunOptionsState(_ state: JSONValue) {
        let previous = runOptions
        runOptions.observeState(state)
        publishRunOptions(previous: previous)
    }

    func observeRunOptionsFrame(_ frame: JSONValue) {
        let previous = runOptions
        _ = runOptions.observeFrame(frame)
        if frame["type"]?.string == "response" {
            let completion = runOptions.finish(frame)
            if completion == .invalid {
                runOptions.markUnknown(AppText.localized("OMP returned an invalid run option result. Its outcome is unknown."))
            } else if completion == .completed {
                Task { [weak self] in _ = try? await self?.readState(timeout: .seconds(5)) }
            }
        }
        publishRunOptions(previous: previous)
    }

    func publishRunOptions(previous: OMPRunOptionsSnapshot) {
        guard previous != runOptions else { return }
        onEvent?(.ompRunOptions(runOptions))
        if let enabled = runOptions.fastEnabled, previous.fastEnabled != enabled {
            onEvent?(.fastModeChanged(enabled))
        }
    }

    func stopRunOptions() {
        let previous = runOptions
        runOptions.disconnect()
        publishRunOptions(previous: previous)
    }
}
