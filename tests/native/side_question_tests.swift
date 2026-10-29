import Foundation
@testable import OMPGUI

@main
struct NativeSideQuestionChecks {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    @MainActor static func main() async throws {
        guard CaptureRun.isEnabled, let output = CaptureRun.outputDirectory,
              output.path.contains("/build.noindex/verification/runs/"),
              let executable = ProcessInfo.processInfo.environment["OMP_P5_NATIVE_EXECUTABLE"] else {
            fatalError("Require an isolated loopback-provider runner and explicit OMP executable")
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
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<1_000 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw Failure(message: "Native side-question lifecycle did not settle")
        }
        do {
            let identity = try await session.start()
            try expect(identity.hasPrefix(output.path + "/"), "Native side questions use a newly generated isolated session")
            var mainEvents = 0
            var mainEnded = false
            session.onEvent = { event in
                switch event {
                case .turnCompleted: mainEnded = true; mainEvents += 1
                case .messageDelta, .messageCompleted, .turnStarted, .tokenSpend: mainEvents += 1
                default: break
                }
            }
            try await session.send(TurnInput(text: "P5_HOLD_BTW_MAIN", images: [], model: "p5-local/forward", effort: "off", runtimeMode: .auto, interactionMode: .build))
            try await wait { session.nativeActivity.streaming }
            try expect(!mainEnded, "The actual native lead is running when the side question is submitted")
            try await session.askSideQuestion("P5_BTW_EXPLAIN", continuing: false, requestID: "native-first")
            try await wait { session.sideQuestionSnapshot.turns.last?.status == .complete && mainEnded }
            let topic = session.sideQuestionSnapshot.recordID!
            try expect(session.sideQuestionSnapshot.turns.last?.answer.contains("P5_REPLY") == true
                && session.capabilities["btw"] == .supported, "Public BTW completes alongside the native prompt through the loopback provider")
            try expect(session.sideQuestionSnapshot.persistencePending, "Answer completion does not claim a native checkpoint acknowledgement")
            let eventsBeforeFollowUp = mainEvents
            try await session.askSideQuestion("P5_BTW_FOLLOW_UP", continuing: true, requestID: "native-follow-up")
            try await wait { session.sideQuestionSnapshot.turns.last?.status == .complete }
            try expect(session.sideQuestionSnapshot.recordID == topic && session.sideQuestionSnapshot.turnCount == 2,
                       "The native cumulative record preserves the exact follow-up topic")
            try expect(mainEvents == eventsBeforeFollowUp, "A side-only follow-up creates no main reply or duplicate token spend")
            try await session.askSideQuestion("P5_HOLD_BTW_CANCEL", continuing: true, requestID: "native-cancel")
            try await session.cancelSideQuestion()
            try await wait { session.sideQuestionSnapshot.turns.last?.status == .cancelled }
            try expect(session.capabilities["btw_cancel"] == .supported && session.sideQuestionSnapshot.recordID == topic,
                       "Actual cancellation targets this topic and waits for its cancelled lifecycle")
            _ = try await session.readState()
            try expect(session.nativeActivity.canRecycle && !session.nativeActivity.hasWork,
                       "Finished side work leaves the lead idle without manufacturing a main turn")
            try expect(session.beginSideQuestionDrain(), "Idle disposal uses native stdin EOF to drain sidecar writes")
            try await wait { session.sideQuestionSnapshot.disconnected }
            try expect(!session.isRunning && !session.sideQuestionSnapshot.persistencePending
                && session.sideQuestionSnapshot.persistenceError == nil,
                       "Native output and disposal finish before releasing the persistence blocker")
            let files = FileManager.default.enumerator(at: output, includingPropertiesForKeys: nil)
            var saved: JSONValue?
            while let file = files?.nextObject() as? URL {
                if file.lastPathComponent == "entry-\(topic).json", file.path.contains("/btw-history/") {
                    saved = JSONValue.parse(try Data(contentsOf: file))
                    break
                }
            }
            try expect(saved?["id"]?.string == topic && saved?["followUps"]?.array?.count == 2
                && saved?["followUps"]?.array?.last?["status"]?.string == "cancelled",
                       "The isolated native sidecar contains both follow-ups and the cancelled final turn after exit")
            let report: [String: Any] = ["status": "passed", "checks": checks,
                "scope": "One explicit runtime, loopback provider, public BTW and native EOF disposal; no GUI, external account or paid-model validation."]
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
