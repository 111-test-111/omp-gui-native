import Foundation
@testable import OMPGUI

@main
struct NativeRunOptionsInterfaceChecks {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    @MainActor static func main() async throws {
        guard CaptureRun.isEnabled, let output = CaptureRun.outputDirectory,
              output.path.contains("/build.noindex/verification/runs/"),
              let executable = ProcessInfo.processInfo.environment["OMP_P5_NATIVE_EXECUTABLE"] else {
            fatalError("Require the isolated native-provider runner and an explicit OMP executable")
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
            try expect(identity.hasPrefix(output.path + "/"), "Native run options use only this run's newly generated session")
            let initial = try configurationBytes()
            try expect(session.runOptions.autoRetryOverride == nil, "Native startup does not invent a readable retry override")
            do {
                try await session.setRunOption(.fast, enabled: true, timeout: .seconds(5))
                throw Failure(message: "The local model unexpectedly accepted Fast mode")
            } catch {
                try expect(error.localizedDescription == "Fast mode is unavailable for the current model."
                    && session.runOptions.fastEnabled != true && session.runOptions.fastActive != true
                    && session.runOptions.pending == nil && !session.runOptions.outcomeUnknown,
                           "A model without native service-tier control rejects Fast without inventing active state")
                try expect(session.capabilities["set_fast_mode"] == .unknown,
                           "A model-specific Fast refusal does not claim that the public command is unsupported")
            }
            try await session.setRunOption(.fast, enabled: false, timeout: .seconds(5))
            try expect(session.runOptions.fastEnabled == false && session.capabilities["set_fast_mode"] == .supported,
                       "The selected runtime acknowledges disabling Fast in the same session")
            try await session.setRunOption(.autoRetry, enabled: false, timeout: .seconds(5))
            try expect(session.runOptions.autoRetryOverride == false && session.runOptions.pending == nil,
                       "Actual set_auto_retry success without result data confirms the requested override")
            try await session.setRunOption(.autoRetry, enabled: true, timeout: .seconds(5))
            try expect(session.runOptions.autoRetryOverride == true, "The native retry override can be explicitly enabled again")
            // This explicit interface check addresses an idle, newly generated
            // native session. Production UI never sends it without retrying.
            let stopped = try await session.rpc.response("abort_retry", timeout: .seconds(5))
            try expect(stopped["success"]?.bool == true && session.capabilities["abort_retry"] == .supported,
                       "Actual abort_retry accepts the isolated idle-session request")
            try expect(!session.runOptions.retrying, "An idle abort acknowledgement does not manufacture retry activity")
            try expect(try configurationBytes() == initial, "Session run options do not rewrite isolated profile configuration")
            let providerLog = output.appendingPathComponent("provider-requests.jsonl")
            try expect(!FileManager.default.fileExists(atPath: providerLog.path)
                || (try Data(contentsOf: providerLog)).isEmpty, "Run-option interface checks make no model requests")
            await session.stopAndWait(timeout: 5)
            try expect(!session.isRunning, "The native check releases only its own process")
            let report: [String: Any] = ["status": "passed", "checks": checks,
                "capabilities": session.capabilities.commands.mapValues(\.rawValue),
                "scope": "One installed runtime, public run-option interfaces, isolated profile and session; no inference, GUI, worker or external account validation."]
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
