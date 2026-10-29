import Foundation

/// Exercises production parsing and synchronization without a model, GUI launch
/// or application data. Gates deliberately deliver RPC reads out of date.
@main
struct TodoSyncChecks {
    @MainActor private static var checks = 0

    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        checks += 1
    }

    private static func json(_ text: String) -> JSONValue {
        guard let value = JSONValue.parse(Data(text.utf8)) else { fatalError("Invalid fixture JSON") }
        return value
    }

    private static func phases(completed: Int) -> JSONValue {
        .array([.object(["name": "Implementation", "tasks": .array((0..<8).map { index in
            .object(["content": .string("Task \(index + 1)"),
                     "status": .string(index < completed ? "completed" : "pending")])
        })])])
    }

    private static func edit(_ id: String, parent: String?, phases: JSONValue) -> JSONValue {
        .object(["type": "custom", "id": .string(id), "parentId": parent.map(JSONValue.string) ?? .null,
                 "customType": "user_todo_edit", "data": .object(["phases": phases])])
    }

    @MainActor static func main() async throws {
        let partial = OMPTodoSnapshot.decode(phases(completed: 3))!
        let done = OMPTodoSnapshot.decode(phases(completed: 8))!
        expect(partial.count == 8 && partial.count { $0.status == .done } == 3, "Decode 3/8")
        expect(done.allSatisfy { $0.status == .done }, "Decode 8/8")
        expect(OMPTodoSnapshot.decode(.array([])) == [], "Empty is a committed clear")
        expect(OMPTodoSnapshot.decode(json(#"[{"name":"Design","tasks":[]}]"#)) == [], "Empty phases clear too")
        expect(OMPTodoSnapshot.decode(nil) == nil, "Missing state must not clear")
        expect(OMPTodoSnapshot.decode(.null) == nil, "Null must not clear")
        expect(OMPTodoSnapshot.decode(json(#"[{"name":"","tasks":[{"content":"valid","status":"completed"},{"content":"bad","status":"unknown"}]}]"#)) == nil, "Reject a partial malformed snapshot")
        expect(OMPTodoSnapshot.decode(json(#"[{"tasks":[]}]"#)) == nil, "Require structured phases")
        let statuses = OMPTodoSnapshot.decode(json(#"[{"name":"","tasks":[{"content":"p","status":"pending"},{"content":"a","status":"in_progress"},{"content":"d","status":"completed"}]},{"name":"Verify","tasks":[{"content":"b","status":"blocked","blocker":"await access"},{"content":"x","status":"abandoned"}]}]"#))!
        expect(statuses.map(\.status) == [.pending, .active, .done, .blocked, .abandoned], "Preserve every native status")
        expect(statuses[0].phase == nil && statuses[3].phase == "Verify" && statuses[3].blocker == "await access", "Preserve grouping and blocker")
        let encoded = try JSONEncoder().encode(statuses)
        expect(try JSONDecoder().decode([TodoStep].self, from: encoded) == statuses, "Preserve saved todo compatibility")

        let initial = edit("initial", parent: nil, phases: phases(completed: 3))
        let completed = edit("completed", parent: "initial", phases: phases(completed: 8))
        let cleared = edit("cleared", parent: "completed", phases: .array([]))
        let archive = OMPTodoSnapshot.snapshot(from: .array([initial, completed, cleared]))!
        expect(archive.steps.isEmpty && archive.recentList == done, "Canonical clear retains a separate completed record")
        expect(archive.displayed(after: partial) == done, "Recover complete-then-rm within one eval")
        expect(TodoSnapshot(steps: []).displayed(after: done) == done, "Retain saved completion after restart")
        expect(TodoSnapshot(steps: []).displayed(after: partial).isEmpty, "Do not retain an incomplete cleared list")
        expect(TodoSnapshot(steps: partial).displayed(after: done) == partial, "New list replaces prior completion")
        expect(TodoSnapshot(steps: [], recentList: partial).displayed(after: done).isEmpty, "A new list created and cleared within eval invalidates prior completion")
        expect(TodoSnapshot(steps: []).displayed(after: []).isEmpty, "Empty warmup remains unused")
        expect(TodoSnapshot(steps: [], recentList: [TodoStep(text: "Blocked", status: .blocked)]).displayed(after: done).isEmpty, "Blocked is not completion")
        let title = json(#"{"type":"title","v":1,"title":"Todo verification"}"#)
        let header = json(#"{"type":"session","id":"session","version":3}"#)
        expect(OMPTodoSnapshot.fromTranscript(.array([title, header, initial])) == partial, "Native file metadata stays outside the branch")
        expect(OMPTodoSnapshot.fromTranscript(.array([initial, completed])) == done, "Eval commits supersede direct tool history")
        expect(OMPTodoSnapshot.fromTranscript(.array([initial, completed, cleared])) == [], "Eval clear supersedes 8/8")
        let branch = json(#"{"type":"message","id":"branch","parentId":"initial","message":{"role":"assistant","content":[{"type":"text","text":"All tasks done"}]}}"#)
        expect(OMPTodoSnapshot.fromTranscript(.array([initial, completed, cleared, branch])) == partial, "Follow the active branch, not physical history order or prose")
        expect(OMPTodoSnapshot.snapshot(from: .array([initial, completed, cleared, branch]), leafID: .string("cleared")) == archive, "Native leafId outranks append order")
        expect(OMPTodoSnapshot.snapshot(from: .array([initial, completed]), leafID: .null)?.recentList == nil, "Null leaf cannot revive another branch's completion")
        expect(OMPTodoSnapshot.snapshot(from: .array([initial]), leafID: .string("missing")) == nil, "Unknown active leaf is malformed")
        let malformed = json(#"{"type":"custom","id":"bad","parentId":"cleared","customType":"user_todo_edit","data":{}}"#)
        expect(OMPTodoSnapshot.snapshot(from: .array([initial, completed, cleared, malformed])) == nil, "Unknown canonical schema is not a clear or an archive")
        let olderMalformed = json(#"{"type":"custom","id":"older-bad","parentId":null,"customType":"user_todo_edit","data":{"phases":[{"name":"unknown","tasks":[{"content":"Task","status":"new-status"}]}]}}"#)
        let knownClear = edit("known-clear", parent: "older-bad", phases: .array([]))
        expect(OMPTodoSnapshot.snapshot(from: .array([olderMalformed, knownClear]))?.steps == [], "An old unknown schema cannot invalidate a later verified clear")
        let view = json(#"{"type":"message","id":"view","parentId":"initial","message":{"role":"toolResult","toolName":"todo","details":{"op":"view","phases":[]}}}"#)
        let error = json(#"{"type":"message","id":"error","parentId":"view","message":{"role":"toolResult","toolName":"todo","isError":true,"details":{"op":"rm","phases":[]}}}"#)
        expect(OMPTodoSnapshot.fromTranscript(.array([initial, view, error])) == partial, "Views and failed tools do not mutate durable state")
        let direct = json(#"{"type":"message","id":"direct","parentId":"initial","message":{"role":"toolResult","toolName":"todo","details":{"op":"rm","phases":[]}}}"#)
        let mounted = json(#"{"type":"message","id":"mounted","parentId":"initial","message":{"role":"toolResult","toolName":"write","details":{"xdev":{"tool":"todo","inner":{"op":"rm","phases":[]}}}}}"#)
        expect(OMPTodoSnapshot.fromTranscript(.array([initial, direct])) == [], "Direct todo mutations")
        expect(OMPTodoSnapshot.fromTranscript(.array([initial, mounted])) == [], "Mounted todo mutations")
        let unrelated = json(#"{"type":"message","id":"unrelated","parentId":"initial","message":{"role":"toolResult","toolName":"eval","details":{"op":"rm","phases":[]}}}"#)
        expect(OMPTodoSnapshot.fromTranscript(.array([initial, unrelated])) == partial, "Require native snapshot provenance")
        expect(OMPTodoSnapshot.fromTranscript(.array([])) == [], "New worker with no todo")
        expect(OMPTodoSnapshot.fromTranscript(nil) == nil, "Absent transcript is unknown")
        expect(OMPTodoSnapshot.fromTranscript(.array([cleared])) == nil, "Reject dangling branch parents")
        expect(OMPTodoSnapshot.fromTranscript(.array([initial, initial])) == nil, "Reject duplicate entry IDs")
        let cycle = json(#"{"type":"message","id":"cycle","parentId":"cycle","message":{"role":"assistant"}}"#)
        expect(OMPTodoSnapshot.fromTranscript(.array([cycle])) == nil, "Reject branch cycles")

        let source = SnapshotSource(partial)
        let sync = OMPTodoStateSync(delay: .zero, read: { try source.read() }, publish: { source.published.append($0) })
        sync.accept(partial, revision: sync.revision)
        sync.observe(json(#"{"type":"tool_execution_start","toolName":"eval"}"#))
        source.steps = done
        sync.observe(json(#"{"type":"tool_execution_end","toolName":"eval","result":{"content":[{"type":"text","text":"Done"}]}}"#))
        await sync.waitForRefresh()
        expect(source.published == [partial, done], "Refresh eval completion even without todo events or result phases")
        source.steps = []
        sync.observe(json(#"{"type":"tool_execution_end","toolName":"eval"}"#))
        await sync.waitForRefresh()
        expect(source.published == [partial, done, []], "Clear the obsolete capsule after eval rm")
        expect(source.reads == 2, "One canonical read per settled burst")
        sync.observe(json(#"{"type":"message_end","message":{"role":"assistant","content":"All done"}}"#))
        sync.observe(json(#"{"type":"subagent_event","payload":{"event":{"type":"tool_execution_end"}}}"#))
        await sync.waitForRefresh()
        expect(source.reads == 2, "Prose and child events cannot change the lead's todo")
        for type in ["todo_auto_clear", "todo_reminder", "agent_end", "session_settled", "compaction_end", "auto_compaction_end", "config_update", "command_output"] {
            sync.observe(.object(["type": .string(type)]))
            await sync.waitForRefresh()
        }
        sync.observe(json(#"{"type":"message_end","message":{"role":"toolResult","toolName":"eval"}}"#))
        await sync.waitForRefresh()
        sync.observe(json(#"{"type":"message_end","message":{"role":"custom","customType":"async-result"}}"#))
        await sync.waitForRefresh()
        expect(source.reads == 12 && source.published.count == 3, "Native boundaries and background results refresh without republishing identical state")
        for _ in 0..<100 { sync.observe(json(#"{"type":"tool_execution_update","toolCallId":"stdout","partialResult":{"content":[{"type":"text","text":"output"}]}}"#)) }
        await sync.waitForRefresh()
        expect(source.reads == 12, "Frequent stdout neither polls state nor invalidates canonical reads")
        let committed = json(#"{"type":"tool_execution_update","toolCallId":"todo-cell","partialResult":{"details":{"statusEvents":[{"op":"todo","committed":true}]}}}"#)
        sync.observe(committed)
        await sync.waitForRefresh()
        sync.observe(committed)
        await sync.waitForRefresh()
        expect(source.reads == 13, "One native commit hint refreshes once despite repeated cumulative status snapshots")

        source.steps = nil
        sync.refresh()
        await sync.waitForRefresh()
        expect(source.reads == 16 && source.published.last == [], "Malformed reads retry with a bound and preserve committed state")
        source.steps = done
        source.failures = 1
        sync.refresh()
        await sync.waitForRefresh()
        expect(source.reads == 18 && source.published.last == done, "Recover from a transient RPC failure")
        let oldRevision = sync.revision
        sync.invalidate()
        sync.accept(partial, revision: oldRevision)
        expect(source.published.last == done, "Fence delayed startup or metadata snapshots")
        sync.stop()
        sync.accept([], revision: sync.revision)
        sync.refresh()
        expect(source.published.last == done, "Stopped sessions cannot publish")

        let gate = ReadGate()
        var fenced: [[TodoStep]] = []
        let delayed = OMPTodoStateSync(delay: .zero, read: { try await gate.read() }, publish: { fenced.append($0) })
        delayed.refresh()
        await gate.waitForRead(1)
        for _ in 0..<20 { delayed.observe(json(#"{"type":"tool_execution_end","toolName":"eval"}"#)) }
        gate.resolve(partial)
        await gate.waitForRead(2)
        expect(fenced.isEmpty, "Discard a 3/8 reply made obsolete by a later event")
        gate.resolve([])
        await delayed.waitForRefresh()
        expect(fenced == [[]] && gate.count == 2 && gate.maximumInFlight == 1, "Coalesce concurrent updates and apply the final clear")

        let batchingGate = ReadGate()
        let batched = OMPTodoStateSync(delay: .milliseconds(10), read: { try await batchingGate.read() }, publish: { _ in })
        for _ in 0..<100 { batched.observe(json(#"{"type":"tool_execution_end","toolName":"eval"}"#)) }
        await batchingGate.waitForRead(1)
        batchingGate.resolve(done)
        await batched.waitForRefresh()
        expect(batchingGate.count == 1, "Merge a burst before making its request")

        let stopGate = ReadGate()
        var stoppedResults: [[TodoStep]] = []
        let stopped = OMPTodoStateSync(delay: .zero, read: { try await stopGate.read() }, publish: { stoppedResults.append($0) })
        stopped.refresh()
        await stopGate.waitForRead(1)
        stopped.stop()
        stopGate.resolve(done)
        await stopped.waitForRefresh()
        expect(stoppedResults.isEmpty, "Cancel publication even if RPC ignores cancellation")

        let childSource = SnapshotSource(partial)
        var released = false
        let child = OMPTodoStateSync(delay: .zero, read: { try childSource.read() }, publish: { childSource.published.append($0) })
        child.onFinished = { released = true }
        child.refresh()
        await child.waitForRefresh()
        childSource.steps = []
        child.invalidate()
        child.finish()
        await child.waitForRefresh()
        expect(childSource.published == [partial, []] && released, "Read a worker's final snapshot before releasing it")
        expect(source.published.last == done, "Worker completion remains independent of the lead")

        if CommandLine.arguments.count == 2 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let entries = try data.split(separator: 0x0A).map { line -> JSONValue in
                guard let value = JSONValue.parse(Data(line)) else { throw CheckError.invalidTranscript }
                return value
            }
            guard let snapshot = OMPTodoSnapshot.fromTranscript(.array(entries)) else { throw CheckError.invalidTranscript }
            print("Native transcript: \(snapshot.count { $0.status == .done })/\(snapshot.count)")
        }
        print("Todo sync regression checks passed: \(checks)")
    }

    private enum CheckError: Error { case invalidTranscript }
}

@MainActor
private final class SnapshotSource {
    var steps: [TodoStep]?
    var published: [[TodoStep]] = []
    var reads = 0
    var failures = 0

    init(_ steps: [TodoStep]?) { self.steps = steps }

    func read() throws -> [TodoStep]? {
        reads += 1
        if failures > 0 { failures -= 1; throw SimulatedFailure.rpc }
        return steps
    }

    private enum SimulatedFailure: Error { case rpc }
}

@MainActor
private final class ReadGate {
    private var reply: CheckedContinuation<[TodoStep]?, Error>?
    private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?
    private var inFlight = 0
    private(set) var count = 0
    private(set) var maximumInFlight = 0

    func read() async throws -> [TodoStep]? {
        count += 1
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        defer { inFlight -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            precondition(reply == nil)
            reply = continuation
            if let waiter, count >= waiter.count {
                self.waiter = nil
                waiter.continuation.resume()
            }
        }
    }

    func waitForRead(_ count: Int) async {
        guard self.count < count else { return }
        await withCheckedContinuation { continuation in waiter = (count, continuation) }
    }

    func resolve(_ steps: [TodoStep]?) {
        let continuation = reply
        reply = nil
        continuation?.resume(returning: steps)
    }
}
