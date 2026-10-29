import Foundation

/// A native OMP session. OMP owns tools, approvals, provider authentication,
/// MCP connections, subagent scheduling, worktrees and result integration.
@MainActor
final class OMPSession: ProviderSession {
    var onEvent: ((ProviderEvent) -> Void)?
    var onHostTool: ((OMPHostToolRequest) async throws -> JSONValue)?
    var previewHostToolsEnabled = false
    var hostToolCalls: [String: Task<Void, Never>] = [:]
    var browserAutomationAvailable = false
    var completedHostToolIDs: [String] = []
    let configuration: SessionConfiguration
    let rpc = OMPRPC()
    lazy var sideQuestions: OMPSideQuestionController = {
        let value = OMPSideQuestionController(rpc: rpc)
        value.onChange = { [weak self] snapshot in
            guard let self else { return }
            onEvent?(.ompSideQuestion(snapshot))
            if isRunning { publishActivity() }
        }
        return value
    }()
    let decoder: OMPEventDecoder
    var agents: [String: OMPEventDecoder] = [:]
    var agentTodos: [String: OMPTodoStateSync<TodoSnapshot>] = [:]
    var knownAgents: Set<String> = []
    private var extensionState = OMPExtensionState()
    private var extensionPublishTask: Task<Void, Never>?
    private var dialogTimeouts: [String: Task<Void, Never>] = [:]
    private var dialogs: [String: QuestionRequest] = [:]
    private var inFlightAnswers: Set<UUID> = []
    private struct Submission {
        var id: UUID
        var delivery: OMPMessageDelivery
        var text: String
        var imageCount: Int
        var state: OMPSubmissionState = .submitting
        var completed = false
        var runGeneration = 0
    }
    private var submissions: [UUID: Submission] = [:]
    private var submissionOrder: [UUID] = []
    private var completedSubmissionIDs: Set<UUID> = []
    private var observedUserMessageIDs: Set<String> = []
    private var completedReplyBeforeNextUser = false
    private var nativeRunGeneration = 0
    var goalRunGeneration: Int { nativeRunGeneration }
    private var latestRunOutcome: (generation: Int, status: TurnStatus, error: String?)?
    private var admissionTail: (id: UUID, task: Task<Void, Never>)?
    private var admissionTasks: [UUID: Task<Void, Error>] = [:]
    private var hasLivePrompt: Bool {
        submissions.values.contains { !$0.completed && ($0.delivery == .prompt || $0.delivery == .stopAndSend) }
    }
    var contextSnapshot = OMPContextSnapshot()
    var runOptions = OMPRunOptionsSnapshot()
    var contextRead: (id: UUID, task: Task<Void, Error>)?
    var contextRefreshedRevision: UInt64?
    var contextHistoryNeedsRefresh = true
    var contextInspectionAvailable = false
    let contextInspectionReplies = PendingReplies<JSONValue>()
    var contextInspectionRequests: Set<String> = []
    var goalSnapshot = OMPGoalSnapshot()
    var goalRead: (id: UUID, task: Task<Void, Error>)?
    var goalGeneration = UUID()
    var goalNeedsSettlement = false
    var nativeHistoryTransitionInFlight = false
    private var model: String?
    private var effort: String?
    private var mode: InteractionMode
    private var overlay: URL?
    private var guidanceExtension: URL?
    private var usesPromptResults = false
    let memoryReplies = PendingReplies<JSONValue>()
    var memoryRequests: [String: String] = [:]
    var memoryBridgeAvailable = false
    var debugSnapshot = OMPDebugSnapshot()
    let debugReplies = PendingReplies<JSONValue>()
    var debugRequests: [String: String] = [:]
    private let queueReplies = PendingReplies<JSONValue>()
    private struct QueueControl {
        var operation: String
        var submissionID: UUID?
    }
    private var queueControls: [String: QueueControl] = [:]
    private var queueControlOrder: [String] = []
    private var withdrawnSubmissionIDs: [UUID] = []
    var canWithdrawQueuedMessages: Bool { isRunning && capabilities["gui_remove_follow_up"] == .supported }
    var stopped = false
    private var turnError: String?
    private var interruptRequested = false
    var sessionFile = ""
    private var availableModels: [ModelOption] = []
    private var fastMode = false
    var agentMetadata: [String: AgentSpawn] = [:]
    var agentCapabilities = OMPSubagentCapabilities()
    var agentDetails: [String: OMPAgentDetailState] = [:]
    var reusedAgentIDs: Set<String> = []
    var stateRevision = 0
    var activity = OMPActivityTracker()
    private var publishedActivity: OMPActivity?
    private var stateRead: (id: UUID, revision: UInt64, modelRevision: Int, task: Task<JSONValue, Error>)?
    var capabilities: OMPCapabilities { rpc.capabilities }
    var nativeActivity: OMPActivity {
        var value = activity.value
        guard !value.stopped else { return value }
        value.prompts.formUnion(admissionTasks.keys.map { "admission-" + $0.uuidString })
        if let pending = goalSnapshot.pending { value.recycleBlockers.insert(pending.requestID) }
        if goalNeedsSettlement { value.recycleBlockers.insert("goal-settlement") }
        value.prompts.formUnion(submissions.values.filter {
            $0.state == .submitting || $0.state == .accepted || $0.state == .unknown
        }.map { $0.id.uuidString })
        if let pending = runOptions.pending { value.recycleBlockers.insert(pending.id) }
        if sideQuestionSnapshot.hasLiveWork || isDraining { value.recycleBlockers.insert("side-question") }
        if debugSnapshot.preventsRecycle { value.recycleBlockers.insert("debug-session") }
        return value
    }
    private let launchID = UUID().uuidString
    private lazy var todos = OMPTodoStateSync(read: { [weak self] in
        guard let self, isRunning else { throw ProviderError.notRunning }
        let state = try await readState(timeout: .seconds(5))
        return await todoSnapshot(state)
    }, publish: { [weak self] snapshot in self?.onEvent?(.todoSnapshot(snapshot)) })

    init(configuration: SessionConfiguration) {
        self.configuration = configuration
        decoder = OMPEventDecoder(prefix: UUID().uuidString, directory: configuration.workingDirectory.path)
        model = configuration.model
        effort = configuration.effort
        mode = configuration.interactionMode
        decoder.onEvent = { [weak self] event in
            guard let self else { return }
            // Tool results are mutation hints. get_state is authoritative even
            // when eval/nested calls leave no todo tool_execution_end frame.
            if case .todos = event { todos.refresh() } else { onEvent?(event) }
        }
        rpc.onFrame = { [weak self] frame in self?.handle(frame) }
        rpc.onCapabilitiesChanged = { [weak self] value in self?.onEvent?(.ompCapabilities(value)) }
        rpc.onExit = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !stopped else { return }
                removeRuntimeFiles()
                await sideQuestions.finishExit(cleanDrain: rpc.isDraining && error == nil)
                guard !stopped else { return }
                completedReplyBeforeNextUser = false
                preserveUnconsumedSubmissions()
                memoryReplies.failAll(ProviderError.notRunning)
                contextInspectionReplies.failAll(ProviderError.notRunning)
                disconnectDebugObservation()
                queueReplies.failAll(ProviderError.notRunning)
                clearExtensionUI()
                stopRunOptions()
                disconnectGoalObservation()
                stopAgentDetails()
                stopHostTools()
                activity.stop()
                todos.stop()
                for sync in Array(agentTodos.values) { sync.stop() }
                agentTodos.removeAll()
                for id in knownAgents { onEvent?(.agentFinished(agentID: id, status: .interrupted, summary: error)) }
                onEvent?(.exited(error: error))
                // Deliver the failure before clearing work, otherwise the runtime
                // could publish a deferred success when a background process dies.
                publishActivity()
            }
        }
    }

    var isRunning: Bool { rpc.isRunning && !stopped }

    func start() async throws -> String {
        let span = RuntimeMetrics.begin(.sessionStartup)
        defer { RuntimeMetrics.end(span) }
        publishActivity()
        guard configuration.provider == .omp, let executable = configuration.executable else {
            throw ProviderError.notInstalled(.omp)
        }
        guard mode == .build else {
            throw ProviderError.failed(AppText.localized("OMP RPC does not expose plan mode. Use OMP's native planning tools."))
        }
        if let file = configuration.resumeID, !FileManager.default.fileExists(atPath: file) {
            throw ProviderError.failed(AppText.localized("OMP no longer has this conversation."))
        }
        var arguments = ["--mode", "rpc-ui", "--no-title", "--session-dir", StoragePaths.directory("omp/sessions").path]
        if let file = configuration.resumeID { arguments += ["--resume", file] }
        if let model, !model.isEmpty, model != "default" { arguments += ["--model", model] }
        if let effort, OMPCLI.thinkingLevels.contains(effort) { arguments += ["--thinking", effort] }
        // Auto means OMP's own configured policy; the other three map to native modes.
        switch configuration.runtimeMode {
        case .supervised: arguments += ["--approval-mode", "always-ask"]
        case .autoAcceptEdits: arguments += ["--approval-mode", "write"]
        case .fullAccess: arguments += ["--approval-mode", "yolo"]
        case .auto: break
        }
        // Keep a watched overlay even for native-default delegation. Changing only
        // this preference updates OMP's config without replacing a live worker process.
        do {
            let directory = StoragePaths.directory("omp/runtime")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(launchID).json")
            overlay = file
            try updateDelegationPreference(configuration.hydra)
            let extensionFile = directory.appendingPathComponent("\(launchID).ts")
            guidanceExtension = extensionFile
            try OMPSystemPrompt.guidanceExtension(enabled: configuration.antiSlopEnabled).write(to: extensionFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: extensionFile.path)
            arguments += ["--config", file.path, "--extension", extensionFile.path]
            var environment = configuration.environment
            environment["OMP_GUI_MEMORY_CONFIG"] = configuration.memory.json.compactString
            environment["OMP_GUI_BROWSER_COMPAT_ROOT"] = StoragePaths.directory("browser/sdk-compat").path
            environment["OMP_GUI_EVAL_RESTART_NOTICE"] = AppText.localized(
                "JavaScript kernel restarted after an unexpected worker exit; previous variables are no longer available.")
            let captureRoot = StoragePaths.directory("omp/requests")
            try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            environment["OMP_GUI_CAPTURE_ROOT"] = captureRoot.resolvingSymlinksInPath().path
            environment["OMP_GUI_SESSION_ROOT"] = StoragePaths.directory("omp/sessions").resolvingSymlinksInPath().path
            let launch = OMPSDKLaunch.command(executable: executable, arguments: arguments, environment: environment)
            if configuration.memory.enabled && launch.environment["OMP_GUI_NATIVE_EXECUTABLE"] == nil {
                throw ProviderError.failed(AppText.localized("Memory requires an OMP installation with the Mnemopi SDK and Bun."))
            }
            try rpc.start(executable: launch.executable, arguments: launch.arguments, directory: configuration.workingDirectory, environment: launch.environment)
            if let negotiated = try? await rpc.request("negotiate_protocol", fields: ["protocolVersion": 2]) {
                usesPromptResults = negotiated["protocolVersion"]?.int == 2
            }
            // Keep every native event while avoiding repeated accumulated
            // message snapshots where this process supports delta projection.
            // The decoder accepts both shapes, including during negotiation.
            _ = try? await rpc.request("set_event_filter", fields: [
                "events": .null, "messageUpdates": "delta"
            ], timeout: .seconds(5))
            let todoRevision = todos.revision
            let revision = stateRevision
            let state = try await readState(timeout: .seconds(60))
            todos.accept(await todoSnapshot(state), revision: todoRevision)
            sessionFile = state["sessionFile"]?.string ?? ""
            guard !sessionFile.isEmpty else { throw ProviderError.failed(AppText.localized("OMP did not return a session file.")) }
            sideQuestions.reset()
            decoder.contextWindow = state["model"]?["contextWindow"]?.int
            let catalog = try? await rpc.request("get_available_models", timeout: .seconds(60))
            let current = Self.modelSelector(state["model"])
            availableModels = catalog.map { OMPCLI.modelOptions($0["models"]?.array ?? [], current: current) } ?? configuration.modelCatalog
            for index in availableModels.indices {
                if let cached = configuration.modelCatalog.first(where: { $0.id == availableModels[index].id }) {
                    availableModels[index].efforts = cached.efforts
                    availableModels[index].defaultEffort = cached.defaultEffort
                    availableModels[index].metadata = availableModels[index].metadata?.merging(cached: cached.metadata) ?? cached.metadata
                }
            }
            await adoptState(state, revision: revision)
            // These are optional on older OMP releases; the native single-question
            // dialogs and chat remain available if the capability is absent.
            _ = try? await rpc.request("set_ask_dialog", fields: ["enabled": true])
            agentCapabilities.canCancel = await rpc.probeSubagentControl("cancel_subagent") == .supported
            agentCapabilities.canSteer = await rpc.probeSubagentControl("steer_subagent") == .supported
            if (try? await rpc.request("set_subagent_subscription", fields: ["level": "progress"])) != nil,
               let roster = try? await rpc.request("get_subagents") {
                for row in roster["subagents"]?.array ?? [] { startAgent(row) }
            }
            if let commands = try? await rpc.request("get_available_commands") {
                contextInspectionAvailable = commands["commands"]?.array?.contains(where: { $0["name"]?.string == "omp-gui-context" && $0["source"]?.string == "extension" }) == true
                if commands["commands"]?.array?.contains(where: { $0["name"]?.string == "omp-gui-queue" && $0["source"]?.string == "extension" }) == true,
                   let hello = try? await queueControl("hello", timeout: .seconds(5)),
                   hello["success"]?.bool == true, hello["protocolVersion"]?.int == 1 {
                    rpc.confirmQueueBridge()
                }
                memoryBridgeAvailable = commands["commands"]?.array?.contains(where: { $0["name"]?.string == "omp-gui-memory" && $0["source"]?.string == "extension" }) == true
                if commands["commands"]?.array?.contains(where: { $0["name"]?.string == "omp-gui-debug" && $0["source"]?.string == "extension" }) == true {
                    await connectDebugObservation()
                }
                if configuration.memory.enabled {
                    let memory = try await memoryControl("prepare")
                    guard memory["enabled"]?.bool == true else {
                        throw ProviderError.failed(AppText.localized("OMP did not confirm that memory is enabled."))
                    }
                }
                onEvent?(.commands(Self.commands(commands)))
            }
            if configuration.memory.enabled && !memoryBridgeAvailable {
                throw ProviderError.failed(AppText.localized("Memory requires an OMP installation with the Mnemopi SDK and Bun."))
            }
            onEvent?(.sessionReady(sessionID: sessionFile))
            await registerPreviewHostTools()
            return sessionFile
        } catch {
            await stopAndWait(timeout: 5)
            throw error
        }
    }

    /// Preserve admission order even when image preprocessing suspends. This
    /// waits only for request acceptance; execution remains OMP's native queue.
    func send(_ input: TurnInput) async throws {
        guard !isDraining else {
            throw ProviderError.failed(AppText.localized("OMP is saving the side question and closing this connection. Wait for it to finish."))
        }
        guard isRunning else { throw ProviderError.notRunning }
        let gateID = UUID()
        let previous = admissionTail?.task
        let pending = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            try Task.checkCancellation()
            guard let self else { throw ProviderError.notRunning }
            try await performSend(input)
        }
        admissionTasks[gateID] = pending
        admissionTail = (gateID, Task { _ = try? await pending.value })
        publishActivity()
        defer {
            admissionTasks[gateID] = nil
            if admissionTail?.id == gateID { admissionTail = nil }
            publishActivity()
        }
        try await withTaskCancellationHandler {
            try await pending.value
        } onCancel: {
            pending.cancel()
        }
    }

    private func performSend(_ input: TurnInput) async throws {
        guard !isDraining else { throw ProviderError.notRunning }
        guard isRunning else { throw ProviderError.notRunning }
        guard !nativeHistoryTransitionInFlight else { throw OMPHistoryError.sessionBusy }
        if configuration.memory.enabled { _ = try await memoryControl("prepare") }
        try Task.checkCancellation()
        guard contextSnapshot.pendingRequestID == nil else {
            throw ProviderError.failed(AppText.localized("Wait until OMP has confirmed the context action before sending another message."))
        }
        let id = input.ompRequestID ?? UUID()
        guard submissions[id] == nil, !completedSubmissionIDs.contains(id) else {
            throw ProviderError.failed(AppText.localized("This message was already submitted. Check its delivery status before sending again."))
        }
        // Model changes belong to a fresh prompt. Steering must not replace the
        // live run's model or configuration while tools/approvals are in flight.
        if input.ompDelivery == .prompt {
            guard !hasLivePrompt else { throw ProviderError.failed(AppText.localized("OMP is still on the last turn.")) }
            stateRevision += 1
            todos.invalidate()
            if let wanted = input.model, wanted != model, let slash = wanted.firstIndex(of: "/") {
                _ = try await rpc.request("set_model", fields: ["provider": .string(String(wanted[..<slash])), "modelId": .string(String(wanted[wanted.index(after: slash)...]))])
                model = wanted
                let todoRevision = todos.revision
                let revision = stateRevision
                let state = try await readState()
                todos.accept(await todoSnapshot(state), revision: todoRevision)
                await adoptState(state, revision: revision)
            }
            if let wanted = input.effort, wanted != effort {
                _ = try await rpc.request("set_thinking_level", fields: ["level": .string(wanted)])
                effort = wanted
            }
        }
        let encoded = await Attachment.base64Images(input.images)
        guard encoded.count == input.images.filter(\.isImage).count else {
            throw ProviderError.failed(AppText.localized("An attached image could not be read. The message was not submitted."))
        }
        try Task.checkCancellation()
        guard isRunning else { throw ProviderError.notRunning }
        guard !nativeHistoryTransitionInFlight else { throw OMPHistoryError.sessionBusy }
        guard contextSnapshot.pendingRequestID == nil else {
            throw ProviderError.failed(AppText.localized("Wait until OMP has confirmed the context action before sending another message."))
        }
        let images: [JSONValue] = encoded.map { image, base64 in
            ["type": "image", "data": .string(base64), "mimeType": .string(image.mimeType)]
        }
        var fields: [String: JSONValue] = ["message": .string(input.text)]
        if !images.isEmpty { fields["images"] = .array(images) }
        submissions[id] = Submission(id: id, delivery: input.ompDelivery, text: input.text, imageCount: images.count,
            runGeneration: nativeRunGeneration)
        submissionOrder.append(id)
        onEvent?(.ompSubmission(id: id, state: .submitting, error: nil))
        activity.beginPrompt(id.uuidString)
        if input.ompDelivery == .prompt || input.ompDelivery == .stopAndSend {
            if input.ompDelivery == .prompt {
                interruptRequested = false
                turnError = nil
                onEvent?(.turnStarted(providerTurnID: id.uuidString))
            }
        }
        publishActivity()
        do {
            let response: JSONValue
            if input.ompDelivery == .followUp, canWithdrawQueuedMessages {
                let result = try await queueControl("follow_up", submissionID: id, fields: fields)
                if result["deliveryUnknown"]?.bool == true {
                    throw ProviderError.failed(queueControlError(result))
                }
                response = .object(["success": result["success"] ?? false, "error": .string(queueControlError(result))])
            } else {
                response = try await rpc.response(input.ompDelivery.command, fields: fields, id: id.uuidString, timeout: .seconds(60))
            }
            guard response["success"]?.bool == true else {
                let error = response["error"]?.string ?? AppText.localized("OMP rejected the request.")
                updateSubmission(id, state: .failed, error: error)
                submissions[id]?.completed = true
                activity.endPrompt(id.uuidString)
                publishActivity()
                throw ProviderError.failed(error)
            }
            updateSubmission(id, state: .accepted)
            if input.ompDelivery == .steer || input.ompDelivery == .followUp {
                activity.endPrompt(id.uuidString)
                publishActivity()
            }
            if response["data"]?["agentInvoked"]?.bool == false {
                updateSubmission(id, state: .consumed)
                completePrompt(id, status: .completed)
            }
            // Queue counts and native settlement are authoritative. A failed
            // status refresh never retracts a positive admission response.
            _ = try? await readState(timeout: .seconds(5))
        } catch {
            if submissions[id]?.state != .failed && submissions[id]?.state.isTerminal != true {
                updateSubmission(id, state: .unknown, error: AppText.localized("OMP did not confirm delivery. This message will not be sent again automatically."))
            }
            // The command may have reached OMP. Keep its identity and pending
            // lifecycle so a late response/result can resolve it without a retry.
            throw error
        }
    }

    private func updateSubmission(_ id: UUID, state: OMPSubmissionState, error: String? = nil) {
        guard let previous = submissions[id]?.state else { return }
        guard !previous.isTerminal || state == previous else { return }
        submissions[id]?.state = state
        onEvent?(.ompSubmission(id: id, state: state, error: error))
    }

    /// True only after the native queue removed this exact submission. A
    /// consumed message is never restored locally on a negative/unknown result.
    func withdrawFollowUp(_ id: UUID) async throws -> Bool {
        guard canWithdrawQueuedMessages else {
            throw ProviderError.failed(AppText.localized("This OMP installation does not support recalling queued messages."))
        }
        if withdrawnSubmissionIDs.contains(id) { return true }
        if completedSubmissionIDs.contains(id), submissions[id] == nil { return false }
        guard let row = submissions[id], row.delivery == .followUp, row.state == .accepted || row.state == .unknown else { return false }
        let result = try await queueControl("remove_follow_up", submissionID: id)
        guard result["success"]?.bool == true else { throw ProviderError.failed(queueControlError(result)) }
        let removed = result["removed"]?.bool == true
        _ = try? await readState(timeout: .seconds(5))
        return removed
    }

    private func queueControl(_ operation: String, submissionID: UUID? = nil,
                              fields: [String: JSONValue] = [:], timeout: Duration = .seconds(60)) async throws -> JSONValue {
        guard isRunning else { throw ProviderError.notRunning }
        let requestID = UUID().uuidString
        var payload = fields
        payload["requestID"] = .string(requestID)
        payload["operation"] = .string(operation)
        if let submissionID { payload["submissionID"] = .string(submissionID.uuidString) }
        let message = "/omp-gui-queue " + String(decoding: JSONValue.object(payload).data(), as: UTF8.self)
        queueControls[requestID] = QueueControl(operation: operation, submissionID: submissionID)
        queueControlOrder.append(requestID)
        // Keep late-outcome correlations after timeout, but never retain text
        // or image payloads. A positive late removal still retires identity.
        while queueControlOrder.count > 512 {
            let oldest = queueControlOrder.removeFirst()
            queueControls[oldest] = nil
        }
        return try await queueReplies.register(requestID, timeout: timeout) {
            rpc.send(["type": "prompt", "id": .string("omp-gui-control-" + requestID), "message": .string(message)]) { [weak self] delivered in
                if !delivered { self?.queueReplies.fail(requestID, ProviderError.notRunning) }
            }
        }
    }

    private func queueControlError(_ result: JSONValue) -> String {
        if result["error"]?.string == "identity_unknown" {
            return AppText.localized("OMP could not uniquely identify this queued message. It was left in the native queue.")
        }
        if result["error"]?.string == "unsupported" {
            return AppText.localized("This OMP installation does not support recalling queued messages.")
        }
        return AppText.localized("OMP could not complete the queued-message action. The message was not restored or deleted locally.")
    }

    /// Private control notifications are correlated before any activity,
    /// timeline or ordinary extension UI handling observes them.
    private func handleQueueControl(_ frame: JSONValue) -> Bool {
        if frame["type"]?.string == "extension_ui_request", frame["method"]?.string == "notify",
           let message = frame["message"]?.string, message.hasPrefix("OMP_GUI_QUEUE_RESULT:") {
            guard let result = JSONValue.parse(String(message.dropFirst("OMP_GUI_QUEUE_RESULT:".count))),
                  let requestID = result["requestID"]?.string, let control = queueControls[requestID],
                  result["operation"]?.string == control.operation else { return true }
            if control.operation == "remove_follow_up", result["success"]?.bool == true, result["removed"]?.bool == true,
               let id = control.submissionID {
                // Retire before resolving the waiter: the next native frame
                // may contain an identical remaining queued user message.
                submissions[id] = nil
                submissionOrder.removeAll { $0 == id }
                completedSubmissionIDs.insert(id)
                if !withdrawnSubmissionIDs.contains(id) {
                    withdrawnSubmissionIDs.append(id)
                    if withdrawnSubmissionIDs.count > 512 { withdrawnSubmissionIDs.removeFirst() }
                }
                activity.endPrompt(id.uuidString)
                publishActivity()
                refreshActivityAfterLifecycle()
            } else if control.operation == "follow_up", let id = control.submissionID,
                      submissions[id]?.state.isTerminal != true {
                if result["success"]?.bool == true {
                    updateSubmission(id, state: .accepted)
                    activity.endPrompt(id.uuidString)
                } else if result["deliveryUnknown"]?.bool == true {
                    updateSubmission(id, state: .unknown, error: queueControlError(result))
                } else {
                    updateSubmission(id, state: .failed, error: queueControlError(result))
                    submissions[id]?.completed = true
                    activity.endPrompt(id.uuidString)
                }
                publishActivity()
                refreshActivityAfterLifecycle()
            }
            queueReplies.resolve(requestID, result)
            return true
        }
        if let id = frame["id"]?.string, id.hasPrefix("omp-gui-control-") {
            let requestID = String(id.dropFirst("omp-gui-control-".count))
            guard queueControls[requestID] != nil else { return true }
            if frame["type"]?.string == "response", frame["success"]?.bool == false {
                queueReplies.fail(requestID, ProviderError.failed(queueControlError(frame)))
            } else if frame["type"]?.string == "prompt_result", frame["status"]?.string == "error" {
                queueReplies.fail(requestID, ProviderError.failed(queueControlError(frame)))
            }
            return true
        }
        return false
    }

    private func preserveUnconsumedSubmissions() {
        for id in submissionOrder where submissions[id]?.state.isTerminal != true && submissions[id]?.state != .failed {
            updateSubmission(id, state: .unknown, error: AppText.localized("OMP disconnected before this message was observed in the conversation. Delivery is unknown; it will not be resent automatically."))
        }
    }

    /// Keep small identity tombstones, rather than every submitted text payload.
    private func pruneCompletedSubmissions() {
        let completed = Set(submissions.values.filter {
            $0.completed && ($0.state.isTerminal || $0.state == .failed)
        }.map(\.id))
        completedSubmissionIDs.formUnion(completed)
        for id in completed { submissions[id] = nil }
        submissionOrder.removeAll { completed.contains($0) }
    }

    /// A terminal native snapshot proves the accepted queue drained, without
    /// inventing a match between transformed input and a durable user entry.
    private func reconcileAcceptedQueueIfSettled() {
        let value = activity.value
        guard value.settled == true, !value.streaming, value.queuedMessages == 0 else { return }
        for id in submissionOrder {
            guard let row = submissions[id], row.state == .accepted,
                  row.delivery == .steer || row.delivery == .followUp else { continue }
            updateSubmission(id, state: .finished,
                error: AppText.localized("OMP is settled and its queue is empty. This message's individual consumption could not be verified."))
            submissions[id]?.completed = true
        }
        pruneCompletedSubmissions()
    }

    private func observeUserMessage(_ frame: JSONValue) {
        guard frame["type"]?.string == "message_end", frame["message"]?["role"]?.string == "user" else { return }
        if let nativeID = frame["messageId"]?.string, !observedUserMessageIDs.insert(nativeID).inserted { return }
        let content = frame["message"]?["content"]
        let text = content?.string ?? content?.array?.compactMap { $0["text"]?.string }.joined() ?? ""
        let images = content?.array?.filter { $0["type"]?.string == "image" }.count ?? 0
        // The public protocol has no request id on user messages. Only exact
        // payload matches prove consumption; expanded templates stay accepted.
        let matches = submissionOrder.filter { id in
            guard let row = submissions[id], !row.state.isTerminal, row.state != .failed else { return false }
            return row.text == text && row.imageCount == images
        }
        // OMP consumes steering before follow-ups, retaining FIFO within each.
        let id = matches.first { submissions[$0]?.delivery != .followUp } ?? matches.first
        let delivery = id.flatMap { submissions[$0]?.delivery }
        let startsNewTurn = completedReplyBeforeNextUser && delivery != .steer && delivery != .stopAndSend
        // OMP drains steering before follow-ups at a stop boundary. Preserve
        // the candidate through known steering in the same batch; the first
        // follow-up (or unmatched transformed user) owns it. Hidden image/video
        // companions do not emit user entries and leave it untouched as well.
        if delivery != .steer { completedReplyBeforeNextUser = false }
        if let id {
            updateSubmission(id, state: .consumed)
            if submissions[id]?.delivery == .steer || submissions[id]?.delivery == .followUp {
                activity.endPrompt(id.uuidString)
                submissions[id]?.completed = true
            }
        }
        onEvent?(.ompUserMessage(requestID: id, nativeID: frame["messageId"]?.string, text: text,
            imageCount: images, startsNewTurn: startsNewTurn))
        pruneCompletedSubmissions()
        // The queued count came from a prior snapshot. A native user entry
        // means OMP has consumed an input, so read its remaining queue again.
        refreshActivityAfterLifecycle()
    }

    /// A successful native branch replaces all process-local queue identities.
    func resetNativeSessionState(_ state: JSONValue) async {
        let hadDebugBridge = debugSnapshot.supported
        disconnectDebugObservation()
        debugSnapshot = OMPDebugSnapshot()
        resetGoalObservation()
        sideQuestions.reset()
        preserveUnconsumedSubmissions()
        memoryReplies.failAll(ProviderError.notRunning)
        contextInspectionReplies.failAll(ProviderError.notRunning)
        queueReplies.failAll(ProviderError.notRunning)
        queueControls.removeAll()
        queueControlOrder.removeAll()
        withdrawnSubmissionIDs.removeAll()
        stopHostTools()
        submissions.removeAll()
        submissionOrder.removeAll()
        completedSubmissionIDs.removeAll()
        observedUserMessageIDs.removeAll()
        completedReplyBeforeNextUser = false
        nativeRunGeneration = 0
        latestRunOutcome = nil
        decoder.resetForSession()
        contextRead?.task.cancel()
        contextRead = nil
        contextSnapshot = OMPContextSnapshot()
        contextRefreshedRevision = nil
        contextHistoryNeedsRefresh = true
        runOptions = OMPRunOptionsSnapshot()
        for sync in agentTodos.values { sync.stop() }
        agentTodos.removeAll()
        agents.removeAll()
        knownAgents.removeAll()
        agentMetadata.removeAll()
        stopAgentDetails()
        reusedAgentIDs.removeAll()
        clearExtensionUI()
        stateRead?.task.cancel()
        stateRead = nil
        stateRevision += 1
        activity = OMPActivityTracker()
        _ = activity.accept(state, revision: activity.revision)
        publishActivity()
        todos.invalidate()
        todos.accept(await todoSnapshot(state), revision: todos.revision)
        sessionFile = state["sessionFile"]?.string ?? sessionFile
        observeGoalState(state, revision: goalSnapshot.revision)
        observeContextState(state)
        observeRunOptionsState(state)
        await adoptState(state, revision: stateRevision)
        if hadDebugBridge { await connectDebugObservation() }
        onEvent?(.sessionReady(sessionID: sessionFile))
    }

    func interrupt() async {
        completedReplyBeforeNextUser = false
        interruptRequested = true
        _ = try? await rpc.request("abort")
    }

    func compact() async throws {
        _ = try await compactContext(customInstructions: nil)
    }

    func stop() {
        completedReplyBeforeNextUser = false
        preserveUnconsumedSubmissions()
        memoryReplies.failAll(ProviderError.notRunning)
        contextInspectionReplies.failAll(ProviderError.notRunning)
        disconnectDebugObservation()
        queueReplies.failAll(ProviderError.notRunning)
        stopped = true
        sideQuestions.exited(cleanDrain: false)
        stopRunOptions()
        disconnectGoalObservation()
        stopAgentDetails()
        stopHostTools()
        clearExtensionUI()
        for pending in admissionTasks.values { pending.cancel() }
        activity.stop()
        publishActivity()
        stateRead?.task.cancel()
        stateRead = nil
        todos.stop()
        for sync in Array(agentTodos.values) { sync.stop() }
        agentTodos.removeAll()
        rpc.stop()
        removeRuntimeFiles()
    }

    private func removeRuntimeFiles() {
        if let overlay { try? FileManager.default.removeItem(at: overlay) }
        overlay = nil
        if let guidanceExtension { try? FileManager.default.removeItem(at: guidanceExtension) }
        guidanceExtension = nil
    }
    func stopAndWait(timeout: TimeInterval) async { stop(); await rpc.stopAndWait(timeout: timeout) }

    func stopAgent(_ id: String) async -> Bool {
        guard agentCapabilities.canCancel else {
            onEvent?(.notice(Notice(level: .warning, message: AppText.localized("This OMP version cannot stop individual heads. Update OMP to enable this control."))))
            return false
        }
        guard isRunning, knownAgents.contains(id) else { return false }
        do {
            let response = try await rpc.request("cancel_subagent", fields: ["subagentId": .string(id)])
            guard OMPSubagentCapabilities.confirmedCancellation(response) else {
                onEvent?(.notice(Notice(level: .warning, message: AppText.localized("OMP did not cancel the head; it may already have finished."))))
                return false
            }
            // The native lifecycle frame, not request acceptance, ends the UI worker.
            return true
        }
        catch { onEvent?(.notice(Notice(level: .error, message: error.localizedDescription))); return false }
    }

    func steerAgent(_ id: String, message: String) async throws {
        guard agentCapabilities.canSteer else {
            throw ProviderError.failed(AppText.localized("This OMP version cannot send additional instructions to heads. Update OMP to enable this control."))
        }
        guard isRunning, knownAgents.contains(id) else {
            throw ProviderError.failed(AppText.localized("This head is no longer running in OMP."))
        }
        _ = try await rpc.request("steer_subagent", fields: ["subagentId": .string(id), "message": .string(message)], timeout: .seconds(60))
    }

    func canControlAgent(_ id: String, steering: Bool) -> Bool {
        isRunning && knownAgents.contains(id) && (steering ? agentCapabilities.canSteer : agentCapabilities.canCancel)
    }

    func updateDelegationPreference(_ launch: HydraLaunch?) throws {
        guard let overlay else { throw ProviderError.notRunning }
        guard case .object(var value) = Self.delegationConfiguration(launch) else { return }
        value["memory"] = ["backend": "off"]
        try JSONValue.object(value).data().write(to: overlay, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: overlay.path)
    }

    static func delegationConfiguration(_ launch: HydraLaunch?) -> JSONValue {
        var task: [String: JSONValue] = [:]
        if let launch {
            task["eager"] = "preferred"
            if let worker = launch.workerModel {
                let selector = launch.workerEffort.map { worker + ":" + $0 } ?? worker
                task["agentModelOverrides"] = ["task": .string(selector)]
            }
            if let cap = launch.maxHeads { task["maxConcurrency"] = .int(cap) }
        }
        // Use OMP's native queue at tool boundaries. Its Codex native lane can
        // reject response.steer; transport, retry and worker inheritance stay OMP-owned.
        var value: [String: JSONValue] = ["providers": ["openaiLiveSteering": false]]
        if !task.isEmpty { value["task"] = .object(task) }
        return .object(value)
    }

    func resolveApproval(_ requestID: String, optionID: String) {
        resolveApproval(requestID, optionID: optionID, delivered: { _ in })
    }
    func resolveApproval(_ requestID: String, optionID: String, delivered: @escaping @MainActor (Bool) -> Void) {
        guard let dialog = dialogs[requestID] else { delivered(false); return }
        let choices = dialog.responseFormat == .confirmation ? ["Yes", "No"]
            : dialog.toolApproval.map { [$0.onceChoice, "Deny"] } ?? []
        guard choices.contains(optionID) else { delivered(false); return }
        answerQuestion(requestID, answers: [requestID: QuestionAnswer(selectedOptions: [optionID])], delivered: delivered)
    }
    func answerQuestion(_ requestID: String, answers: [String: QuestionAnswer]) {
        answerQuestion(requestID, answers: answers, delivered: { _ in })
    }
    func answerQuestion(_ requestID: String, answers: [String: QuestionAnswer], delivered: @escaping @MainActor (Bool) -> Void) {
        guard let dialog = dialogs[requestID], isRunning else { delivered(false); return }
        if let deadline = dialog.deadline, deadline <= .now {
            expireDialog(requestID, instanceID: dialog.instanceID)
            delivered(false)
            return
        }
        guard inFlightAnswers.insert(dialog.instanceID).inserted else { delivered(false); return }
        rpc.send(OMPExtensionDialog.response(to: dialog, answers: answers)) { [weak self] accepted in
            guard let self else { delivered(false); return }
            inFlightAnswers.remove(dialog.instanceID)
            guard dialogs[requestID]?.instanceID == dialog.instanceID else { delivered(false); return }
            if accepted {
                dialogs[requestID] = nil
                dialogTimeouts.removeValue(forKey: requestID)?.cancel()
                activity.answer(requestID)
                publishActivity()
                onEvent?(.ompRequestEnded(instanceID: dialog.instanceID, reason: .delivered))
                onEvent?(.requestResolved(id: requestID))
            }
            delivered(accepted)
        }
    }

    private func handle(_ frame: JSONValue) {
        if handleContextInspection(frame) { return }
        if sideQuestions.observe(frame) { return }
        if handleMemoryControl(frame) { return }
        if handleDebugControl(frame) { return }
        if handleQueueControl(frame) { return }
        if frame["type"]?.string == "omp_gui_deferred_context", frame["sessionFile"]?.string != sessionFile { return }
        observeReplyBoundary(frame)
        activity.observe(frame)
        observeContextFrame(frame)
        observeRunOptionsFrame(frame)
        observeGoalFrame(frame)
        observeUserMessage(frame)
        publishActivity()
        todos.observe(frame)
        observeAgentResults(frame)
        switch frame["type"]?.string {
        case "host_tool_call", "host_tool_cancel": handleHostToolFrame(frame)
        case "omp_gui_browser_ready": browserAutomationAvailable = true
        case "agent_start":
            nativeRunGeneration += 1
            turnError = nil
            interruptRequested = false
            if !hasLivePrompt { turnError = nil; onEvent?(.turnStarted(providerTurnID: nil)) }
        case "prompt_result":
            guard let rawID = frame["id"]?.string, let id = UUID(uuidString: rawID), submissions[id] != nil else { return }
            let status: TurnStatus = frame["status"]?.string == "aborted" ? .interrupted
                : frame["status"]?.string == "error" ? .failed : .completed
            if frame["agentInvoked"]?.bool == false {
                updateSubmission(id, state: status == .completed ? .consumed : .failed,
                    error: frame["error"]?["message"]?.string)
            }
            completePrompt(id, status: status, error: frame["error"]?["message"]?.string)
        case "agent_end":
            if frame["isTerminal"]?.bool != false {
                let lastAssistant = frame["messages"]?.array?.last { $0["role"]?.string == "assistant" }
                let reason = lastAssistant?["stopReason"]?.string
                let error = lastAssistant?["errorMessage"]?.string ?? turnError
                let status: TurnStatus = reason == "aborted" || interruptRequested ? .interrupted
                    : reason == "error" || error != nil ? .failed : .completed
                latestRunOutcome = (nativeRunGeneration, status, error)
                if !usesPromptResults {
                    for id in submissionOrder where submissions[id]?.completed == false {
                        submissions[id]?.completed = true
                        activity.endPrompt(id.uuidString)
                    }
                    publishActivity()
                    onEvent?(.turnCompleted(status: status, error: error))
                } else if !hasLivePrompt {
                    onEvent?(.turnCompleted(status: status, error: error))
                }
                // A background result can resume the agent without a prompt
                // ticket. It has no prompt_result to refresh get_state for us.
                // agent_end is only a yield: ask OMP whether work remains.
                refreshActivityAfterLifecycle()
            }
        case "response":
            // A response arriving after its admission timeout remains useful,
            // but never initiates another command.
            if let rawID = frame["id"]?.string, let id = UUID(uuidString: rawID), let row = submissions[id],
               frame["command"]?.string == row.delivery.command {
                updateSubmission(id, state: frame["success"]?.bool == true ? .accepted : .failed, error: frame["error"]?.string)
                if frame["success"]?.bool == true, frame["data"]?["agentInvoked"]?.bool == false {
                    updateSubmission(id, state: .consumed)
                    completePrompt(id, status: .completed)
                }
                if frame["success"]?.bool == true, row.delivery == .steer || row.delivery == .followUp {
                    activity.endPrompt(id.uuidString)
                    publishActivity()
                    Task { [weak self] in _ = try? await self?.readState(timeout: .seconds(5)) }
                }
                if frame["success"]?.bool == false {
                    submissions[id]?.completed = true
                    activity.endPrompt(id.uuidString)
                    publishActivity()
                }
            }
        case "command_output":
            if let text = frame["text"]?.string { onEvent?(.messageCompleted(id: "\(launchID)-command-\(UUID().uuidString)", text: text)) }
        case "available_commands_update":
            onEvent?(.commands(Self.commands(frame)))
        case "config_update":
            stateRevision += 1
            decoder.contextWindow = frame["model"]?["contextWindow"]?.int
            onEvent?(.models(availableModels, current: Self.modelSelector(frame["model"])))
            onEvent?(.effortChanged(frame["thinkingLevel"]?.string))
        case "session_info_update":
            if let title = frame["title"]?.string { onEvent?(.title(title)) }
        case "subagent_lifecycle", "subagent_progress", "subagent_event":
            handleSubagentFrame(frame)
            if frame["type"]?.string == "subagent_lifecycle", frame["payload"]?["status"]?.string != "started" {
                refreshActivityAfterLifecycle()
            }
        case "extension_ui_request": handleUI(frame)
        case "session_settled":
            reconcileAcceptedQueueIfSettled()
            publishActivity()
            break // publishActivity already delivered the native transition.
        case "omp_gui_deferred_context": break // SDK observation already published above; queues remain in OMP.
        case "extension_error": onEvent?(.notice(Notice(level: .error, message: frame["error"]?.string ?? AppText.localized("OMP reported an extension error."))))
        default:
            if frame["message"]?["stopReason"]?.string == "error" { turnError = frame["message"]?["errorMessage"]?.string }
            decoder.handle(frame)
        }
    }

    /// OMP emits turn_end after every model/tool iteration. Only a successful
    /// reply without tools can precede a new follow-up display group. In
    /// particular, pause_turn is a native continuation despite stopReason=stop.
    private func observeReplyBoundary(_ frame: JSONValue) {
        switch frame["type"]?.string {
        case "turn_end":
            let message = frame["message"]
            let reason = message?["stopReason"]?.string
            completedReplyBeforeNextUser = message?["role"]?.string == "assistant"
                && (reason == "stop" || reason == "length")
                && message?["stopDetails"]?["type"]?.string != "pause_turn"
                && message?["content"]?.array?.contains(where: { $0["type"]?.string == "toolCall" }) == false
                && frame["toolResults"]?.array?.isEmpty == true
                && !interruptRequested
        case "message_start", "message_update", "message_end":
            if frame["message"]?["role"]?.string == "assistant"
                || frame["type"]?.string == "message_update" {
                completedReplyBeforeNextUser = false
            }
        case "agent_start", "agent_end", "tool_execution_start", "tool_execution_update", "tool_execution_end":
            completedReplyBeforeNextUser = false
        default: break
        }
    }

    private func completePrompt(_ id: UUID, status: TurnStatus, error: String? = nil) {
        guard let row = submissions[id], !row.completed else { return }
        submissions[id]?.completed = true
        if !row.state.isTerminal && row.state != .failed {
            updateSubmission(id, state: .finished,
                error: AppText.localized("OMP finished this request. Its user entry could not be matched; the original message is retained here."))
        }
        onEvent?(.ompPromptOutcome(id: id, status: status, error: error))
        if activity.value.prompts.contains(id.uuidString) { activity.endPrompt(id.uuidString) }
        publishActivity()
        todos.invalidate()
        todos.refresh()
        // Interleaved results from the aborted run cannot close a newer prompt.
        if !hasLivePrompt && !activity.value.streaming {
            let outcome = latestRunOutcome.flatMap { $0.generation > row.runGeneration + 1 ? $0 : nil }
            if let outcome { onEvent?(.turnCompleted(status: outcome.status, error: outcome.error)) }
            else { onEvent?(.turnCompleted(status: status, error: error)) }
        }
        pruneCompletedSubmissions()
        Task { [weak self] in
            guard let self, isRunning else { return }
            let revision = stateRevision
            let todoRevision = todos.revision
            guard let state = try? await readState(), stateRevision == revision else { return }
            todos.accept(await todoSnapshot(state), revision: todoRevision)
            guard stateRevision == revision, isRunning else { return }
            if let file = state["sessionFile"]?.string { sessionFile = file; onEvent?(.sessionReady(sessionID: file)) }
            await adoptState(state, revision: revision)
        }
    }

    func publishActivity() {
        let value = nativeActivity
        guard value != publishedActivity else { return }
        publishedActivity = value
        onEvent?(.ompActivity(value))
        onEvent?(.backgroundTasks(value.pendingAsyncWork ? [AppText.localized("OMP background work")] : []))
    }

    private func refreshActivityAfterLifecycle() {
        Task { [weak self] in
            guard let self, isRunning else { return }
            // readState coalesces matching reads and fences replies against
            // newer lifecycle events; a late snapshot cannot revive old work.
            _ = try? await readState(timeout: .seconds(5))
        }
    }

    /// Share reads only while both native work and model/config identity match.
    /// A newer lifecycle event invalidates publication of an older response.
    func readState(timeout: Duration = .seconds(30), publishesContext: Bool = true) async throws -> JSONValue {
        let revision = activity.revision
        let modelRevision = stateRevision
        let goalRevision = goalSnapshot.revision
        if let read = stateRead, read.revision == revision, read.modelRevision == stateRevision {
            return try await read.task.value
        }
        let id = UUID()
        let task = Task { try await rpc.request("get_state", timeout: timeout) }
        stateRead = (id, revision, stateRevision, task)
        defer { if stateRead?.id == id { stateRead = nil } }
        let value = try await task.value
        if stateRevision == modelRevision, activity.accept(value, revision: revision) {
            goalNeedsSettlement = false
            observeGoalState(value, revision: goalRevision)
            reconcileAcceptedQueueIfSettled()
            observeContextState(value, publishes: publishesContext)
            observeRunOptionsState(value)
            publishActivity()
        }
        return value
    }

    private func todoSnapshot(_ state: JSONValue) async -> TodoSnapshot? {
        guard let steps = OMPTodoSnapshot.decode(state["todoPhases"]) else { return nil }
        guard steps.isEmpty else { return TodoSnapshot(steps: steps) }
        // Public append-history includes eval's custom commits, which get_messages
        // omits. OMP's leafId selects the active branch, even after a rewind.
        if let history = try? await rpc.request("get_entries", timeout: .seconds(5)),
           let snapshot = OMPTodoSnapshot.snapshot(from: history["entries"], leafID: history["leafId"]) {
            // Active state always comes from get_state. History is only the
            // completion record, never authority to revive open work.
            return TodoSnapshot(steps: steps, recentList: snapshot.recentList)
        }
        return TodoSnapshot(steps: steps)
    }

    private func clearExtensionUI() {
        extensionPublishTask?.cancel()
        extensionPublishTask = nil
        for timer in dialogTimeouts.values { timer.cancel() }
        dialogTimeouts.removeAll()
        for (id, dialog) in dialogs {
            onEvent?(.ompRequestEnded(instanceID: dialog.instanceID, reason: .disconnected))
            onEvent?(.requestResolved(id: id))
        }
        dialogs.removeAll()
        inFlightAnswers.removeAll()
        extensionState = OMPExtensionState()
        onEvent?(.ompExtensionReset)
        onEvent?(.ompExtensionState(extensionState))
    }

    private func expireDialog(_ id: String, instanceID: UUID) {
        guard dialogs[id]?.instanceID == instanceID else { return }
        dialogs[id] = nil
        onEvent?(.ompRequestEnded(instanceID: instanceID, reason: .timedOut))
        dialogTimeouts.removeValue(forKey: id)?.cancel()
        // OMP may already have expired its own promise. This response cannot
        // start another request and tells older runtimes why it was cancelled.
        rpc.send(["type": "extension_ui_response", "id": .string(id), "cancelled": true, "timedOut": true])
        activity.answer(id)
        publishActivity()
        onEvent?(.requestResolved(id: id))
    }

    private func handleUI(_ frame: JSONValue) {
        guard let id = frame["id"]?.string, let method = frame["method"]?.string else { return }
        if method == "cancel" {
            if let target = frame["targetId"]?.string {
                if let dialog = dialogs.removeValue(forKey: target) {
                    onEvent?(.ompRequestEnded(instanceID: dialog.instanceID, reason: .cancelled))
                }
                dialogTimeouts.removeValue(forKey: target)?.cancel()
                onEvent?(.requestResolved(id: target))
            }
            return
        }
        if method == "notify" {
            let level: Notice.Level = frame["notifyType"]?.string == "error" ? .error : frame["notifyType"]?.string == "warning" ? .warning : .info
            onEvent?(.notice(Notice(level: level, message: frame["message"]?.string ?? "")))
            return
        }
        if method == "setTitle", let title = frame["title"]?.string { onEvent?(.title(title)); return }
        if method == "set_editor_text", let text = frame["text"]?.string { onEvent?(.ompEditorText(text)); return }
        if method == "open_url", let link = OMPLoginLink(frame) { onEvent?(.ompLoginURL(link)); return }
        if extensionState.observe(frame) {
            // Coalesce status/widget bursts without delaying interactive dialogs.
            if extensionPublishTask == nil {
                extensionPublishTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self else { return }
                    extensionPublishTask = nil
                    onEvent?(.ompExtensionState(extensionState))
                }
            }
            return
        }
        guard let request = OMPExtensionDialog.request(frame) else { return }
        if let previous = dialogs[id] { onEvent?(.ompRequestEnded(instanceID: previous.instanceID, reason: .cancelled)) }
        dialogs[id] = request
        dialogTimeouts.removeValue(forKey: id)?.cancel()
        if let deadline = request.deadline {
            dialogTimeouts[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                self?.expireDialog(id, instanceID: request.instanceID)
            }
        }
        if let approval = OMPExtensionDialog.approval(for: request, frame: frame) {
            onEvent?(.approval(approval))
        } else {
            onEvent?(.question(request))
        }
    }

    static func commands(_ value: JSONValue) -> [SlashCommand] {
        SlashCommand.ompCommands(value).filter { !["omp-gui-queue", "omp-gui-memory", "omp-gui-debug", "omp-gui-context"].contains($0.name) }
    }

    static func modelSelector(_ value: JSONValue?) -> String? {
        guard let provider = value?["provider"]?.string, let id = value?["id"]?.string else { return nil }
        return "\(provider)/\(id)"
    }

    func adoptState(_ state: JSONValue, revision: Int) async {
        guard stateRevision == revision else { return }
        let current = Self.modelSelector(state["model"])
        var currentLevels: [String]?
        if let current, let index = availableModels.firstIndex(where: { $0.id == current }),
           let response = try? await rpc.request("get_available_thinking_levels"), let levels = response["levels"]?.array {
            _ = index
            currentLevels = levels.compactMap(\.string)
        }
        guard stateRevision == revision else { return }
        model = current
        effort = state["thinkingLevel"]?.string
        fastMode = state["fastModeEnabled"]?.bool ?? false
        decoder.contextWindow = state["model"]?["contextWindow"]?.int
        if let currentLevels, let index = availableModels.firstIndex(where: { $0.id == current }) {
            availableModels[index].efforts = currentLevels
            availableModels[index].defaultEffort = effort
        }
        onEvent?(.models(availableModels, current: current))
        onEvent?(.effortChanged(effort))
        onEvent?(.fastModeChanged(fastMode))
    }
}
