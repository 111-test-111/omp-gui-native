import Foundation

extension ThreadRuntime {
    var canUseOMPRunOptions: Bool { activeOMPSession != nil }

    func refreshOMPRunOptions() async throws {
        try await withActiveOMPSession { try await $0.refreshRunOptions() }
    }
    func setOMPFastMode(_ enabled: Bool) async throws {
        try await withActiveOMPSession { try await $0.setRunOption(.fast, enabled: enabled) }
    }
    func setOMPAutoRetry(_ enabled: Bool) async throws {
        try await withActiveOMPSession { try await $0.setRunOption(.autoRetry, enabled: enabled) }
    }
    func abortOMPRetry() async throws {
        try await withActiveOMPSession { try await $0.setRunOption(.stopRetry) }
    }
    func setOMPSlowMode(_ enabled: Bool, expectedModel: String, expectedScope: OMPSlowModeScope) async throws {
        try await withActiveOMPSession { try await $0.setSlowMode(enabled, expectedModel: expectedModel, expectedScope: expectedScope) }
    }
    func setOMPCacheWarming(_ mode: OMPCacheWarmingMode) async throws {
        try await withActiveOMPSession { try await $0.setRunOption(.cacheWarming, warmingMode: mode) }
    }
}
