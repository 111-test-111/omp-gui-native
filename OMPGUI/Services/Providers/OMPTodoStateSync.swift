import Foundation

/// Coalesces native state reads, not agent work. One request in flight, with a
/// generation fence so a delayed reply cannot undo a newer tool/turn transition.
@MainActor
final class OMPTodoStateSync<Snapshot: Equatable> {
    private let read: @MainActor () async throws -> Snapshot?
    private let publish: @MainActor (Snapshot) -> Void
    private let delay: Duration
    private var pending = false
    private var stopped = false
    private var finishing = false
    private var task: Task<Void, Never>?
    private var lastPublished: Snapshot?
    private(set) var revision: UInt64 = 0
    private var activity: [String: JSONValue] = [:]
    var onFinished: (@MainActor () -> Void)?

    init(delay: Duration = .milliseconds(100), read: @escaping @MainActor () async throws -> Snapshot?,
         publish: @escaping @MainActor (Snapshot) -> Void) {
        self.delay = delay
        self.read = read
        self.publish = publish
    }

    func invalidate() { revision &+= 1 }

    /// Eval and extension tools can commit todos without emitting a todo tool
    /// event. Refresh after every tool, and at native turn/session boundaries.
    func observe(_ frame: JSONValue) {
        switch frame["type"]?.string {
        case "tool_execution_start", "agent_start":
            if let id = frame["toolCallId"]?.string { activity[id] = nil }
            invalidate()
        case "tool_execution_update":
            let result = frame["partialResult"] ?? frame["result"] ?? .null
            let raw = result["details"] ?? .null
            let details = raw["xdev"]?["inner"] ?? raw
            let commits = details["statusEvents"]?.array?.filter {
                ($0["op"]?.string == "todo" && $0["committed"]?.bool == true)
                    || ($0["op"]?.string == "write" && $0["path"]?.string.map {
                        $0.prefix(5).lowercased() == "xd://" && $0.dropFirst(5) == "todo"
                    } == true
                        && $0["hasError"]?.bool != true && $0["error"] == nil)
            } ?? []
            var hint: [String: JSONValue] = [:]
            if !commits.isEmpty { hint["commits"] = .array(commits) }
            if let phases = details["phases"], frame["toolName"]?.string == "todo" { hint["phases"] = phases }
            if let state = details["async"]?["state"]?.string, state != "running" { hint["async"] = .string(state) }
            guard !hint.isEmpty else { return } // stdout does not commit todo state.
            let value = JSONValue.object(hint)
            if let id = frame["toolCallId"]?.string {
                guard activity[id] != value else { return }
                activity[id] = value
            }
            invalidate()
            refresh()
        case "tool_execution_end", "todo_auto_clear", "todo_reminder", "agent_end",
             "auto_compaction_end", "compaction_end", "session_settled", "command_output", "config_update":
            if let id = frame["toolCallId"]?.string { activity[id] = nil }
            invalidate()
            refresh()
        case "message_end" where frame["message"]?["role"]?.string == "toolResult"
            || frame["message"]?["customType"]?.string == "async-result":
            invalidate()
            refresh()
        default: break
        }
    }

    func accept(_ steps: Snapshot?, revision: UInt64) {
        guard !stopped, revision == self.revision, let steps, lastPublished != steps else { return }
        lastPublished = steps
        publish(steps)
    }

    func refresh() {
        guard !stopped else { return }
        pending = true
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                task = nil
                if finishing { stop(); onFinished?() }
            }
            var failures = 0
            while pending && !stopped && !Task.isCancelled {
                pending = false
                do {
                    try await Task.sleep(for: delay)
                    try Task.checkCancellation()
                    // Changes during the batching interval belong to this read.
                    pending = false
                    let generation = revision
                    let steps = try await read()
                    guard !stopped, !Task.isCancelled else { return }
                    if generation != revision { pending = true; continue }
                    guard let steps else { throw SnapshotError.invalid }
                    accept(steps, revision: generation)
                    failures = 0
                } catch {
                    guard !stopped, !Task.isCancelled else { return }
                    // Bound transient retries; the next native event can retry again.
                    failures += 1
                    if failures < 3 { pending = true }
                }
            }
        }
    }

    /// A finished worker remains readable through OMP's transcript API. Fetch
    /// its final snapshot before releasing this synchronizer.
    func finish() { finishing = true; refresh() }

    func waitForRefresh() async { await task?.value }

    func stop() {
        stopped = true
        invalidate()
        pending = false
        activity.removeAll()
        task?.cancel()
    }

    private enum SnapshotError: Error { case invalid }
}
