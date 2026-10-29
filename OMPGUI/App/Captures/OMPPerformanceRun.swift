#if DEBUG
import AppKit
import SwiftUI

/// Explicitly launched Dev verification: production windows, isolated fixed data,
/// read-only native OMP RPC. No model request, scheduler or release entry point.
@MainActor
enum OMPPerformanceRun {
    static var enabled: Bool { CaptureRun.isEnabled && CommandLine.arguments.contains("--omp-performance-check") }
    private static var forwardOnly: Bool { CommandLine.arguments.contains("--omp-p5-forward") }
    private static var previewSmoke: Bool { CommandLine.arguments.contains("--omp-preview-smoke") }
    private static let projectID = UUID(uuidString: "00000000-0000-4000-8000-000000000100")!
    private static let ids = (1...3).map { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", $0))! }
    private static var coldThread: ChatThread?
    private static var window: NSWindow?
    private static var ompPID: Int32?
    private static var checks = 0
    private static var coldMilliseconds = 0.0
    private static var recentMilliseconds = 0.0
    private static var switchesCompleted = 0
    private static var previewsCompleted = 0
    private static var nativeCapabilities = OMPCapabilities()
    private static var nativeVersion = "unknown"
    private static var nativeSettled: Bool?
    private static var stalePreviewReadyRejections = 0
    private static var started = ContinuousClock.now
    private static var workspace: URL { CaptureRun.outputDirectory!.appendingPathComponent("workspace") }

    private static func argument(_ key: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: key), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    static func prepare() {
        guard let output = CaptureRun.outputDirectory, let root = CaptureRun.storageRoot, let defaults = CaptureRun.defaults,
              (output.path.contains("/build.noindex/omp-p0-live/") || (forwardOnly && output.path.contains("/build.noindex/omp-p5-live/"))),
              !FileManager.default.fileExists(atPath: root.path),
              let executable = argument("--omp-executable"), FileManager.default.isExecutableFile(atPath: executable) else {
            fatalError("Performance runs require fresh isolated build.noindex/omp-p0-live storage and an explicit OMP executable")
        }
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("threads"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let agentDirectory = output.appendingPathComponent("omp-config/agent")
            try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
            // Native OMP requires a selectable model even for read-only RPC.
            // This local, unauthenticated definition cannot call a paid provider.
            let nativeModels = #"{"providers":{"p0-fixture":{"api":"openai-completions","baseUrl":"http://127.0.0.1:9/v1","auth":"none","models":[{"id":"verification-only","contextWindow":200000,"maxTokens":4096}]}}}"#
            try nativeModels.write(to: agentDirectory.appendingPathComponent("models.yml"), atomically: true, encoding: .utf8)
            defaults.removePersistentDomain(forName: CaptureRun.suiteName)
            for (key, value) in ["notifyWhenFinished": false, "chimeWhenFinished": false, "performanceMode": false,
                                 "hasSeenHydraIntro": true, "sidebarActivityView": false] { defaults.set(value, forKey: key) }
            defaults.set("dark", forKey: "appTheme")
            defaults.set("omp", forKey: "defaultProvider")
            defaults.set(["omp": executable], forKey: "providerBinaryPaths")
            defaults.synchronize()
            LoginEnvironment.setOverlay(["PI_CONFIG_DIR": output.appendingPathComponent("omp-config").path,
                                         "PI_CODING_AGENT_DIR": output.appendingPathComponent("omp-config/agent").path,
                                         "OMP_PROFILE": "default", "PI_PROFILE": "default"])
            var library = Library()
            var project = Project(name: "OMP P0 验证", path: workspace.path)
            project.id = projectID
            library.projects = [project]
            for (index, id) in ids.enumerated() {
                var thread = ChatThread(projectID: projectID, provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
                thread.id = id
                thread.title = index == 2 ? "万条记录 · 新会话" : "原生验证会话 \(index + 1)"
                thread.hasCustomTitle = true
                thread.lastStatus = .completed
                thread.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
                thread.updatedAt = thread.createdAt
                if index == 2 { coldThread = thread } else { library.threads.append(thread) }
                var document = ThreadDocument(threadID: id)
                for turnIndex in 0..<(index == 2 ? 5_000 : 64) {
                    var turn = TurnRecord(index: turnIndex, status: .completed)
                    turn.id = UUID(uuidString: String(format: "00000000-0000-4000-%04d-%012d", index + 1, turnIndex + 1))!
                    turn.startedAt = thread.createdAt.addingTimeInterval(Double(turnIndex))
                    turn.completedAt = turn.startedAt
                    let user = TimelineItem(id: "user-\(turnIndex)", turnID: turn.id, date: turn.startedAt,
                                            content: .user(UserMessage(text: "记录 \(turnIndex)：说明原生会话状态。")))
                    turn.userItemID = user.id
                    document.turns.append(turn)
                    document.items.append(user)
                    document.items.append(TimelineItem(id: "answer-\(turnIndex)", turnID: turn.id, date: turn.startedAt,
                        content: .assistant(AssistantMessage(text: "记录 \(turnIndex)：OMP 持有任务状态，GUI 展示原生结果。\n\n状态包括 **回复中**、等待用户和后台工作。`session_settled` 表示原生会话结束。"))))
                }
                if forwardOnly {
                    var head = ThreadDocument(threadID: id)
                    head.turnIndex = []
                    var stored: [UUID: StoredTurn] = [:]
                    for (offset, turn) in document.turns.enumerated() {
                        var items = Array(document.items[(offset * 2)..<(offset * 2 + 2)])
                        items.append(TimelineItem(id: "end-\(offset)", turnID: turn.id, date: turn.startedAt,
                            content: .turnEnd(TurnSummary(turnID: turn.id, status: .completed, duration: 0,
                                filesChanged: 0, additions: 0, deletions: 0))))
                        let positions = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, Double(offset * 3 + $0.offset)) })
                        stored[turn.id] = StoredTurn(turn: turn, items: items, itemPositions: positions)
                        head.turnIndex?.append(ThreadTurnReference(id: turn.id, revision: 1))
                    }
                    guard DiskWriter.shared.writeThreadSynchronously(ThreadSave(head: head, dirtyTurns: stored)) else {
                        throw CheckFailure(message: "Cannot write fresh segmented performance fixture")
                    }
                } else {
                    try JSONEncoder.storage.encode(document).write(to: root.appendingPathComponent("threads/\(id.uuidString).json"), options: .atomic)
                }
            }
            try JSONEncoder.storage.encode(library).write(to: root.appendingPathComponent("library.json"), options: .atomic)
            let markdown = (1...60).map { "## 第 \($0) 节\n\n原生预览性能验证。公式：$E=mc^2$。\n\n| 状态 | 说明 |\n| --- | --- |\n| settled | 已结束 |\n\n```swift\nlet count = \($0)\n```\n" }.joined(separator: "\n")
            try markdown.write(to: workspace.appendingPathComponent("Preview.md"), atomically: true, encoding: .utf8)
        } catch { fatalError("Cannot prepare isolated performance data: \(error)") }
    }

    static func run(model: AppModel) async {
        started = .now
        do {
            await model.bootstrap()
            try require(model.threads.count == 2, "Isolated library starts with two warm OMP conversations")
            model.providers.updateCatalog([], for: .omp)
            model.providers.updateCommands([], for: .omp, directory: workspace.path)
            model.selectedThreadID = ids[0]
            let window = WindowManager.shared.makeCaptureWindow(size: NSSize(width: 1320, height: 860), threadControls: true)
            self.window = window
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            try await Task.sleep(for: .seconds(2))
            phase("native-start")
            let rpc = OMPRPC()
            defer { rpc.stop() }
            let executable = URL(fileURLWithPath: argument("--omp-executable")!)
            let environment = LoginEnvironment.current
            nativeVersion = try await OMPCLI.run(["--version"], executable: executable, environment: environment, directory: workspace)
            try rpc.start(executable: executable, arguments: ["--mode", "rpc-ui", "--no-session", "--no-title", "--model", "p0-fixture/verification-only"],
                          directory: workspace, environment: environment)
            ompPID = rpc.process?.processIdentifier
            phase("native-start")
            _ = try? await rpc.request("negotiate_protocol", fields: ["protocolVersion": 2])
            let state = try await rpc.request("get_state", timeout: .seconds(60))
            nativeSettled = state["isSettled"]?.bool
            try require(state["isStreaming"]?.bool == false, "Native read-only session is not streaming")
            _ = try? await rpc.request("set_subagent_subscription", fields: ["level": "events"])
            _ = try? await rpc.request("get_subagents")
            _ = await rpc.probeSubagentControl("cancel_subagent")
            _ = await rpc.probeSubagentControl("steer_subagent")
            nativeCapabilities = rpc.capabilities

            phase("cold-history")
            let coldStart = ContinuousClock.now
            // Insert only now: startup prefetch/prebuilt columns must not warm this chat.
            model.insertThread(coldThread!)
            model.selectedThreadID = ids[2]
            let cold = model.runtime(for: ids[2])
            if forwardOnly {
                while cold.entries.isEmpty {
                    try require(milliseconds(coldStart) < 30_000, "New segmented history yields a recent page")
                    try await Task.sleep(for: .milliseconds(2))
                }
                await draw()
                recentMilliseconds = milliseconds(coldStart)
            }
            await cold.ensureLoaded()
            await draw()
            coldMilliseconds = milliseconds(coldStart)
            try require(cold.entries.count == 15_000 && cold.turns.count == 5_000, "Long history retains all messages and recovered turn markers")
            // Return to a fixed two-chat cache and warm the preview engine before
            // comparing the same closed-preview state at both memory checkpoints.
            for id in ids.prefix(2) { model.selectedThreadID = id; await model.runtime(for: id).ensureLoaded(); await draw() }
            guard let previews = (window as? ThreadWindow)?.filePreviews else { throw CheckFailure(message: "Native window did not register its preview store") }
            try await previewCycle(previews)
            model.selectedThreadID = ids[0]
            await draw()
            phase("warm-settle")
            if !previewSmoke { try await Task.sleep(for: .seconds(30)) }
            phase("idle-before")
            if !previewSmoke { try await Task.sleep(for: .seconds(60)) }

            phase("chat-switches")
            for index in 0..<100 {
                model.selectedThreadID = ids[(index + 1) % 2]
                await draw()
                switchesCompleted += 1
            }
            try require(model.selectedThreadID == ids[0], "100 switches return to the same conversation")
            phase("preview-cycles")
            for _ in 0..<20 { try await previewCycle(previews); previewsCompleted += 1 }
            try require(!previews.isVisible && previews.snapshot == nil, "Hidden preview releases its visible snapshot")
            phase("after-settle")
            if !previewSmoke { try await Task.sleep(for: .seconds(30)) }
            phase("idle-after")
            if !previewSmoke { try await Task.sleep(for: .seconds(60)) }

            phase("inspection")
            // Keep a representative document and native status on screen for
            // external accessibility/screenshot inspection, outside timed phases.
            let runtime = model.runtime(for: ids[0])
            runtime.receiveOMPEvent(.ompActivity(OMPActivity(connected: true, compacting: true, settled: false)))
            try await showPreview(previews)
            await draw()
            try await writeReport(status: "inspection")
            // Allow a bounded inspection period; completion still needs its marker.
            for _ in 0..<600 {
                if FileManager.default.fileExists(atPath: CaptureRun.outputDirectory!.appendingPathComponent("finish").path) { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            try require(FileManager.default.fileExists(atPath: CaptureRun.outputDirectory!.appendingPathComponent("finish").path), "Inspection must be explicitly completed")
            runtime.receiveOMPEvent(.ompActivity(OMPActivity(connected: true, settled: true)))
            previews.setVisible(false)
            await rpc.stopAndWait(timeout: 5)
            try require(!rpc.isRunning, "Native OMP exits after the explicit verification stop")
            try await writeReport(status: "completed")
            phase("completed")
            NSApp.terminate(nil)
        } catch {
            phase("failed", error: error.localizedDescription)
            try? await writeReport(status: "failed", error: error.localizedDescription)
            NSApp.terminate(nil)
        }
    }

    private static func showPreview(_ previews: FilePreviewStore) async throws {
        try require(previews.open(FilePreviewReference(path: workspace.appendingPathComponent("Preview.md").path)), "Preview accepts a local file")
        for _ in 0..<400 {
            let hosts = descendants(window?.contentView).compactMap { $0 as? PreviewMarkdownHost }
            let usable = hosts.filter {
                !$0.renderedToken.isEmpty && $0.web.superview === $0 && $0.web.window === window
                    && $0.bounds.height > 10 && $0.web.bounds.height > 10 && !$0.isHiddenOrHasHiddenAncestor
            }
            stalePreviewReadyRejections += hosts.filter { !$0.renderedToken.isEmpty }.count - usable.count
            let split = descendants(window?.contentView).compactMap { $0 as? PreviewSplitView }.first
            if let host = usable.first, split?.isSliding == false, split?.previewClip?.hasSnapshot == false {
                let visible = await withCheckedContinuation { continuation in
                    host.web.evaluateJavaScript("!!document.querySelector('#document')?.textContent?.trim() && innerHeight > 10") { value, _ in
                        continuation.resume(returning: (value as? NSNumber)?.boolValue == true)
                    }
                }
                if visible { return }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let diagnostics = descendants(window?.contentView).compactMap { $0 as? PreviewMarkdownHost }.map {
            "host=\($0.bounds) web=\($0.web.bounds) attached=\($0.web.superview === $0) window=\($0.web.window === window) hidden=\($0.isHiddenOrHasHiddenAncestor) rendered=\(!$0.renderedToken.isEmpty)"
        }.joined(separator: "; ")
        throw CheckFailure(message: "Markdown preview did not finish rendering: " + diagnostics)
    }

    private static func previewCycle(_ previews: FilePreviewStore) async throws {
        try await showPreview(previews)
        await draw()
        previews.setVisible(false)
        try await Task.sleep(for: .milliseconds(300))
    }

    private static func descendants(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants($0) }
    }

    private static func draw() async {
        // A bounded run-loop opportunity and display/layout check. This is not
        // a timestamp of the GPU presenting the first readable frame.
        try? await Task.sleep(for: .milliseconds(35))
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(message: message) }
        checks += 1
    }
    private struct CheckFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }
    private static func phase(_ name: String, error: String? = nil) {
        var value: [String: Any] = ["phase": name, "gui_pid": ProcessInfo.processInfo.processIdentifier,
                                    "uptime": ProcessInfo.processInfo.systemUptime, "active": NSApp.isActive,
                                    "visible": window?.occlusionState.contains(.visible) == true]
        if let ompPID { value["omp_pid"] = ompPID }
        if let error { value["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: CaptureRun.outputDirectory!.appendingPathComponent("phase.json"), options: .atomic)
        }
    }
    private static func writeReport(status: String, error: String? = nil) async throws {
        var value: [String: Any] = ["schema": 1, "workload": previewSmoke ? "omp-p5-preview-smoke" : (forwardOnly ? "omp-p5-forward-v2" : "omp-p0-live-v2"), "status": status, "checks": checks,
            "native_version": nativeVersion, "native_settled": nativeSettled as Any? ?? NSNull(),
            "native_capabilities": nativeCapabilities.commands.mapValues(\.rawValue),
            "elapsed_milliseconds": milliseconds(started), "cold_history_layout_cycle_ms": coldMilliseconds,
            "recent_history_layout_cycle_ms": recentMilliseconds,
            "stale_preview_ready_rejections": stalePreviewReadyRejections,
            "chat_switches": switchesCompleted, "preview_cycles": previewsCompleted, "history_entries": 10_000,
            "metrics": try JSONSerialization.jsonObject(with: JSONEncoder().encode(RuntimeMetrics.snapshot())),
            "unmeasured": ["GPU first readable frame", "input event to displayed glyph", "paid model requests", "live MCP tools", "sleep/wake", "VoiceOver speech"]]
        if let error { value["error"] = error }
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: CaptureRun.outputDirectory!.appendingPathComponent("checks.json"), options: .atomic)
    }
}
#endif
