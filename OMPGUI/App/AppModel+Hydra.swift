import Foundation

/// Hydra's UI and persistence facade. Execution, worktree isolation and integration
/// are owned by OMP; the app stores only observed worker state.
extension AppModel {
    func hydraIsOn(_ thread: ChatThread) -> Bool { settings.hydraEnabled && thread.hydraEnabled && !thread.isHelper }
    static func hydraDefinesPolicyAtLaunch(_ provider: ProviderKind) -> Bool { provider == .omp }
    func hydraPair(for thread: ChatThread) -> HydraPair? {
        guard thread.provider == .omp else { return nil }
        return supportedHydraPairs.first { $0.id == thread.hydraPairID }
    }
    func hydraHeadsProvider(of pair: HydraPair) -> ProviderKind { .omp }
    func hydraHeadsFallbackNote(of pair: HydraPair) -> String? { nil }
    static func hydraHeadsEffort(leadEffort: String?, scale: [String]) -> String? { leadEffort }
    func hydraLaunch(for thread: ChatThread) -> HydraLaunch? {
        guard hydraIsOn(thread) else { return nil }
        let pair = hydraPair(for: thread)
        let nativeCap = omp.values["task.maxConcurrency"]?.int
        let cap = (pair?.maxHeads).map { pairCap in
            nativeCap.map { $0 > 0 ? min(pairCap, $0) : pairCap } ?? pairCap
        }
        return HydraLaunch(headsProvider: .omp, headsLabel: nil,
            workerModel: pair.flatMap { $0.workerModel ?? thread.model },
            workerEffort: pair.flatMap { $0.workerEffort ?? thread.effort },
            maxHeads: cap)
    }
    func setHydra(_ on: Bool, for id: UUID) {
        updateThread(id) { $0.hydraEnabled = on }
        settings.hydraDefaultEnabled = on
        if let updated = thread(id) { existingRuntime(for: id)?.updateOMPDelegationPreference(hydraLaunch(for: updated)) }
    }
    func syncHydraDelegationPreferences() {
        for runtime in liveRuntimes {
            if let lead = thread(runtime.threadID), !lead.isHelper {
                runtime.updateOMPDelegationPreference(hydraLaunch(for: lead))
            }
        }
    }
    func hydraHeads(of parentID: UUID) -> [ChatThread] { panelHeads(of: parentID) }
    func hydraTeam(of parentID: UUID) -> [ChatThread] {
        children(of: parentID).filter { !$0.isArchived && $0.isHydraHead }.sorted { ($0.hydra?.index ?? 0) < ($1.hydra?.index ?? 0) }
    }
    func runningTivanoHeads(of parentID: UUID) -> Int { 0 }
    func runningHydraHeads(of parentID: UUID) -> Int { hydraTeam(of: parentID).count { $0.hydra?.status == .running } }
    func hydraUnmergedFileCount(of leadID: UUID) -> Int { 0 }
    func workingHydraHeadNames(of parentID: UUID, excluding: Set<Int> = []) -> [String] {
        hydraTeam(of: parentID).filter { $0.hydra?.status == .running && !excluding.contains($0.hydra?.index ?? -1) }.compactMap { $0.hydra?.displayName }
    }
    func updateHydraHead(_ id: UUID, _ change: (inout HydraHeadInfo) -> Void) {
        updateThread(id) { thread in
            guard var info = thread.hydra else { return }
            change(&info)
            thread.hydra = info
        }
    }
    func finishHydraHead(_ id: UUID, status: TurnStatus, summary: String?, landing: HydraLanding? = nil) {
        guard let head = thread(id), let info = head.hydra, !info.isFinished else { return }
        let outcome: HydraHeadInfo.Status = switch status {
        case .completed: .completed
        case .failed: .failed
        case .interrupted: .stopped
        case .running: .running
        }
        updateHydraHead(id) {
            $0.status = outcome
            $0.summary = summary ?? $0.summary
            $0.finishedAt = .now
            if let landing { $0.landing = landing }
        }
        if let parentID = head.parentThreadID, let finished = thread(id)?.hydra {
            runtime(for: parentID).hydraHeadFinished(id, info: finished, status: outcome, summary: summary)
        }
        if status != .running, settings.hydraAutoClearFinished {
            updateThread(id) { $0.isInPanel = false }
        }
    }
    func hydraHeadTurnFinished(_ head: ChatThread, status: TurnStatus) {
        // OMP's lifecycle frame is authoritative, independently of transcript turns.
    }
    func stopHydraHead(_ id: UUID) {
        guard let head = thread(id), let info = head.hydra, !info.isFinished, info.canStop,
              let parentID = head.parentThreadID, let nativeID = info.nativeID else { return }
        let worker = runtime(for: id)
        guard worker.canStopNativeOMPAgent, !worker.isOMPAgentStopPending else { return }
        worker.isOMPAgentStopPending = true
        worker.ompAgentStopAcceptance = nil
        Task {
            defer { worker.isOMPAgentStopPending = false }
            let accepted = await runtime(for: parentID).stopOMPAgent(nativeID, observationID: info.nativeObservationID)
            guard thread(id)?.hydra?.nativeObservationID == info.nativeObservationID else { return }
            worker.ompAgentStopAcceptance = accepted
            // OMP's lifecycle frame is authoritative; cancelled:false never ends a head.
        }
    }
    func stopAllHydraHeads(of parentID: UUID) {
        for head in hydraTeam(of: parentID) where head.hydra?.isFinished != true { stopHydraHead(head.id) }
    }
    func dismissHydraHeads(of parentID: UUID) {
        stopAllHydraHeads(of: parentID)
        for head in hydraHeads(of: parentID) { updateThread(head.id) { $0.isInPanel = false } }
    }
    func clearFinishedHydraHeads(of parentID: UUID) {
        for head in hydraHeads(of: parentID) where head.hydra?.isFinished == true { updateThread(head.id) { $0.isInPanel = false } }
    }
    func releaseHydraCopy(of id: UUID) {}
    func sweepHydraCopies() {}
    func startHydraWatchdog() {}
}
