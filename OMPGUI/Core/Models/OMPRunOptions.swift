import Foundation

enum OMPRunOption: String, Sendable {
    case fast = "set_fast_mode"
    case autoRetry = "set_auto_retry"
    case stopRetry = "abort_retry"
    case slow = "set_slow_mode"
    case cacheWarming = "set_cache_warming"
}

enum OMPSlowModeScope: String, Sendable { case session, global }
enum OMPCacheWarmingMode: String, CaseIterable, Hashable, Sendable { case off, streaming, idle }

/// The public events have no refresh ID. This is the last observed fact, never
/// an inferred current refresh, timer, total cost or scheduling state.
struct OMPCacheWarmingEvent: Equatable, Sendable {
    enum Phase: String, Sendable { case streaming, idle }
    enum Outcome: String, Sendable { case hit, miss, error, aborted }
    let phase: Phase
    let provider: String
    let model: String
    let isStart: Bool
    let outcome: Outcome?
    let costUSD: Double?
    let stopReason: String?

    init?(_ frame: JSONValue) {
        guard let type = frame["type"]?.string,
              type == "cache_warming_start" || type == "cache_warming_end",
              let phase = frame["phase"]?.string.flatMap(Phase.init(rawValue:)),
              let provider = frame["provider"]?.string, !provider.isEmpty,
              let model = frame["model"]?.string, !model.isEmpty else { return nil }
        isStart = type == "cache_warming_start"
        outcome = frame["outcome"]?.string.flatMap(Outcome.init(rawValue:))
        guard isStart || outcome != nil else { return nil }
        self.phase = phase
        self.provider = TextCleanup.utf8Prefix(provider, maximumBytes: 4 * 1_024)
        self.model = TextCleanup.utf8Prefix(model, maximumBytes: 4 * 1_024)
        let cost = frame["usage"]?["cost"]?["total"]?.double
        costUSD = !isStart ? cost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } : nil
        stopReason = !isStart ? frame["warmingStopReason"]?.string.map {
            TextCleanup.utf8Prefix($0, maximumBytes: 16 * 1_024)
        } : nil
    }
}

/// Native observations and explicitly confirmed session overrides. Missing
/// values are unknown; a local preference is never evidence of native state.
struct OMPRunOptionsSnapshot: Equatable, Sendable {
    struct Pending: Equatable, Sendable {
        let option: OMPRunOption
        let id: String
        let enabled: Bool?
        let model: String?
        let slowScope: OMPSlowModeScope?
        let warmingMode: OMPCacheWarmingMode?
    }
    enum Completion: Equatable { case ignored, completed, invalid }

    private(set) var model: String?
    private(set) var fastEnabled: Bool?
    private(set) var fastActive: Bool?
    private(set) var autoRetryOverride: Bool?
    private(set) var slowSupported: Bool?
    private(set) var slowEnabled: Bool?
    private(set) var slowScope: OMPSlowModeScope?
    private(set) var cacheWarmingOverride: OMPCacheWarmingMode?
    private(set) var lastCacheWarmingEvent: OMPCacheWarmingEvent?
    private(set) var retrying = false
    private(set) var retryAttempt: Int?
    private(set) var retryMaxAttempts: Int?
    private(set) var retryDelayMilliseconds: Int?
    private(set) var retryError: String?
    private(set) var pending: Pending?
    private(set) var outcomeUnknown = false
    private(set) var error: String?
    var pendingCommand: String? { pending?.option.rawValue }

    mutating func observeState(_ state: JSONValue) {
        model = Self.modelIdentity(state["model"])
        fastEnabled = state["fastModeEnabled"]?.bool
        fastActive = state["fastModeActive"]?.bool
        slowSupported = state["slowModeSupported"]?.bool
        slowEnabled = state["slowModeEnabled"]?.bool
        slowScope = state["slowModeScope"]?.string.flatMap(OMPSlowModeScope.init(rawValue:))
    }

    @discardableResult
    mutating func observeFrame(_ frame: JSONValue) -> Bool {
        if let event = OMPCacheWarmingEvent(frame) {
            lastCacheWarmingEvent = event
            return true
        }
        switch frame["type"]?.string {
        case "auto_retry_start":
            retrying = true
            retryAttempt = Self.count(frame["attempt"])
            retryMaxAttempts = Self.count(frame["maxAttempts"])
            retryDelayMilliseconds = Self.count(frame["delayMs"])
            retryError = Self.text(frame["errorMessage"]?.string)
        case "auto_retry_end":
            retrying = false
            retryDelayMilliseconds = nil
            retryAttempt = Self.count(frame["attempt"]) ?? retryAttempt
            retryError = Self.text(frame["finalError"]?.string)
        case "session_settled":
            guard retrying else { return false }
            retrying = false
            retryDelayMilliseconds = nil
        default: return false
        }
        return true
    }

    mutating func begin(_ option: OMPRunOption, id: String, enabled: Bool?, warmingMode: OMPCacheWarmingMode? = nil) {
        pending = Pending(option: option, id: id, enabled: enabled, model: model,
                          slowScope: slowScope, warmingMode: warmingMode)
        outcomeUnknown = false
        error = nil
    }

    /// Called only for a matching actual response, including a late one. A
    /// malformed success cannot release an operation with an unknown outcome.
    @discardableResult
    mutating func finish(_ response: JSONValue) -> Completion {
        guard let pending, response["type"]?.string == "response",
              response["id"]?.string == pending.id,
              response["command"]?.string == pending.option.rawValue,
              let success = response["success"]?.bool else { return .ignored }
        if success {
            switch pending.option {
            case .fast:
                guard let enabled = response["data"]?["enabled"]?.bool else {
                    outcomeUnknown = true
                    return .invalid
                }
                if model == pending.model {
                    fastEnabled = enabled
                    fastActive = response["data"]?["active"]?.bool
                } else {
                    fastEnabled = nil
                    fastActive = nil
                }
            case .autoRetry: autoRetryOverride = pending.enabled
            case .stopRetry: break // Acceptance is not the retry lifecycle end.
            case .slow:
                guard let enabled = response["data"]?["enabled"]?.bool else {
                    outcomeUnknown = true
                    return .invalid
                }
                slowEnabled = model == pending.model && slowScope == pending.slowScope && slowSupported == true ? enabled : nil
            case .cacheWarming:
                guard let mode = response["data"]?["mode"]?.string.flatMap(OMPCacheWarmingMode.init(rawValue:)) else {
                    outcomeUnknown = true
                    return .invalid
                }
                cacheWarmingOverride = mode
            }
            error = nil
        } else {
            error = Self.text(response["error"]?.string)
        }
        self.pending = nil
        outcomeUnknown = false
        return .completed
    }

    mutating func markUnknown(_ message: String) {
        guard pending != nil else { return }
        outcomeUnknown = true
        error = Self.text(message)
    }

    mutating func disconnect() {
        outcomeUnknown = outcomeUnknown || pending != nil
        pending = nil
        retrying = false
        retryDelayMilliseconds = nil
    }

    private static func count(_ value: JSONValue?) -> Int? {
        value?.int.flatMap { $0 >= 0 ? $0 : nil }
    }
    private static func text(_ value: String?) -> String? {
        value.map { TextCleanup.utf8Prefix($0, maximumBytes: 16 * 1024) }
    }
    private static func modelIdentity(_ value: JSONValue?) -> String? {
        guard let provider = value?["provider"]?.string, let id = value?["id"]?.string else { return nil }
        return provider + "/" + id
    }
}
