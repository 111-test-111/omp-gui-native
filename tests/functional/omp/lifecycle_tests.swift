import Foundation
import AppKit
@testable import OMPGUI

@main
struct OMPP0Checks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        checks += 1
    }
    private static func frame(_ text: String) -> JSONValue { JSONValue.parse(text)! }

    @MainActor private static func checkLaunchSelection(_ root: URL) async throws {
        let settings = AppSettings()
        let previousProject = settings.lastProjectID
        let previousSelection = settings.lastSelectedThreadID
        defer {
            settings.lastProjectID = previousProject
            settings.lastSelectedThreadID = previousSelection
        }
        let project = Project(name: "Viewed project", path: root.appendingPathComponent("viewed").path)
        let otherProject = Project(name: "Other project", path: root.appendingPathComponent("other").path)
        var viewed = ChatThread(projectID: project.id, provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        viewed.updatedAt = Date(timeIntervalSince1970: 10)
        var interrupted = viewed
        interrupted.id = UUID()
        interrupted.lastStatus = .interrupted
        interrupted.updatedAt = Date(timeIntervalSince1970: 20)
        var recent = viewed
        recent.id = UUID()
        recent.updatedAt = Date(timeIntervalSince1970: 30)
        var other = viewed
        other.id = UUID()
        other.projectID = otherProject.id
        other.updatedAt = Date(timeIntervalSince1970: 40)
        var library = Library()
        library.projects = [project, otherProject]
        library.threads = [viewed, interrupted, recent, other]
        try JSONEncoder.storage.encode(library).write(to: Storage.libraryURL, options: .atomic)

        settings.lastProjectID = otherProject.id
        settings.lastSelectedThreadID = viewed.id
        let firstLaunch = AppModel()
        firstLaunch.openThreadOnLaunch()
        expect(firstLaunch.selectedThreadID == nil, "Launch waits for the library before resolving the saved selection")
        await firstLaunch.bootstrap()
        expect(firstLaunch.selectedThreadID == viewed.id && firstLaunch.currentProject?.id == project.id,
               "The last viewed chat wins over interrupted chats, newer activity and a stale project preference")
        firstLaunch.selectedThreadID = other.id
        expect(AppSettings().lastSelectedThreadID == other.id, "Selecting a chat persists it without requiring a message")
        firstLaunch.updateThread(recent.id) { $0.updatedAt = .now }
        expect(AppSettings().lastSelectedThreadID == other.id, "Background activity cannot replace the saved selection")
        expect(firstLaunch.saveBeforeQuit(), "The selected conversation survives the normal quit persistence barrier")

        let reopened = AppModel()
        reopened.openThreadOnLaunch()
        await reopened.bootstrap()
        expect(reopened.selectedThreadID == other.id, "A fresh model reopens the conversation selected before quitting")
        expect(reopened.liveRuntimes.isEmpty, "Restoring the selection does not start an OMP runtime")
        reopened.selectedThreadID = nil
        expect(AppSettings().lastSelectedThreadID == nil, "Clearing the selection removes its saved identity")
        reopened.settings.lastProjectID = project.id
        reopened.settings.lastSelectedThreadID = UUID()
        reopened.openThreadOnLaunch()
        expect(reopened.selectedThreadID == recent.id, "A missing saved chat falls back to recent activity without preferring interrupted chats")
        reopened.selectedThreadID = nil
        reopened.updateThread(viewed.id) { $0.isArchived = true }
        reopened.settings.lastSelectedThreadID = viewed.id
        reopened.openThreadOnLaunch()
        expect(reopened.selectedThreadID == recent.id, "An archived saved chat uses the safe fallback")
        reopened.selectedThreadID = nil
        reopened.updateThread(viewed.id) { $0.isArchived = false; $0.isInPanel = true }
        reopened.settings.lastSelectedThreadID = viewed.id
        reopened.openThreadOnLaunch()
        expect(reopened.selectedThreadID == recent.id, "A panel-only saved chat uses the safe fallback")
        expect(reopened.saveBeforeQuit(), "Fallback changes remain durably saved")

        reopened.settings.lastSelectedThreadID = recent.id
        let selectedDuringLoad = AppModel()
        selectedDuringLoad.openThreadOnLaunch()
        selectedDuringLoad.selectedThreadID = other.id
        await selectedDuringLoad.bootstrap()
        expect(selectedDuringLoad.selectedThreadID == other.id && AppSettings().lastSelectedThreadID == other.id,
               "An explicit selection during library loading wins and becomes the next launch selection")
        expect(selectedDuringLoad.saveBeforeQuit(), "The launch-time selection can be saved normally")

        try JSONEncoder.storage.encode(Library()).write(to: Storage.libraryURL, options: .atomic)
        let empty = AppModel()
        empty.openThreadOnLaunch()
        await empty.bootstrap()
        expect(empty.selectedThreadID == nil && empty.threads.isEmpty && empty.settings.lastSelectedThreadID == nil,
               "An empty library clears a stale selection without creating a chat")
        expect(empty.saveBeforeQuit(), "An empty launch remains safe to quit")
    }

    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--metrics-disabled") {
            expect(!RuntimeMetrics.enabled && RuntimeMetrics.begin(.rpcRequest) == nil, "Metrics default to disabled")
            expect(RuntimeMetrics.snapshot().isEmpty, "Disabled metrics retain no samples")
            print("OMP P0 default metrics checks passed: \(checks)")
            return
        }
        guard CaptureRun.isEnabled, let root = CaptureRun.storageRoot,
              root.path.contains("/build.noindex/verification/runs/"),
              let fixtureIndex = CommandLine.arguments.firstIndex(of: "--fixture") else { fatalError("Require isolated fixture storage") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[fixtureIndex + 1])
        let benchmark = CommandLine.arguments.contains("--benchmark")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared // AppKit support only; no application entry point or windows.
        if !benchmark { try await checkLaunchSelection(root) }
        let app = AppModel()
        app.settings.chimeWhenFinished = false
        app.settings.notifyWhenFinished = false
        let idle = frame(#"{"isStreaming":false,"isCompacting":false,"queuedMessageCount":0,"hasPendingAsyncWork":false,"isSettled":true}"#)
        let background = frame(#"{"isStreaming":false,"isCompacting":false,"queuedMessageCount":0,"hasPendingAsyncWork":true,"isSettled":false}"#)
        var activity = OMPActivityTracker()
        expect(!activity.value.canRecycle, "Unknown startup cannot authorize recycling")
        expect(activity.accept(idle, revision: activity.revision), "Accept native quiescence")
        expect(activity.value.canRecycle && activity.value.phase == .settled, "Verified idle can recycle")
        activity.beginPrompt("a")
        let beforeStart = activity.revision
        activity.observe(["type": "agent_start"])
        expect(!activity.accept(idle, revision: beforeStart), "An old idle response cannot end a new run")
        activity.observe(["type": "agent_end", "isTerminal": true])
        expect(activity.value.hasWork && !activity.value.canRecycle, "Agent yield is not session completion")
        activity.observe(["type": "prompt_result", "id": "a", "sessionSettled": false])
        expect(activity.value.hasWork && activity.value.phase == .background, "Background work survives prompt completion")
        let beforeSettled = activity.revision
        activity.observe(["type": "session_settled"])
        expect(!activity.accept(background, revision: beforeSettled), "Late pending state cannot resurrect settled work")
        expect(activity.value.canRecycle, "Native settlement releases process protection")
        activity.beginPrompt("next")
        activity.observe(["type": "session_settled"])
        expect(!activity.value.canRecycle, "A late settled event cannot discard pending admission")
        activity.observe(["type": "prompt_result", "id": "unrelated", "sessionSettled": true])
        expect(activity.value.prompts.contains("next"), "Unrelated completion cannot resolve a prompt")
        activity.observe(["type": "prompt_result", "id": "next", "sessionSettled": true])
        activity.observe(["type": "extension_ui_request", "method": "select", "id": "q"])
        expect(activity.value.phase == .awaitingInput && !activity.value.canRecycle, "Dialogs protect idle sessions")
        activity.observe(["type": "session_settled"])
        expect(!activity.value.canRecycle, "Settlement cannot discard an unanswered dialog")
        activity.answer("q")
        expect(activity.value.canRecycle, "Resolved dialog can release a settled session")
        _ = activity.accept(["isSettled": true, "queuedMessageCount": 2], revision: activity.revision)
        expect(!activity.value.canRecycle && activity.value.phase == .queued, "Native queue independently protects a session")
        activity.observe(["type": "session_settled"])
        activity.observe(["type": "auto_compaction_start"])
        expect(activity.value.phase == .compacting, "Compaction is work")
        activity.observe(["type": "auto_compaction_end"])
        expect(!activity.value.canRecycle, "Compaction end alone does not prove quiescence")
        activity.observe(["type": "auto_retry_start"])
        expect(activity.value.phase == .retrying, "Retry wait is work")
        activity.observe(["type": "session_settled"])
        _ = activity.accept(["isStreaming": false], revision: activity.revision)
        expect(activity.value.phase == .unknown && !activity.value.canRecycle, "Missing legacy fields remain unknown")
        activity.stop()
        expect(!activity.value.hasWork && activity.value.phase == .stopped, "Exited sessions do not keep work alive")
        expect(!activity.accept(background, revision: activity.revision), "An exit rejects in-flight snapshots")

        var deferred = OMPActivityTracker()
        let parked = frame(#"{"isStreaming":false,"isCompacting":false,"queuedMessageCount":1,"hasPendingAsyncWork":false,"isSettled":false}"#)
        _ = deferred.accept(parked, revision: deferred.revision)
        expect(deferred.value.hasWork, "A nonempty RPC queue stays active without SDK idle evidence")
        let beforeDeferred = deferred.revision
        deferred.observe(["type": "omp_gui_deferred_context", "queuedMessageCount": 1])
        expect(!deferred.value.hasWork && deferred.value.hasOnlyDeferredContext && deferred.value.phase == .unknown,
               "Native idle evidence retires waiting for next-turn context")
        expect(!deferred.value.canRecycle && deferred.value.queuedMessages == 1,
               "Idle deferred context remains protected from process recycling")
        expect(!deferred.accept(parked, revision: beforeDeferred), "An earlier state reply cannot undo the native idle observation")
        _ = deferred.accept(parked, revision: deferred.revision)
        expect(!deferred.value.hasWork && !deferred.value.canRecycle,
               "A refreshed RPC total preserves the distinction between deferred context and active work")
        let recoveredThread = ChatThread(projectID: UUID(), provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        app.insertThread(recoveredThread)
        let recoveredRuntime = app.runtime(for: recoveredThread.id)
        await recoveredRuntime.ensureLoaded()
        recoveredRuntime.receiveOMPEvent(.ompActivity(OMPActivity(connected: true, settled: false, queuedMessages: 1)))
        let recoveredTurn = UUID()
        app.turnFinished(recoveredThread.id, status: .completed, continues: false, turnID: recoveredTurn, userStopped: false)
        expect(app.thread(recoveredThread.id)?.pendingResultTurnID == recoveredTurn, "Unclassified native work defers completion attention")
        recoveredRuntime.receiveOMPEvent(.ompActivity(deferred.value))
        expect(!recoveredRuntime.hasNativeWork && recoveredRuntime.nativeWorkDescription == nil
               && !recoveredRuntime.canRecycleSession && app.thread(recoveredThread.id)?.pendingResultTurnID == nil,
               "Native idle clears the chat/sidebar wait and publishes completion without discarding deferred context")
        recoveredRuntime.cancelPersistence()
        deferred.beginPrompt("new-input")
        expect(deferred.value.hasWork && deferred.value.deferredMessages == 0, "A new submission invalidates old deferred-context evidence")
        deferred.observe(["type": "session_settled"])
        deferred.observe(["type": "prompt_result", "id": "new-input", "sessionSettled": true])
        expect(deferred.value.canRecycle && deferred.value.deferredMessages == 0, "Native queue consumption restores normal idle recycling")
        deferred.observe(["type": "omp_gui_deferred_context", "queuedMessageCount": 1])
        _ = deferred.accept(background, revision: deferred.revision)
        expect(deferred.value.hasWork && deferred.value.deferredMessages == 0, "Actual background work cannot be hidden by prior idle context")

        let failedThread = ChatThread(projectID: UUID(), provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        app.insertThread(failedThread)
        let failedRuntime = app.runtime(for: failedThread.id)
        await failedRuntime.ensureLoaded()
        let deferredTurn = UUID()
        failedRuntime.receiveOMPEvent(.ompActivity(OMPActivity(connected: true, settled: false, queuedMessages: 1)))
        app.turnFinished(failedThread.id, status: .completed, continues: false, turnID: deferredTurn, userStopped: false)
        expect(app.thread(failedThread.id)?.pendingResultTurnID == deferredTurn, "Native queues defer a finished reply's result")
        failedRuntime.receiveOMPEvent(.ompActivity(OMPActivity(stopped: true)))
        expect(app.thread(failedThread.id)?.pendingResultTurnID == deferredTurn, "Stopped activity alone cannot publish success")
        failedRuntime.receiveOMPEvent(.exited(error: "Fixture process exit"))
        expect(app.thread(failedThread.id)?.pendingResultTurnID == nil, "An exit releases deferred attention")
        expect(app.thread(failedThread.id)?.lastStatus == .failed, "Queued work fails on exit even without a background row")
        failedRuntime.cancelPersistence()

        var capabilities = OMPCapabilities()
        expect(capabilities["fork"] == .unknown, "Unobserved capabilities remain unknown")
        capabilities.observe(frame(#"{"type":"response","command":"fork","success":false,"error":"session busy"}"#))
        expect(capabilities["fork"] == .unknown, "Operational failure is not support evidence")
        capabilities.observe(frame(#"{"type":"response","command":"fork","success":false,"error":"Unknown command: fork"}"#))
        expect(capabilities["fork"] == .unsupported, "Unknown command is negative evidence")
        capabilities.observe(frame(#"{"type":"response","command":"get_tree","success":true}"#))
        expect(capabilities["get_tree"] == .supported, "Successful public command is positive evidence")
        capabilities.observe(frame(#"{"type":"response","command":"cancel_subagent","success":false,"error":"`subagentId` must be a non-empty string."}"#))
        expect(capabilities["cancel_subagent"] == .supported, "Harmless validation establishes worker controls")

        let cache = OMPDiscoveryCache<Int>(lifetime: .seconds(60))
        let context = OMPDiscoveryContext(executable: fixture, environment: [:])
        var loads = 0
        let read: @MainActor () async throws -> Int = { loads += 1; await Task.yield(); return loads }
        let requests = (0..<24).map { _ in Task { try await cache.value(for: context, load: read) } }
        var sharedResults: [Int] = []
        for request in requests { sharedResults.append(try await request.value) }
        expect(sharedResults.allSatisfy { $0 == 1 }, "Concurrent discovery shares one request")
        expect(loads == 1, "No duplicate discovery subprocess work")
        expect(try await cache.value(for: context, load: read) == 1, "Warm page refresh uses cache")
        expect(try await cache.value(for: context, force: true, load: read) == 2, "Explicit refresh bypasses cache")
        cache.invalidate()
        expect(try await cache.value(for: context, load: read) == 3, "Configuration changes invalidate discovery")
        var other = context; other.environment = ["OMP_PROFILE": "fixture"]
        expect(try await cache.value(for: other, load: read) == 4, "Profile contexts never share results")
        let gate = ReadGate()
        cache.invalidate()
        let oldRead = Task { try await cache.value(for: context) { await gate.wait(); return 100 } }
        while !gate.waiting { await Task.yield() }
        cache.invalidate()
        expect(try await cache.value(for: context) { 200 } == 200, "A write can start a fresh discovery generation")
        gate.resume()
        _ = try await oldRead.value
        expect(try await cache.value(for: context) { 300 } == 200, "A late old read cannot replace the new cache")
        let expiring = OMPDiscoveryCache<Int>(lifetime: .zero)
        _ = try await expiring.value(for: context) { 1 }
        expect(try await expiring.value(for: context) { 2 } == 2, "Expired discovery reads external changes")
        let recovering = OMPDiscoveryCache<Int>()
        do { _ = try await recovering.value(for: context) { throw CancellationError() }; fatalError("Expected discovery failure") }
        catch { }
        expect(try await recovering.value(for: context) { 1 } == 1, "Failed discovery remains retryable")

        let log = root.appendingPathComponent("requests.txt")
        let environment = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                           "OMP_FIXTURE_LOG": log.path, "OMP_FIXTURE_SESSION_FILE": root.appendingPathComponent("native.jsonl").path]
        let config = SessionConfiguration(provider: .omp, executable: fixture, workingDirectory: root,
            environment: environment, resumeID: nil, resumeAt: nil, model: nil, effort: nil,
            runtimeMode: .auto, interactionMode: .build, apiKey: nil, hydra: nil, antiSlopEnabled: false)
        let session = OMPSession(configuration: config)
        let runtime = ThreadRuntime(threadID: UUID(), app: app)
        await runtime.ensureLoaded()
        session.onEvent = { event in
            switch event {
            case .ompActivity, .ompCapabilities, .backgroundTasks: runtime.receiveOMPEvent(event)
            default: break
            }
        }
        _ = try await session.start()
        expect(session.isRunning, "Legacy optional command failures do not break startup")
        expect(session.capabilities["get_subagents"] == .unknown, "Absent subscription avoids needless roster query")
        expect(session.capabilities["set_subagent_subscription"] == .unsupported, "Persist optional negative capability")
        expect(session.nativeActivity.canRecycle, "Startup state proves native idle")
        try await session.send(TurnInput(text: "late-state", images: [], model: nil, effort: nil, runtimeMode: .auto, interactionMode: .build))
        for _ in 0..<200 where !session.nativeActivity.canRecycle { try await Task.sleep(for: .milliseconds(10)) }
        expect(session.nativeActivity.canRecycle && !runtime.hasNativeWork, "Production RPC fences a stale snapshot after session_settled")
        expect(runtime.backgroundTasks.isEmpty, "Late state cannot recreate a background UI row")
        try await session.send(TurnInput(text: "background", images: [], model: nil, effort: nil, runtimeMode: .auto, interactionMode: .build))
        for _ in 0..<200 where !session.nativeActivity.pendingAsyncWork { try await Task.sleep(for: .milliseconds(10)) }
        expect(runtime.hasNativeWork && !runtime.canRecycleSession, "Idle GUI with native background work cannot recycle")
        expect(!runtime.recycleSessionIfIdle() && session.isRunning, "Automatic recycler preserves actual child process")
        await session.stopAndWait(timeout: 5)
        expect(!session.isRunning && !runtime.hasNativeWork, "Explicit stop releases process and work state")
        runtime.cancelPersistence()

        let rpc = OMPRPC()
        var controlEnvironment = environment; controlEnvironment["OMP_FIXTURE_SCENARIO"] = "controls"
        try rpc.start(executable: fixture, arguments: [], directory: root, environment: controlEnvironment)
        _ = try await rpc.request("negotiate_protocol", fields: ["protocolVersion": 2])
        expect(rpc.capabilities["fixture_unsolicited"] == .unknown, "Unsolicited replies cannot establish capabilities")
        expect(await rpc.probeSubagentControl("cancel_subagent") == .supported, "Production control probe recognizes support")
        _ = await rpc.probeSubagentControl("cancel_subagent")
        _ = await rpc.probeSubagentControl("cancel_subagent")
        let methods = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        expect(methods.filter { $0 == "cancel_subagent" }.count == 2, "Probe once in each of two independent processes")
        do { _ = try await rpc.request("fixture_timeout", timeout: .milliseconds(50)); fatalError("Expected timeout") }
        catch { expect(rpc.capabilities["fixture_timeout"] == .unknown, "Timeout remains unknown") }
        // Frame correctness belongs to the focused RPC checks. Repetition is
        // useful only for the explicitly selected performance workload.
        if benchmark {
            for _ in 0..<12 {
                let large = try await rpc.request("fixture_chunks")
                expect(large["text"]?.string?.utf8.count == 2 * 1024 * 1024, "Large v2 frames reassemble losslessly")
            }
        }
        _ = try await rpc.request("get_state") // Ordered barrier after the fixture's late response.
        expect(rpc.capabilities["fixture_timeout"] == .unknown, "Late replies after timeout remain inconclusive")
        await rpc.stopAndWait(timeout: 5)

        var crashConfig = config
        crashConfig.environment["OMP_FIXTURE_SCENARIO"] = "crash"
        let crashing = OMPSession(configuration: crashConfig)
        var exitEvents: [String] = []
        crashing.onEvent = { event in
            switch event {
            case .exited: exitEvents.append("exit")
            case .ompActivity(let state) where state.stopped: exitEvents.append("stopped")
            case .backgroundTasks(let rows) where rows.isEmpty: exitEvents.append("clear")
            default: break
            }
        }
        _ = try await crashing.start()
        exitEvents.removeAll()
        try await crashing.send(TurnInput(text: "background", images: [], model: nil, effort: nil, runtimeMode: .auto, interactionMode: .build))
        for _ in 0..<200 where !exitEvents.contains("exit") { try await Task.sleep(for: .milliseconds(10)) }
        let exitIndex = exitEvents.firstIndex(of: "exit")
        expect(exitIndex != nil, "Unexpected process exit is delivered")
        expect(exitEvents.firstIndex(of: "stopped").map { $0 > exitIndex! } == true, "Report process failure before releasing deferred results")
        expect(crashing.nativeActivity.phase == .stopped, "Exited native activity is terminal")
        await crashing.stopAndWait(timeout: 5)

        var benchmarkDetails: [String: Any] = [:]
        if benchmark {
            // Historical synthetic recovery corpus is retained only in the opt-in
            // benchmark; routine checks never scan or migrate existing conversations.
            // Legacy recovery must preserve rows and markers without per-turn array
            // publication. Missing completion times also exercise the turn dirty index.
            let legacyID = UUID()
            var legacy = ThreadDocument(threadID: legacyID)
            var existingMarkers = Set<String>()
            for index in 0..<5_000 {
                var turn = TurnRecord(index: index, status: index % 2 == 0 ? .running : .completed)
                turn.startedAt = Date(timeIntervalSince1970: Double(index))
                let user = TimelineItem(id: "legacy-user-\(index)", turnID: turn.id, date: turn.startedAt,
                                        content: .user(UserMessage(text: "Question \(index)")))
                turn.userItemID = user.id
                legacy.turns.append(turn)
                legacy.items.append(user)
                legacy.items.append(TimelineItem(id: "legacy-answer-\(index)", turnID: turn.id,
                    date: turn.startedAt.addingTimeInterval(1), content: .assistant(AssistantMessage(text: "Answer \(index)"))))
                if index % 3 == 1 {
                    let marker = TimelineItem(id: "legacy-end-\(index)", turnID: turn.id,
                        content: .turnEnd(TurnSummary(turnID: turn.id, status: .completed, duration: 1,
                            filesChanged: 0, additions: 0, deletions: 0, changes: nil)))
                    legacy.items.append(marker)
                    existingMarkers.insert(marker.id)
                }
            }
            legacy.itemPositions = Dictionary(uniqueKeysWithValues: legacy.items.enumerated().map { ($0.element.id, Double($0.offset * 2)) })
            try JSONEncoder.storage.encode(legacy).write(to: Storage.threadURL(legacyID), options: .atomic)
            let recoveryStart = ContinuousClock.now
            let recovered = ThreadRuntime(threadID: legacyID, app: app)
            await recovered.ensureLoaded()
            let recoveryDuration = recoveryStart.duration(to: .now)
            expect(recoveryDuration < .seconds(5), "10k-message legacy recovery must not stall for tens of seconds")
            expect(recovered.entries.count == 15_000 && recovered.turns.count == 5_000, "Recovery retains every message and one marker per turn")
            expect(Set(recovered.entries.filter { existingMarkers.contains($0.id) }.map(\.id)) == existingMarkers, "Existing markers retain identity")
            expect(recovered.turns.allSatisfy { $0.status != .running }, "Interrupted turns are restored in a batch")
            expect(recovered.turns.enumerated().allSatisfy { index, turn in index % 3 == 1 || turn.completedAt == turn.startedAt.addingTimeInterval(1) }, "Recovered completion times use the final message date")
            expect(recovered.turns.enumerated().allSatisfy { index, turn in
                let rows = recovered.entries[(index * 3)..<(index * 3 + 3)]
                return rows.allSatisfy { $0.turnID == turn.id } && rows.last?.kind == .turnEnd
            }, "Each restored marker follows its own final message")
            let recoveredIDs = recovered.entries.map(\.id)
            recovered.saveNow()
            let savedRecovery = await Task.detached { Storage.readDocument(legacyID)?.document }.value
            expect(savedRecovery?.items.map(\.id) == recoveredIDs, "Split-turn persistence preserves recovered row order and positions")
            recovered.cancelPersistence()
            let reopened = ThreadRuntime(threadID: legacyID, app: app)
            await reopened.ensureLoaded()
            expect(reopened.entries.map(\.id) == recoveredIDs, "Recent-plus-older loading does not duplicate recovered markers")
            reopened.cancelPersistence()

            // A fixed headless storage/stream workload, not a UI responsiveness test.
            let historyID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
            var history = ThreadDocument(threadID: historyID)
            history.items = (0..<10_000).map { index in
                TimelineItem(id: "fixture-\(index)", turnID: nil, date: Date(timeIntervalSince1970: 0), content: .assistant(AssistantMessage(text: "Record \(index): " + String(repeating: "bounded history ", count: 8))))
            }
            let historyData = try JSONEncoder.storage.encode(history)
            try historyData.write(to: Storage.threadURL(historyID), options: .atomic)
            for _ in 0..<10 { expect(Storage.readRecentDocument(historyID)?.document.items.count == 10_000, "Fixed history corpus remains complete") }
            let stream = ThreadRuntime(threadID: UUID(), app: app)
            await stream.ensureLoaded()
            for round in 0..<20 {
                for _ in 0..<200 { stream.receiveOMPEvent(.messageDelta(id: "stream-\(round)", text: "delta ")) }
                stream.receiveOMPEvent(.messageCompleted(id: "stream-\(round)", text: String(repeating: "delta ", count: 200)))
            }
            stream.cancelPersistence()
            benchmarkDetails = [
                "history_entries": 10_000, "history_bytes": historyData.count,
                "legacy_recovery_seconds": Double(recoveryDuration.components.seconds) + Double(recoveryDuration.components.attoseconds) / 1e18,
                "rpc_chunk_payload_bytes": 2 * 1024 * 1024, "rpc_chunk_repetitions": 12
            ]
        }
        let workloadMetrics = RuntimeMetrics.snapshot()
        for _ in 0..<400 { let span = RuntimeMetrics.begin(.chatSwitch); RuntimeMetrics.end(span) }
        expect(RuntimeMetrics.snapshot()["chatSwitch"]?.retained == RuntimeMetrics.sampleLimit, "Timing storage has a fixed bound")
        var report: [String: Any] = [
            "schema": 1, "workload": benchmark ? "omp-p0-v1" : "omp-lifecycle-v1", "checks": checks,
            "scope": benchmark ? "headless production RPC, state, discovery, storage and stream benchmark; no GUI or model execution" : "headless lifecycle and discovery checks; no benchmark, GUI or model execution",
            "legacy_capabilities": session.capabilities.commands.mapValues(\.rawValue),
            "control_capabilities": rpc.capabilities.commands.mapValues(\.rawValue),
            "metrics": try JSONSerialization.jsonObject(with: JSONEncoder().encode(workloadMetrics))
        ]
        report.merge(benchmarkDetails) { _, benchmarkValue in benchmarkValue }
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try reportData.write(to: root.deletingLastPathComponent().appendingPathComponent("checks.json"))
        print("OMP P0 production checks passed: \(checks)")
    }
}

@MainActor private final class ReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}
