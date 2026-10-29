import AppKit
import Foundation
@testable import OMPGUI

@main
struct SideQuestionChecks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        checks += 1
    }
    @MainActor private static func wait(line: UInt = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Side-question fixture did not settle at line \(line)")
    }
    static func turn(_ question: String, answer: String = "", status: String = "complete", timestamp: Int = 1) -> JSONValue {
        ["question": .string(question), "answer": .string(answer), "status": .string(status),
         "createdAt": .int(timestamp), "updatedAt": .int(timestamp)]
    }
    static func record(_ question: String, answer: String = "", status: String = "complete", followUps: [JSONValue] = []) -> JSONValue {
        var value = turn(question, answer: answer, status: status).object!
        value["id"] = "topic-core"
        value["leafId"] = "leaf"
        if !followUps.isEmpty { value["followUps"] = .array(followUps) }
        return .object(value)
    }

    @MainActor static func main() async throws {
        guard let root = CaptureRun.storageRoot, root.path.contains("/build.noindex/verification/runs/"),
              let fixtureIndex = CommandLine.arguments.firstIndex(of: "--fixture") else { fatalError("Require isolated fixture storage") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[fixtureIndex + 1])

        var bounded = OMPSideQuestionSnapshot()
        let oversized = String(repeating: "🙂原生", count: 20_000)
        let projection = OMPSideQuestionRecord(record("Question", answer: oversized))!
        bounded.apply(projection)
        expect(bounded.displayBytes <= 65_536 && bounded.omitted, "One answer remains within the cumulative display budget")
        expect(bounded.nativeBodyBytes == "Question".utf8.count + oversized.utf8.count, "Native byte accounting uses the original record, not its display suffix")
        expect(!bounded.turns[0].answer.contains("�"), "UTF-8 truncation preserves complete Unicode scalars")
        let rounds = (1..<16).map { turn("追问 \($0)", answer: String(repeating: "a", count: 8_000), timestamp: $0 + 1) }
        bounded.apply(OMPSideQuestionRecord(record("Question", answer: oversized, followUps: rounds))!)
        expect(bounded.turnCount == 16 && !bounded.canFollowUp && bounded.turns.count <= 16 && bounded.displayBytes <= 65_536,
               "Sixteen native rounds stop follow-ups without retaining sixteen full bodies")
        var nativeLimit = OMPSideQuestionSnapshot()
        nativeLimit.apply(OMPSideQuestionRecord(record("Q", answer: String(repeating: "b", count: 1_048_576)))!)
        expect(!nativeLimit.canFollowUp && nativeLimit.nativeBodyBytes > 1_048_576, "The independent native cumulative-body boundary stops another cumulative record")
        expect(OMPSideQuestionRecord(["id": "bad", "question": "Q", "answer": "A", "status": "invented", "updatedAt": 1]) == nil,
               "Unknown lifecycle values never become successful results")

        func make(_ name: String, scenario: String = "normal") throws -> (OMPSession, URL) {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let configuration = SessionConfiguration(provider: .omp, executable: fixture, workingDirectory: directory,
                environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                              "OMP_FIXTURE_LOG": directory.appendingPathComponent("requests.jsonl").path,
                              "OMP_FIXTURE_SESSION_FILE": directory.appendingPathComponent("session.jsonl").path,
                              "OMP_FIXTURE_SCENARIO": scenario],
                resumeID: nil, resumeAt: nil, model: nil, effort: nil, runtimeMode: .auto,
                interactionMode: .build, apiKey: nil, hydra: nil, antiSlopEnabled: false)
            return (OMPSession(configuration: configuration), directory)
        }
        let (session, normalRoot) = try make("normal")
        let app = AppModel()
        let thread = ChatThread(projectID: UUID(), provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        app.insertThread(thread)
        let runtime = app.runtime(for: thread.id)
        await runtime.ensureLoaded()
        var mainText = ""
        var mainEnds = 0
        var startedBeforeAcceptance = false
        var notices = 0
        session.onEvent = { event in
            switch event {
            case .ompSideQuestion(let state):
                if state.isRunning && state.pendingRequestID != nil { startedBeforeAcceptance = true }
                runtime.receiveOMPEvent(event)
            case .ompActivity, .ompCapabilities, .exited: runtime.receiveOMPEvent(event)
            case .messageDelta(_, let text): mainText += text
            case .turnCompleted: mainEnds += 1
            case .notice: notices += 1
            default: break
            }
        }
        _ = try await session.start()
        expect(session.nativeActivity.canRecycle, "The unchanged lead starts with native idle evidence")
        do { try await session.askSideQuestion(String(repeating: "x", count: 131_073), continuing: false, requestID: "oversized-before-send"); fatalError("Expected oversized input rejection") } catch { }
        let earlyLog = try String(contentsOf: normalRoot.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        expect(!earlyLog.contains("oversized-before-send"), "The input byte budget is checked before a native mutation")
        try await session.send(TurnInput(text: "hold main", images: [], model: nil, effort: nil, runtimeMode: .auto, interactionMode: .build))
        try await wait { mainText == "Main reply " }
        try await session.askSideQuestion("Explain", continuing: false, requestID: "ask-first")
        try await wait { runtime.ompSideQuestion.turns.last?.answer == "partial " }
        expect(startedBeforeAcceptance, "A started record before the response is associated with its pending question")
        expect(runtime.entries.isEmpty && !runtime.isRunning && mainEnds == 0, "Side-question events do not create a main turn or finish its live reply")
        expect(!session.nativeActivity.canRecycle, "The side question and real main work protect their process")
        let topic = session.sideQuestionSnapshot.recordID!
        expect(session.sideQuestionSnapshot.acceptedRequestID == "ask-first", "Only matched admission confirms the draft")
        _ = try await session.rpc.request("fixture_finish")
        try await wait { session.sideQuestionSnapshot.turns.last?.status == .complete }
        expect(session.sideQuestionSnapshot.turns.last?.answer == "Native answer", "The terminal native snapshot corrects the streamed answer")
        expect(session.sideQuestionSnapshot.persistencePending && !FileManager.default.fileExists(atPath: normalRoot.appendingPathComponent("native-sidecar-saved").path),
               "Answer completion does not claim that the asynchronous sidecar write finished")
        try await session.askSideQuestion("More", continuing: true, requestID: "ask-follow-up")
        expect(session.sideQuestionSnapshot.recordID == topic && session.sideQuestionSnapshot.turnCount == 2, "Follow-up continues the exact native topic")
        try await session.cancelSideQuestion()
        try await wait { session.sideQuestionSnapshot.turns.last?.status == .cancelled }
        expect(mainEnds == 0 && mainText == "Main reply ", "Cancelling a side question leaves the main reply running")
        _ = try await session.rpc.request("fixture_main_finish")
        try await wait { mainEnds > 0 && session.nativeActivity.canRecycle }
        expect(!runtime.hasNativeWork && runtime.ompSideQuestion.persistencePending && !runtime.canRecycleSession,
               "An idle lead remains protected until the native sidecar disposal barrier")
        try await session.askSideQuestion("instant", continuing: false, requestID: "instant")
        try await wait { session.sideQuestionSnapshot.turns.last?.status == .complete }
        expect(session.sideQuestionSnapshot.turns.last?.answer == "Final snapshot corrects the stream", "A quick terminal frame cannot regress to the older admission snapshot")
        let entriesBeforeError = runtime.entries.count
        _ = try await session.rpc.request("fixture_storage_error")
        try await wait { session.sideQuestionSnapshot.persistenceError != nil }
        expect(!session.beginSideQuestionDrain() && runtime.entries.count == entriesBeforeError && notices == 0,
               "A save failure prevents automatic EOF disposal and stays outside the main transcript")
        try await session.askSideQuestion("Retry native checkpoint", continuing: false, requestID: "retry-save")
        expect(session.sideQuestionSnapshot.persistenceError == nil, "A successful new native admission confirms the prior checkpoint retry")
        _ = try await session.rpc.request("fixture_finish")
        try await wait { !session.sideQuestionSnapshot.hasLiveWork }
        expect(session.beginSideQuestionDrain(), "Only idle automatic disposal closes stdin for a native save drain")
        try await wait { session.sideQuestionSnapshot.disconnected }
        expect(FileManager.default.fileExists(atPath: normalRoot.appendingPathComponent("eof-received").path)
               && FileManager.default.fileExists(atPath: normalRoot.appendingPathComponent("native-sidecar-saved").path)
               && !session.sideQuestionSnapshot.persistencePending, "Native EOF and full output/exit drain precede release of the save blocker")

        let (slow, slowRoot) = try make("slow", scenario: "slow-drain")
        _ = try await slow.start()
        try await slow.askSideQuestion("instant", continuing: false, requestID: "slow")
        try await wait { !slow.sideQuestionSnapshot.hasLiveWork }
        expect(slow.beginSideQuestionDrain(), "A completed side answer may enter graceful disposal")
        try await wait { FileManager.default.fileExists(atPath: slowRoot.appendingPathComponent("eof-received").path) }
        expect(slow.isRunning && slow.isDraining && slow.sideQuestionSnapshot.blocksRecycling, "A slow save retains the actual process rather than immediately sending SIGTERM")
        do { _ = try await slow.rpc.request("prompt", fields: ["message": "must not send"]); fatalError("Expected draining input rejection") } catch { }
        do { try await slow.send(TurnInput(text: "must not send", images: [], model: nil, effort: nil, runtimeMode: .auto, interactionMode: .build)); fatalError("Expected draining public prompt rejection") } catch { }
        do { try await slow.askSideQuestion("must not send", continuing: false, requestID: "forbidden"); fatalError("Expected draining side question rejection") } catch { }
        let slowLog = try String(contentsOf: slowRoot.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        expect(!slowLog.contains("must not send"), "A draining connection accepts no new prompt or side question")
        try Data().write(to: slowRoot.appendingPathComponent("allow-exit"))
        try await wait { slow.sideQuestionSnapshot.disconnected }
        expect(!slow.isRunning && !slow.sideQuestionSnapshot.blocksRecycling, "Actual clean native exit releases graceful disposal protection")

        let (failure, _) = try make("drain-error", scenario: "drain-error")
        _ = try await failure.start()
        try await failure.askSideQuestion("instant", continuing: false, requestID: "drain-error")
        try await wait { !failure.sideQuestionSnapshot.hasLiveWork }
        expect(failure.beginSideQuestionDrain(), "Unknown pending persistence is handed to native shutdown")
        try await wait { failure.sideQuestionSnapshot.disconnected }
        expect(failure.sideQuestionSnapshot.persistenceError != nil && failure.sideQuestionSnapshot.blocksRecycling,
               "A save-failure notice during EOF drain survives even an exit status of zero")

        let (unknown, unknownRoot) = try make("unknown")
        _ = try await unknown.start()
        do {
            try await unknown.sideQuestions.ask("hold-admission", continuing: false, requestID: "late", timeout: .milliseconds(30))
            fatalError("Expected unknown admission")
        } catch { }
        expect(unknown.sideQuestionSnapshot.outcomeUnknown && unknown.sideQuestionSnapshot.pendingRequestID == "late", "Timeout retains request identity and the uncertain input admission")
        do { try await unknown.askSideQuestion("repeat", continuing: false, requestID: "duplicate"); fatalError("Expected duplicate prevention") } catch { }
        _ = try await unknown.rpc.request("fixture_admit")
        try await wait { unknown.sideQuestionSnapshot.acceptedRequestID == "late" }
        expect(!unknown.sideQuestionSnapshot.outcomeUnknown, "A matching late response settles the same request without retransmission")
        let unknownLog = try String(contentsOf: unknownRoot.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        expect(unknownLog.components(separatedBy: "\"id\": \"late\"").count == 2 && !unknownLog.contains("duplicate"), "Unknown admission was transmitted exactly once")
        _ = try await unknown.rpc.request("fixture_frame_error")
        try await wait { unknown.sideQuestionSnapshot.outcomeUnknown }
        expect(!unknown.beginSideQuestionDrain(), "A missing terminal frame preserves uncertainty and process protection")
        await unknown.stopAndWait(timeout: 2)

        let (noStart, noStartRoot) = try make("no-start")
        _ = try await noStart.start()
        do {
            try await noStart.sideQuestions.ask("  hold-without-start\n", continuing: false, requestID: "without-start", timeout: .milliseconds(30))
            fatalError("Expected no-start admission timeout")
        } catch { }
        expect(noStart.sideQuestionSnapshot.recordID == nil && noStart.sideQuestionSnapshot.pendingRequestID == "without-start"
               && noStart.sideQuestionSnapshot.outcomeUnknown && !noStart.beginSideQuestionDrain(),
               "A timeout with no started record still retains possible native work and blocks disposal")
        let originalLog = try String(contentsOf: noStartRoot.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        expect(originalLog.contains("  hold-without-start\\n"), "GUI submits original whitespace while matching OMP's trimmed question")
        _ = try await noStart.rpc.request("fixture_admit")
        try await wait { noStart.sideQuestionSnapshot.acceptedRequestID == "without-start" }
        do { try await noStart.sideQuestions.cancel(timeout: .milliseconds(30)); fatalError("Expected cancellation timeout") } catch { }
        expect(noStart.sideQuestionSnapshot.pendingCancellationID != nil && noStart.sideQuestionSnapshot.outcomeUnknown,
               "An unconfirmed cancellation retains its own native request identity")
        _ = try await noStart.rpc.request("fixture_cancel_confirm")
        try await wait { noStart.sideQuestionSnapshot.pendingCancellationID == nil && noStart.sideQuestionSnapshot.turns.last?.status == .cancelled }
        expect(!noStart.sideQuestionSnapshot.outcomeUnknown && noStart.sideQuestionSnapshot.error == nil, "A matching late cancellation and terminal lifecycle clear the old unknown error without a second cancel")
        await noStart.stopAndWait(timeout: 2)

        let (replaced, _) = try make("reset-during-admission")
        _ = try await replaced.start()
        let oldConnection = replaced.sideQuestionSnapshot.connectionID
        var resetDuringRecord = false
        replaced.onEvent = { event in
            if case .ompSideQuestion(let state) = event, state.pendingRequestID == "reset-admission",
               state.recordID != nil, !resetDuringRecord {
                resetDuringRecord = true
                // Native branch/session reset can happen while admission is
                // awaiting the started record's background projection.
                replaced.sideQuestions.reset()
            }
        }
        do { try await replaced.askSideQuestion("reset admission", continuing: false, requestID: "reset-admission"); fatalError("Expected replaced admission cancellation") } catch { }
        expect(resetDuringRecord && replaced.sideQuestionSnapshot.connectionID != oldConnection
               && replaced.sideQuestionSnapshot.pendingRequestID == nil && !replaced.sideQuestionSnapshot.outcomeUnknown
               && replaced.sideQuestionSnapshot.error == nil && replaced.sideQuestionSnapshot.recordID == nil,
               "An old admission resuming across reset never writes unknown or error into the replacement snapshot")
        await replaced.stopAndWait(timeout: 2)

        let (cross, crossRoot) = try make("goal-settlement")
        _ = try await cross.start()
        _ = try await cross.rpc.request("fixture_hold_state")
        let goalOperation = Task { try await cross.performGoalOperation(.create, objective: "Native goal settlement", expectedGoalID: nil) }
        try await wait { FileManager.default.fileExists(atPath: crossRoot.appendingPathComponent("state-read-held").path) }
        expect(cross.goalNeedsSettlement && cross.goalSnapshot.pending == nil, "The goal's unique post-control settlement read is in flight")
        try await cross.askSideQuestion("Explain the settling goal", continuing: false, requestID: "goal-btw-interleave")
        try await cross.cancelSideQuestion()
        try await wait { cross.sideQuestionSnapshot.turns.last?.status == .cancelled }
        _ = try await cross.rpc.request("fixture_release_state")
        try await goalOperation.value
        expect(!cross.goalNeedsSettlement && cross.goalSnapshot.goal?.id == "cross-goal" && cross.nativeActivity.canRecycle,
               "Side-question admission and cancellation do not invalidate the goal's only valid settlement reply")
        expect(cross.beginSideQuestionDrain(), "A settled goal and cancelled side question permit native EOF disposal without extra polling")
        try await wait { cross.sideQuestionSnapshot.disconnected }

        let (unsupported, unsupportedRoot) = try make("unsupported", scenario: "unsupported")
        _ = try await unsupported.start()
        do { try await unsupported.askSideQuestion("Keep draft", continuing: false, requestID: "unsupported"); fatalError("Expected unsupported request") } catch { }
        expect(unsupported.capabilities["btw"] == .unsupported && unsupported.isRunning, "Exact unknown-command evidence disables only the optional side-question operation")
        do { try await unsupported.askSideQuestion(String(repeating: "x", count: 131_073), continuing: false, requestID: "too-large"); fatalError("Expected oversized rejection") } catch { }
        let unsupportedLog = try String(contentsOf: unsupportedRoot.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        expect(!unsupportedLog.contains("too-large") && !unsupportedLog.contains("get_btw_history"), "Input validation and capability checks do not transmit oversized inputs or history probes")
        await unsupported.stopAndWait(timeout: 2)

        runtime.sideQuestionDraft.text = "Independent new draft"
        let before = runtime.entries.count
        runtime.draft.text = "Main composer draft"
        let first = OMPSession(configuration: session.configuration)
        runtime.observe(first)
        let stale = first.onEvent!
        let second = OMPSession(configuration: session.configuration)
        runtime.observe(second)
        let current = OMPSideQuestionSnapshot()
        second.onEvent?(.ompSideQuestion(current))
        stale(.ompSideQuestion(bounded))
        expect(runtime.ompSideQuestion.connectionID == current.connectionID && runtime.entries.count == before,
               "Late records from a replaced native connection cannot overwrite the current topic or transcript")
        expect(runtime.sideQuestionDraft.text == "Independent new draft" && runtime.draft.text == "Main composer draft", "Separate side-question drafts survive view closure without replacing the main composer")
        var newState = current
        runtime.sideQuestionSubmission = ("draft-accept", "Independent new draft")
        runtime.installOMPSideQuestion(newState)
        expect(runtime.sideQuestionSubmission?.id == "draft-accept", "An unrelated state publication cannot retire another window's pending submission")
        newState.acceptedRequestID = "draft-accept"
        runtime.sideQuestionSubmission = ("draft-accept", "Independent new draft")
        runtime.sideQuestionDraft.text = "Edited after submission"
        runtime.installOMPSideQuestion(newState)
        expect(runtime.sideQuestionDraft.text == "Edited after submission", "A confirmed acceptance preserves a draft edited after submission")
        runtime.sideQuestionSubmission = ("next", "Edited after submission")
        newState.acceptedRequestID = "next"
        runtime.installOMPSideQuestion(newState)
        expect(runtime.sideQuestionDraft.text.isEmpty, "Matching native acceptance clears only the submitted draft")
        runtime.cancelPersistence()
        print("\(checks) side-question checks passed")
    }
}
