import Foundation
@testable import OMPGUI

@main
struct NativeResourceOptionsChecks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        checks += 1
        print("PASS \(message)")
    }
    @MainActor private static func until(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try !condition() {
            guard ContinuousClock.now < deadline else { fatalError("Resource-option fixture deadline exceeded") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private static func response(_ command: String, id: String, data: JSONValue) -> JSONValue {
        ["type": "response", "command": .string(command), "id": .string(id), "success": true, "data": data]
    }
    @MainActor private static func modelChecks() {
        var snapshot = OMPRunOptionsSnapshot()
        expect(snapshot.slowSupported == nil && snapshot.slowScope == nil && snapshot.cacheWarmingOverride == nil,
               "New resource options do not invent support, scope or a cache policy")
        snapshot.observeState(["model": ["provider": "fixture", "id": "model"],
            "slowModeSupported": true, "slowModeEnabled": false, "slowModeScope": "session"])
        snapshot.begin(.slow, id: "slow", enabled: true)
        _ = snapshot.finish(response("set_slow_mode", id: "slow", data: ["enabled": true]))
        expect(snapshot.slowSupported == true && snapshot.slowEnabled == true && snapshot.slowScope == .session,
               "Native Slow acknowledgement retains its observed session scope")
        snapshot.begin(.slow, id: "changed-scope", enabled: false)
        snapshot.observeState(["model": ["provider": "fixture", "id": "model"],
            "slowModeSupported": true, "slowModeEnabled": true, "slowModeScope": "global"])
        _ = snapshot.finish(response("set_slow_mode", id: "changed-scope", data: ["enabled": false]))
        expect(snapshot.slowEnabled == nil, "A delayed result cannot relabel a changed Slow scope")
        snapshot.begin(.cacheWarming, id: "warming", enabled: nil, warmingMode: .streaming)
        expect(snapshot.finish(response("set_cache_warming", id: "warming", data: [:])) == .invalid
            && snapshot.outcomeUnknown && snapshot.cacheWarmingOverride == nil,
               "Cache warming success without a valid mode remains pending and unknown")
        expect(snapshot.finish(response("set_cache_warming", id: "foreign", data: ["mode": "idle"])) == .ignored,
               "An unrelated cache reply cannot replace an unresolved mode")
        _ = snapshot.finish(response("set_cache_warming", id: "warming", data: ["mode": "streaming"]))
        expect(snapshot.cacheWarmingOverride == .streaming && snapshot.pending == nil && !snapshot.outcomeUnknown,
               "A matching late cache mode confirms the returned native override")
        snapshot.observeState(["cacheWarmingMode": "idle"])
        expect(snapshot.slowScope == nil && snapshot.slowSupported == nil && snapshot.cacheWarmingOverride == .streaming,
               "Absent Slow fields clear stale scope and an undocumented state field is not a warming getter")
        let start: JSONValue = ["type": "cache_warming_start", "phase": "idle", "provider": "fixture", "model": "old"]
        expect(snapshot.observeFrame(start) && snapshot.lastCacheWarmingEvent?.isStart == true,
               "Native warming start is retained only as the latest event fact")
        let end: JSONValue = ["type": "cache_warming_end", "phase": "idle", "provider": "fixture", "model": "old",
            "outcome": "hit", "usage": ["cost": ["total": 0.125]], "warmingStopReason": "Native stop reason"]
        _ = snapshot.observeFrame(end)
        expect(snapshot.lastCacheWarmingEvent?.outcome == .hit && snapshot.lastCacheWarmingEvent?.costUSD == 0.125,
               "The last refresh exposes only the provider's reported cost")
        for outcome in ["miss", "error", "aborted"] {
            _ = snapshot.observeFrame(["type": "cache_warming_end", "phase": "streaming", "provider": "fixture",
                "model": "replacement", "outcome": .string(outcome)])
            expect(snapshot.lastCacheWarmingEvent?.outcome?.rawValue == outcome
                && snapshot.lastCacheWarmingEvent?.costUSD == nil, "A \(outcome) event replaces the previous cost instead of accumulating it")
        }
        let last = snapshot.lastCacheWarmingEvent
        expect(!snapshot.observeFrame(["type": "cache_warming_end", "phase": "idle", "provider": "fixture", "model": "x", "outcome": "future"])
            && snapshot.lastCacheWarmingEvent == last, "Unknown event outcomes do not fabricate a refresh state")
        _ = snapshot.observeFrame(["type": "cache_warming_end", "phase": "idle", "provider": "fixture", "model": "x",
            "outcome": "aborted", "usage": ["cost": ["total": -1]],
            "warmingStopReason": .string(String(repeating: "🙂", count: 10_000))])
        expect(snapshot.lastCacheWarmingEvent?.costUSD == nil
            && snapshot.lastCacheWarmingEvent!.stopReason!.utf8.count <= 16 * 1_024,
               "Invalid costs stay unknown and native stop text is byte-bounded")
        var capabilities = OMPCapabilities()
        capabilities.observe(response("set_cache_warming", id: "x", data: ["mode": "future"]))
        capabilities.observe(response("set_slow_mode", id: "y", data: ["enabled": "true"]))
        expect(capabilities["set_cache_warming"] == .unknown && capabilities["set_slow_mode"] == .unknown,
               "Malformed successful resource responses do not prove command support")
    }

    @MainActor private static func goalSettlementAfterRejection(root: URL, fixture: URL) async throws {
        let log = root.appendingPathComponent("goal-interlock.jsonl")
        let configuration = SessionConfiguration(provider: .omp, executable: fixture, workingDirectory: root,
            environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                "OMP_FIXTURE_LOG": log.path, "OMP_FIXTURE_SESSION_FILE": root.appendingPathComponent("goal-interlock.jsonl.native").path],
            resumeID: nil, resumeAt: nil, model: nil, effort: nil, runtimeMode: .auto, interactionMode: .build,
            apiKey: nil, hydra: nil, antiSlopEnabled: false)
        let session = OMPSession(configuration: configuration)
        func reads() throws -> Int {
            try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
                .compactMap { JSONValue.parse(String($0)) }.filter { $0["type"]?.string == "get_state" }.count
        }
        _ = try await session.start()
        _ = try await session.rpc.request("fixture_hold_state")
        let previous = try reads()
        let goalAction = Task {
            try await session.performGoalOperation(.create, objective: "Native settlement interlock", expectedGoalID: nil)
        }
        try await until { try reads() > previous && session.goalSnapshot.pending == nil && session.goalNeedsSettlement }
        do { try await session.setRunOption(.fast, enabled: true); fatalError("Expected explicit Fast rejection") }
        catch {
            expect(session.runOptions.pending == nil && !session.goalNeedsSettlement && session.nativeActivity.canRecycle,
                   "An explicit run-option rejection replaces a displaced goal settlement read before releasing protection")
        }
        expect(try reads() == previous + 2, "The rejection issues one fresh state read without a polling loop")
        _ = try await session.rpc.request("fixture_release_state")
        try await goalAction.value
        expect(!session.goalNeedsSettlement && session.nativeActivity.canRecycle,
               "Releasing the older goal read cannot recreate a settled recycling blocker")
        await session.stopAndWait(timeout: 5)
    }

    @MainActor static func main() async throws {
        guard CaptureRun.isEnabled, let root = CaptureRun.outputDirectory,
              root.path.contains("/build.noindex/verification/runs/"),
              let index = CommandLine.arguments.firstIndex(of: "--fixture") else { fatalError("Require isolated fixture output") }
        modelChecks()
        let log = root.appendingPathComponent("requests.jsonl")
        let config = SessionConfiguration(provider: .omp, executable: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
            workingDirectory: root, environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                "OMP_FIXTURE_LOG": log.path, "OMP_FIXTURE_SESSION_FILE": root.appendingPathComponent("native.jsonl").path],
            resumeID: nil, resumeAt: nil, model: nil, effort: nil, runtimeMode: .auto, interactionMode: .build,
            apiKey: nil, hydra: nil, antiSlopEnabled: false)
        let session = OMPSession(configuration: config)
        var tokenEvents = 0
        session.onEvent = { if case .tokenSpend = $0 { tokenEvents += 1 } }
        func count(_ method: String) throws -> Int {
            try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
                .compactMap { JSONValue.parse(String($0)) }.filter { $0["type"]?.string == method }.count
        }
        _ = try await session.start()
        expect(try count("set_slow_mode") == 0 && count("set_cache_warming") == 0, "Startup adds no mutating resource probes")
        do { try await session.setSlowMode(true, expectedModel: "fixture/initial", expectedScope: .session); fatalError("Unknown Slow scope accepted") }
        catch { expect(try count("set_slow_mode") == 0, "Slow is blocked before writing when native support and scope are unknown") }
        _ = try await session.rpc.request("fixture_resource_state", fields: ["supported": true, "scope": "session"])
        try await session.refreshRunOptions()
        try await session.setSlowMode(true, expectedModel: "fixture/initial", expectedScope: .session)
        expect(session.runOptions.slowEnabled == true && session.runOptions.slowScope == .session, "A matching observed session-scoped Slow operation reaches native RPC")
        _ = try await session.rpc.request("fixture_mode", fields: ["mode": "hold-state"])
        let earlierReads = try count("get_state")
        let oldRead = Task { try await session.refreshRunOptions() }
        try await until { try count("get_state") > earlierReads }
        _ = try await session.rpc.request("fixture_resource_state", fields: ["supported": true, "scope": "global", "enabled": true])
        let beforeGlobal = try count("set_slow_mode")
        do { try await session.setSlowMode(false, expectedModel: "fixture/initial", expectedScope: .session); fatalError("Changed global scope accepted") }
        catch { expect(try count("set_slow_mode") == beforeGlobal && session.runOptions.slowScope == .global,
                       "A Slow action reads after the action rather than reusing an in-flight old session scope") }
        _ = try await session.rpc.request("fixture_release_state")
        try await oldRead.value
        expect(session.runOptions.slowScope == .global, "The old pre-action state cannot undo the fresh global-scope refusal")
        try await session.setSlowMode(false, expectedModel: "fixture/initial", expectedScope: .global)
        expect(session.runOptions.slowEnabled == false && session.runOptions.slowScope == .global,
               "An explicitly acknowledged global scope permits the native operation")
        for mode in OMPCacheWarmingMode.allCases {
            try await session.setRunOption(.cacheWarming, warmingMode: mode)
            expect(session.runOptions.cacheWarmingOverride == mode, "The explicit \(mode.rawValue) mode uses the native returned override")
        }
        _ = try await session.rpc.request("fixture_warming_event", fields: ["event": ["type": "cache_warming_end", "phase": "idle",
            "provider": "fixture", "model": "initial", "outcome": "aborted", "usage": ["cost": ["total": 0.02]]]])
        try await until { session.runOptions.lastCacheWarmingEvent?.outcome == .aborted }
        expect(tokenEvents == 0 && session.nativeActivity.canRecycle,
               "A reported warming event neither double-counts native spend nor invents main-task activity")
        _ = try await session.rpc.request("fixture_mode", fields: ["mode": "hold"])
        do { try await session.setRunOption(.cacheWarming, warmingMode: .off, timeout: .milliseconds(20)); fatalError("Held mode completed") }
        catch { expect(session.runOptions.outcomeUnknown && !session.nativeActivity.canRecycle
            && session.runOptions.cacheWarmingOverride == .idle, "A timed-out warming change preserves the old override and process protection") }
        let writes = try count("set_cache_warming")
        do { try await session.setRunOption(.fast, enabled: false); fatalError("Mutation raced unknown warming change") }
        catch { expect(try count("set_cache_warming") == writes, "The shared operation fence does not resend an unknown warming change") }
        _ = try await session.rpc.request("fixture_release")
        try await until { session.runOptions.pending == nil }
        expect(session.runOptions.cacheWarmingOverride == .off && !session.runOptions.outcomeUnknown,
               "A matching late warming response resolves the existing operation")
        _ = try await session.rpc.request("fixture_mode", fields: ["mode": "unsupported"])
        do { try await session.setRunOption(.cacheWarming, warmingMode: .streaming); fatalError("Unsupported warming accepted") }
        catch { expect(session.capabilities["set_cache_warming"] == .unsupported
            && session.runOptions.cacheWarmingOverride == .off, "Old runtimes disable only the unsupported warming control") }
        await session.stopAndWait(timeout: 5)
        try await goalSettlementAfterRejection(root: root,
            fixture: URL(fileURLWithPath: CommandLine.arguments[index + 1]).deletingLastPathComponent().appendingPathComponent("goal.py"))
        try JSONSerialization.data(withJSONObject: ["checks": checks,
            "scope": "Production model and isolated RPC fixtures; global scope is simulated and no provider is called."], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("summary.json"))
        print("Native resource-options checks passed: \(checks)")
    }
}
