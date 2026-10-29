import Foundation
import Observation
import Synchronization
@testable import OMPGUI

/// Runs production app types as a CLI, without an app entry point or window.
@main
struct EvalRuntimeChecks {
    @MainActor private static var checks = 0

    @MainActor private static func expect(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        checks += 1
    }

    @MainActor private static func json(_ text: String) -> JSONValue { JSONValue.parse(text)! }

    @MainActor static func main() async throws {
        guard CaptureRun.isEnabled, let isolated = CaptureRun.storageRoot,
              isolated.path.contains("/build.noindex/verification/runs/") else { fatalError("Require isolated storage") }
        expect(Storage.root == isolated, "Never use the owner's app data")
        try FileManager.default.createDirectory(at: Storage.threadsDirectory, withIntermediateDirectories: true)
        let app = AppModel()
        let partial = (0..<8).map { TodoStep(text: "Task \($0)", status: $0 < 3 ? .done : .pending, phase: "Implementation") }
        let done = partial.map { TodoStep(text: $0.text, status: .done, phase: $0.phase) }
        let id = UUID()
        var turn = TurnRecord(index: 0, status: .completed)
        turn.completedAt = .now
        var old = ThreadDocument(threadID: id)
        old.turns = [turn]
        old.items = [TimelineItem(turnID: turn.id, content: .todos(partial))]
        try JSONEncoder.storage.encode(old).write(to: Storage.threadURL(id), options: .atomic)

        let runtime = ThreadRuntime(threadID: id, app: app)
        runtime.receiveOMPEvent(.todoSnapshot(TodoSnapshot(steps: [], recentList: done)))
        expect(runtime.todoSteps == done, "Complete-then-clear recovers from the native journal")
        await runtime.ensureLoaded()
        expect(runtime.todoSteps == done, "Late 3/8 history cannot overwrite 8/8 completion")
        expect(runtime.snapshotForPersistence().items.last { if case .todos = $0.content { return true }; return false }?.turnID == turn.id, "Retained completion belongs to a turn so rewind can remove it")
        runtime.saveNow()
        let saved = Storage.decodeDocument(id)!
        expect(saved.items.last { if case .todos = $0.content { return true }; return false }?.content == .todos(done), "Persist the completed display record")
        let reopened = ThreadRuntime(threadID: id, app: app)
        reopened.receiveOMPEvent(.todoSnapshot(TodoSnapshot(steps: [])))
        await reopened.ensureLoaded()
        expect(reopened.todoSteps == done, "Resume before disk load retains saved completion")
        reopened.receiveOMPEvent(.todoSnapshot(TodoSnapshot(steps: partial)))
        expect(reopened.todoSteps == partial, "A new list replaces the completion record")
        reopened.receiveOMPEvent(.todoSnapshot(TodoSnapshot(steps: [], recentList: partial)))
        expect(reopened.todoSteps.isEmpty, "A new unfinished list followed by clear cannot revive old completion")
        reopened.saveNow()
        let reopenedClear = ThreadRuntime(threadID: id, app: app)
        await reopenedClear.ensureLoaded()
        expect(reopenedClear.todoSteps.isEmpty, "Persist the replacement/clear across reopening")
        let empty = ThreadRuntime(threadID: UUID(), app: app)
        empty.receiveOMPEvent(.todoSnapshot(TodoSnapshot(steps: [])))
        await empty.ensureLoaded()
        expect(empty.entries.isEmpty, "Warming an unused chat does not create a todo row")
        let observed = Mutex(false)
        withObservationTracking { _ = runtime.todoSteps } onChange: { observed.withLock { $0 = true } }
        runtime.receiveOMPEvent(.todoSnapshot(TodoSnapshot(steps: partial)))
        expect(observed.withLock { $0 }, "Capsule and popover observe the same projection")
        for value in [runtime, reopened, reopenedClear, empty] { value.cancelPersistence() }

        let sink = EventSink()
        let decoder = OMPEventDecoder(prefix: "fixture", directory: isolated.path)
        decoder.onEvent = { sink.events.append($0) }
        let args = json(#"{"language":"js","code":"await tool.write({path:'file.txt',content:'changed'});","title":"ls"}"#)
        decoder.handle(["type": "tool_execution_start", "toolName": "eval", "toolCallId": "input", "args": args])
        guard case .toolStarted(_, let call) = sink.events.last! else { fatalError("Missing call") }
        expect(call.detail?.contains("tool.write") == true && call.title == "ls", "Keep eval code and its native caption")
        expect(call.commandMayWriteFiles, "An eval caption of ls cannot suppress file tracking")
        expect(!ToolCall(kind: .command, title: "ls", toolName: "bash").commandMayWriteFiles, "A real shell ls remains read-only")
        let nested = json(#"{"content":[{"type":"text","text":"false"}],"details":{"cells":[{"status":"complete","exitCode":0}],"statusEvents":[{"op":"todo","hasError":true,"error":"Missing task"}],"jsonOutputs":[{"ok":false}]}}"#)
        decoder.handle(["type": "tool_execution_end", "toolName": "eval", "toolCallId": "input", "result": nested])
        guard case .toolUpdated(_, let update) = sink.events.last! else { fatalError("Missing update") }
        expect(update.status == .completed, "Caught nested errors do not falsify the outer result")
        expect(update.detail?.contains("Missing task") == true && update.detail?.contains("jsonOutputs") == true, "Preserve native structured diagnostics")
        decoder.handle(["type": "tool_execution_start", "toolName": "eval", "toolCallId": "failure", "args": args])
        decoder.handle(json(#"{"type":"tool_execution_end","toolCallId":"failure","result":{"details":{"isError":true},"content":[{"type":"text","text":"Failed"}]}}"#))
        guard case .toolUpdated(_, let failure) = sink.events.last! else { fatalError("Missing failure") }
        expect(failure.status == .failed, "Honor structured failure flags even without an outer flag")
        decoder.handle(json(#"{"type":"message_end","messageId":"async","message":{"role":"custom","customType":"async-result","display":true,"content":"Background eval failed: Regression failure"}}"#))
        guard case .messageCompleted(let messageID, let text) = sink.events.last! else { fatalError("Missing async report") }
        expect(messageID == "fixture-async-async" && text.contains("Regression failure"), "Display owner-routed native background results")
        let beforeHidden = sink.events.count
        decoder.handle(json(#"{"type":"message_end","message":{"role":"custom","customType":"async-result","display":false,"content":"Hidden"}}"#))
        expect(sink.events.count == beforeHidden, "Respect native hidden messages")
        decoder.handle(json(#"{"type":"notice","level":"error","message":"Cannot persist session"}"#))
        guard case .notice(let notice) = sink.events.last! else { fatalError("Missing notice") }
        expect(notice.level == .error && notice.message == "Cannot persist session", "Expose native persistence failures")
        decoder.handle(json(#"{"type":"auto_retry_start","errorMessage":"Rate limited"}"#))
        guard case .notice(let retry) = sink.events.last! else { fatalError("Missing retry") }
        expect(retry.message == "Rate limited", "Keep native retry reasons")

        let prefix = UUID().uuidString
        let historyURL = isolated.appendingPathComponent("native.jsonl")
        let journal = [json(#"{"type":"session","id":"native"}"#),
            JSONValue.object(["type": "message", "message": ["role": "assistant", "content": .array([
                ["type": "toolCall", "id": "native-call", "name": "eval", "arguments": args]
            ])]])]
        try Data((journal.map(\.compactString).joined(separator: "\n") + "\n").utf8).write(to: historyURL)
        let identities = OMPToolHistory.readIdentities(sessionFile: historyURL.path)
        var legacy = ToolCall(kind: .command, title: "eval", toolName: "eval")
        expect(OMPToolHistory.restore(&legacy, timelineID: "\(prefix)-native-call", identities: identities), "Restore lost eval inputs even when identity was already saved")
        expect(legacy.detail?.contains("tool.write") == true, "Use the exact native call's input")
        let unchanged = legacy
        expect(!OMPToolHistory.restore(&legacy, timelineID: "\(prefix)-native-call", identities: identities) && legacy == unchanged, "Input restoration is idempotent")
        var worker = ToolCall(kind: .command, title: "eval")
        expect(OMPToolHistory.restore(&worker, timelineID: "\(prefix)-worker-native-call", identities: identities, nativeAgentID: "worker"), "Fresh worker prefixes preserve native history lookup")

        if let index = CommandLine.arguments.firstIndex(of: "--sdk-results"), index + 1 < CommandLine.arguments.count {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            let fixtures = JSONValue.parse(data)!.array!
            for (index, fixture) in fixtures.enumerated() {
                let id = "sdk-\(index)"
                decoder.handle(["type": "tool_execution_start", "toolName": "eval", "toolCallId": .string(id), "args": fixture["args"]!])
                decoder.handle(["type": "tool_execution_end", "toolName": "eval", "toolCallId": .string(id), "result": fixture["result"]!])
                guard case .toolUpdated(_, let update) = sink.events.last! else { fatalError("Missing SDK result") }
                let expected: ToolCall.Status = fixture["result"]?["isError"]?.bool == true ? .failed : .completed
                expect(update.status == expected, "GUI status agrees with actual OMP SDK result \(index)")
                expect(update.detail?.contains("code") == true, "Actual SDK input survives result \(index)")
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--native-history"), index + 1 < CommandLine.arguments.count {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            let history = JSONValue.parse(data)!
            let snapshot = OMPTodoSnapshot.snapshot(from: history["entries"], leafID: history["leafId"])!
            expect(snapshot.steps.isEmpty, "Native active list is cleared")
            expect(snapshot.displayed(after: []).allSatisfy { $0.status == .done } && !snapshot.displayed(after: []).isEmpty, "Native RPC history recovers completion")
        }
        if let index = CommandLine.arguments.firstIndex(of: "--native-executable"), index + 1 < CommandLine.arguments.count,
           let resumeIndex = CommandLine.arguments.firstIndex(of: "--native-resume"), resumeIndex + 1 < CommandLine.arguments.count {
            let nativeSink = EventSink()
            let config = SessionConfiguration(provider: .omp,
                executable: URL(fileURLWithPath: CommandLine.arguments[index + 1]), workingDirectory: isolated,
                environment: ProcessInfo.processInfo.environment, resumeID: CommandLine.arguments[resumeIndex + 1], resumeAt: nil,
                model: nil, effort: nil, runtimeMode: .auto, interactionMode: .build, apiKey: nil, hydra: nil, antiSlopEnabled: false)
            let session = OMPSession(configuration: config)
            session.onEvent = { nativeSink.events.append($0) }
            do {
                _ = try await session.start()
                let snapshots = nativeSink.events.compactMap { event -> TodoSnapshot? in
                    if case .todoSnapshot(let snapshot) = event { return snapshot }; return nil
                }
                expect(snapshots.last?.steps.isEmpty == true, "Production OMPSession reads native cleared state")
                let displayed = snapshots.last?.displayed(after: []) ?? []
                expect(!displayed.isEmpty && displayed.allSatisfy { $0.status == .done }, "Production OMPSession retrieves the completed record via get_entries")
                await session.stopAndWait(timeout: 5)
            } catch { await session.stopAndWait(timeout: 5); throw error }
        }
        print("Production eval/runtime regression checks passed: \(checks)")
    }
}

@MainActor private final class EventSink {
    var events: [ProviderEvent] = []
}
