import Foundation

extension AppModel {
    /// Metadata-only repair. Original alias documents remain on disk; journals are
    /// read only when their stable page is opened, never scanned at startup.
    static func coalescingOMPAgentHeads(_ source: [ChatThread]) -> [ChatThread] {
        var result = source
        let groups = Dictionary(grouping: source.indices.filter {
            source[$0].hydra?.kind == .native && source[$0].parentThreadID != nil
                && source[$0].hydra?.nativeCanonicalID == nil
                && source[$0].providerSessionID?.isEmpty == false
        }) { index in
            let head = source[index]
            return "\(head.parentThreadID!)|\(head.hydra?.nativeID ?? "")|\(head.providerSessionID!)"
        }
        for group in groups.values where group.count > 1 {
            let ordered = group.sorted { (source[$0].hydra?.index ?? 0) < (source[$1].hydra?.index ?? 0) }
            let first = ordered[0]
            let latest = group.max { (source[$0].hydra?.startedAt ?? .distantPast) < (source[$1].hydra?.startedAt ?? .distantPast) }!
            guard var info = source[latest].hydra, let initial = source[first].hydra else { continue }
            info.index = initial.index
            info.startedAt = initial.startedAt
            info.task = initial.task
            info.nativeCanonicalID = nil
            info.nativeObservationSequence = info.nativeObservationSequence ?? source[latest].hydra?.index
            info.summary = info.summary ?? group.reversed().compactMap { source[$0].hydra?.summary }.first
            result[first].hydra = info
            result[first].model = source[latest].model ?? source[first].model
            result[first].effort = source[latest].effort ?? source[first].effort
            result[first].updatedAt = source[latest].updatedAt
            result[first].lastStatus = source[latest].lastStatus
            for index in ordered.dropFirst() {
                result[index].hydra?.nativeCanonicalID = source[first].id
                result[index].hydra?.canStop = false
                result[index].hydra?.canSteer = false
            }
        }
        return result
    }

    private func ompHead(_ nativeID: String, parentID: UUID, observationID: String? = nil) -> ChatThread? {
        children(of: parentID).filter {
            $0.hydra?.kind == .native && $0.hydra?.nativeID == nativeID
                && (observationID == nil || $0.hydra?.nativeObservationID == observationID)
        }.max { ($0.hydra?.nativeObservationSequence ?? $0.hydra?.index ?? 0)
            < ($1.hydra?.nativeObservationSequence ?? $1.hydra?.index ?? 0) }
    }

    /// A head is a view of an OMP worker, with the original roster, cards and
    /// transcript assets. It never starts another process or owns a merge queue.
    func mirrorOMPAgent(_ spawn: AgentSpawn, parentID: UUID) {
        guard let parent = thread(parentID) else { return }
        let sequence = (children(of: parentID).compactMap { $0.hydra.map { $0.nativeObservationSequence ?? $0.index } }.max() ?? -1) + 1
        for old in children(of: parentID) where old.hydra?.kind == .native && old.hydra?.nativeID == spawn.id
            && old.hydra?.nativeObservationID != spawn.observationID
            && (spawn.sessionFile == nil || old.providerSessionID != spawn.sessionFile) {
            guard old.hydra?.canStop == true || old.hydra?.canSteer == true else { continue }
            updateHydraHead(old.id) {
                $0.canStop = false
                $0.canSteer = false
                if $0.providerHistoryIssue == nil {
                    $0.providerHistoryIssue = Chrome.localized("OMP reused this agent ID. Controls are available only for its current task.")
                }
            }
        }
        var observed = OMPAgentResult()
        observed.model = spawn.model
        observed.effort = spawn.effort
        observed.workingDirectory = spawn.workingDirectory
        observed.agentSource = spawn.agentSource
        observed.parentSessionFile = spawn.parentSessionFile
        observed.sessionFile = spawn.sessionFile
        observed.parentToolCallID = spawn.toolUseID
        // A wake changes control ownership, not the worker's durable conversation.
        // A reused slot with a different journal still receives a separate page.
        if let file = spawn.sessionFile, let existing = children(of: parentID).first(where: {
            $0.hydra?.kind == .native && $0.hydra?.nativeID == spawn.id && $0.providerSessionID == file
        }) {
            let newRun = existing.hydra?.nativeObservationID != spawn.observationID
            updateHydraHead(existing.id) {
                $0.status = .running
                $0.finishedAt = nil
                if newRun {
                    $0.nativeObservationSequence = sequence
                    $0.executionStartedAt = .now
                    $0.executionFinishedAt = nil
                    $0.tokens = 0
                    $0.toolCalls = 0
                }
                $0.nativeObservationID = spawn.observationID
                $0.canStop = spawn.canStop
                $0.canSteer = spawn.canSteer
                var result = $0.nativeResult ?? OMPAgentResult()
                result.merge(observed)
                $0.nativeResult = result
                if let prompt = spawn.prompt { $0.task = prompt }
                $0.toolUseID = spawn.toolUseID ?? $0.toolUseID
            }
            if let model = spawn.model { updateThread(existing.id) { $0.model = model } }
            updateThread(existing.id) {
                if let effort = spawn.effort { $0.effort = effort }
                if let directory = spawn.workingDirectory { $0.worktreePath = directory }
                if let file = spawn.sessionFile { $0.providerSessionID = file }
            }
            let headRuntime = runtime(for: existing.id)
            headRuntime.beginOMPAgentTurn(spawn.prompt)
            if newRun, headRuntime.hasNativeDetailConsumers {
                headRuntime.cancelNativeAgentHistoryRead()
                Task {
                    _ = await runtime(for: parentID).setOMPAgentDetailsVisible(spawn.id,
                        observationID: spawn.observationID, visible: headRuntime.hasNativeDetailConsumers)
                }
            }
            return
        }
        let index = parent.hydraSpawnCount
        var head = ChatThread(projectID: parent.projectID, provider: .omp, model: spawn.model,
                              effort: spawn.effort, runtimeMode: parent.runtimeMode)
        head.parentThreadID = parentID
        head.isInPanel = true
        head.hydraEnabled = false
        head.worktreePath = spawn.workingDirectory ?? parent.worktreePath
        head.branch = parent.branch
        var info = HydraHeadInfo(index: index, task: spawn.prompt ?? spawn.description, kind: .native, origin: .delegated)
        info.nativeID = spawn.id
        info.toolUseID = spawn.toolUseID
        info.profile = spawn.description
        info.isBackground = spawn.isBackground
        info.canStop = spawn.canStop
        info.canSteer = spawn.canSteer
        info.nativeObservationID = spawn.observationID
        info.nativeObservationSequence = sequence
        info.nativeResult = observed
        info.executionStartedAt = .now
        head.hydra = info
        head.effort = spawn.effort
        head.providerSessionID = spawn.sessionFile
        head.title = "\(info.displayName) · \(TextCleanup.singleLine(spawn.description, limit: 60))"
        head.hasCustomTitle = true
        insertThread(head)
        if let toolID = spawn.toolUseID { runtime(for: parentID).rehearseHydraHead(toolID: toolID, headID: head.id) }
        updateThread(parentID) { $0.hydraSpawnCount += 1 }
        runtime(for: head.id).beginOMPAgentTurn(spawn.prompt)
    }

    func setOMPAgentDetailsVisible(headID: UUID, visible: Bool, consumer: String = "hydra-panel") async {
        guard let head = thread(headID), let info = head.hydra, info.kind == .native,
              let parentID = head.parentThreadID, let id = info.nativeID else { return }
        let headRuntime = runtime(for: headID)
        let needed = headRuntime.updateNativeDetailConsumer(consumer, visible: visible)
        if needed { await headRuntime.ensureLoaded() }
        let observation = thread(headRuntime.threadID)?.hydra?.nativeObservationID
        let observing = await runtime(for: parentID).setOMPAgentDetailsVisible(id, observationID: observation, visible: headRuntime.hasNativeDetailConsumers)
        if headRuntime.hasNativeDetailConsumers && !observing { await headRuntime.loadNativeAgentHistory() }
        else { headRuntime.cancelNativeAgentHistoryRead() }
    }

    func refreshVisibleOMPAgentHistories(parentID: UUID) {
        for head in children(of: parentID) where head.hydra?.kind == .native {
            guard let runtime = existingRuntime(for: head.id), runtime.hasNativeDetailConsumers else { continue }
            Task { await runtime.loadNativeAgentHistory() }
        }
    }

    func recoverOMPAgentHistory(nativeID: String, parentID: UUID, observationID: String?) {
        guard let head = ompHead(nativeID, parentID: parentID, observationID: observationID),
              head.hydra?.nativeObservationID == observationID else { return }
        Task { await runtime(for: head.id).loadNativeAgentHistory() }
    }

    func receiveOMPAgentEvent(_ event: ProviderEvent, nativeID: String, parentID: UUID) {
        guard let head = ompHead(nativeID, parentID: parentID) else { return }
        runtime(for: head.id).receiveOMPEvent(event)
        var observed = OMPAgentResult()
        if case .toolUpdated(_, let update) = event { observed.files = update.edits?.map(\.path) ?? [] }
        if case .tokenSpend(let spend) = event { observed.model = spend.model }
        if !observed.files.isEmpty || observed.model != nil {
            updateOMPAgentResult(nativeID: nativeID, parentID: parentID, observationID: head.hydra?.nativeObservationID, result: observed, summary: nil)
        }
    }

    func resetOMPAgentTranscript(nativeID: String, parentID: UUID, observationID: String?) {
        guard let head = ompHead(nativeID, parentID: parentID, observationID: observationID),
              head.hydra?.nativeObservationID == observationID else { return }
        runtime(for: head.id).resetNativeAgentTranscript()
    }

    func completeOMPAgentTranscript(nativeID: String, parentID: UUID, observationID: String?) {
        guard let head = ompHead(nativeID, parentID: parentID, observationID: observationID),
              head.hydra?.nativeObservationID == observationID else { return }
        runtime(for: head.id).completeNativeAgentTranscript()
    }

    func updateOMPAgentResult(nativeID: String, parentID: UUID, observationID: String?, result: OMPAgentResult, summary: String?) {
        guard let head = ompHead(nativeID, parentID: parentID, observationID: observationID), head.hydra?.nativeObservationID == observationID else { return }
        updateHydraHead(head.id) {
            var merged = $0.nativeResult ?? OMPAgentResult()
            merged.merge(result)
            $0.nativeResult = merged
            if let summary, !summary.isEmpty { $0.summary = summary }
        }
        if let model = result.model { updateThread(head.id) { $0.model = model } }
    }

    func updateOMPAgent(nativeID: String, parentID: UUID, summary: String?, tool: String?, tokens: Int?, calls: Int?) {
        guard let head = ompHead(nativeID, parentID: parentID), head.hydra?.isFinished != true else { return }
        updateHydraHead(head.id) {
            $0.activity = tool ?? summary
            if let tokens { $0.tokens = tokens }
            if let calls { $0.toolCalls = calls }
        }
    }

    func finishOMPAgent(nativeID: String, parentID: UUID, status: TurnStatus, summary: String?) {
        guard let head = ompHead(nativeID, parentID: parentID), head.hydra?.isFinished != true else { return }
        let runtime = runtime(for: head.id)
        let spoken = runtime.entries.reversed().compactMap { entry -> String? in
            if case .assistant(let message) = entry.item.content { return message.text }
            return nil
        }.first
        updateHydraHead(head.id) { $0.executionFinishedAt = .now }
        finishHydraHead(head.id, status: status, summary: summary ?? spoken)
        // Lifecycle completion can overtake the final journal read. Update the
        // worker now, but let the drained transcript establish its turn boundary.
        runtime.endOMPAgentExecution()
    }
}
