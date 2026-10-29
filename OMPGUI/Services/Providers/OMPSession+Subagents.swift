import Foundation

/// OMP 18.3.2 exposes one subscription for the entire parent process. Raw
/// events have neither a session identity nor durable message ids. Keep the
/// native progress subscription and read only visible workers' durable deltas.
@MainActor
final class OMPAgentDetailState {
    let observationID: String
    let sessionFile: String?
    var visible = false
    var nextByte = 0
    var loaded = false
    var completion: TurnStatus?
    var seenEntries = Set<String>()
    var needsRead = false
    var read: Task<Void, Never>?
    var readID: UUID?

    init(observationID: String, sessionFile: String?) {
        self.observationID = observationID
        self.sessionFile = sessionFile
    }
}

extension OMPSession {
    @discardableResult
    func setAgentDetailsVisible(_ id: String, observationID: String?, visible: Bool) async -> Bool {
        guard isRunning, let state = agentDetails[id], state.observationID == observationID else { return false }
        guard state.visible != visible else { return true }
        state.visible = visible
        if visible { refreshAgentDetails(id) }
        else { state.read?.cancel(); state.read = nil; state.readID = nil }
        return true
    }

    func stopAgentDetails() {
        for state in agentDetails.values { state.read?.cancel() }
        agentDetails.removeAll()
    }

    private func hasCurrentOwner(_ payload: JSONValue, id: String) -> Bool {
        guard let metadata = agentMetadata[id] else { return false }
        var confirmed = false
        if let file = payload["sessionFile"]?.string, let known = metadata.sessionFile {
            guard file == known else { return false }
            confirmed = true
        }
        if let tool = payload["parentToolCallId"]?.string, let known = metadata.toolUseID {
            guard known == "\(decoder.prefix)-\(tool)" else { return false }
            confirmed = true
        }
        // Once an id has changed owners it cannot establish identity by itself.
        // Older runtimes may omit both fields; leave their state unchanged.
        return !reusedAgentIDs.contains(id) || confirmed
    }

    func handleSubagentFrame(_ frame: JSONValue) {
        let payload = frame["payload"] ?? .null
        switch frame["type"]?.string {
        case "subagent_lifecycle":
            guard let id = payload["id"]?.string else { return }
            if payload["status"]?.string == "started" {
                startAgent(payload, newRun: true)
            } else {
                guard knownAgents.contains(id), hasCurrentOwner(payload, id: id) else { return }
                let status: TurnStatus = payload["status"]?.string == "completed" ? .completed
                    : payload["status"]?.string == "aborted" ? .interrupted : .failed
                onEvent?(.agentFinished(agentID: id, status: status, summary: nil))
                knownAgents.remove(id)
                agentDetails[id]?.completion = status
                refreshAgentDetails(id)
            }
        case "subagent_progress":
            let progress = payload["progress"] ?? .null
            guard let id = progress["id"]?.string, knownAgents.contains(id), hasCurrentOwner(payload, id: id) else { return }
            var metadata = payload.object ?? [:]
            metadata["id"] = .string(id)
            startAgent(.object(metadata))
            onEvent?(.agentProgress(agentID: id,
                summary: progress["lastIntent"]?.string ?? progress["recentOutput"]?.array?.compactMap(\.string).last,
                lastTool: progress["currentTool"]?.string, tokens: progress["tokens"]?.int, toolCalls: progress["toolCount"]?.int))
            // `tokens` is cumulative spend. Only `contextTokens` describes the
            // latest response's context, including when its transcript is hidden.
            if let usage = OMPAgentJournal.ContextReport.progressUsage(progress) {
                onEvent?(.agentEvent(agentID: id, .usage(usage)))
            }
            refreshAgentDetails(id)
        default:
            // Old in-flight raw frames are intentionally ignored. OMP's
            // durable journal is the only safe cursor across visibility changes.
            break
        }
    }

    func startAgent(_ payload: JSONValue, newRun: Bool = false) {
        guard let id = payload["id"]?.string else { return }
        let old = agentMetadata[id]
        let file = payload["sessionFile"]?.string ?? old?.sessionFile
        let sameSession = file != nil && file == old?.sessionFile
        let previous = sameSession || !newRun ? old : nil
        let replaces = newRun || previous == nil || file != previous?.sessionFile
        let oldDetails = agentDetails[id]
        if replaces {
            if old != nil { reusedAgentIDs.insert(id) }
            agentDetails.removeValue(forKey: id)?.read?.cancel()
            agentTodos.removeValue(forKey: id)?.stop()
            agents[id] = nil
        }
        knownAgents.insert(id)
        let observation = replaces ? UUID().uuidString : (previous?.observationID ?? UUID().uuidString)
        if agentDetails[id] == nil {
            let details = OMPAgentDetailState(observationID: observation, sessionFile: file)
            if sameSession, let oldDetails {
                details.visible = oldDetails.visible
                details.loaded = oldDetails.loaded
                details.nextByte = oldDetails.nextByte
                details.seenEntries = oldDetails.seenEntries
            }
            agentDetails[id] = details
        }
        if agents[id] == nil {
            let child = OMPEventDecoder(prefix: "\(observation)-\(id)", directory: configuration.workingDirectory.path, capturesSnapshots: false)
            child.onEvent = { [weak self] event in
                guard let self, agentMetadata[id]?.observationID == observation else { return }
                if case .todos = event { return }
                onEvent?(.agentEvent(agentID: id, event))
            }
            agents[id] = child
        }
        let directory = payload["workingDirectory"]?.string ?? payload["cwd"]?.string
            ?? (file == previous?.sessionFile ? previous?.workingDirectory : nil)
            ?? file.flatMap(OMPCLI.sessionWorkingDirectory)
        if let directory { agents[id]?.directory = directory }
        let spawn = AgentSpawn(id: id, taskID: nil,
            toolUseID: payload["parentToolCallId"]?.string.map { "\(decoder.prefix)-\($0)" } ?? previous?.toolUseID,
            description: payload["description"]?.string ?? payload["agent"]?.string ?? previous?.description ?? "OMP",
            prompt: payload["assignment"]?.string ?? payload["task"]?.string ?? previous?.prompt,
            model: payload["progress"]?["resolvedModelIdentity"]?.string ?? previous?.model,
            isBackground: payload["detached"]?.bool ?? previous?.isBackground ?? true,
            workingDirectory: directory, sessionFile: file,
            effort: payload["progress"]?["resolvedThinkingLevel"]?.string ?? previous?.effort,
            canStop: agentCapabilities.canCancel, canSteer: agentCapabilities.canSteer, observationID: observation,
            agentSource: payload["agentSource"]?.string ?? previous?.agentSource, parentSessionFile: sessionFile.nilIfEmpty)
        if agentMetadata[id] != spawn { agentMetadata[id] = spawn; onEvent?(.agentStarted(spawn)) }
        if replaces, agentDetails[id]?.visible == true { refreshAgentDetails(id) }
    }

    private func refreshAgentDetails(_ id: String) {
        guard let state = agentDetails[id], state.visible, let file = state.sessionFile else { return }
        state.needsRead = true
        guard state.read == nil else { return }
        let readID = UUID()
        state.readID = readID
        state.read = Task { [weak self, weak state] in
            guard let self, let state else { return }
            defer { if agentDetails[id] === state, state.readID == readID { state.read = nil; state.readID = nil } }
            // Coalesce native progress bursts, with no recurring timer while hidden.
            try? await Task.sleep(for: .milliseconds(180))
            while !Task.isCancelled, state.visible, state.needsRead, isRunning, agentDetails[id] === state, state.readID == readID {
                state.needsRead = false
                let fromByte = state.nextByte
                let data: JSONValue
                do {
                    data = try await rpc.request("get_subagent_messages", fields: ["sessionFile": .string(file), "fromByte": .int(fromByte)], timeout: .seconds(5))
                } catch {
                    // The selected worker's durable journal remains readable after its
                    // native registry/connection goes away. This never revives work.
                    guard !Task.isCancelled, state.visible, agentDetails[id] === state else { return }
                    onEvent?(.agentTranscriptUnavailable(agentID: id, observationID: state.observationID))
                    return
                }
                guard !Task.isCancelled, state.visible, agentDetails[id] === state, state.readID == readID,
                      agentMetadata[id]?.observationID == state.observationID,
                      data["sessionFile"]?.string == file,
                      let nextByte = data["nextByte"]?.int, let entries = data["entries"]?.array else { return }
                if data["reset"]?.bool == true || !state.loaded {
                    state.nextByte = 0
                    state.seenEntries.removeAll()
                    agents[id]?.resetForSession()
                    onEvent?(.agentTranscriptReset(agentID: id, observationID: state.observationID))
                } else if data["fromByte"]?.int != fromByte || nextByte < fromByte { return }
                for (index, entry) in entries.enumerated() {
                    if index.isMultiple(of: 24) {
                        await Task.yield()
                        guard !Task.isCancelled, state.visible, agentDetails[id] === state, state.readID == readID else { return }
                    }
                    guard let entryID = entry["id"]?.string, state.seenEntries.insert(entryID).inserted else { continue }
                    consumeAgentEntry(entry, id: id, entryID: entryID)
                }
                state.loaded = true
                state.nextByte = nextByte
                // Once the native byte watermark advances only an interrupted
                // current batch needs entry-id deduplication memory.
                state.seenEntries.removeAll()
                onEvent?(.agentTranscriptLoaded(agentID: id, observationID: state.observationID))
                // A completion arriving during this request requires another read:
                // this batch may have been captured before the final journal tail.
                if let status = state.completion, !state.needsRead {
                    onEvent?(.agentEvent(agentID: id, .turnCompleted(status: status, error: nil)))
                }
            }
        }
    }

    private func consumeAgentEntry(_ entry: JSONValue, id: String, entryID: String) {
        onEvent?(.agentEvent(agentID: id, .ompAgentJournalEntry(entry)))
        if let message = entry["message"], message["role"]?.string == "assistant",
           message["stopReason"]?.string == "stop", !knownAgents.contains(id) {
            let text = ToolText.blocks(message["content"])
            if !text.isEmpty {
                onEvent?(.agentResult(agentID: id, observationID: agentMetadata[id]?.observationID, result: OMPAgentResult(), summary: text))
            }
        }
    }

    func observeAgentResults(_ frame: JSONValue) {
        let type = frame["type"]?.string
        if type == "tool_execution_end" || type == "tool_execution_update" {
            let value = frame["result"] ?? frame["partialResult"] ?? .null
            let toolID = frame["toolCallId"]?.string.map { "\(decoder.prefix)-\($0)" }
            for row in value["details"]?["results"]?.array ?? [] {
                guard let id = row["id"]?.string, let metadata = agentMetadata[id], let toolID,
                      metadata.toolUseID == toolID || (metadata.toolUseID == nil && !reusedAgentIDs.contains(id) && frame["toolName"]?.string == "task") else { continue }
                var result = OMPAgentResult(native: row)
                result.nativeReport = ToolText.blocks(value["content"]).nilIfEmpty
                onEvent?(.agentResult(agentID: id, observationID: metadata.observationID, result: result, summary: row["output"]?.string?.nilIfEmpty))
            }
        } else if type == "message_end", frame["message"]?["customType"]?.string == "async-result" {
            let message = frame["message"] ?? .null
            for job in message["details"]?["jobs"]?.array ?? [] where job["type"]?.string == "task" {
                guard let id = job["jobId"]?.string, !reusedAgentIDs.contains(id), let metadata = agentMetadata[id] else { continue }
                var result = OMPAgentResult()
                result.nativeReport = ToolText.blocks(message["content"]).nilIfEmpty
                onEvent?(.agentResult(agentID: id, observationID: metadata.observationID, result: result, summary: nil))
            }
        }
    }
}
