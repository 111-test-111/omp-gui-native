import Foundation
import AppKit
@testable import OMPGUI

/// Only Goal RPC against the explicitly selected OMP and local provider. This
/// helper deliberately does not run the general RPC compatibility workload.
@main
struct OMPNativeGoalChecks {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
    @MainActor private static var checks: [String] = []
    @MainActor private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Failure(message: message) }
        checks.append(message)
        print("PASS \(message)")
    }
    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure(message: "Native goal condition did not arrive") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor static func main() async throws {
        guard CaptureRun.isEnabled, let output = CaptureRun.outputDirectory,
              output.path.contains("/build.noindex/verification/runs/"),
              let executable = ProcessInfo.processInfo.environment["OMP_P5_NATIVE_EXECUTABLE"] else {
            fatalError("Require isolated native goal run with an explicit OMP")
        }
        _ = NSApplication.shared // AppKit support, no GUI entry point or windows.
        let profile = output.appendingPathComponent("profile")
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("PI_") || key.hasPrefix("OMP_") { environment[key] = nil }
        environment["PI_CONFIG_DIR"] = profile.path
        environment["PI_CODING_AGENT_DIR"] = profile.appendingPathComponent("agent").path
        environment["OMP_PROFILE"] = "default"
        environment["PI_PROFILE"] = "default"
        var configuration = SessionConfiguration(provider: .omp, executable: URL(fileURLWithPath: executable),
            workingDirectory: output, environment: environment, resumeID: nil, resumeAt: nil,
            model: "p5-local/forward", effort: "off", runtimeMode: .auto, interactionMode: .build,
            apiKey: nil, hydra: nil, antiSlopEnabled: false)
        var current = OMPSession(configuration: configuration)
        do {
            let identity = try await current.start()
            try await current.refreshGoal()
            try expect(current.capabilities["goal"] == .supported && current.goalSnapshot.goal == nil,
                "Selected native OMP exposes public Goal RPC and an empty new goal state")
            try await current.performGoalOperation(.create, objective: "Complete through the native goal tool", expectedGoalID: nil)
            let firstID = current.goalSnapshot.goal!.id
            try expect(current.goalSnapshot.goal?.status == .active && current.nativeActivity.canRecycle,
                "An active native goal with RPC continuation disabled does not fabricate executing work")
            func send(_ text: String, to session: OMPSession) async throws {
                try await session.send(TurnInput(text: text, images: [], model: nil, effort: nil,
                    runtimeMode: .auto, interactionMode: .build, ompDelivery: .prompt, ompRequestID: UUID()))
            }
            try await send("GOAL_NATIVE_COMPLETE", to: current)
            try await wait { current.goalSnapshot.lastTerminal?.status == .complete && current.nativeActivity.canRecycle }
            // Settlement and the background state read are separate deliveries.
            // Query the native singleton before asserting it has been cleared.
            try await current.refreshGoal()
            try expect(current.goalSnapshot.lastTerminal?.id == firstID && current.goalSnapshot.goal == nil,
                "Native goal complete tool yields explicit terminal evidence before goal clears to null")
            try expect((current.goalSnapshot.lastTerminal?.tokensUsed ?? 0) > 0,
                "Native goal accounting reports deterministic provider token consumption")

            try await current.performGoalOperation(.create, objective: "Control native continuation separately from the current turn", expectedGoalID: nil)
            let liveID = current.goalSnapshot.goal!.id
            try await send("GOAL_NATIVE_HOLD", to: current)
            try await wait { current.nativeActivity.streaming }
            try await current.performGoalOperation(.pause, expectedGoalID: liveID)
            try expect(current.goalSnapshot.goal?.status == .paused && current.nativeActivity.streaming,
                "Public native pause leaves the in-flight provider turn running")
            try await current.performGoalOperation(.drop, expectedGoalID: liveID)
            try expect(current.goalSnapshot.lastTerminal?.status == .dropped && current.nativeActivity.streaming,
                "Public native drop clears the goal without aborting the provider turn")
            try await wait { current.nativeActivity.canRecycle }

            try await current.performGoalOperation(.create, objective: "Verify user stop pauses the native goal", expectedGoalID: nil)
            let interruptedID = current.goalSnapshot.goal!.id
            try await send("GOAL_NATIVE_HOLD", to: current)
            try await wait { current.nativeActivity.streaming }
            await current.interrupt()
            try await wait { current.nativeActivity.canRecycle && current.goalSnapshot.goal?.status == .paused }
            try expect(current.goalSnapshot.goal?.id == interruptedID,
                "Stopping a native reply pauses its active goal without replacing its identity")
            let restarted = try await current.resumeGoalFromUser(expectedGoalID: interruptedID)
            try expect(restarted?.goalID == interruptedID && current.nativeActivity.canRecycle,
                "Without native RPC continuation an explicit resume admits one ordinary prompt")
            try await send("GOAL_NATIVE_RESUME", to: current)
            try await wait { current.nativeActivity.canRecycle }
            try await current.performGoalOperation(.drop, expectedGoalID: interruptedID)

            try await current.performGoalOperation(.create, objective: "Observe the native soft budget", tokenBudget: 1, expectedGoalID: nil)
            try await send("GOAL_NATIVE_BUDGET", to: current)
            try await wait { current.nativeActivity.canRecycle && current.goalSnapshot.goal?.status == .budgetLimited }
            try expect((current.goalSnapshot.goal?.tokensUsed ?? 0) > 1 && current.goalSnapshot.lastTerminal == nil,
                "Native budget-limited is separate from completion and can exceed the requested budget")
            let budgetID = current.goalSnapshot.goal!.id
            try await current.performGoalOperation(.pause, expectedGoalID: budgetID)
            do {
                _ = try await current.resumeGoalFromUser(expectedGoalID: budgetID)
                throw Failure(message: "A spent native budget must not resume")
            } catch ProviderError.failed(_) {
                try expect(current.goalSnapshot.goal?.status == .paused,
                    "A paused spent native budget is rejected before another model turn")
            }
            try await current.performGoalOperation(.drop, expectedGoalID: budgetID)
            try await current.performGoalOperation(.create, objective: "Resume native goal state without auto-restarting it", expectedGoalID: nil)
            let restoredID = current.goalSnapshot.goal!.id
            await current.stopAndWait(timeout: 5)
            configuration.resumeID = identity
            current = OMPSession(configuration: configuration)
            _ = try await current.start()
            try await current.refreshGoal()
            try expect(current.goalSnapshot.goal?.id == restoredID && current.goalSnapshot.goal?.status == .paused,
                "A new native process restores an active goal as paused without GUI replay")
            let restoredResume = try await current.resumeGoalFromUser(expectedGoalID: restoredID)
            try expect(restoredResume?.goalID == restoredID && current.goalSnapshot.goal?.status == .active && current.nativeActivity.canRecycle,
                "Explicit restored resume preserves goal identity and admits one user prompt without a GUI loop")
            try await current.performGoalOperation(.drop, expectedGoalID: restoredID)
            await current.stopAndWait(timeout: 5)

            // Opt into OMP's own driver only in this generated profile. A fresh
            // process makes the setting deterministic without polling a watcher.
            try await OMPCLI.set("goal.continuationModes", value: ["rpc"], executable: configuration.executable!,
                environment: environment, directory: output)
            current = OMPSession(configuration: configuration)
            var automaticTurns = 0
            current.onEvent = { if case .turnStarted = $0 { automaticTurns += 1 } }
            _ = try await current.start()
            try await current.refreshGoal()
            try await current.performGoalOperation(.create, objective: "Let OMP decide whether to continue this goal", expectedGoalID: nil)
            try await wait { automaticTurns > 0 && current.nativeActivity.canRecycle }
            try expect(automaticTurns == 1 && current.goalSnapshot.goal?.status == .active,
                "OMP RPC continuation starts a turn without a GUI prompt and suppresses another after no tool progress")
            let automaticID = current.goalSnapshot.goal!.id
            try await current.performGoalOperation(.pause, expectedGoalID: automaticID)
            let automaticResume = try await current.resumeGoalFromUser(expectedGoalID: automaticID)
            try await wait { automaticTurns > 1 && current.nativeActivity.canRecycle }
            try expect(automaticResume == nil && automaticTurns == 2,
                "Native RPC resume continuation suppresses the GUI fallback, including a fast completed turn")
            try await current.performGoalOperation(.drop, expectedGoalID: current.goalSnapshot.goal!.id)
            await current.stopAndWait(timeout: 5)
            try await OMPCLI.set("goal.enabled", value: false, executable: configuration.executable!,
                environment: environment, directory: output)
            current = OMPSession(configuration: configuration)
            _ = try await current.start()
            try await current.refreshGoal()
            do {
                try await current.performGoalOperation(.create, objective: "Disabled goal policy", expectedGoalID: nil)
                throw Failure(message: "Disabled native goals must reject creation")
            } catch ProviderError.failed(_) {
                try await current.refreshGoal()
                try expect(current.capabilities.goalIsDisabled && current.capabilities["goal"] == .supported,
                    "Native disabled policy is distinct from supported read-only Goal RPC")
            }
            await current.stopAndWait(timeout: 5)
            try writeSummary(output, status: "passed", error: nil)
        } catch {
            await current.stopAndWait(timeout: 5)
            try writeSummary(output, status: "failed", error: error.localizedDescription)
            throw error
        }
    }

    @MainActor private static func writeSummary(_ output: URL, status: String, error: String?) throws {
        var value: [String: Any] = ["status": status, "checks": checks, "provider": "local deterministic HTTP", "guiWindows": 0]
        if let error { value["error"] = error }
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("summary.json"))
    }
}
