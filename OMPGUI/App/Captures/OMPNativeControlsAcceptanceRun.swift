#if DEBUG
import AppKit
import Observation
import SwiftUI

/// An explicitly launched manual inspection, with one real lead connection and
/// a local deterministic provider. No synthetic activity or historical workload.
@MainActor
enum OMPNativeControlsAcceptanceRun {
    static var enabled: Bool { CaptureRun.isEnabled && CommandLine.arguments.contains("--omp-native-controls-acceptance") }
    private static var output: URL { CaptureRun.outputDirectory! }
    private static var runtime: ThreadRuntime?
    private static var native: OMPSession?
    private static var window: NSWindow?
    private static var bootstrapWaiter: BootstrapWaiter?
    private static var readyDeadline: Date?
    private static var report: [String: Any] = [:]

    private static func argument(_ key: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    static func prepare() {
        guard let root = CaptureRun.storageRoot, let defaults = CaptureRun.defaults,
              output.path.contains("/build.noindex/native-controls-live/"),
              !FileManager.default.fileExists(atPath: root.path),
              let executable = argument("--omp-executable"), FileManager.default.isExecutableFile(atPath: executable),
              let actual = argument("--omp-native-executable"), FileManager.default.isExecutableFile(atPath: actual),
              let width = argument("--omp-window-width").flatMap(Double.init), width.isFinite, width >= 860,
              FileManager.default.fileExists(atPath: output.appendingPathComponent("profile/agent/models.yml").path)
        else { fatalError("Require fresh isolated native-controls storage, profile, native executable and width >= 860") }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defaults.removePersistentDomain(forName: CaptureRun.suiteName)
            for (key, value) in ["notifyWhenFinished": false, "chimeWhenFinished": false,
                                 "hasSeenHydraIntro": true, "sidebarActivityView": false,
                                 "antiSlopEnabled": false, "performanceMode": false] { defaults.set(value, forKey: key) }
            defaults.set("dark", forKey: "appTheme")
            defaults.set("omp", forKey: "defaultProvider")
            defaults.set(["omp": executable], forKey: "providerBinaryPaths")
            defaults.synchronize()
            LoginEnvironment.setOverlay([
                "PI_CONFIG_DIR": output.appendingPathComponent("profile").path,
                "PI_CODING_AGENT_DIR": output.appendingPathComponent("profile/agent").path,
                "PI_CONFIG_FILES": output.appendingPathComponent("empty-native-config.json").path,
                "OMP_PROFILE": "default", "PI_PROFILE": "default"
            ])
            var library = Library()
            let project = Project(name: "Native controls acceptance", path: output.appendingPathComponent("workspace").path)
            library.projects = [project]
            var chat = ChatThread(projectID: project.id, provider: .omp, model: "p5-local/forward", effort: "off", runtimeMode: .auto)
            chat.title = "Native controls acceptance"
            chat.hasCustomTitle = true
            chat.hydraEnabled = false
            library.threads = [chat]
            try JSONEncoder.storage.encode(library).write(to: root.appendingPathComponent("library.json"), options: .atomic)
            try writePhase("prepared")
        } catch { fatalError("Cannot prepare native-controls acceptance: \(error.localizedDescription)") }
    }

    static func run(model: AppModel) async {
        do {
            await model.bootstrap()
            guard model.threads.count == 1, let chat = model.threads.first else { throw Failure("Missing isolated lead") }
            model.selectedThreadID = chat.id
            let current = model.runtime(for: chat.id)
            runtime = current
            await current.ensureLoaded()
            let width = Double(argument("--omp-window-width")!)!
            let shown = WindowManager.shared.makeCaptureWindow(size: NSSize(width: width, height: 860), threadControls: true)
            window = shown
            shown.title = "OMP Native Controls Acceptance"
            shown.contentMinSize = NSSize(width: 860, height: 560)
            shown.center()
            shown.makeKeyAndOrderFront(nil)
            NSApp.activate()
            try writePhase("bootstrap")
            current.draft = ComposerDraft(text: "Q_BOOTSTRAP")
            current.send()
            let waiter = BootstrapWaiter(runtime: current)
            bootstrapWaiter = waiter
            try await waiter.wait()
            bootstrapWaiter = nil
            guard let connected = current.activeOMPSession,
                  let pid = connected.rpc.process?.processIdentifier else { throw Failure("Bootstrap did not retain its native lead") }
            native = connected
            readyDeadline = Date.now.addingTimeInterval(600)
            report["native_session_file"] = connected.sessionFile
            report["omp_pid"] = Int(pid)
            report["bootstrap_reply_observed"] = true
            report["automated_scope"] = "One Q_BOOTSTRAP through the production ThreadRuntime; subsequent Goal, side-question and Usage actions are manual."
            try writePhase("ready")
            if ChatMathAcceptanceRun.enabled { try await ChatMathAcceptanceRun.run(runtime: current, window: shown, output: output) }
            // Only a test marker is polled. No product state reads, refreshes,
            // actions or periodic native requests run during manual inspection.
            let deadline = ContinuousClock.now.advanced(by: .seconds(600))
            var finished = false
            while ContinuousClock.now < deadline {
                if FileManager.default.fileExists(atPath: output.appendingPathComponent("abort").path) {
                    throw Failure("Manual inspection was aborted by this launcher")
                }
                if FileManager.default.fileExists(atPath: output.appendingPathComponent("finish").path) { finished = true; break }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard finished else { throw Failure("Manual finish marker was not received within 600 seconds") }
            let exited = await stopOwnSession()
            guard exited else { throw Failure("The native process did not exit after explicit stop") }
            try writeReport(status: "completed")
            try writePhase("completed")
        } catch {
            bootstrapWaiter = nil
            _ = await stopOwnSession()
            try? writeReport(status: "failed", error: error.localizedDescription)
            try? writePhase("failed", error: error.localizedDescription)
        }
        NSApp.terminate(nil)
    }

    private static func stopOwnSession() async -> Bool {
        let stopping = runtime?.activeOMPSession ?? native
        if let side = stopping?.sideQuestionSnapshot {
            report["side_question_before_explicit_stop"] = [
                "live_work": side.hasLiveWork, "persistence_pending": side.persistencePending,
                "persistence_error": side.persistenceError as Any? ?? NSNull()
            ]
        }
        // This is the existing explicit-stop path, not a sidecar-save ACK.
        runtime?.stopSession()
        runtime?.saveNow()
        runtime?.cancelPersistence()
        await stopping?.stopAndWait(timeout: 5)
        let exited = stopping?.rpc.process?.isRunning != true
        report["native_process_exited"] = exited
        report["sidecar_save_acknowledged"] = false
        report["shutdown_scope"] = "Explicit stop; process exit does not certify sidecar persistence."
        return exited
    }

    private static func writePhase(_ phase: String, error: String? = nil) throws {
        var value: [String: Any] = ["phase": phase, "gui_pid": Int(ProcessInfo.processInfo.processIdentifier),
                                    "window_title": "OMP Native Controls Acceptance"]
        if let pid = native?.rpc.process?.processIdentifier { value["omp_pid"] = Int(pid) }
        if let readyDeadline { value["finish_deadline"] = ISO8601DateFormatter().string(from: readyDeadline) }
        if let error { value["error"] = error }
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("phase.json"), options: .atomic)
    }

    private static func writeReport(status: String, error: String? = nil) throws {
        report["status"] = status
        report["gui_pid"] = Int(ProcessInfo.processInfo.processIdentifier)
        report["manual_finish_marker_received"] = FileManager.default.fileExists(atPath: output.appendingPathComponent("finish").path)
        report["requested_content_width"] = Double(argument("--omp-window-width")!)!
        report["unmeasured"] = ["Automatic confirmation of manual labels or sheet-cycle counts", "Screen latency and p95", "Whole-app resource budgets"]
        if let error { report["error"] = error }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("checks.json"), options: .atomic)
    }

    /// Observe the bootstrap's production projection, rather than repeatedly
    /// querying OMP or sampling runtime state on a timer.
    @MainActor private final class BootstrapWaiter {
        let runtime: ThreadRuntime
        var continuation: CheckedContinuation<Void, Error>?
        var timeout: Task<Void, Never>?

        init(runtime: ThreadRuntime) { self.runtime = runtime }

        func wait() async throws {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    self?.complete(.failure(Failure("Timed out waiting for the local bootstrap reply")))
                }
                observe()
            }
        }

        private func observe() {
            guard continuation != nil else { return }
            let ready = withObservationTracking {
                runtime.phase == .idle && runtime.ompActivity?.connected == true && runtime.ompActivity?.canRecycle == true
                    && runtime.followUps.allSatisfy { $0.ompState?.isTerminal == true }
                    && runtime.entries.contains { entry in
                        if case .assistant(let answer) = entry.item.content { return answer.text.contains("P5_REPLY") }
                        return false
                    }
            } onChange: { [weak self] in
                Task { @MainActor in self?.observe() }
            }
            if ready { complete(.success(())) }
        }

        private func complete(_ result: Result<Void, Error>) {
            guard let pending = continuation else { return }
            continuation = nil
            timeout?.cancel()
            timeout = nil
            pending.resume(with: result)
        }
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
#endif
