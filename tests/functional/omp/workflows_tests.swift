import Foundation
import AppKit
import SwiftUI
@testable import OMPGUI

@main
struct OMPWorkflowChecks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        checks += 1
    }
    @MainActor private static func wait(line: UInt = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Fixture event did not arrive at line \(line)")
    }

    @MainActor static func main() async throws {
        guard CaptureRun.isEnabled, let root = CaptureRun.storageRoot,
              root.path.contains("/build.noindex/verification/runs/"),
              let index = CommandLine.arguments.firstIndex(of: "--fixture") else { fatalError("Require isolated storage") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let log = root.appendingPathComponent("requests.jsonl")
        try Data().write(to: log)
        _ = NSApplication.shared // No GUI application entry point or windows.
        let config = SessionConfiguration(provider: .omp, executable: fixture, workingDirectory: root,
            environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                          "OMP_FIXTURE_LOG": log.path,
                          "OMP_FIXTURE_SESSION_FILE": root.appendingPathComponent("native.jsonl").path],
            resumeID: nil, resumeAt: nil, model: nil, effort: nil,
            runtimeMode: .auto, interactionMode: .build, apiKey: nil, hydra: nil, antiSlopEnabled: false)
        let session = OMPSession(configuration: config)
        var states: [UUID: [OMPSubmissionState]] = [:]
        var consumed: [UUID] = []
        var completed: [TurnStatus] = []
        var outcomes: [UUID: TurnStatus] = [:]
        var rewrites = 0
        session.onEvent = { event in
            switch event {
            case .ompSubmission(let id, let state, _): states[id, default: []].append(state)
            case .ompUserMessage(let id, _, _, _, _): if let id { consumed.append(id) }
            case .turnCompleted(let status, _): completed.append(status)
            case .ompPromptOutcome(let id, let status, _): outcomes[id] = status
            case .ompContextRewritten: rewrites += 1
            default: break
            }
        }
        _ = try await session.start()
        func input(_ text: String, _ delivery: OMPMessageDelivery, _ id: UUID, images: [Attachment] = []) -> TurnInput {
            TurnInput(text: text, images: images, model: nil, effort: nil, runtimeMode: .auto,
                      interactionMode: .build, ompDelivery: delivery, ompRequestID: id)
        }
        let first = UUID(), steering = UUID(), followUp = UUID()
        try await session.send(input("hold", .prompt, first))
        try await session.send(input("same message", .steer, steering))
        try await session.send(input("same message", .followUp, followUp))
        expect(states[steering]?.last == .accepted && states[followUp]?.last == .accepted, "Acceptance is distinct from consumption")
        expect(consumed == [first], "Native queue owns execution")
        expect(!session.nativeActivity.canRecycle, "Queued work protects the process")
        let rejected = UUID()
        do { try await session.send(input("reject", .steer, rejected)); fatalError("Expected rejection") }
        catch { expect(states[rejected]?.last == .failed, "Explicit rejection is retryable failure") }
        expect(states[first]?.last == .consumed, "Rejected parallel request cannot settle another prompt")
        _ = try await session.rpc.request("fixture_release")
        try await wait { consumed.count == 3 && session.nativeActivity.canRecycle }
        expect(consumed == [first, steering, followUp], "Identical queued messages correlate once in submission order")
        expect(states[steering]?.last == .consumed && states[followUp]?.last == .consumed, "Consumption is confirmed by native user messages")
        let rapid = UUID()
        try await session.send(input("consume-before-acceptance", .steer, rapid))
        expect(states[rapid]?.last == .consumed, "Fast consumption cannot regress to accepted")

        let backgroundInput = UUID()
        try await session.send(input("background-resumed input", .followUp, backgroundInput))
        expect(session.nativeActivity.phase == .responding && !session.nativeActivity.canRecycle, "Admitted queue input protects the native process")
        _ = try await session.rpc.request("fixture_background_yield")
        _ = try await session.readState()
        expect(!session.nativeActivity.canRecycle, "A background yield cannot discard a native queued message")
        _ = try await session.rpc.request("fixture_background_resume")
        try await wait { session.nativeActivity.canRecycle }
        expect(states[backgroundInput]?.last == .consumed, "Background consumption refreshes stale queue state without a prompt_result or session_settled")

        let imageURL = root.appendingPathComponent("one.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j5WQAAAAASUVORK5CYII=")!.write(to: imageURL)
        let image = Attachment(name: "one.png", path: imageURL.path, mimeType: "image/png")
        let imageID = UUID()
        try await session.send(input("with image", .followUp, imageID, images: [image]))
        _ = try await session.rpc.request("fixture_release")
        try await wait { states[imageID]?.last == .consumed && session.nativeActivity.canRecycle }
        let history = try await session.nativeHistory()
        expect(history.activeUserEntries.last?.message?.images.count == 1, "Image payload survives queue admission and native history")
        let restoredImage = try await OMPHistoryAttachments.restore(images: history.activeUserEntries.last!.message!.images,
            keeping: [Attachment(id: image.id, name: image.name, path: root.appendingPathComponent("moved.png").path, mimeType: image.mimeType)])
        let restoredBytes = try Data(contentsOf: restoredImage[0].url)
        expect(restoredImage[0].id == image.id && restoredBytes == Data(base64Encoded: history.activeUserEntries.last!.message!.images[0].data), "Missing GUI image is restored from the authoritative native bytes")
        let missing = UUID()
        do {
            try await session.send(input("missing image", .steer, missing,
                images: [Attachment(name: "missing.png", path: root.appendingPathComponent("missing.png").path, mimeType: "image/png")]))
            fatalError("Expected missing image failure")
        } catch { expect(states[missing] == nil, "Unreadable image fails before admission") }

        let unknown = UUID()
        let pending = Task { try await session.send(input("hold-acceptance", .followUp, unknown)) }
        try await wait { states[unknown]?.last == .submitting }
        try await Task.sleep(for: .milliseconds(30))
        pending.cancel()
        do { try await pending.value; fatalError("Expected cancellation") } catch { }
        expect(states[unknown]?.last == .unknown, "Lost acceptance remains unknown")
        let logsBeforeConfirm = try String(contentsOf: log, encoding: .utf8)
        expect(logsBeforeConfirm.split(separator: "\n").filter { $0.contains(unknown.uuidString) }.count == 1, "Unknown admission is sent only once")
        _ = try await session.rpc.request("fixture_confirm")
        try await wait { states[unknown]?.last == .accepted }
        expect(states[unknown]?.last == .accepted, "Correlated late acceptance resolves unknown without resending")

        // A separate prompt_result from an interrupted prompt must not settle its replacement.
        let old = UUID(), replacement = UUID()
        try await session.send(input("old prompt", .prompt, old))
        let previousEnds = completed.count
        try await session.send(input("replacement", .stopAndSend, replacement))
        expect(states[replacement]?.last == .consumed && !session.nativeActivity.canRecycle, "Stop-and-send retains the replacement after the old result")
        _ = try await session.rpc.request("fixture_release")
        try await wait { session.nativeActivity.canRecycle }
        expect(completed.count > previousEnds, "Correlated replacement has its own completion")

        let template = UUID()
        try await session.send(input("expand-template", .prompt, template))
        _ = try await session.rpc.request("fixture_release")
        try await wait { session.nativeActivity.canRecycle }
        expect(states[template]?.last == .finished && !consumed.contains(template), "Transformed input can finish without inventing a durable user match")
        let holdTemplate = UUID(), queuedTemplate = UUID()
        try await session.send(input("hold templates", .prompt, holdTemplate))
        try await session.send(input("expand-template", .followUp, queuedTemplate))
        _ = try await session.rpc.request("fixture_release")
        try await wait { session.nativeActivity.canRecycle }
        expect(states[queuedTemplate]?.last == .finished && !consumed.contains(queuedTemplate), "Native settled empty queue releases transformed admissions without claiming consumption")
        let deferred = UUID(), newer = UUID()
        try await session.send(input("deferred-old", .prompt, deferred))
        let beforeDeferred = completed.count
        try await session.send(input("queue-next", .steer, newer))
        expect(completed.count == beforeDeferred && session.nativeActivity.streaming, "Old prompt_result cannot finish a newer queue-driven run")
        expect(outcomes[deferred] == .failed, "Previous request keeps its own outcome")
        _ = try await session.rpc.request("fixture_release")
        try await wait { session.nativeActivity.canRecycle }
        expect(completed.last == .completed, "Newer successful native run keeps its own status")
        let approvalPrompt = UUID(), duringApproval = UUID()
        try await session.send(input("waiting-approval", .prompt, approvalPrompt))
        try await session.send(input("continue with care", .steer, duringApproval))
        expect(session.nativeActivity.dialogs.contains("fixture-approval"), "Steering preserves the pending approval dialog")
        session.answerQuestion("fixture-approval", answers: ["fixture-approval": QuestionAnswer(selectedOptions: ["Yes"])])
        try await wait { session.nativeActivity.dialogs.isEmpty }
        _ = try await session.rpc.request("fixture_release")
        try await wait { session.nativeActivity.canRecycle }

        try await session.refreshContext()
        expect(session.contextSnapshot.stats?.reasoningTokens == nil && session.contextSnapshot.stats?.cost == nil, "Missing native counters stay unknown")
        do {
            let stagedLog = root.appendingPathComponent("staged-context-requests.jsonl")
            try Data().write(to: stagedLog)
            var stagedConfig = config
            stagedConfig.environment["OMP_FIXTURE_LOG"] = stagedLog.path
            stagedConfig.environment["OMP_FIXTURE_SESSION_FILE"] = root.appendingPathComponent("staged-context.jsonl").path
            let session = OMPSession(configuration: stagedConfig)
            var publishedContexts: [OMPContextSnapshot] = []
            session.onEvent = { if case .ompContext(let value) = $0 { publishedContexts.append(value) } }
            _ = try await session.start()
            try await session.refreshContext()
            func contextRequestCount(_ command: String) -> Int {
                let text = (try? String(contentsOf: stagedLog, encoding: .utf8)) ?? ""
                return text.split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
                    .filter { $0["type"]?.string == command }.count
            }
            let statsBeforeRead = contextRequestCount("get_session_stats")
            let historyBeforeRead = contextRequestCount("get_entries")
            // A compaction is the native event that invalidates saved handoff history.
            session.observeContextFrame(["type": "auto_compaction_end", "skipped": true])
            _ = try await session.rpc.request("fixture_hold_context_reads")
            let publishedBeforeRead = publishedContexts.count
            var contextReadFinished = false
            let stagedContextRead = Task {
                try await session.refreshContext()
                contextReadFinished = true
            }
            try await wait { publishedContexts.count > publishedBeforeRead }
            expect(publishedContexts.last?.usedTokens != nil && !contextReadFinished,
                   "Context occupancy is visible while native statistics are still held")
            // The peer has received get_session_stats before releasing it.
            try await wait { contextRequestCount("get_session_stats") > statsBeforeRead }
            _ = try await session.rpc.request("fixture_release_context_stats")
            try await wait { publishedContexts.last?.stats?.userMessages == 77 }
            expect(!contextReadFinished, "Native statistics appear before a slow history read completes")
            try await wait { contextRequestCount("get_entries") > historyBeforeRead }
            _ = try await session.rpc.request("fixture_release_context_history")
            try await stagedContextRead.value
            try await session.refreshContext()
            let preparedStatsReads = contextRequestCount("get_session_stats")
            let preparedHistoryReads = contextRequestCount("get_entries")
            try await session.refreshContextIfNeeded()
            try await session.refreshContextIfNeeded()
            expect(contextRequestCount("get_session_stats") == preparedStatsReads,
                   "Repeated Usage opens reuse a prepared snapshot while native context is unchanged")
            _ = try await session.rpc.request("fixture_background_yield")
            try await wait { session.contextRefreshedRevision != session.contextSnapshot.revision && session.nativeActivity.canRecycle }
            try await session.refreshContextIfNeeded()
            expect(session.contextSnapshot.stats?.userMessages != 77
                   && contextRequestCount("get_session_stats") == preparedStatsReads + 1
                   && contextRequestCount("get_entries") == preparedHistoryReads,
                   "New native work updates statistics without rereading unchanged handoff history")
            await session.stopAndWait(timeout: 5)
        }
        var compaction = OMPContextSnapshot()
        compaction.observeState(["contextUsage": ["tokens": 228400, "contextWindow": 500000]])
        compaction.begin("compact", id: "manual-compaction")
        compaction.finish("compact", data: ["summary": "Preserved decisions", "tokensBefore": 228400])
        compaction.observeState(["isCompacting": false])
        expect(compaction.tokensAfterCompaction == nil, "Missing post-compaction usage remains unknown, not the pre-compaction count")
        compaction.observeState(["isCompacting": false, "contextUsage": ["tokens": 9400, "contextWindow": 500000]])
        expect(compaction.lastResult?.tokensBefore == 228400 && compaction.tokensAfterCompaction == 9400,
               "A completed compaction retains the native before and first after counts")
        compaction.observeState(["isCompacting": false, "contextUsage": ["tokens": 18000, "contextWindow": 500000]])
        expect(compaction.usedTokens == 18000 && compaction.tokensAfterCompaction == 9400,
               "Later conversation growth updates occupancy without rewriting the compaction result")
        _ = compaction.observeFrame(["type": "auto_compaction_start"])
        expect(compaction.tokensAfterCompaction == nil, "A new automatic compaction clears the previous after count")
        _ = compaction.observeFrame(["type": "auto_compaction_end", "result": ["summary": "New summary", "tokensBefore": 18000]])
        compaction.observeState(["isCompacting": false, "contextUsage": ["tokens": 0, "contextWindow": 500000]])
        expect(compaction.tokensAfterCompaction == 0, "Automatic compaction accepts a genuinely empty context")
        compaction.begin("compact", id: "next-manual-compaction")
        expect(compaction.tokensAfterCompaction == nil, "A new manual compaction clears the previous after count")
        var manualActivity = OMPActivityTracker()
        _ = manualActivity.accept(["isStreaming": false, "isSettled": true], revision: manualActivity.revision)
        let beforeManual = manualActivity.revision
        manualActivity.observe(["type": "manual_compaction_start"])
        expect(manualActivity.value.phase == .compacting && !manualActivity.value.canRecycle,
               "Native manual compaction without a GUI request protects its progress and process")
        expect(!manualActivity.accept(["isSettled": true], revision: beforeManual),
               "A pre-compaction idle reply cannot retire manual maintenance")
        _ = compaction.observeFrame(["type": "manual_compaction_start"])
        expect(compaction.isCompacting == true, "Manual progress uses the native compaction state")
        _ = compaction.observeFrame(["type": "manual_compaction_end", "aborted": true])
        manualActivity.observe(["type": "manual_compaction_end", "aborted": true])
        expect(compaction.isCompacting == false && compaction.lastOutcome == .aborted && !manualActivity.value.canRecycle,
               "A cancelled compaction ends progress without inventing native settlement")
        manualActivity.observe(["type": "session_settled"])
        expect(manualActivity.value.canRecycle, "Native settlement releases completed manual maintenance")
        _ = compaction.observeFrame(["type": "manual_compaction_start"])
        _ = compaction.observeFrame(["type": "manual_compaction_end", "aborted": false,
                                      "skipped": true, "errorMessage": "Nothing to compact"])
        expect(compaction.lastOutcome == .skipped && compaction.lastResult == nil,
               "A native manual skip remains distinct from a failed compaction")
        try await session.setAutoCompaction(false)
        expect(session.contextSnapshot.autoCompactionEnabled == false, "Automatic compaction is a native session override")
        _ = try await session.compactContext(customInstructions: "Keep file paths")
        expect(session.contextSnapshot.lastResult?.summary == "Fixture summary", "Custom compaction reports native result")
        let export = root.appendingPathComponent("export.html")
        expect(try await session.exportContextHTML(to: export.path) == export.path && FileManager.default.fileExists(atPath: export.path), "HTML export uses the returned native path")
        let handoff = try await session.handoffContext(customInstructions: "Next steps")
        expect(handoff.completed && handoff.savedPath == nil && handoff.document == "# Handoff\n\nNext steps",
               "A pathless manual handoff exposes its committed document, not only its empty RPC reply")
        let compactTask = Task { try await session.compactContext(customInstructions: "hold-acceptance") }
        try await wait { session.contextSnapshot.pendingCommand == "compact" }
        try await Task.sleep(for: .milliseconds(30))
        compactTask.cancel()
        do { _ = try await compactTask.value; fatalError("Expected cancelled wait") } catch { }
        expect(session.contextSnapshot.outcomeUnknown && !session.nativeActivity.canRecycle, "Unconfirmed maintenance stays protected even when get_state says settled")
        _ = try await session.rpc.request("fixture_confirm")
        try await wait { session.contextSnapshot.pendingCommand == nil && session.nativeActivity.canRecycle }
        expect(session.contextSnapshot.lastResult?.summary == "Late summary", "Late context reply settles exactly its own operation")
        expect(rewrites == 3, "Normal compact, handoff and late compact each confirm a context rewrite")
        let beforeBranch = try await session.nativeHistory()
        let selected = beforeBranch.activeUserEntries[1]
        let branch = try await session.branchHistory(entryID: selected.id)
        expect(!branch.cancelled && branch.sessionFile != beforeBranch.sessionFile && branch.sessionID != beforeBranch.sessionID, "Native branch adopts the identity returned by get_state")
        expect(FileManager.default.fileExists(atPath: beforeBranch.sessionFile), "Native branch preserves the original journal")
        expect(branch.editorText == selected.message?.text, "Branch restores the selected native message as an editor draft")
        let afterBranch = try await session.nativeHistory()
        expect(afterBranch.activeUserEntries.count == 1, "Branch retains only the selected user's ancestors")
        let leftover = UUID()
        try await session.send(input("unconsumed", .followUp, leftover))
        await session.stopAndWait(timeout: 5)
        expect(states[leftover]?.last == .unknown, "Stopping preserves unconsumed native admission as unknown")
        var cancelledConfig = config
        cancelledConfig.environment["OMP_FIXTURE_BRANCH_CANCEL"] = "1"
        let cancelledSession = OMPSession(configuration: cancelledConfig)
        _ = try await cancelledSession.start()
        try await cancelledSession.send(input("preserve original", .prompt, UUID()))
        _ = try await cancelledSession.rpc.request("fixture_release")
        try await wait { cancelledSession.nativeActivity.canRecycle }
        let cancelledHistory = try await cancelledSession.nativeHistory()
        let declined = try await cancelledSession.branchHistory(entryID: cancelledHistory.activeUserEntries[0].id)
        expect(declined.cancelled && declined.sessionFile == cancelledHistory.sessionFile && cancelledSession.isRunning, "Extension-declined branch preserves the original live session")
        await cancelledSession.stopAndWait(timeout: 5)

        let handoffHistory = try OMPHistorySnapshot([
            "entries": [
                ["type": "compaction", "id": "active-handoff", "parentId": .null,
                 "method": "handoff", "summary": "Selected branch document"],
                ["type": "compaction", "id": "abandoned-handoff", "parentId": .null,
                 "method": "handoff", "summary": "Abandoned branch document"],
                ["type": "compaction", "id": "active-compact", "parentId": "active-handoff",
                 "method": "remote", "summary": "Ordinary compaction is not a handoff"]
            ],
            "leafId": "active-compact"
        ], sessionFile: "selected.jsonl", sessionID: "selected")
        var restoredHandoff = OMPContextSnapshot()
        try restoredHandoff.restoreHandoff(handoffHistory)
        expect(restoredHandoff.lastHandoff?.document == "Selected branch document"
               && restoredHandoff.lastHandoff?.entryID == "active-handoff",
               "Recovery follows the active native branch and ignores abandoned handoffs and ordinary compaction")

        var handoffConfig = config
        handoffConfig.environment["OMP_FIXTURE_SESSION_FILE"] = root.appendingPathComponent("handoff-native.jsonl").path
        let handoffSession = OMPSession(configuration: handoffConfig)
        _ = try await handoffSession.start()
        let abandonedHandoff = Task { try await handoffSession.handoffContext(customInstructions: "Never submit") }
        abandonedHandoff.cancel()
        do { _ = try await abandonedHandoff.value; fatalError("Expected cancellation before admission") } catch { }
        expect(handoffSession.contextSnapshot.pendingCommand == nil && !handoffSession.contextSnapshot.outcomeUnknown,
               "Cancellation before native admission does not leave a nonexistent handoff awaiting confirmation")
        let lateHandoff = Task { try await handoffSession.handoffContext(customInstructions: "hold-serial-handoff") }
        try await wait { handoffSession.contextSnapshot.pendingCommand == "handoff" }
        try await handoffSession.refreshContext()
        expect(handoffSession.contextSnapshot.pendingCommand == "handoff"
               && handoffSession.contextSnapshot.lastHandoff == nil && !handoffSession.nativeActivity.canRecycle,
               "Opening or refreshing during a serial handoff neither times out behind it nor invents completion")
        lateHandoff.cancel()
        do { _ = try await lateHandoff.value; fatalError("Expected cancelled handoff wait") } catch { }
        expect(handoffSession.contextSnapshot.outcomeUnknown && !handoffSession.nativeActivity.canRecycle,
               "Losing the handoff waiter preserves unknown outcome and duplicate-action protection")
        _ = try await handoffSession.rpc.request("fixture_confirm")
        try await wait { handoffSession.contextSnapshot.lastHandoff?.document == "# Handoff\n\nhold-serial-handoff" }
        expect(!handoffSession.contextSnapshot.outcomeUnknown && handoffSession.contextSnapshot.pendingCommand == nil,
               "A late handoff reply publishes durable completion and its body without the original view waiter")
        let durableHandoff = try await handoffSession.rpc.request("get_entries")
        let resumedFile = root.appendingPathComponent("restored-handoff.jsonl")
        let header: JSONValue = ["type": "session", "id": "restored-handoff"]
        let savedHandoff = ([header] + durableHandoff["entries"]!.array!).map(\.compactString).joined(separator: "\n") + "\n"
        try savedHandoff.write(to: resumedFile, atomically: true, encoding: .utf8)
        do { _ = try await handoffSession.handoffContext(customInstructions: "reject-handoff"); fatalError("Expected native rejection") }
        catch { }
        try await handoffSession.refreshContext()
        expect(handoffSession.contextSnapshot.handoffError == "Fixture handoff generation failed"
               && handoffSession.contextSnapshot.lastHandoff == nil,
               "A failed new handoff remains a real error, not success inferred from a previous document")
        let skippedHandoff = try await handoffSession.handoffContext(customInstructions: "skip-handoff")
        expect(!skippedHandoff.completed && skippedHandoff.document == nil,
               "A null handoff response never reuses an earlier successful document")
        await handoffSession.stopAndWait(timeout: 5)
        handoffConfig.resumeID = resumedFile.path
        let resumedHandoff = OMPSession(configuration: handoffConfig)
        _ = try await resumedHandoff.start()
        try await resumedHandoff.refreshContext()
        expect(resumedHandoff.contextSnapshot.lastHandoff?.document == "# Handoff\n\nhold-serial-handoff"
               && resumedHandoff.contextSnapshot.lastHandoff?.savedPath == nil,
               "A new process restores the existing pathless handoff from native history without generating another")
        await resumedHandoff.stopAndWait(timeout: 5)

        // A positive removal outcome must retire its Swift admission identity
        // before the next identical native message can be correlated.
        let identicalSession = OMPSession(configuration: config)
        var identicalStates: [UUID: [OMPSubmissionState]] = [:]
        var identicalConsumed: [UUID] = []
        identicalSession.onEvent = { event in
            switch event {
            case .ompSubmission(let id, let state, _): identicalStates[id, default: []].append(state)
            case .ompUserMessage(let id, _, _, _, _): if let id { identicalConsumed.append(id) }
            default: break
            }
        }
        _ = try await identicalSession.start()
        let identicalHold = UUID(), removedIdentical = UUID(), remainingIdentical = UUID()
        try await identicalSession.send(input("identical queue hold", .prompt, identicalHold))
        try await identicalSession.send(input("identical image follow-up", .followUp, removedIdentical, images: [image]))
        try await identicalSession.send(input("identical image follow-up", .followUp, remainingIdentical, images: [image]))
        expect(identicalStates[removedIdentical]?.last == .accepted && identicalStates[remainingIdentical]?.last == .accepted,
            "Identical image follow-ups retain separate accepted native identities")
        expect(try await identicalSession.withdrawFollowUp(removedIdentical), "Native withdrawal confirms removal of the first identical input")
        _ = try await identicalSession.rpc.request("fixture_release")
        try await wait { identicalStates[remainingIdentical]?.last == .consumed && identicalSession.nativeActivity.canRecycle }
        expect(identicalConsumed == [identicalHold, remainingIdentical], "Only the remaining identical input owns the native user-message correlation")
        expect(identicalStates[removedIdentical]?.contains(.consumed) != true,
            "A removed identity cannot consume a later identical message after the native outcome")
        await identicalSession.stopAndWait(timeout: 5)

        // The queue delivery mode and native stop reason together distinguish
        // a new follow-up answer from steering within continuing model work.
        let boundarySession = OMPSession(configuration: config)
        var newAnswerBoundaries: [UUID: Bool] = [:]
        boundarySession.onEvent = { event in
            if case .ompUserMessage(let id?, _, _, _, let startsNewTurn) = event {
                newAnswerBoundaries[id] = startsNewTurn
            }
        }
        _ = try await boundarySession.start()
        try await boundarySession.send(input("boundary-hold", .prompt, UUID()))
        for (name, reason, details, calls, results, expected) in [
            ("successful final", "stop", nil as String?, false, false, true),
            ("length-limited final", "length", nil, false, false, true),
            ("length-limited tool call", "length", nil, true, false, false),
            ("tool continuation", "toolUse", nil, false, false, false),
            ("paused final", "stop", "pause_turn", false, false, false),
            ("failed final", "error", nil, false, false, false),
            ("aborted final", "aborted", nil, false, false, false),
            ("tool-bearing stop", "stop", nil, true, false, false),
            ("tool results", "stop", nil, false, true, false)
        ] {
            let requestID = UUID()
            try await boundarySession.send(input(name, .followUp, requestID))
            var command: [String: JSONValue] = ["stopReason": .string(reason),
                "consume": .array([.string(requestID.uuidString)]), "toolCall": .bool(calls),
                "toolResults": .array(results ? [["role": "toolResult"]] : [])]
            if let details { command["stopDetails"] = ["type": .string(details)] }
            _ = try await boundarySession.rpc.request("fixture_boundary", fields: command)
            expect(newAnswerBoundaries[requestID] == expected,
                "Native \(name) preserves the correct follow-up answer boundary")
        }
        let sameBatchSteer = UUID(), sameBatchFollowUp = UUID()
        try await boundarySession.send(input("same-batch steer", .steer, sameBatchSteer))
        try await boundarySession.send(input("same-batch follow-up", .followUp, sameBatchFollowUp))
        _ = try await boundarySession.rpc.request("fixture_boundary", fields: ["stopReason": "stop",
            "consume": .array([.string(sameBatchSteer.uuidString), .string(sameBatchFollowUp.uuidString)])])
        expect(newAnswerBoundaries[sameBatchSteer] == false && newAnswerBoundaries[sameBatchFollowUp] == true,
            "Same-batch steering cannot consume the successful boundary intended for a native follow-up")
        _ = try await boundarySession.rpc.request("fixture_release")
        try await wait { boundarySession.nativeActivity.canRecycle }
        await boundarySession.stopAndWait(timeout: 5)

        let crashing = OMPSession(configuration: config)
        var exitState: OMPSubmissionState?
        crashing.onEvent = { event in if case .ompSubmission(_, let state, _) = event { exitState = state } }
        _ = try await crashing.start()
        do { try await crashing.send(input("exit-before-acceptance", .followUp, UUID())); fatalError("Expected process exit") } catch { }
        try await wait { crashing.nativeActivity.stopped }
        expect(exitState == .unknown, "Unexpected exit preserves uncertain admission")
        await crashing.stopAndWait(timeout: 5)

        // Exercise the real runtime startup path, including its asynchronous
        // checkpoint/launch preparation, rather than only the session adapter.
        let wrapper = root.appendingPathComponent("runtime-fixture.sh")
        let runtimeLog = root.appendingPathComponent("runtime-requests.jsonl")
        let cancelFile = root.appendingPathComponent("cancel-branch")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let wrapperText = "#!/bin/sh\nexport OMP_FIXTURE_LOG=\(quote(runtimeLog.path))\nexport OMP_FIXTURE_SESSION_FILE=\(quote(root.appendingPathComponent("runtime-native.jsonl").path))\nexport OMP_FIXTURE_AUTO_RELEASE=1\nexport OMP_FIXTURE_CANCEL_FILE=\(quote(cancelFile.path))\nexec \(quote(fixture.path)) \"$@\"\n"
        try wrapperText.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let app = AppModel()
        await app.bootstrap()
        app.settings.chimeWhenFinished = false
        app.settings.notifyWhenFinished = false
        app.settings.setBinaryPath(wrapper.path, for: .omp)
        let projectURL = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let project = app.addProject(at: projectURL)
        let savedContextFile = root.appendingPathComponent("saved-context.jsonl")
        let savedContextText = """
        {"type":"session","id":"saved-context","timestamp":"2026-10-16T00:00:00.000Z"}
        {"type":"message","id":"saved-a","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"First saved question"}]}}
        {"type":"message","id":"saved-b","parentId":"saved-a","message":{"role":"user","content":[{"type":"text","text":"Second saved question"}]}}

        """
        try savedContextText.write(to: savedContextFile, atomically: true, encoding: .utf8)
        var contextChat = ChatThread(projectID: project.id, provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        contextChat.providerSessionID = savedContextFile.path
        contextChat.hydraEnabled = false
        app.insertThread(contextChat)
        let contextRuntime = app.runtime(for: contextChat.id)
        await contextRuntime.ensureLoaded()
        contextRuntime.draft = ComposerDraft(text: "Do not submit this draft")
        let contextReads = (0..<2).map { _ in Task { await contextRuntime.prepareOMPContext() } }
        for read in contextReads { await read.value }
        expect(contextRuntime.ompContext.usedTokens == 30 && contextRuntime.ompContext.windowTokens == 128000
               && contextRuntime.ompContext.stats?.userMessages == 2,
               "Concurrent cold reads restore the selected native conversation's context and saved message counts")
        expect(contextRuntime.draft.text == "Do not submit this draft" && contextRuntime.turns.isEmpty
               && contextRuntime.followUps.isEmpty && app.thread(contextChat.id)?.providerSessionID == savedContextFile.path,
               "Context inspection preserves the original conversation, draft and unsubmitted GUI history")
        try await contextRuntime.refreshOMPContext(ifNeeded: true)
        try await contextRuntime.refreshOMPContext(ifNeeded: true)
        let contextCommands = try String(contentsOf: runtimeLog, encoding: .utf8).split(separator: "\n").map { JSONValue.parse(String($0))! }
        expect(contextCommands.filter { $0["type"]?.string == "negotiate_protocol" }.count == 1
               && contextCommands.filter { $0["type"]?.string == "get_session_stats" }.count == 1,
               "Concurrent usage surfaces share one cold process and one statistics read")
        expect(contextCommands.allSatisfy {
            !["steer", "follow_up"].contains($0["type"]?.string ?? "")
                && ($0["type"]?.string != "prompt" || $0["message"]?.string?.hasPrefix("/omp-gui-queue ") == true)
        }, "Inspection never sends the draft or creates a model request")
        contextRuntime.stopSession()
        expect(contextRuntime.ompContext.stats?.userMessages == 2 && contextRuntime.ompContext.usedTokens == 30
               && contextRuntime.ompContextIsCached && !contextRuntime.canManageContext,
               "Disconnect retains immediately readable context without retaining live management permission")

        var persistedContext = try JSONDecoder.storage.decode(ThreadDocument.self,
            from: JSONEncoder.storage.encode(contextRuntime.snapshotForPersistence()))
        var cachedChat = contextChat
        cachedChat.id = UUID()
        persistedContext.threadID = cachedChat.id
        try await DiskWriter.shared.writeOrThrow(persistedContext, to: Storage.threadURL(cachedChat.id))
        app.insertThread(cachedChat)
        let cachedRuntime = app.runtime(for: cachedChat.id)
        await cachedRuntime.ensureLoaded()
        expect(cachedRuntime.ompContext.usedTokens == 30 && cachedRuntime.ompContext.stats?.userMessages == 2
               && cachedRuntime.ompContextIsCached && cachedRuntime.activeOMPSession == nil,
               "Reopening a saved conversation exposes context and statistics before starting any native process")
        cachedRuntime.cancelPersistence()

        var otherChat = cachedChat
        otherChat.id = UUID()
        otherChat.providerSessionID = root.appendingPathComponent("different-context.jsonl").path
        persistedContext.threadID = otherChat.id
        try await DiskWriter.shared.writeOrThrow(persistedContext, to: Storage.threadURL(otherChat.id))
        app.insertThread(otherChat)
        let otherRuntime = app.runtime(for: otherChat.id)
        await otherRuntime.ensureLoaded()
        expect(otherRuntime.ompContext.stats == nil && !otherRuntime.ompContextIsCached,
               "A saved context cache cannot populate a different native conversation")
        otherRuntime.cancelPersistence()

        var inFlightContext = contextRuntime.ompContext
        inFlightContext.begin("compact", id: "old-connection")
        inFlightContext.markUnknown()
        _ = inFlightContext.observeFrame(["type": "auto_compaction_start"])
        let safeCache = try JSONDecoder.storage.decode(OMPContextCache.self, from: JSONEncoder.storage.encode(
            OMPContextCache(sessionFile: savedContextFile.path, snapshot: inFlightContext)))
        expect(safeCache.snapshot.pendingCommand == nil && safeCache.snapshot.pendingRequestID == nil
               && safeCache.snapshot.isCompacting == nil && !safeCache.snapshot.outcomeUnknown,
               "Saved snapshots never resurrect an old connection's compaction or pending command")
        // Mount the actual Usage surface offscreen: its appearance must restore
        // a disconnected conversation, not require another message or Refresh.
        NSApplication.shared.setActivationPolicy(.prohibited)
        let contextHost = NSHostingView(rootView: UsagePanel(runtime: contextRuntime, provider: .omp).environment(app))
        let contextWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 720),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        contextWindow.isReleasedWhenClosed = false
        contextWindow.contentView = contextHost
        contextHost.layoutSubtreeIfNeeded()
        try await wait { contextRuntime.ompContext.stats?.userMessages == 2 && !contextRuntime.ompContextIsCached
            && contextRuntime.activeOMPSession != nil }
        expect(contextRuntime.ompContext.usedTokens == 30 && contextRuntime.draft.text == "Do not submit this draft",
               "Opening Usage after disconnect restores native context without submitting the draft")
        contextHost.layoutSubtreeIfNeeded()
        if let bitmap = contextHost.bitmapImageRepForCachingDisplay(in: contextHost.bounds) {
            contextHost.cacheDisplay(in: contextHost.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("cold-context-usage.png"))
        }
        contextWindow.close()
        contextRuntime.stopSession()
        contextRuntime.cancelPersistence()
        expect(try String(contentsOf: savedContextFile, encoding: .utf8) == savedContextText,
               "Cold context inspection leaves the saved native journal unchanged")
        var missingContextChat = ChatThread(projectID: project.id, provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        missingContextChat.hydraEnabled = false
        missingContextChat.providerSessionID = root.appendingPathComponent("missing-context.jsonl").path
        app.insertThread(missingContextChat)
        let missingContextRuntime = app.runtime(for: missingContextChat.id)
        do { try await missingContextRuntime.refreshOMPContext(); fatalError("Expected a missing native conversation") }
        catch {
            expect(missingContextRuntime.activeOMPSession == nil
                   && app.thread(missingContextChat.id)?.providerSessionID == missingContextChat.providerSessionID,
                   "A missing saved conversation cannot silently become a fresh empty context")
        }
        missingContextRuntime.cancelPersistence()
        var chat = ChatThread(projectID: project.id, provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        chat.hasCustomTitle = true
        chat.hydraEnabled = false
        app.insertThread(chat)
        let runtime = app.runtime(for: chat.id)
        await runtime.ensureLoaded()
        await runtime.prepareOMPContext()
        expect(runtime.activeOMPSession == nil, "Prefetching a new empty conversation does not create a native session")
        runtime.draft = ComposerDraft(text: "runtime-a")
        let startupContextRead = Task { try await runtime.refreshOMPContext() }
        runtime.send()
        expect(runtime.visibleFollowUps.isEmpty, "An idle send does not flash a delivery panel during startup")
        runtime.draft = ComposerDraft(text: "runtime-b")
        runtime.send()
        expect(runtime.visibleFollowUps.map(\.text) == ["runtime-b"], "A message submitted behind a live startup appears in the delivery panel")
        runtime.draft = ComposerDraft(text: "runtime-c")
        runtime.steerDraft()
        try await wait { runtime.turns.count == 3 && runtime.followUps.isEmpty && runtime.phase == .idle }
        try await startupContextRead.value
        let runtimeHistory = try await runtime.loadNativeHistory()
        expect(runtimeHistory.activeUserEntries.map { $0.message?.text } == ["runtime-a", "runtime-b", "runtime-c"], "Cold-start rapid inputs retain one identity and native order")
        expect(runtime.turns.count == 3 && runtime.turns.allSatisfy { $0.status != .running }, "Every consumed input group finishes without an orphan turn")
        expect(runtime.followUps.isEmpty, "Consumed messages leave the delivery panel once their transcript items exist")
        expect(runtime.canRecycleSession && runtime.canBranchConversation, "Completed queue records do not pin the native process")
        let oldFile = app.thread(chat.id)?.providerSessionID
        runtime.draft = ComposerDraft(text: "Unrelated composer draft")
        let originalCount = app.threads.count
        _ = try await runtime.revert(to: runtime.turns[1].id, restoreFiles: false)
        expect(runtime.turns.count == 1 && runtime.draft.text == "runtime-b", "Runtime adopts the native ancestor path and selected draft")
        expect(app.thread(chat.id)?.providerSessionID != oldFile && app.threads.count == originalCount + 1, "Runtime preserves a separate original GUI conversation")
        let original = app.threads.first { $0.id != chat.id && $0.providerSessionID == oldFile }!
        expect(app.runtime(for: original.id).draft.text == "Unrelated composer draft", "Branching preserves unrelated composer content")
        expect(Storage.decodeDocument(original.id)?.turns.count == 3, "Original GUI transcript is saved before branching")
        try Data().write(to: cancelFile)
        let beforeDecline = app.thread(chat.id)?.providerSessionID
        let beforeDeclineCount = app.threads.count
        do { _ = try await runtime.revert(to: runtime.turns[0].id, restoreFiles: false); fatalError("Expected declined branch") } catch { }
        expect(app.thread(chat.id)?.providerSessionID == beforeDecline && app.threads.count == beforeDeclineCount && runtime.turns.count == 1, "Declined runtime branch keeps the original identity and GUI transcript")
        expect(runtime.draft.text == "runtime-b", "Declined branch preserves the current composer draft")
        runtime.stopSession()
        runtime.cancelPersistence()
        app.runtime(for: original.id).cancelPersistence()

        // Keep OMP's queue admitted but unconsumed while exercising the same
        // public recall/delete actions used by the composer.
        let queueWrapper = root.appendingPathComponent("queue-runtime-fixture.sh")
        let queueControl = root.appendingPathComponent("queue-runtime-control.json")
        let queueWrapperText = wrapperText
            .replacingOccurrences(of: "export OMP_FIXTURE_AUTO_RELEASE=1\n", with: "export OMP_FIXTURE_CONTROL_FILE=\(quote(queueControl.path))\n")
            .replacingOccurrences(of: "runtime-native.jsonl", with: "queue-runtime-native.jsonl")
            .replacingOccurrences(of: "runtime-requests.jsonl", with: "queue-runtime-requests.jsonl")
        try queueWrapperText.write(to: queueWrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: queueWrapper.path)
        app.settings.setBinaryPath(queueWrapper.path, for: .omp)
        var queueChat = ChatThread(projectID: project.id, provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        queueChat.hasCustomTitle = true
        queueChat.hydraEnabled = false
        app.insertThread(queueChat)
        let queueRuntime = app.runtime(for: queueChat.id)
        await queueRuntime.ensureLoaded()
        queueRuntime.draft = ComposerDraft(text: "recall hold")
        queueRuntime.send()
        expect(queueRuntime.visibleFollowUps.isEmpty, "A cold idle send stays outside the delivery panel")
        try await wait { queueRuntime.turns.count == 1 && queueRuntime.phase == .running && queueRuntime.followUps.isEmpty }
        queueRuntime.draft = ComposerDraft(text: "recall with image", attachments: [image])
        queueRuntime.queueDraftAsFollowUp()
        try await wait { queueRuntime.followUps.first?.ompState == .accepted }
        let recalledID = queueRuntime.followUps[0].id
        queueRuntime.draft = ComposerDraft(text: "preserved steering")
        queueRuntime.steerDraft()
        try await wait { queueRuntime.followUps.count == 2 && queueRuntime.followUps.allSatisfy { $0.ompState == .accepted } }
        expect(queueRuntime.visibleFollowUps.count == 2 && queueRuntime.canWithdrawFollowUp(recalledID), "An accepted live follow-up exposes its native withdrawal action")
        queueRuntime.recallFollowUp(recalledID)
        expect(queueRuntime.draft.isEmpty && queueRuntime.followUps.contains { $0.id == recalledID }, "Recall waits for native removal before returning the draft")
        queueRuntime.draft = ComposerDraft(text: "Owner typed during recall", attachments: [image])
        try await wait { !queueRuntime.followUps.contains { $0.id == recalledID } && !queueRuntime.isWithdrawingFollowUp(recalledID) }
        expect(queueRuntime.draft.text == "Owner typed during recall\n\nrecall with image" && queueRuntime.draft.attachments == [image], "Confirmed recall preserves newly typed text and restores original attachments without duplication")
        expect(queueRuntime.followUps.map(\.text) == ["preserved steering"], "Recalling a follow-up preserves unrelated native steering")
        try #"{"release":true}"#.write(to: queueControl, atomically: true, encoding: .utf8)
        try await queueRuntime.refreshOMPContext()
        try await wait { queueRuntime.phase == .idle && queueRuntime.followUps.isEmpty }
        let recalledHistory = try await queueRuntime.loadNativeHistory()
        expect(recalledHistory.activeUserEntries.map { $0.message?.text } == ["recall hold", "preserved steering"], "Recalled input is absent from native consumption and remaining steering still executes")

        queueRuntime.draft = ComposerDraft(text: "delete hold")
        queueRuntime.send()
        expect(queueRuntime.visibleFollowUps.isEmpty, "A warm idle send also stays outside the delivery panel")
        try await wait { queueRuntime.turns.count == 3 && queueRuntime.phase == .running && queueRuntime.followUps.isEmpty }
        queueRuntime.draft = ComposerDraft(text: "delete queued input", attachments: [image])
        queueRuntime.queueDraftAsFollowUp()
        try await wait { queueRuntime.followUps.first?.ompState == .accepted }
        let deletedID = queueRuntime.followUps[0].id
        queueRuntime.draft = ComposerDraft(text: "preserved follow-up")
        queueRuntime.queueDraftAsFollowUp()
        try await wait { queueRuntime.followUps.count == 2 && queueRuntime.followUps.allSatisfy { $0.ompState == .accepted } }
        let ownerDraft = ComposerDraft(text: "Unrelated owner draft", attachments: [image])
        queueRuntime.draft = ownerDraft
        queueRuntime.removeFollowUp(deletedID)
        expect(queueRuntime.draft == ownerDraft && queueRuntime.followUps.contains { $0.id == deletedID }, "Delete waits for native confirmation and does not refill the composer")
        try await wait { !queueRuntime.followUps.contains { $0.id == deletedID } && !queueRuntime.isWithdrawingFollowUp(deletedID) }
        expect(queueRuntime.draft == ownerDraft && queueRuntime.followUps.map(\.text) == ["preserved follow-up"], "Confirmed deletion preserves the owner draft and other queued follow-ups")
        try #"{"release":true}"#.write(to: queueControl, atomically: true, encoding: .utf8)
        try await queueRuntime.refreshOMPContext()
        try await wait { queueRuntime.phase == .idle && queueRuntime.followUps.isEmpty }
        let deletedHistory = try await queueRuntime.loadNativeHistory()
        expect(deletedHistory.activeUserEntries.map { $0.message?.text } == ["recall hold", "preserved steering", "delete hold", "preserved follow-up"], "Deleted input never reaches native history and other follow-ups retain their order")

        queueRuntime.draft = ComposerDraft(text: "rejection hold")
        queueRuntime.send()
        try await wait { queueRuntime.turns.count == 5 && queueRuntime.phase == .running && queueRuntime.followUps.isEmpty }
        queueRuntime.draft = ComposerDraft(text: "reject native cancellation")
        queueRuntime.queueDraftAsFollowUp()
        try await wait { queueRuntime.followUps.first?.ompState == .accepted }
        let rejectedRemovalID = queueRuntime.followUps[0].id
        queueRuntime.draft = ownerDraft
        try #"{"cancel":"reject"}"#.write(to: queueControl, atomically: true, encoding: .utf8)
        queueRuntime.recallFollowUp(rejectedRemovalID)
        try await wait { !queueRuntime.isWithdrawingFollowUp(rejectedRemovalID) && queueRuntime.followUps.first?.deliveryError != nil }
        expect(queueRuntime.followUps.first?.ompState == .accepted && queueRuntime.draft == ownerDraft, "Rejected native removal keeps the admitted input and leaves the composer untouched")

        queueRuntime.draft = ComposerDraft(text: "consume-before-recall", attachments: [image])
        queueRuntime.queueDraftAsFollowUp()
        try await wait { queueRuntime.followUps.count == 2 && queueRuntime.followUps.allSatisfy { $0.ompState == .accepted } }
        let racingID = queueRuntime.followUps.first { $0.text == "consume-before-recall" }!.id
        queueRuntime.draft = ownerDraft
        try #"{"cancel":"consume-first"}"#.write(to: queueControl, atomically: true, encoding: .utf8)
        queueRuntime.recallFollowUp(racingID)
        try await wait { !queueRuntime.isWithdrawingFollowUp(racingID) && !queueRuntime.followUps.contains { $0.id == racingID } }
        expect(queueRuntime.draft == ownerDraft && queueRuntime.followUps.map(\.id) == [rejectedRemovalID], "Native consumption winning recall never recreates a running input or removes a different queued message")
        try #"{"release":true}"#.write(to: queueControl, atomically: true, encoding: .utf8)
        try await queueRuntime.refreshOMPContext()
        try await wait { queueRuntime.phase == .idle && queueRuntime.followUps.isEmpty }
        let racedHistory = try await queueRuntime.loadNativeHistory()
        expect(Array(racedHistory.activeUserEntries.suffix(3)).map { $0.message?.text } == ["rejection hold", "consume-before-recall", "reject native cancellation"], "Failed removal and a consumed-target race preserve every remaining native queue item")
        queueRuntime.stopSession()
        queueRuntime.cancelPersistence()

        // Native follow-ups run within one agent_start/agent_end envelope. A
        // successful assistant turn_end is still a real final reply before OMP
        // consumes the next input; tools and steering are continuing work.
        func visibleFinalTexts(_ entries: [TimelineEntry], isRunning: Bool) -> [String] {
            let blocks = DisplayBlock.build(entries, meta: TimelineMeta.build(entries),
                showReasoning: false, isRunning: isRunning, hydraMergeID: nil)
            return blocks.compactMap { block in
                guard case .turn(_, _, let rows, let summary?, let final?, _, _) = block,
                      summary.status == .completed,
                      let row = rows.first(where: { $0.id == final }),
                      case .assistant(let message) = row.item.content else { return nil }
                return message.text
            }
        }
        func summaries(_ entries: [TimelineEntry], for id: UUID) -> [TurnSummary] {
            entries.compactMap { entry in
                guard case .turnEnd(let summary) = entry.item.content, summary.turnID == id else { return nil }
                return summary
            }
        }
        for (name, steering, failed) in [("follow-up-final", false, false),
                                         ("steering-final", true, false),
                                         ("failed-follow-up-final", false, true)] {
            let control = root.appendingPathComponent(name + "-control.json")
            let answerWrapper = root.appendingPathComponent(name + "-fixture.sh")
            let answerWrapperText = queueWrapperText
                .replacingOccurrences(of: queueControl.path, with: control.path)
                .replacingOccurrences(of: "queue-runtime-native.jsonl", with: name + "-native.jsonl")
                .replacingOccurrences(of: "queue-runtime-requests.jsonl", with: name + "-requests.jsonl")
            try answerWrapperText.write(to: answerWrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: answerWrapper.path)
            app.settings.setBinaryPath(answerWrapper.path, for: .omp)
            var answerChat = ChatThread(projectID: project.id, provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
            answerChat.hasCustomTitle = true
            answerChat.hydraEnabled = false
            app.insertThread(answerChat)
            let answering = app.runtime(for: answerChat.id)
            await answering.ensureLoaded()
            answering.draft = ComposerDraft(text: "final-reply-root")
            answering.send()
            try await wait { answering.turns.count == 1 && answering.phase == .running && answering.followUps.isEmpty }
            let firstID = answering.turns[0].id
            answering.draft = ComposerDraft(text: steering ? "tool-boundary-steer" : "final-reply-next")
            if steering { answering.steerDraft() } else { answering.queueDraftAsFollowUp() }
            try await wait { answering.turns.count == 2 && answering.entries.contains { entry in
                if case .tool(let call) = entry.item.content { return call.title.contains("fixture.txt") }
                return false
            } }
            let early = summaries(answering.entries, for: firstID)
            let earlyEndIDs = answering.entries.filter { $0.turnID == firstID && $0.kind == .turnEnd }.map(\.id)
            let earlyCompletedAt = answering.turns[0].completedAt
            expect(answering.phase == .running && answering.turns[1].status == .running,
                "The next native input remains active after its predecessor's boundary")
            if steering {
                expect(early.isEmpty && answering.turns[0].status == .running,
                    "A tool-call turn_end followed by steering must not seal the prior group")
                expect(visibleFinalTexts(answering.entries, isRunning: true).isEmpty,
                    "Tool commentary stays inside work while a steered native turn continues")
            } else {
                expect(early.count == 1 && answering.turns[0].status == .completed,
                    "A successful native final closes its display group when the follow-up is consumed")
                expect(visibleFinalTexts(answering.entries, isRunning: true) == ["First independent final response"],
                    "The first final is rendered independently while the follow-up is still working")
                answering.saveNow()
                let liveReload = Storage.decodeDocument(answerChat.id)!
                expect(visibleFinalTexts(liveReload.items.map(TimelineEntry.init), isRunning: true)
                    == ["First independent final response"],
                    "Saving an active follow-up preserves the earlier independent final reply")
            }
            try (failed ? #"{"release":true,"fail":true}"# : #"{"release":true}"#)
                .write(to: control, atomically: true, encoding: .utf8)
            try await answering.refreshOMPContext()
            try await wait { answering.phase == .idle && answering.turns.allSatisfy { $0.status != .running } }
            let expected = steering ? ["Final response after steering"] : failed
                ? ["First independent final response"]
                : ["First independent final response", "Second independent final response"]
            expect(visibleFinalTexts(answering.entries, isRunning: false) == expected,
                "Each completed native follow-up retains its own final without promoting tool commentary")
            if failed {
                expect(answering.turns[0].status == .completed && answering.turns[1].status == .failed,
                    "A failed follow-up does not replace the preceding successful response's completion status")
            }
            if !steering {
                let finished = summaries(answering.entries, for: firstID)
                expect(finished.count == 1 && finished[0].status == early[0].status
                    && finished[0].duration == early[0].duration && answering.turns[0].completedAt == earlyCompletedAt
                    && answering.entries.filter { $0.turnID == firstID && $0.kind == .turnEnd }.map(\.id) == earlyEndIDs,
                    "Whole-run completion preserves the earlier final's summary without duplication or retiming")
            }
            answering.saveNow()
            let reopened = ThreadRuntime(threadID: answerChat.id, app: app)
            await reopened.ensureLoaded()
            expect(visibleFinalTexts(reopened.entries, isRunning: false) == expected,
                "Reopening the persisted transcript retains every independently completed final")
            reopened.cancelPersistence()
            answering.stopSession()
            answering.cancelPersistence()
        }

        app.settings.setBinaryPath(root.appendingPathComponent("missing-runtime").path, for: .omp)
        let failedChat = ChatThread(projectID: project.id, provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        app.insertThread(failedChat)
        let failedRuntime = app.runtime(for: failedChat.id)
        await failedRuntime.ensureLoaded()
        failedRuntime.draft = ComposerDraft(text: "Retain pre-admission draft")
        failedRuntime.send()
        try await wait { failedRuntime.followUps.first?.ompState == .failed && failedRuntime.phase == .idle }
        expect(failedRuntime.draft.text == "Retain pre-admission draft", "Cold-launch failure remains editable and finalizes the displayed turn")
        expect(failedRuntime.visibleFollowUps.first?.ompState == .failed, "Failed idle delivery remains visible for recovery")
        failedRuntime.cancelPersistence()
        // A native bash tool may return before its background job writes. The
        // original before-tree must survive steering and subsequent display groups.
        for conflicts in [false, true] {
            let name = conflicts ? "background-conflict" : "background-restore"
            let checkout = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
            let initial = "native-original\n"
            let target = checkout.appendingPathComponent("Acceptance.txt")
            try Data(initial.utf8).write(to: target)
            let initialized = try await Shell.run(URL(fileURLWithPath: "/usr/bin/git"), ["init", "-q"], in: checkout)
            expect(initialized.succeeded, "Isolated restoration checkout initializes")
            let nativeWrapper = root.appendingPathComponent(name + ".sh")
            let nativeWrapperText = wrapperText.replacingOccurrences(of: "runtime-native.jsonl", with: name + ".jsonl")
                .replacingOccurrences(of: cancelFile.path, with: root.appendingPathComponent(name + "-cancel").path)
            try nativeWrapperText.write(to: nativeWrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nativeWrapper.path)
            app.settings.setBinaryPath(nativeWrapper.path, for: .omp)
            let restoreProject = app.addProject(at: checkout)
            var restoreChat = ChatThread(projectID: restoreProject.id, provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
            restoreChat.hasCustomTitle = true
            restoreChat.hydraEnabled = false
            app.insertThread(restoreChat)
            let restoring = app.runtime(for: restoreChat.id)
            await restoring.ensureLoaded()
            restoring.draft = ComposerDraft(text: "background-file-write")
            restoring.send()
            restoring.draft = ComposerDraft(text: "steering-group")
            restoring.steerDraft()
            restoring.draft = ComposerDraft(text: "follow-up-group")
            restoring.queueDraftAsFollowUp()
            try await wait { restoring.turns.count == 3 && restoring.phase == .idle && restoring.followUps.allSatisfy { $0.ompState?.isTerminal == true } }
            expect(try String(contentsOf: target, encoding: .utf8) == "native-changed\n", "Native background fixture writes after returning tool control")
            let origin = restoring.turns[0]
            expect(origin.baseCheckpoint != nil && origin.endCheckpoint != nil && origin.touchedPaths == ["Acceptance.txt"], "Origin group persists real checkpoint bounds and background command attribution")
            expect(restoring.turns.dropFirst().allSatisfy { $0.baseCheckpoint == nil }, "Queued groups never inherit a fabricated Git boundary")
            let shellRows = restoring.entries.compactMap { entry -> ToolCall? in
                if case .tool(let call) = entry.item.content, call.toolName == "bash" { return call }
                return nil
            }
            expect(shellRows.first?.edits.count == 1, "The originating bash row owns the delayed file edit")
            let ownerText = "owner-change\n"
            if conflicts { try Data(ownerText.utf8).write(to: target) }
            let preview = try await restoring.revertPreview(for: origin.id).value
            expect(preview.files.count == 1 && preview.files[0].isKept == conflicts, "File preview keeps changes made after the native job settled")
            let restored = try await restoring.revert(to: origin.id, restoreFiles: true)
            expect(restored != conflicts, "Partial file restoration is reported independently from successful native branching")
            expect(try String(contentsOf: target, encoding: .utf8) == (conflicts ? ownerText : initial), "Native branch restores only attributable files and preserves later owner edits")
            if !conflicts {
                let oldBase = origin.baseCheckpoint!
                let oldBaseObject = try await Git(checkout.path).output(["rev-parse", "--verify", oldBase])
                try Data("second-run-original\n".utf8).write(to: target)
                restoring.draft = ComposerDraft(text: "background-file-write")
                restoring.send()
                restoring.draft = ComposerDraft(text: "steering-group")
                restoring.steerDraft()
                restoring.draft = ComposerDraft(text: "follow-up-group")
                restoring.queueDraftAsFollowUp()
                try await wait { restoring.turns.count == 3 && restoring.phase == .idle && restoring.followUps.allSatisfy { $0.ompState?.isTerminal == true } }
                let replacement = restoring.turns[0]
                expect(replacement.index == origin.index && replacement.id != origin.id, "Native branching can reuse a display index with a new turn identity")
                expect(replacement.baseCheckpoint != origin.baseCheckpoint && replacement.endCheckpoint != origin.endCheckpoint, "New turn UUIDs isolate both start and end checkpoint refs")
                expect(try await Git(checkout.path).output(["rev-parse", "--verify", oldBase]) == oldBaseObject, "Sending after a branch never overwrites the original conversation's file baseline")
            }
            restoring.stopSession()
            restoring.cancelPersistence()
        }
        print("OMP P1/P2 production workflow checks passed: \(checks)")
    }
}
