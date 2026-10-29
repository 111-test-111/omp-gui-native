import Foundation

/// Values reported by this OMP process. Missing counters remain unknown.
struct OMPContextStats: Codable, Equatable, Sendable {
    var userMessages: Int?
    var assistantMessages: Int?
    var toolCalls: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var totalTokens: Int?
    var cost: Double?

    init(_ value: JSONValue) {
        userMessages = OMPContextNumber.count(value["userMessages"])
        assistantMessages = OMPContextNumber.count(value["assistantMessages"])
        toolCalls = OMPContextNumber.count(value["toolCalls"])
        let tokens = value["tokens"]
        inputTokens = OMPContextNumber.count(tokens?["input"])
        outputTokens = OMPContextNumber.count(tokens?["output"])
        reasoningTokens = OMPContextNumber.count(tokens?["reasoning"])
        cacheReadTokens = OMPContextNumber.count(tokens?["cacheRead"])
        cacheWriteTokens = OMPContextNumber.count(tokens?["cacheWrite"])
        totalTokens = OMPContextNumber.count(tokens?["total"])
        cost = value["cost"]?.double.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

struct OMPCompactionResult: Codable, Equatable, Sendable {
    var summary: String
    var shortSummary: String?
    var tokensBefore: Int?

    init?(_ value: JSONValue?) {
        guard let value, let summary = value["summary"]?.string else { return nil }
        self.summary = summary
        shortSummary = value["shortSummary"]?.string
        tokensBefore = OMPContextNumber.count(value["tokensBefore"])
    }
}

struct OMPHandoffResult: Codable, Equatable, Sendable {
    var completed: Bool
    var savedPath: String?
    var document: String?
    var entryID: String?

    init(_ value: JSONValue) {
        completed = value.object != nil
        savedPath = value["savedPath"]?.string
    }
}

/// Display facts belong to one native journal. Never persist in-flight commands.
struct OMPContextCache: Codable, Equatable, Sendable {
    var sessionFile: String
    var snapshot: OMPContextSnapshot

    init(sessionFile: String, snapshot: OMPContextSnapshot) {
        self.sessionFile = sessionFile
        self.snapshot = snapshot.savedSnapshot
    }
}

struct OMPContextSnapshot: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case completed, aborted, skipped, failed, retrying }
    private(set) var revision: UInt64 = 0
    private(set) var autoCompactionEnabled: Bool?
    private(set) var isCompacting: Bool?
    private(set) var usedTokens: Int?
    private(set) var windowTokens: Int?
    private(set) var stats: OMPContextStats?
    private(set) var compactionReason: String?
    private(set) var compactionAction: String?
    private(set) var lastOutcome: Outcome?
    private(set) var lastResult: OMPCompactionResult?
    private(set) var tokensAfterCompaction: Int?
    private(set) var compactionError: String?
    private(set) var lastHandoff: OMPHandoffResult?
    private(set) var handoffError: String?
    private(set) var pendingCommand: String?
    private(set) var pendingRequestID: String?
    private(set) var outcomeUnknown = false

    var fraction: Double? {
        guard let usedTokens, let windowTokens, windowTokens > 0 else { return nil }
        return Double(usedTokens) / Double(windowTokens)
    }

    var savedSnapshot: Self {
        var saved = self
        saved.revision = 0
        saved.isCompacting = nil
        saved.pendingCommand = nil
        saved.pendingRequestID = nil
        saved.outcomeUnknown = false
        saved.handoffError = nil
        saved.compactionError = nil
        if saved.lastHandoff?.completed == false { saved.lastHandoff = nil }
        if saved.lastOutcome == .retrying || saved.lastOutcome == .failed { saved.lastOutcome = nil }
        return saved
    }

    mutating func observeState(_ state: JSONValue) {
        revision &+= 1
        autoCompactionEnabled = state["autoCompactionEnabled"]?.bool
        isCompacting = state["isCompacting"]?.bool
        usedTokens = OMPContextNumber.count(state["contextUsage"]?["tokens"])
        windowTokens = OMPContextNumber.count(state["contextUsage"]?["contextWindow"])
        // Keep the first post-compaction reading, not later conversation growth.
        if lastOutcome == .completed, isCompacting != true, tokensAfterCompaction == nil {
            tokensAfterCompaction = usedTokens
        }
    }

    @discardableResult
    mutating func observeFrame(_ frame: JSONValue) -> Bool {
        switch frame["type"]?.string {
        case "auto_compaction_start", "manual_compaction_start":
            revision &+= 1
            isCompacting = true
            compactionReason = frame["reason"]?.string
            compactionAction = frame["action"]?.string
            compactionError = nil
            lastOutcome = nil
            lastResult = nil
            tokensAfterCompaction = nil
            return true
        case "auto_compaction_end", "manual_compaction_end":
            revision &+= 1
            isCompacting = false
            usedTokens = nil
            windowTokens = nil
            compactionAction = frame["action"]?.string ?? compactionAction
            compactionError = frame["errorMessage"]?.string
            lastResult = OMPCompactionResult(frame["result"])
            tokensAfterCompaction = nil
            if frame["willRetry"]?.bool == true { lastOutcome = .retrying }
            else if frame["aborted"]?.bool == true { lastOutcome = .aborted }
            else if frame["skipped"]?.bool == true { lastOutcome = .skipped }
            else if compactionError != nil { lastOutcome = .failed }
            else if lastResult != nil { lastOutcome = .completed }
            else { lastOutcome = nil }
            return true
        case "agent_start", "message_end", "config_update":
            // An old stats response must not publish over a changed native snapshot.
            revision &+= 1
            return false
        default: return false
        }
    }

    mutating func acceptStats(_ value: JSONValue, revision expected: UInt64) -> Bool {
        guard expected == revision else { return false }
        stats = OMPContextStats(value)
        return true
    }

    /// The public handoff reply contains no body. Its committed compaction
    /// entry is the durable source, including after a reconnect or late reply.
    mutating func restoreHandoff(_ history: OMPHistorySnapshot) throws {
        guard pendingCommand != "handoff", handoffError == nil,
              lastHandoff?.completed != false else { return }
        guard let entry = try history.activePath().last(where: { $0.type == "compaction" && $0.method == "handoff" }),
              let document = entry.summary else {
            lastHandoff = nil
            return
        }
        var result = lastHandoff ?? OMPHandoffResult([:])
        if let previous = result.entryID, previous != entry.id { result.savedPath = nil }
        result.entryID = entry.id
        result.document = document
        lastHandoff = result
    }

    mutating func begin(_ command: String, id: String) {
        revision &+= 1
        pendingCommand = command
        pendingRequestID = id
        outcomeUnknown = false
        if command == "handoff" {
            lastHandoff = nil
            handoffError = nil
        }
        if command == "compact" {
            lastOutcome = nil
            lastResult = nil
            tokensAfterCompaction = nil
            compactionError = nil
            compactionAction = nil
            compactionReason = nil
        }
    }

    mutating func markUnknown() { outcomeUnknown = true }

    mutating func finish(_ command: String, data: JSONValue?, error: String? = nil) {
        revision &+= 1
        if command == "compact" {
            lastResult = OMPCompactionResult(data)
            tokensAfterCompaction = nil
            compactionError = error
            lastOutcome = error != nil ? .failed : lastResult == nil ? nil : .completed
            usedTokens = nil
            windowTokens = nil
        }
        if command == "handoff" {
            handoffError = error
            lastHandoff = error == nil ? data.map(OMPHandoffResult.init) : nil
            if lastHandoff?.completed == true {
                usedTokens = nil
                windowTokens = nil
            }
        }
        pendingCommand = nil
        pendingRequestID = nil
        outcomeUnknown = false
    }
}

private enum OMPContextNumber {
    static func count(_ value: JSONValue?) -> Int? {
        let count: Int?
        switch value {
        case .int(let number): count = number
        case .double(let number): count = number.isFinite ? Int(exactly: number) : nil
        default: count = nil
        }
        return count.flatMap { $0 >= 0 ? $0 : nil }
    }
}
