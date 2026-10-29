import Foundation
@testable import OMPGUI

@main
struct NativeResourceOptionsInterfaceChecks {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    @MainActor static func main() async throws {
        guard CaptureRun.isEnabled, let output = CaptureRun.outputDirectory,
              output.path.contains("/build.noindex/verification/runs/"),
              let executable = ProcessInfo.processInfo.environment["OMP_P5_NATIVE_EXECUTABLE"] else {
            fatalError("Require isolated native-provider runner and an explicit OMP executable")
        }
        let profile = output.appendingPathComponent("profile")
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("PI_") || key.hasPrefix("OMP_") { environment[key] = nil }
        environment["PI_CONFIG_DIR"] = profile.path
        environment["PI_CODING_AGENT_DIR"] = profile.appendingPathComponent("agent").path
        environment["OMP_PROFILE"] = "default"
        environment["PI_PROFILE"] = "default"
        let configuration = SessionConfiguration(provider: .omp, executable: URL(fileURLWithPath: executable),
            workingDirectory: output, environment: environment, resumeID: nil, resumeAt: nil,
            model: "p5-local/forward", effort: "off", runtimeMode: .auto, interactionMode: .build,
            apiKey: nil, hydra: nil, antiSlopEnabled: false)
        let session = OMPSession(configuration: configuration)
        var checks: [String] = []
        func expect(_ value: Bool, _ message: String) throws {
            guard value else { throw Failure(message: message) }
            checks.append(message)
            print("PASS \(message)")
        }
        func configurationBytes() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: ["config.yml", "models.yml"].map { name in
                (name, try Data(contentsOf: profile.appendingPathComponent("agent/" + name)))
            })
        }
        do {
            let identity = try await session.start()
            try expect(identity.hasPrefix(output.path + "/"), "Native resource controls use only this run's generated session")
            let initial = try configurationBytes()
            try expect(session.runOptions.slowSupported == false && session.runOptions.slowScope == nil,
                       "The local model reports unsupported Slow without a fabricated scope")
            var slowRefused = false
            do {
                try await session.setSlowMode(true, expectedModel: "p5-local/forward", expectedScope: .session)
            } catch {
                slowRefused = true
            }
            try expect(slowRefused && session.runOptions.pending == nil && !session.runOptions.outcomeUnknown,
                       "The production scope guard rejects unsupported Slow before beginning a change")
            let enable = try await session.rpc.response("set_slow_mode", fields: ["enabled": true], timeout: .seconds(5))
            try expect(enable["success"]?.bool == false
                && enable["error"]?.string == "Slow mode is unavailable for the current model.",
                       "Actual native Slow rejects a model without a supported service policy")
            let disable = try await session.rpc.request("set_slow_mode", fields: ["enabled": false], timeout: .seconds(5))
            try expect(disable["enabled"]?.bool == false, "Actual native disable is a no-op on the unsupported local model")
            for mode in [OMPCacheWarmingMode.off, .streaming, .idle, .off] {
                try await session.setRunOption(.cacheWarming, warmingMode: mode, timeout: .seconds(5))
                try expect(session.runOptions.cacheWarmingOverride == mode && session.runOptions.pending == nil,
                           "Actual native \(mode.rawValue) acknowledgement confirms its session override")
            }
            try expect(session.runOptions.lastCacheWarmingEvent == nil, "Selecting a policy before any model request does not invent a warm refresh")
            try expect(try configurationBytes() == initial, "Unsupported Slow and warming overrides leave isolated profile configuration unchanged")
            let providerLog = output.appendingPathComponent("provider-requests.jsonl")
            try expect(!FileManager.default.fileExists(atPath: providerLog.path)
                || (try Data(contentsOf: providerLog)).isEmpty, "Resource-option interface checks make no model requests")
            await session.stopAndWait(timeout: 5)
            try expect(!session.isRunning, "Resource checks release their own native process")
            let report: [String: Any] = ["status": "passed", "checks": checks,
                "capabilities": session.capabilities.commands.mapValues(\.rawValue),
                "scope": "One explicit native runtime, isolated profile/session, no inference. Global Slow writes, paid warming lifecycles and real-account model behavior are not exercised."]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("summary.json"))
        } catch {
            await session.stopAndWait(timeout: 5)
            let report: [String: Any] = ["status": "failed", "checks": checks, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("summary.json"))
            throw error
        }
    }
}
