import Foundation

/// OMP owns goal execution and accounting. These values only project its public
/// RPC state; a budget is not a GUI stop condition or a completion percentage.
struct OMPGoal: Equatable, Sendable {
    enum Status: String, Sendable {
        case active, paused, budgetLimited = "budget-limited", complete, dropped, unknown

        var title: String {
            switch self {
            case .active: "Active"
            case .paused: "Paused"
            case .budgetLimited: "Budget reached"
            case .complete: "Completed"
            case .dropped: "Dropped"
            case .unknown: "Unknown"
            }
        }

        var isTerminal: Bool { self == .complete || self == .dropped }
    }

    let id: String
    let objective: String
    let objectiveIsTruncated: Bool
    let status: Status
    let rawStatus: String
    let tokenBudget: Int?
    let tokensUsed: Int
    let timeUsedSeconds: Double
    let createdAt: Double
    let updatedAt: Double

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.string, !id.isEmpty, id.utf8.count <= 1_024,
              let objective = value["objective"]?.string,
              let raw = value["status"]?.string, !raw.isEmpty, raw.utf8.count <= 128,
              let used = OMPGoalNumber.count(value["tokensUsed"]),
              let seconds = OMPGoalNumber.timestamp(value["timeUsedSeconds"]),
              let created = OMPGoalNumber.timestamp(value["createdAt"]),
              let updated = OMPGoalNumber.timestamp(value["updatedAt"]) else { return nil }
        let budget = value["tokenBudget"]
        guard budget == nil || budget == .null || OMPGoalNumber.positiveCount(budget) != nil else { return nil }
        self.id = id
        self.objective = OMPGoalLimits.displayText(objective)
        objectiveIsTruncated = objective.utf8.count > OMPGoalLimits.displayBytes
        status = Status(rawValue: raw) ?? .unknown
        rawStatus = raw
        tokenBudget = OMPGoalNumber.positiveCount(budget)
        tokensUsed = used
        timeUsedSeconds = seconds
        createdAt = created
        updatedAt = updated
    }

    var hasReachedTokenBudget: Bool { tokenBudget.map { tokensUsed >= $0 } ?? false }
}

struct OMPGoalModeState: Equatable, Sendable {
    enum Mode: String, Sendable { case active, exiting, unknown }
    let enabled: Bool
    let mode: Mode
    let rawMode: String
    let goal: OMPGoal

    init?(_ value: JSONValue) {
        guard let enabled = value["enabled"]?.bool, let raw = value["mode"]?.string,
              !raw.isEmpty, raw.utf8.count <= 128,
              let nested = value["goal"], let goal = OMPGoal(nested) else { return nil }
        self.enabled = enabled
        mode = Mode(rawValue: raw) ?? .unknown
        rawMode = raw
        self.goal = goal
    }
}

/// Both fields are required by the public goal reply. Missing/malformed data
/// must never clear a previously observed goal or prove command support.
struct OMPGoalReply: Equatable, Sendable {
    let state: OMPGoalModeState?

    init?(_ value: JSONValue) {
        guard let goalValue = value["goal"], let stateValue = value["state"] else { return nil }
        if goalValue == .null, stateValue == .null { state = nil; return }
        guard let goal = OMPGoal(goalValue), let modeState = OMPGoalModeState(stateValue),
              goal == modeState.goal else { return nil }
        state = modeState
    }
}

enum OMPGoalOperation: String, Sendable {
    case create, resume, pause, drop
}

struct OMPGoalPendingOperation: Equatable, Sendable {
    let requestID: String
    let operation: OMPGoalOperation
    let expectedGoalID: String?
    let revision: UInt64
    var outcomeUnknown = false
}

struct OMPGoalSnapshot: Equatable, Sendable {
    private(set) var revision: UInt64 = 0
    private(set) var goal: OMPGoal?
    private(set) var modeState: OMPGoalModeState?
    private(set) var hasObservation = false
    private(set) var observationIsStale = false
    /// Null can mean no goal, completion or drop. Retain only an explicit
    /// terminal event/result from this session, never infer one from null.
    private(set) var lastTerminal: OMPGoal?
    private(set) var pending: OMPGoalPendingOperation?
    private(set) var error: String?

    var displayedGoal: OMPGoal? { goal ?? lastTerminal }
    var completedGoal: OMPGoal? { lastTerminal?.status == .complete ? lastTerminal : nil }
    var hasUnrecognizedState: Bool { goal?.status == .unknown || modeState?.mode == .unknown }
    var isPending: Bool { pending != nil }

    @discardableResult
    mutating func observeState(_ value: JSONValue?) -> Bool {
        guard let value else { return false } // Older OMP omits this field.
        if value == .null { accept(nil); return true }
        guard let state = OMPGoalModeState(value) else { markStale(); return false }
        accept(state)
        return true
    }

    @discardableResult
    mutating func observeEvent(_ frame: JSONValue) -> Bool {
        guard frame["type"]?.string == "goal_updated", let value = frame["goal"] else { return false }
        if value == .null {
            guard frame["state"] == nil || frame["state"] == .null else { markStale(); return false }
            accept(nil)
            return true
        }
        guard let goal = OMPGoal(value) else { markStale(); return false }
        var state: OMPGoalModeState?
        if let native = frame["state"], native != .null {
            guard let decoded = OMPGoalModeState(native), decoded.goal == goal else { markStale(); return false }
            state = decoded
        }
        revision &+= 1
        self.goal = goal
        modeState = state
        hasObservation = true
        observationIsStale = false
        if goal.status.isTerminal { lastTerminal = goal }
        else { lastTerminal = nil }
        return true
    }

    mutating func accept(_ reply: OMPGoalReply, revision expected: UInt64) {
        guard revision == expected else { return }
        accept(reply.state)
    }

    mutating func begin(_ operation: OMPGoalOperation, id: String, expectedGoalID: String?) {
        revision &+= 1
        error = nil
        pending = OMPGoalPendingOperation(requestID: id, operation: operation,
            expectedGoalID: expectedGoalID, revision: revision)
    }

    /// A newer goal event wins over the command's earlier snapshot. Confirmation
    /// still resolves this request; a later state read can fill optional details.
    mutating func finish(id: String, reply: OMPGoalReply?, error: String? = nil) {
        guard let operation = pending, operation.requestID == id else { return }
        if let reply { accept(reply, revision: operation.revision) }
        pending = nil
        setError(error)
    }

    mutating func markUnknown(id: String, error: String) {
        guard pending?.requestID == id else { return }
        pending?.outcomeUnknown = true
        setError(error)
    }

    mutating func setError(_ error: String?) {
        self.error = error.map { TextCleanup.utf8Prefix($0, maximumBytes: OMPGoalLimits.errorBytes) }
    }

    mutating func disconnect() {
        revision &+= 1
        pending = nil
        observationIsStale = hasObservation
    }

    private mutating func accept(_ state: OMPGoalModeState?) {
        revision &+= 1
        modeState = state
        goal = state?.goal
        hasObservation = true
        observationIsStale = false
        if let goal = state?.goal {
            if goal.status.isTerminal { lastTerminal = goal }
            else { lastTerminal = nil }
        }
    }

    private mutating func markStale() {
        revision &+= 1
        observationIsStale = true
    }
}

enum OMPGoalLimits {
    static let inputBytes = 128 * 1_024
    static let displayBytes = 64 * 1_024
    static let errorBytes = 16 * 1_024
    /// JSON numbers pass through JavaScript; reject budgets it cannot represent
    /// exactly instead of silently changing the user's request.
    static let maxTokenBudget = 9_007_199_254_740_991

    static func displayText(_ text: String) -> String {
        guard text.utf8.count > displayBytes else { return text }
        var bytes = text.utf8.prefix(displayBytes)
        while String(bytes: bytes, encoding: .utf8) == nil, !bytes.isEmpty { bytes = bytes.dropLast() }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func tokenBudget(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(trimmed), value > 0, value <= maxTokenBudget else { return nil }
        return value
    }
}

private enum OMPGoalNumber {
    static func count(_ value: JSONValue?) -> Int? {
        let number: Int?
        switch value {
        case .int(let value): number = value
        case .double(let value): number = value.isFinite ? Int(exactly: value) : nil
        default: number = nil
        }
        return number.flatMap { $0 >= 0 && $0 <= OMPGoalLimits.maxTokenBudget ? $0 : nil }
    }

    static func positiveCount(_ value: JSONValue?) -> Int? { count(value).flatMap { $0 > 0 ? $0 : nil } }
    static func timestamp(_ value: JSONValue?) -> Double? {
        value?.double.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}
