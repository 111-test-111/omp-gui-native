import Foundation
import AppKit
@testable import OMPGUI

@main
struct NativeRunOptionsChecks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        checks += 1
        print("PASS \(message)")
    }
    @MainActor private static func until(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while try !condition() {
            guard ContinuousClock.now < deadline else { fatalError("Run-option fixture event deadline exceeded") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private static func response(_ option: OMPRunOption, id: String, data: JSONValue? = nil, error: String? = nil) -> JSONValue {
        var result: [String: JSONValue] = ["type": "response", "command": .string(option.rawValue),
            "id": .string(id), "success": .bool(error == nil)]
        if let data { result["data"] = data }
        if let error { result["error"] = .string(error) }
        return .object(result)
    }

    @MainActor private static func modelCapabilityChecks() {
        func row(_ provider: String, _ api: String, _ modelClass: String = "openai", tiers: [String]? = nil) -> JSONValue {
            var value: [String: JSONValue] = ["provider": .string(provider), "id": "model-without-name-guesses", "api": .string(api),
                                    "identity": ["class": .string(modelClass)]]
            if let tiers { value["serviceTiers"] = .array(tiers.map(JSONValue.string)) }
            return .object(value)
        }
        expect(OMPCLI.modelOptions([row("openai-codex", "openai-codex-responses", tiers: ["default", "priority"])])[0].supportsFast,
               "Native Codex priority advertisement enables the Fast button")
        expect(!OMPCLI.modelOptions([row("openai-codex", "openai-codex-responses", tiers: ["default"])])[0].supportsFast,
               "An explicit native tier list without priority hides Fast")
        expect(OMPCLI.fastTier(row("openai-codex", "openai-codex-responses", tiers: [])) == "priority",
               "Unreported Codex tiers preserve OMP's native priority fallback")
        expect(OMPCLI.fastTier(row("anthropic", "anthropic-messages", "anthropic")) == "priority",
               "Direct Anthropic uses OMP's native Fast family")
        expect(OMPCLI.fastTier(row("amazon-bedrock", "anthropic-messages", "anthropic")) == nil
                && OMPCLI.fastTier(row("openrouter", "openai-completions", "anthropic")) == nil,
               "Claude routes without a realizable Fast tier do not expose the toggle")
        expect(OMPCLI.fastTier(row("google", "google-generative-ai", "gemini")) == "priority"
                && OMPCLI.fastTier(row("openrouter", "openai-completions", "gemini")) == "priority",
               "Native Google-family priority routes expose Fast")
        expect(OMPCLI.fastTier(row("relay", "openai-responses")) == "priority"
                && OMPCLI.fastTier(row("relay", "openai-completions", "kimi")) == nil,
               "Custom relays use native API identity rather than an OpenAI-compatible endpoint guess")
        expect(OMPCLI.fastTier(row("github-copilot", "openai-responses")) == nil
                && OMPCLI.fastTier(row("fireworks", "openai-completions")) == nil,
               "Providers without OMP's fast toggle do not get a selectable button")
        expect(OMPCLI.fastTier(["provider": "openai-codex", "id": "gpt-anything"]) == nil,
               "Compact discovery with missing native capability metadata stays unknown")
    }

    @MainActor private static func snapshotChecks() {
        var snapshot = OMPRunOptionsSnapshot()
        expect(snapshot.fastEnabled == nil && snapshot.fastActive == nil && snapshot.autoRetryOverride == nil,
               "Unobserved run settings remain unknown")
        snapshot.observeState(["model": ["provider": "fixture", "id": "first"], "fastModeEnabled": true, "fastModeActive": false])
        expect(snapshot.fastEnabled == true && snapshot.fastActive == false, "Requested Fast does not imply active Fast")
        snapshot.observeState(["model": ["provider": "fixture", "id": "second"]])
        expect(snapshot.fastEnabled == nil && snapshot.fastActive == nil, "A changed model cannot retain absent Fast state")
        snapshot.begin(.autoRetry, id: "retry", enabled: false)
        expect(snapshot.autoRetryOverride == nil && snapshot.pendingCommand == "set_auto_retry", "A request alone does not confirm an override")
        expect(snapshot.finish(response(.autoRetry, id: "foreign")) == .ignored && snapshot.pending != nil,
               "A foreign response cannot resolve the current option")
        expect(snapshot.finish(response(.fast, id: "retry", data: ["enabled": true, "active": true])) == .ignored,
               "The right request ID cannot validate another command")
        expect(snapshot.finish(response(.autoRetry, id: "retry")) == .completed && snapshot.autoRetryOverride == false,
               "Native auto-retry acknowledgement needs no result data")
        snapshot.observeState(["model": ["provider": "fixture", "id": "second"]])
        expect(snapshot.autoRetryOverride == false, "State without a readable retry override preserves confirmed session intent")
        snapshot.begin(.fast, id: "enabled-only", enabled: true)
        expect(snapshot.finish(response(.fast, id: "enabled-only", data: ["enabled": true])) == .completed
            && snapshot.fastEnabled == true && snapshot.fastActive == nil && snapshot.pending == nil,
               "A confirmed Fast request without an actual-state field keeps actual state unknown")
        snapshot.begin(.fast, id: "fast", enabled: true)
        expect(snapshot.finish(response(.fast, id: "fast", data: ["active": false])) == .invalid
            && snapshot.outcomeUnknown && snapshot.fastEnabled == true, "Fast results without a requested setting remain unknown and pending")
        snapshot.markUnknown("Timeout")
        expect(snapshot.pending?.id == "fast", "A timeout retains the exact unresolved native request")
        expect(snapshot.finish(response(.fast, id: "fast", data: ["enabled": true, "active": false])) == .completed
            && snapshot.fastEnabled == true && snapshot.fastActive == false && !snapshot.outcomeUnknown,
               "A matched late Fast reply resolves uncertainty without assuming active mode")
        snapshot.begin(.fast, id: "old-model", enabled: true)
        snapshot.observeState(["model": ["provider": "fixture", "id": "third"]])
        _ = snapshot.finish(response(.fast, id: "old-model", data: ["enabled": true, "active": true]))
        expect(snapshot.fastEnabled == nil && snapshot.fastActive == nil, "A delayed old-model result cannot label a new model")
        snapshot.begin(.autoRetry, id: "rejected", enabled: true)
        _ = snapshot.finish(response(.autoRetry, id: "rejected", error: "Rejected"))
        expect(snapshot.autoRetryOverride == false && snapshot.pending == nil && snapshot.error == "Rejected",
               "An explicit rejection preserves the confirmed override and releases the request")
        _ = snapshot.observeFrame(["type": "auto_retry_start", "attempt": 2, "maxAttempts": 4, "delayMs": 1_250,
                                   "errorMessage": "Rate limited"])
        expect(snapshot.retrying && snapshot.retryAttempt == 2 && snapshot.retryMaxAttempts == 4
            && snapshot.retryDelayMilliseconds == 1_250 && snapshot.retryError == "Rate limited",
               "Retry status comes from native lifecycle fields")
        snapshot.begin(.stopRetry, id: "stop", enabled: nil)
        _ = snapshot.finish(response(.stopRetry, id: "stop"))
        expect(snapshot.retrying, "Stop acknowledgement does not manufacture a retry lifecycle end")
        _ = snapshot.observeFrame(["type": "auto_retry_end", "success": true, "attempt": 2])
        expect(!snapshot.retrying && snapshot.retryDelayMilliseconds == nil, "Native retry end clears the waiting delay")
        _ = snapshot.observeFrame(["type": "auto_retry_start", "attempt": -1, "delayMs": -2,
                                   "errorMessage": .string(String(repeating: "🙂", count: 10_000))])
        expect(snapshot.retryAttempt == nil && snapshot.retryDelayMilliseconds == nil
            && snapshot.retryError!.utf8.count <= 16 * 1_024, "Malformed counts stay unknown and retry diagnostics have a byte bound")
        snapshot.begin(.autoRetry, id: "disconnected", enabled: true)
        snapshot.disconnect()
        expect(snapshot.pending == nil && snapshot.outcomeUnknown && !snapshot.retrying,
               "Disconnect releases request bookkeeping while retaining an unknown outcome")
        expect(snapshot.finish(response(.autoRetry, id: "disconnected")) == .ignored && snapshot.autoRetryOverride == false,
               "A disconnected operation cannot apply its delayed acknowledgement")
    }

    @MainActor static func main() async throws {
        guard CaptureRun.isEnabled, let root = CaptureRun.outputDirectory,
              root.path.contains("/build.noindex/verification/runs/"),
              let fixtureIndex = CommandLine.arguments.firstIndex(of: "--fixture") else { fatalError("Require isolated fixture output") }
        modelCapabilityChecks()
        snapshotChecks()
        let fixture = URL(fileURLWithPath: CommandLine.arguments[fixtureIndex + 1])
        let log = root.appendingPathComponent("requests.jsonl")
        let file = root.appendingPathComponent("native.jsonl")
        let config = SessionConfiguration(provider: .omp, executable: fixture, workingDirectory: root, environment: [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "OMP_FIXTURE_LOG": log.path, "OMP_FIXTURE_SESSION_FILE": file.path],
            resumeID: nil, resumeAt: nil, model: nil, effort: nil, runtimeMode: .auto,
            interactionMode: .build, apiKey: nil, hydra: nil, antiSlopEnabled: false)
        let session = OMPSession(configuration: config)
        var snapshots: [OMPRunOptionsSnapshot] = []
        session.onEvent = { if case .ompRunOptions(let snapshot) = $0 { snapshots.append(snapshot) } }
        func requests(_ method: String) throws -> [JSONValue] {
            try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
                .compactMap { JSONValue.parse(String($0)) }.filter { $0["type"]?.string == method }
        }
        let discovered = try await OMPCLI.models(executable: fixture, environment: config.environment, directory: root)
        let fastModel = discovered.first { $0.id == "fixture/initial" }!
        expect(fastModel.supportsFast && fastModel.efforts == ["low", "max"],
               "Read-only native capability discovery preserves the compact CLI's exact effort list")
        expect(discovered.first { $0.id == "fixture/nonfast" }?.supportsFast == false,
               "The model list exposes Fast only for the native-capable model")
        expect(try requests("set_fast_mode").isEmpty && requests("prompt").isEmpty,
               "Catalogue discovery never probes Fast or starts a model turn")
        _ = try await session.start()
        expect(session.runOptions.fastEnabled == false && session.runOptions.fastActive == false,
               "Native startup populates independent Fast request and active fields")
        expect(try requests("set_fast_mode").isEmpty && requests("set_auto_retry").isEmpty && requests("abort_retry").isEmpty,
               "Session startup never probes a mutating run option")
        try await session.setRunOption(.fast, enabled: true)
        expect(session.runOptions.fastEnabled == true && session.runOptions.fastActive == false,
               "Fast acknowledgement preserves a supported model's inactive result")
        try await session.setRunOption(.autoRetry, enabled: false)
        expect(session.runOptions.autoRetryOverride == false, "An empty native auto-retry acknowledgement confirms the explicit override")
        do { try await session.setRunOption(.stopRetry); fatalError("Stop retry outside a retry was accepted") }
        catch { expect(try requests("abort_retry").isEmpty, "No abort_retry is sent when native retrying is false") }
        _ = try await session.rpc.request("fixture_retry_start")
        try await until { session.runOptions.retrying }
        try await session.setRunOption(.stopRetry)
        expect(session.runOptions.retrying && session.runOptions.retryDelayMilliseconds == 1_250,
               "Stop-retry acceptance waits for the independent native lifecycle")
        _ = try await session.rpc.request("fixture_retry_end")
        try await until { !session.runOptions.retrying }
        expect(session.runOptions.retryDelayMilliseconds == nil && session.runOptions.fastEnabled == true,
               "Retry lifecycle completion leaves other run options intact")
        _ = try await session.rpc.request("fixture_mode", fields: ["mode": "reject"])
        do { try await session.setRunOption(.autoRetry, enabled: true); fatalError("Rejected override accepted") }
        catch { expect(session.runOptions.autoRetryOverride == false && session.runOptions.pending == nil,
                       "Native rejection keeps the old override and permits another explicit action") }

        _ = try await session.rpc.request("fixture_mode", fields: ["mode": "hold"])
        do { try await session.setRunOption(.autoRetry, enabled: true, timeout: .milliseconds(20)); fatalError("Held request completed") }
        catch { expect(session.runOptions.outcomeUnknown && session.runOptions.pendingCommand == "set_auto_retry"
            && !session.nativeActivity.canRecycle, "An unconfirmed override protects its process after timeout") }
        let beforeBlocked = try requests("set_fast_mode").count
        do { try await session.setRunOption(.fast, enabled: false); fatalError("Second mutation raced a pending override") }
        catch { expect(try requests("set_fast_mode").count == beforeBlocked, "Unknown delivery prevents a second mutation or silent resend") }
        _ = try await session.rpc.request("fixture_release")
        try await until { session.runOptions.pending == nil && !session.runOptions.outcomeUnknown }
        expect(session.runOptions.autoRetryOverride == true && session.nativeActivity.canRecycle,
               "A correlated late acknowledgement settles exactly the pending override")

        _ = try await session.rpc.request("fixture_mode", fields: ["mode": "hold-state"])
        let priorReads = try requests("get_state").count
        let oldRead = Task { try await session.refreshRunOptions() }
        try await until { try requests("get_state").count > priorReads }
        try await session.setRunOption(.fast, enabled: false)
        _ = try await session.rpc.request("fixture_release_state")
        try await oldRead.value
        expect(session.runOptions.fastEnabled == false, "A read started before a mutation cannot overwrite the confirmed Fast setting")

        _ = try await session.rpc.request("fixture_model", fields: ["model": "replacement"])
        try await session.refreshRunOptions()
        expect(session.runOptions.model == "fixture/replacement" && session.runOptions.fastActive == nil,
               "A replacement model with no native active field stays unknown")
        try await session.setRunOption(.fast, enabled: true)
        expect(session.runOptions.fastEnabled == true && session.runOptions.fastActive == nil
            && session.runOptions.pending == nil, "A successful Fast change can retain an unknown actual state")
        _ = try await session.rpc.request("fixture_mode", fields: ["mode": "hold"])
        do { try await session.setRunOption(.autoRetry, enabled: false, timeout: .milliseconds(20)); fatalError("Held second request completed") }
        catch { }
        let replacement = root.appendingPathComponent("replacement.jsonl")
        let nextState = try await session.rpc.request("fixture_session", fields: ["sessionFile": .string(replacement.path)])
        await session.resetNativeSessionState(nextState)
        _ = try await session.rpc.request("fixture_release")
        expect(session.sessionFile == replacement.path && session.runOptions.autoRetryOverride == nil
            && session.runOptions.pending == nil, "Native session replacement fences a late prior-session acknowledgement")

        _ = try await session.rpc.request("fixture_mode", fields: ["mode": "normal"])
        _ = try await session.rpc.request("fixture_fast_active", fields: ["active": true])
        try await session.setModelFastMode(true, expectedModel: "fixture/alternate", effort: "off")
        expect(session.runOptions.model == "fixture/alternate" && session.runOptions.fastEnabled == true
                && session.runOptions.fastActive == true,
               "Picker Fast changes the idle native model and enters actual Fast mode")
        expect(try requests("set_model").last?["modelId"]?.string == "alternate"
                && requests("set_thinking_level").last?["level"]?.string == "off",
               "The picker preserves its selected model and effort without a prompt")
        expect(try requests("prompt").isEmpty && requests("steer").isEmpty,
               "A Fast toggle never sends or replaces the composer draft")
        try await session.setModelFastMode(false, expectedModel: "fixture/alternate", effort: "off")
        expect(session.runOptions.fastEnabled == false && session.runOptions.fastActive == false,
               "Disabling Fast confirms native standard mode before stopping accelerated animation")
        _ = try await session.rpc.request("fixture_busy", fields: ["busy": true])
        try await session.refreshRunOptions()
        let modelChanges = try requests("set_model").count
        let fastChanges = try requests("set_fast_mode").count
        do {
            try await session.setModelFastMode(true, expectedModel: "fixture/initial", effort: "off")
            fatalError("A busy session changed its active model through Fast")
        } catch {
            expect(try requests("set_model").count == modelChanges && requests("set_fast_mode").count == fastChanges,
                   "Busy native work prevents Fast from switching to a different UI model")
        }
        _ = try await session.rpc.request("fixture_busy", fields: ["busy": false])
        try await session.refreshRunOptions()

        _ = try await session.rpc.request("fixture_mode", fields: ["mode": "unsupported"])
        do { try await session.setRunOption(.autoRetry, enabled: true); fatalError("Unsupported override accepted") }
        catch { expect(session.capabilities["set_auto_retry"] == .unsupported && session.runOptions.autoRetryOverride == nil,
                       "Exact unknown-command disables only the unsupported action") }
        let unsupportedCount = try requests("set_auto_retry").count
        do { try await session.setRunOption(.autoRetry, enabled: false); fatalError("Unsupported override resent") }
        catch { expect(try requests("set_auto_retry").count == unsupportedCount, "Known unsupported controls do not send another request") }
        await session.stopAndWait(timeout: 5)
        expect(!session.isRunning && !session.runOptions.retrying, "Explicit stop clears native retry activity")
        expect(snapshots.contains { $0.outcomeUnknown } && snapshots.contains { $0.autoRetryOverride == true },
               "Native run-option observations are published to the runtime boundary")
        // Exercise the actual cold-start UI action with an isolated native peer.
        _ = NSApplication.shared
        let wrapper = root.appendingPathComponent("fast-runtime.sh")
        let runtimeLog = root.appendingPathComponent("fast-runtime-requests.jsonl")
        let runtimeFile = root.appendingPathComponent("fast-runtime.jsonl")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let script = "#!/bin/sh\nexport OMP_FIXTURE_LOG=\(quote(runtimeLog.path))\nexport OMP_FIXTURE_SESSION_FILE=\(quote(runtimeFile.path))\nexport OMP_FIXTURE_FAST_ACTIVE=1\nexec \(quote(fixture.path)) \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let app = AppModel()
        app.settings.chimeWhenFinished = false
        app.settings.notifyWhenFinished = false
        app.settings.setBinaryPath(wrapper.path, for: .omp)
        app.providers.updateCatalog(discovered, for: .omp)
        let projectURL = root.appendingPathComponent("fast-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let project = app.addProject(at: projectURL)
        var chat = ChatThread(projectID: project.id, provider: .omp, model: "fixture/initial", effort: "off", runtimeMode: .auto)
        chat.hydraEnabled = false
        chat.hasCustomTitle = true
        app.insertThread(chat)
        let runtime = app.runtime(for: chat.id)
        await runtime.ensureLoaded()
        runtime.draft = ComposerDraft(text: "Keep this unsent draft")
        expect(runtime.activeOMPSession == nil && !FileManager.default.fileExists(atPath: runtimeLog.path),
               "Creating model control state never starts a conversation process")
        try await runtime.changeOMPModelFastMode(true, expectedModel: "fixture/initial")
        expect(runtime.ompRunOptions.fastEnabled == true && runtime.ompRunOptions.fastActive == true
                && app.thread(chat.id)?.fastMode == true && !runtime.ompFastModeWorking,
               "The real Fast action starts cold and publishes confirmed request and active state")
        let runtimeRequests = try String(contentsOf: runtimeLog, encoding: .utf8).split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
        expect(runtime.draft.text == "Keep this unsent draft" && runtime.turns.isEmpty
                && !runtimeRequests.contains { ["prompt", "steer"].contains($0["type"]?.string ?? "") },
               "Cold Fast startup preserves the draft and sends no model input")
        expect(app.thread(chat.id)?.providerSessionID == runtimeFile.path,
               "Fast configured before the first prompt retains its native journal identity")
        try await runtime.changeOMPModelFastMode(false, expectedModel: "fixture/initial")
        expect(runtime.ompRunOptions.fastEnabled == false && runtime.ompRunOptions.fastActive == false,
               "The same UI action disables native Fast on the existing connection")
        let runtimeSession = runtime.activeOMPSession!
        runtime.stopSession()
        try await until { !runtimeSession.isRunning }

        try JSONSerialization.data(withJSONObject: ["checks": checks, "scope": "Deterministic production snapshot and isolated RPC peer; no installed OMP or GUI."], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("summary.json"))
        print("Native run-options checks passed: \(checks)")
    }
}
