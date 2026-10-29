import Foundation
import AppKit
@testable import OMPGUI

@main
struct OMPGoalChecks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        checks += 1
    }
    @MainActor private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Goal fixture event did not arrive")
    }

    private static func goal(_ id: String = "core", status: String = "active") -> JSONValue {
        ["id": .string(id), "objective": "Native objective", "status": .string(status),
         "tokensUsed": 12, "timeUsedSeconds": 3, "createdAt": 1, "updatedAt": 2]
    }

    @MainActor static func main() async throws {
        guard CaptureRun.isEnabled, let root = CaptureRun.storageRoot,
              root.path.contains("/build.noindex/verification/runs/"),
              let index = CommandLine.arguments.firstIndex(of: "--fixture") else { fatalError("Require isolated storage") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared // No application entry point or windows.
        let fixture = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let cappedError = TextCleanup.utf8Prefix(String(repeating: "😀", count: 20_000), maximumBytes: 65_535)
        expect(cappedError.utf8.count == 65_532 && !cappedError.contains("�"), "Bounded native text preserves whole UTF-8 scalars")
        let log = root.appendingPathComponent("goal-requests.jsonl")
        try Data().write(to: log)
        func config(_ name: String, supported: Bool = true) -> SessionConfiguration {
            SessionConfiguration(provider: .omp, executable: fixture, workingDirectory: root,
                environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                    "OMP_FIXTURE_SESSION_FILE": root.appendingPathComponent(name + ".jsonl").path,
                    "OMP_FIXTURE_LOG": log.path, "OMP_FIXTURE_GOAL_SUPPORT": supported ? "1" : "0"],
                resumeID: nil, resumeAt: nil, model: nil, effort: nil, runtimeMode: .auto,
                interactionMode: .build, apiKey: nil, hydra: nil, antiSlopEnabled: false)
        }
        func requests() throws -> [JSONValue] {
            try String(contentsOf: log, encoding: .utf8).split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
        }
        func mutationCount() throws -> Int {
            try requests().filter { $0["type"]?.string == "goal" && $0["op"]?.string != "get" }.count
        }

        // Null and malformed snapshots are different facts. A clear never proves
        // completion, and only explicit native terminal evidence survives it.
        var core = OMPGoalSnapshot()
        expect(core.observeState(nil) == false && !core.hasObservation, "Missing old-version field is unknown")
        expect(core.observeState(.null) && core.lastTerminal == nil, "Null does not invent completion")
        let terminal: JSONValue = ["type": "goal_updated", "goal": goal(status: "complete"),
            "state": ["enabled": false, "mode": "exiting", "goal": goal(status: "complete")]]
        expect(core.observeEvent(terminal), "Explicit completion event is valid")
        _ = core.observeState(.null)
        expect(core.goal == nil && core.lastTerminal?.status == .complete, "Explicit terminal evidence survives native clear")
        let rev = core.revision
        _ = core.observeEvent(["type": "goal_updated", "goal": goal("new"),
            "state": ["enabled": true, "mode": "active", "goal": goal("new")]])
        let empty = OMPGoalReply(["goal": nil, "state": nil])!
        core.accept(empty, revision: rev)
        expect(core.goal?.id == "new" && core.lastTerminal == nil, "Late read cannot clear a newer native goal")
        expect(!core.observeState(["enabled": true, "mode": "active", "goal": ["id": "broken"]]), "Malformed state is rejected")
        expect(core.goal?.id == "new" && core.observationIsStale, "Malformed state keeps previous observation visibly stale")
        expect(OMPGoalReply(["goal": nil]) == nil, "Incomplete success cannot prove support")
        var fractional = goal().object!
        fractional["timeUsedSeconds"] = .double(1.25)
        expect(OMPGoal(.object(fractional))?.timeUsedSeconds == 1.25, "Public number-valued goal duration preserves fractional seconds")
        fractional["tokensUsed"] = .double(1.25)
        expect(OMPGoal(.object(fractional)) == nil, "Fractional tokens remain invalid integer accounting")
        fractional["tokensUsed"] = 12
        fractional["timeUsedSeconds"] = .double(-0.5)
        expect(OMPGoal(.object(fractional)) == nil, "Negative goal duration is rejected")
        let future: JSONValue = ["enabled": true, "mode": "native-future-mode", "goal": goal(status: "native-future-status")]
        var forward = OMPGoalSnapshot()
        expect(forward.observeState(future) && forward.hasUnrecognizedState && !forward.observationIsStale
            && forward.goal?.rawStatus == "native-future-status" && forward.modeState?.rawMode == "native-future-mode",
            "Future enum values retain native identity and usage while disabling mutations")
        var disabledPolicy = OMPCapabilities()
        disabledPolicy.observe(["type": "response", "command": "goal", "success": false,
            "error": "Goal mode is disabled (goal.enabled)."])
        expect(disabledPolicy.goalIsDisabled && disabledPolicy["goal"] == .unknown,
            "A policy rejection records disabled availability without inventing supported schema")
        expect(OMPGoalLimits.tokenBudget("1.5") == nil && OMPGoalLimits.tokenBudget("0") == nil
            && OMPGoalLimits.tokenBudget("9007199254740992") == nil, "Budget must be a positive exact JavaScript integer")
        expect(OMPGoalLimits.displayText(String(repeating: "中", count: 30_000)).utf8.count <= OMPGoalLimits.displayBytes,
            "Goal display respects UTF-8 byte budget")
        core.setError(String(repeating: "错", count: 20_000))
        expect((core.error?.utf8.count ?? 0) <= OMPGoalLimits.errorBytes, "Native error text is retained within 16 KiB")
        expect(OMPGoal(goal(String(repeating: "x", count: 1_025))) == nil, "Oversized native identity cannot become retained goal state")
        expect(ComposerDraft(text: "/goal").ompGoalObjective == "", "A bare local goal command waits for its objective")
        expect(ComposerDraft(text: "/goal  original body\n").ompGoalObjective == " original body\n",
            "Inline goal syntax removes only its command separator and preserves objective text")
        expect(ComposerDraft(text: "body\n", command: ThreadRuntime.goalDraftCommand).ompGoalObjective == "body\n"
            && ComposerDraft(text: "/goalkeeper text").ompGoalObjective == nil,
            "Goal mode consumes the body while unrelated slash commands retain their native meaning")

        let session = OMPSession(configuration: config("supported"))
        var nativeTurns = 0
        session.onEvent = { if case .turnStarted = $0 { nativeTurns += 1 } }
        _ = try await session.start()
        expect(session.goalSnapshot.hasObservation && session.goalSnapshot.goal == nil, "Startup adopts native goal state without running work")
        expect(session.capabilities["goal"] == .unknown, "State field does not prove write command support")
        _ = try await session.rpc.request("fixture_bad_get")
        do { try await session.refreshGoal(); fatalError("Expected malformed goal reply") } catch {}
        expect(session.capabilities["goal"] == .unknown && session.goalSnapshot.goal == nil, "Malformed success does not confirm support or change state")
        try await session.refreshGoal()
        expect(session.capabilities["goal"] == .supported && nativeTurns == 0, "Goal get proves support and never starts a model turn")

        _ = try await session.rpc.request("fixture_hold_state")
        let oldStateReads = try requests().filter { $0["type"]?.string == "get_state" }.count
        let oldStateRead = Task { try await session.readState(timeout: .seconds(5)) }
        try await wait { (try? requests().filter { $0["type"]?.string == "get_state" }.count) == oldStateReads + 1 }
        let originalObjective = "  native work\n"
        try await session.performGoalOperation(.create, objective: originalObjective, tokenBudget: 100, expectedGoalID: nil)
        let id = session.goalSnapshot.goal!.id
        _ = try await session.rpc.request("fixture_release_state")
        _ = try await oldStateRead.value
        expect(session.goalSnapshot.goal?.id == id && session.nativeActivity.canRecycle,
            "A state read started before mutation cannot replace the confirmed goal or settlement")
        expect(try requests().first { $0["type"]?.string == "goal" && $0["op"]?.string == "create" }?["objective"]?.string == originalObjective,
            "Goal submission preserves the user's full original objective")
        expect(session.goalSnapshot.goal?.tokenBudget == 100 && nativeTurns == 0, "Create preserves native budget without a GUI continuation")
        _ = try await session.rpc.request("fixture_goal_event", fields: ["action": "time"])
        try await wait { session.goalSnapshot.goal?.timeUsedSeconds == 1.25 }
        expect(session.goalSnapshot.goal?.tokensUsed == 0, "A wall-clock-only update is consumed without inventing token usage")
        _ = try await session.rpc.request("fixture_work", fields: ["action": "start"])
        try await wait { session.nativeActivity.streaming }
        try await session.performGoalOperation(.pause, expectedGoalID: id)
        expect(session.goalSnapshot.goal?.status == .paused && session.nativeActivity.streaming, "Pause does not abort the live model turn")
        let busyResume = try await session.resumeGoalFromUser(expectedGoalID: id)
        expect(busyResume == nil && session.nativeActivity.streaming,
            "Resuming during an existing turn never offers another ordinary prompt")
        _ = try await session.rpc.request("fixture_goal_event", fields: ["action": "budget"])
        try await wait { session.goalSnapshot.goal?.status == .budgetLimited }
        expect(session.goalSnapshot.goal?.tokensUsed == 120 && session.nativeActivity.streaming, "Budget can be exceeded by an in-flight turn and never means complete")
        let beforeResume = try mutationCount()
        do { try await session.performGoalOperation(.resume, expectedGoalID: id); fatalError("Cannot resume budget-limited state") } catch {}
        expect(try mutationCount() == beforeResume, "Invalid resume is not sent")
        try await session.performGoalOperation(.pause, expectedGoalID: id)
        let spentResume = try mutationCount()
        do { _ = try await session.resumeGoalFromUser(expectedGoalID: id); fatalError("Spent budget cannot be resumed") } catch {}
        expect(try mutationCount() == spentResume && session.goalSnapshot.goal?.status == .paused,
            "Pausing a spent goal cannot bypass its budget through resume")
        try await session.performGoalOperation(.drop, expectedGoalID: id)
        expect(session.goalSnapshot.goal == nil && session.goalSnapshot.lastTerminal?.status == .dropped
            && session.nativeActivity.streaming, "Drop retains explicit terminal evidence without aborting the model turn")
        _ = try await session.rpc.request("fixture_work", fields: ["action": "finish"])
        try await wait { session.nativeActivity.canRecycle }

        let beforeInvalid = try mutationCount()
        do {
            try await session.performGoalOperation(.create, objective: String(repeating: "x", count: OMPGoalLimits.inputBytes + 1), expectedGoalID: nil)
            fatalError("Expected input budget rejection")
        } catch {}
        expect(try mutationCount() == beforeInvalid, "Oversized input is refused before sending")
        do {
            try await session.performGoalOperation(.create, objective: "delayed confirmation", expectedGoalID: nil, timeout: .milliseconds(60))
            fatalError("Expected goal admission timeout")
        } catch {}
        expect(session.goalSnapshot.pending?.outcomeUnknown == true && !session.nativeActivity.canRecycle,
            "Timed-out goal mutation pins native process without claiming a main response")
        expect(!session.nativeActivity.hasWork, "Unknown goal control alone does not fabricate main work")
        let sent = try mutationCount()
        do { try await session.performGoalOperation(.drop, expectedGoalID: session.goalSnapshot.goal?.id); fatalError("Pending operation must fence another") } catch {}
        expect(try mutationCount() == sent, "Unknown mutation cannot be repeated or overwritten")
        _ = try await session.rpc.request("fixture_goal_event", fields: ["action": "complete"])
        try await wait { session.goalSnapshot.lastTerminal?.status == .complete }
        _ = try await session.rpc.request("fixture_release_goal")
        try await wait { session.goalSnapshot.pending == nil && session.nativeActivity.canRecycle }
        expect(session.goalSnapshot.goal == nil && session.goalSnapshot.lastTerminal?.status == .complete,
            "Late create confirmation cannot revive a completed native goal")
        expect(try mutationCount() == sent, "Late settlement never resends a goal mutation")

        let idleInitial = try await session.createGoalFromComposer(objective: "ordinary first turn", tokenBudget: nil)
        expect(idleInitial != nil, "A known idle create without native continuation admits one initial user prompt")
        let idleID = session.goalSnapshot.goal!.id
        try await session.performGoalOperation(.pause, expectedGoalID: idleID)
        let idleResume = try await session.resumeGoalFromUser(expectedGoalID: idleID)
        expect(idleResume?.goalID == idleID && session.canStartGoalPrompt(goalID: idleID, runGeneration: idleResume!.runGeneration),
            "A settled explicit resume admits one prompt when native continuation is disabled")
        _ = try await session.rpc.request("fixture_goal_event", fields: ["action": "unknown"])
        try await wait { session.goalSnapshot.hasUnrecognizedState }
        let futureCount = try mutationCount()
        do { try await session.performGoalOperation(.drop, expectedGoalID: idleID); fatalError("Future state must be read-only") } catch {}
        expect(try mutationCount() == futureCount && session.capabilities["goal"] == .supported,
            "Unfamiliar native state remains readable and does not send a guessed control")
        _ = try await session.rpc.request("fixture_goal_event", fields: ["action": "unknown-mode"])
        try await wait { session.goalSnapshot.goal?.status == .active && session.goalSnapshot.modeState?.mode == .unknown }
        expect(!session.canStartGoalPrompt(goalID: idleID, runGeneration: session.goalRunGeneration),
            "An active status with an unfamiliar mode cannot start a fallback goal prompt")
        _ = try await session.rpc.request("fixture_goal_event", fields: ["action": "active"])
        try await wait { !session.goalSnapshot.hasUnrecognizedState }
        _ = try await session.rpc.request("fixture_hold_goal_read")
        let getReads = try requests().filter { $0["type"]?.string == "goal" && $0["op"]?.string == "get" }.count
        let visibleRead = Task { try await session.refreshGoal() }
        try await wait { (try? requests().filter { $0["type"]?.string == "goal" && $0["op"]?.string == "get" }.count) == getReads + 1 }
        _ = try await session.rpc.request("fixture_replace_goal")
        let staleCount = try mutationCount()
        var controlStarted = false
        let staleControl = Task {
            controlStarted = true
            do { try await session.performGoalOperation(.pause, expectedGoalID: idleID); fatalError("Stale view must be rejected") } catch {}
        }
        try await wait { controlStarted }
        _ = try await session.rpc.request("fixture_release_goal_read")
        try await visibleRead.value
        await staleControl.value
        expect(try mutationCount() == staleCount && session.goalSnapshot.goal?.id == "replaced-goal",
            "A control performs a fresh identity read even when a visible read was already in flight")
        _ = try await session.rpc.request("fixture_race_goal")
        do { try await session.performGoalOperation(.pause, expectedGoalID: "replaced-goal"); fatalError("Mismatched mutation reply must be reported") } catch {}
        expect(try mutationCount() == staleCount + 1 && session.goalSnapshot.goal?.id == "raced-goal"
            && session.goalSnapshot.pending == nil && session.goalSnapshot.error != nil,
            "An identity change during native mutation is reported and never retried")
        try await session.performGoalOperation(.drop, expectedGoalID: session.goalSnapshot.goal!.id)
        _ = try await session.rpc.request("fixture_goal_auto", fields: ["mode": "scheduled"])
        let scheduledInitial = try await session.createGoalFromComposer(objective: "native scheduled turn", tokenBudget: nil)
        expect(scheduledInitial == nil && !session.nativeActivity.canRecycle,
            "A scheduled native continuation suppresses the GUI initial prompt before agent_start")
        _ = try await session.rpc.request("fixture_work", fields: ["action": "finish"])
        let scheduledID = session.goalSnapshot.goal!.id
        try await session.performGoalOperation(.pause, expectedGoalID: scheduledID)
        let scheduledResume = try await session.resumeGoalFromUser(expectedGoalID: scheduledID)
        expect(scheduledResume == nil && !session.nativeActivity.canRecycle,
            "A native scheduled resume suppresses a duplicate GUI prompt before agent_start")
        _ = try await session.rpc.request("fixture_work", fields: ["action": "finish"])
        try await session.performGoalOperation(.drop, expectedGoalID: session.goalSnapshot.goal!.id)
        _ = try await session.rpc.request("fixture_goal_auto", fields: ["mode": "finished"])
        let finishedInitial = try await session.createGoalFromComposer(objective: "native turn already finished", tokenBudget: nil)
        expect(finishedInitial == nil && session.nativeActivity.canRecycle,
            "A native turn that already settled still suppresses a duplicate GUI initial prompt")
        let finishedID = session.goalSnapshot.goal!.id
        try await session.performGoalOperation(.pause, expectedGoalID: finishedID)
        let finishedResume = try await session.resumeGoalFromUser(expectedGoalID: finishedID)
        expect(finishedResume == nil && session.nativeActivity.canRecycle,
            "A resume turn that already finished still suppresses a duplicate GUI prompt")
        await session.stopAndWait(timeout: 3)

        let old = OMPSession(configuration: config("old", supported: false))
        _ = try await old.start()
        expect(!old.goalSnapshot.hasObservation, "Old runtime missing goal stays unknown")
        do { try await old.refreshGoal(); fatalError("Expected unsupported command") } catch {}
        expect(old.capabilities["goal"] == .unsupported && old.isRunning, "Exact unsupported reply disables only goal controls")
        await old.stopAndWait(timeout: 3)

        // The actual composer path starts cold only when the objective is sent.
        // Its first ordinary prompt shares existing native admission and history.
        let wrapper = root.appendingPathComponent("goal-runtime.sh")
        let runtimeLog = root.appendingPathComponent("goal-runtime-requests.jsonl")
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let script = "#!/bin/sh\nexport OMP_FIXTURE_LOG=\(quote(runtimeLog.path))\nexport OMP_FIXTURE_SESSION_FILE=\(quote(root.appendingPathComponent("goal-runtime.jsonl").path))\nexec \(quote(fixture.path)) \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let app = AppModel()
        app.settings.chimeWhenFinished = false
        app.settings.notifyWhenFinished = false
        app.settings.setBinaryPath(wrapper.path, for: .omp)
        let projectURL = root.appendingPathComponent("goal-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let project = app.addProject(at: projectURL)
        var chat = ChatThread(projectID: project.id, provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        chat.hasCustomTitle = true
        chat.hydraEnabled = false
        app.insertThread(chat)
        let runtime = app.runtime(for: chat.id)
        await runtime.ensureLoaded()
        expect(!runtime.showsOMPGoalEntry, "The ordinary composer hides Goal controls without a current goal")
        runtime.draft = ComposerDraft(text: "/goal")
        runtime.steerDraft()
        expect(runtime.isOMPGoalComposerMode && runtime.showsOMPGoalEntry && runtime.activeOMPSession == nil
            && !FileManager.default.fileExists(atPath: runtimeLog.path), "Activating goal mode creates only its chip, without a runtime or native request")
        let body = "  user-authored goal\n"
        runtime.draft.text = body
        runtime.ompGoalBudgetDraft = "2048"
        runtime.send()
        try await wait { !runtime.ompGoalComposerWorking && runtime.ompGoal.goal != nil && runtime.phase == .idle && runtime.followUps.isEmpty }
        let runtimeRequests = try String(contentsOf: runtimeLog, encoding: .utf8).split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
        expect(runtimeRequests.filter { $0["type"]?.string == "goal" && $0["op"]?.string == "create" }.map { $0["objective"]?.string } == [body],
            "Sending in goal mode creates exactly the user's message as the native objective")
        expect(runtimeRequests.filter { $0["type"]?.string == "prompt" }.count == 1
            && !runtimeRequests.contains { $0["message"]?.string?.hasPrefix("/goal") == true },
            "Cold idle Goal starts through one ordinary prompt and never forwards TUI goal syntax")
        expect(runtime.draft.isEmpty && runtime.showsOMPGoalEntry && app.thread(chat.id)?.providerSessionID != nil,
            "Confirmed creation clears only the submitted mode draft and retains native recovery identity")
        let runtimeGoalID = runtime.ompGoal.goal!.id
        try await runtime.changeOMPGoal(.pause, expectedGoalID: runtimeGoalID)
        try await runtime.changeOMPGoal(.resume, expectedGoalID: runtimeGoalID)
        try await wait { runtime.phase == .idle && runtime.followUps.isEmpty }
        func runtimeRequestsNow() throws -> [JSONValue] {
            try String(contentsOf: runtimeLog, encoding: .utf8).split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
        }
        expect(try runtimeRequestsNow().filter { $0["type"]?.string == "prompt" }.count == 2
            && runtime.ompGoal.goal?.id == runtimeGoalID,
            "The actual resume action starts exactly one ordinary prompt with the same native goal")
        _ = try await runtime.activeOMPSession!.rpc.request("fixture_goal_event", fields: ["action": "complete"])
        try await wait { runtime.ompGoal.goal == nil && runtime.ompGoal.completedGoal != nil }
        try await runtime.refreshOMPGoal()
        expect(runtime.showsOMPGoalEntry && runtime.ompGoalSummary?.status == .complete,
            "Explicit completion keeps a visible toolbar entry after native null and a read-only refresh")
        runtime.draft = ComposerDraft(text: "/goal next objective")
        runtime.send()
        try await wait { !runtime.ompGoalComposerWorking && runtime.ompGoal.goal != nil && runtime.phase == .idle }
        expect(runtime.ompGoal.completedGoal == nil && runtime.ompGoal.goal?.id != runtimeGoalID,
            "A new native goal replaces retained completion evidence")
        try await runtime.changeOMPGoal(.drop, expectedGoalID: runtime.ompGoal.goal!.id)
        expect(!runtime.showsOMPGoalEntry, "Dropping the native goal hides its controls after the composer mode is cleared")
        _ = try await runtime.activeOMPSession!.rpc.request("fixture_goal_enabled", fields: ["enabled": false])
        runtime.draft = ComposerDraft(text: "/goal disabled objective")
        runtime.send()
        try await wait { !runtime.ompGoalComposerWorking && runtime.ompCapabilities.goalIsDisabled }
        try await runtime.refreshOMPGoal()
        expect(!runtime.canSuggestOMPGoalComposer && runtime.isOMPGoalComposerMode && !runtime.draft.isEmpty
            && runtime.ompCapabilities["goal"] == .supported,
            "Disabled native policy preserves the objective, hides suggestions and survives a successful read")
        let disabledCount = try runtimeRequestsNow().filter { $0["type"]?.string == "goal" && $0["op"]?.string == "create" }.count
        runtime.send()
        expect(try runtimeRequestsNow().filter { $0["type"]?.string == "goal" && $0["op"]?.string == "create" }.count == disabledCount
            && !runtime.ompGoalComposerWorking, "A known disabled goal is not resubmitted to native OMP")
        runtime.stopSession()
        runtime.cancelPersistence()
        let record = ["checks": checks, "nativeModelCalls": 0, "guiWindows": 0]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("goal.json"))
        print("Goal checks: \(checks)")
    }
}
