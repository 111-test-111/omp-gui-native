import Foundation

/// A projection of native work, independent of a displayed turn's completion.
/// Nil quiescence means unknown and must never authorize idle process recycling.
struct OMPActivity: Equatable, Sendable {
    enum Phase: String, Sendable { case starting, responding, awaitingInput, queued, compacting, retrying, background, settled, unknown, stopped }
    var connected = false
    var stopped = false
    var streaming = false
    var compacting = false
    var retrying = false
    var settled: Bool?
    var pendingAsyncWork = false
    var queuedMessages = 0
    /// Native nextTurn context proven idle by the SDK. Keep it in the total
    /// queue count so automatic process recycling cannot discard this context.
    var deferredMessages = 0
    var prompts: Set<String> = []
    var dialogs: Set<String> = []
    /// Native control operations may need confirmation without representing a
    /// primary assistant turn or changing its displayed busy state.
    var recycleBlockers: Set<String> = []

    var hasOnlyDeferredContext: Bool { deferredMessages > 0 && queuedMessages == deferredMessages }

    var canRecycle: Bool {
        connected && !stopped && settled == true && !streaming && !compacting && !retrying
            && !pendingAsyncWork && queuedMessages == 0 && prompts.isEmpty && dialogs.isEmpty && recycleBlockers.isEmpty
    }

    var hasWork: Bool {
        !stopped && (streaming || compacting || retrying || pendingAsyncWork || queuedMessages > deferredMessages
            || !prompts.isEmpty || !dialogs.isEmpty || (settled == false && !hasOnlyDeferredContext))
    }

    var phase: Phase {
        if stopped { return .stopped }
        if !connected { return .starting }
        if !dialogs.isEmpty { return .awaitingInput }
        if compacting { return .compacting }
        if retrying { return .retrying }
        if streaming || !prompts.isEmpty { return .responding }
        if queuedMessages > deferredMessages { return .queued }
        if pendingAsyncWork || (settled == false && !hasOnlyDeferredContext) { return .background }
        return canRecycle ? .settled : .unknown
    }
}

/// Lifecycle events fence asynchronous snapshots, including a settled event
/// received while a prior get_state reply is still in flight.
struct OMPActivityTracker: Sendable {
    private(set) var value = OMPActivity()
    private(set) var revision: UInt64 = 0
    /// Fences history reads against work/session lifecycle changes. Merely
    /// accepting another identical get_state snapshot does not change history.
    private(set) var eventRevision: UInt64 = 0

    mutating func beginPrompt(_ id: String) {
        revision &+= 1
        eventRevision &+= 1
        value.prompts.insert(id)
        value.settled = false
        value.deferredMessages = 0
    }

    mutating func endPrompt(_ id: String) {
        revision &+= 1
        eventRevision &+= 1
        value.prompts.remove(id)
        // A rejected/admission-timeout prompt needs a fresh state observation.
        value.settled = nil
    }

    mutating func answer(_ id: String) {
        revision &+= 1
        eventRevision &+= 1
        value.dialogs.remove(id)
    }

    mutating func stop() {
        revision &+= 1
        eventRevision &+= 1
        value = OMPActivity(stopped: true)
    }

    @discardableResult
    mutating func accept(_ state: JSONValue, revision expected: UInt64) -> Bool {
        guard expected == revision, !value.stopped else { return false }
        revision &+= 1
        value.connected = true
        value.streaming = state["isStreaming"]?.bool ?? value.streaming
        value.compacting = state["isCompacting"]?.bool ?? value.compacting
        value.queuedMessages = max(0, state["queuedMessageCount"]?.int ?? value.queuedMessages)
        value.pendingAsyncWork = state["hasPendingAsyncWork"]?.bool ?? value.pendingAsyncWork
        value.settled = state["isSettled"]?.bool
        if value.queuedMessages != value.deferredMessages || value.streaming || value.compacting || value.pendingAsyncWork {
            value.deferredMessages = 0
        }
        return true
    }

    mutating func observe(_ frame: JSONValue) {
        guard !value.stopped, let type = frame["type"]?.string else { return }
        switch type {
        case "agent_start":
            value.connected = true
            value.streaming = true
            value.settled = false
            value.deferredMessages = 0
        case "agent_end":
            if frame["isTerminal"]?.bool != false { value.streaming = false }
        case "prompt_result":
            guard let id = frame["id"]?.string, value.prompts.remove(id) != nil else { return }
            if let settled = frame["sessionSettled"]?.bool {
                value.settled = settled
                if settled { value.pendingAsyncWork = false; value.queuedMessages = 0; value.deferredMessages = 0 }
            }
        case "session_settled":
            value.settled = true
            value.streaming = false
            value.compacting = false
            value.retrying = false
            value.pendingAsyncWork = false
            value.queuedMessages = 0
            value.deferredMessages = 0
        case "omp_gui_deferred_context":
            guard let count = frame["queuedMessageCount"]?.int, count > 0 else { return }
            value.connected = true
            value.streaming = false
            value.compacting = false
            value.retrying = false
            value.pendingAsyncWork = false
            value.queuedMessages = count
            value.deferredMessages = count
            value.settled = false
        case "auto_compaction_start", "manual_compaction_start": value.compacting = true; value.settled = false; value.deferredMessages = 0
        case "auto_compaction_end", "manual_compaction_end": value.compacting = false
        case "auto_retry_start": value.retrying = true; value.settled = false; value.deferredMessages = 0
        case "auto_retry_end": value.retrying = false
        case "extension_ui_request":
            guard let method = frame["method"]?.string else { return }
            if ["select", "confirm", "input", "editor", "ask"].contains(method), let id = frame["id"]?.string {
                value.dialogs.insert(id)
                value.settled = false
                value.deferredMessages = 0
            } else if method == "cancel", let id = frame["targetId"]?.string {
                value.dialogs.remove(id)
            } else { return }
        case "subagent_lifecycle":
            if frame["payload"]?["status"]?.string == "started" {
                value.pendingAsyncWork = true
                value.settled = false
                value.deferredMessages = 0
            }
        default: return
        }
        revision &+= 1
        eventRevision &+= 1
    }
}
