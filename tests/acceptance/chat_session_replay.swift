import AppKit
import SwiftUI
@testable import OMPGUI

/// Manual GUI acceptance only. The caller stages a selected chat and its parent
/// metadata in an isolated capture library; this helper never copies a live
/// library, launches OMP, or sends a message. Link the current worktree Dev module.
@main private enum ChatSessionReplay {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run() }
            catch { print("Replay failed: \(error)"); exit(1) }
            app.terminate(nil)
        }
        // Real AppKit event dispatch is required for wheel/trackpad acceptance.
        // The async-main executor alone can draw windows without pumping input.
        app.run()
    }
    @MainActor static func run() async throws {
        func argument(_ name: String) -> String? {
            guard let i = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.indices.contains(i + 1) else { return nil }
            return CommandLine.arguments[i + 1]
        }
        guard let output = CaptureRun.outputDirectory, output.path.contains("/build.noindex/"),
              let resources = argument("--resources"), let rawID = argument("--thread-id"), let id = UUID(uuidString: rawID)
        else { fatalError("Require isolated --website-captures, --resources and --thread-id") }
        let app = NSApplication.shared
        ChatMathRenderer.shared.resourceRoot = URL(fileURLWithPath: resources)
        let manager = WindowManager.shared
        await manager.model.bootstrap()
        guard manager.model.threads.contains(where: { $0.id == id }) else { fatalError("Selected chat is missing from the isolated library") }
        let performance = CommandLine.arguments.contains("--performance")
        let preparationCheck = CommandLine.arguments.contains("--preparation-check")
        let switchCheck = CommandLine.arguments.contains("--switch-check")
        let start = ProcessInfo.processInfo.systemUptime
        var preparations: [[String: Any]] = []
        var frames: [[String: Any]] = [], wheelEvents: [[String: Any]] = [], manualGaps: [Double] = []
        var preparationPhase = "entry"
        @discardableResult func recordPreparation(_ window: NSWindow) -> Bool {
            var seen: Set<ObjectIdentifier> = []
            var waiting = false
            var textViews = 0, mathHosts = 0, indicators = 0
            var viewport: NSScrollView?
            func visit(_ view: NSView) {
                if !view.isHiddenOrHasHiddenAncestor {
                    if view is LinkTextView { textViews += 1 }
                    if view is MathParagraphHost { mathHosts += 1 }
                    if view is SpinnerLayerView { indicators += 1 }
                    if let scroll = view as? NSScrollView, !(scroll is MathParagraphHost),
                       scroll.bounds.height > 200,
                       (scroll.documentView?.bounds.height ?? 0) > (viewport?.documentView?.bounds.height ?? 0) { viewport = scroll }
                }
                if let scope = (view as? LinkTextView)?.mathPreparation, scope.isActive,
                   seen.insert(ObjectIdentifier(scope)).inserted {
                    waiting = waiting || scope.presentation.hidesContent
                    preparations.append(["phase": preparationPhase, "ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                                         "hides_content": scope.presentation.hidesContent, "spinner": scope.presentation.showsSpinner,
                                         "pending": scope.pendingCount, "assessed": scope.hasInitialAssessment,
                                         "history_loading": manager.model.runtime(for: id).nativeAgentHistoryLoading,
                                         "answers": manager.model.runtime(for: id).entries.filter { $0.kind == .assistant }.count])
                }
                for child in view.subviews { visit(child) }
            }
            if let view = window.contentView { visit(view) }
            frames.append(["phase": preparationPhase, "ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                           "waiting": waiting, "indicators": indicators, "text_views": textViews, "math_hosts": mathHosts,
                           "offset": viewport?.contentView.bounds.minY ?? 0, "document_height": viewport?.documentView?.bounds.height ?? 0])
            if frames.count.isMultiple(of: 20), let data = try? JSONSerialization.data(withJSONObject: ["preparation": preparations, "frames": frames, "wheel_events": wheelEvents, "manual_gaps_ms": manualGaps], options: [.sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("preparation-live.json"), options: .atomic)
            }
            return waiting || indicators > 0
        }
        var paints: [String: Double] = [:]
        var reopenedAt: Double?
        var reopenedPaints: [String: Double] = [:]
        var rendererStages: [[String: Any]] = []
        ChatMathRenderer.timingObserver = { stage, ms in rendererStages.append(["stage": stage, "ms": ms]) }
        MathRendering.paintObserver = { key, _, _ in
            let now = ProcessInfo.processInfo.systemUptime
            if let reopenedAt {
                if reopenedPaints[key] == nil { reopenedPaints[key] = (now - reopenedAt) * 1000 }
            } else if paints[key] == nil { paints[key] = (now - start) * 1000 }
        }
        manager.model.selectedThreadID = id
        await manager.model.runtime(for: id).ensureLoaded()
        let window = manager.makeCaptureWindow(size: NSSize(width: 1320, height: 860), threadControls: true)
        window.title = "Chat Session Layout Acceptance"
        window.center(); window.makeKeyAndOrderFront(nil); app.activate()
        let wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            if event.window === window {
                wheelEvents.append(["ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                                    "dy": event.scrollingDeltaY, "phase": event.phase.rawValue])
            }
            return event
        }
        defer { if let wheel { NSEvent.removeMonitor(wheel) } }
        defer { window.close(); ChatMathRenderer.shared.release() }
        print("shown pid \(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout)
        var gaps: [Double] = []
        var last = ProcessInfo.processInfo.systemUptime
        var timeline: [[String: Any]] = []
        var quietSince: Double?
        var firstIdleMS: Double?, lastIdleMS: Double?
        for i in 0..<(performance ? 600 : 24) {
            try await Task.sleep(for: .milliseconds(performance ? 50 : 250))
            let now = ProcessInfo.processInfo.systemUptime
            gaps.append((now - last) * 1000); last = now
            if preparationCheck || switchCheck { recordPreparation(window) }
            if !performance, i == 4 { window.setContentSize(NSSize(width: 920, height: 860)) }
            if !performance, i == 12 { window.setContentSize(NSSize(width: 1320, height: 860)) }
            timeline.append(["ms": (now - start) * 1000, "typeset": MathRendering.typesetCount,
                             "snapshots": ChatMathRenderer.shared.batchCount, "painted_unique": paints.count,
                             "rendering": MathRendering.isRendering])
            try Data("heartbeat \(i)".utf8).write(to: output.appendingPathComponent("heartbeat"), options: .atomic)
            if performance {
                if MathRendering.isRendering { quietSince = nil; lastIdleMS = nil }
                else if quietSince == nil {
                    quietSince = now; lastIdleMS = (now - start) * 1000
                    if firstIdleMS == nil { firstIdleMS = lastIdleMS }
                }
                if let quietSince, now - quietSince > 0.5 { break }
            }
        }
        let ready = ProcessInfo.processInfo.systemUptime
        let coldCount = MathRendering.typesetCount
        let coldDiskHits = MathRendering.diskHitCount
        let coldCreations = ChatMathRenderer.shared.creationCount
        if switchCheck, let rawOther = argument("--other-id"), let other = UUID(uuidString: rawOther) {
            await manager.model.runtime(for: other).ensureLoaded()
            manager.model.selectedThreadID = other
            try await Task.sleep(for: .milliseconds(80))
            preparationPhase = "quick_return"
            manager.model.selectedThreadID = id
            for _ in 0..<80 {
                try await Task.sleep(for: .milliseconds(50))
                recordPreparation(window)
            }
            if CommandLine.arguments.contains("--history-change"),
               let file = manager.model.thread(id)?.providerSessionID, file.hasPrefix(output.path + "/storage/") {
                preparationPhase = "history_refresh"
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("{\"type\":\"title\",\"title\":\"Acceptance refresh\"}\n".utf8))
                try handle.close()
                let read = Task { await manager.model.runtime(for: id).loadNativeAgentHistory() }
                for _ in 0..<60 {
                    try await Task.sleep(for: .milliseconds(50)); recordPreparation(window)
                }
                await read.value
            }
            print("needs-scroll pid \(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout)
            try Data().write(to: output.appendingPathComponent("needs-scroll"))
            preparationPhase = "scroll"
            var previousFrame = ProcessInfo.processInfo.systemUptime
            for _ in 0..<900 {
                try await Task.sleep(for: .milliseconds(50))
                let now = ProcessInfo.processInfo.systemUptime
                manualGaps.append((now - previousFrame) * 1000); previousFrame = now
                recordPreparation(window)
                if FileManager.default.fileExists(atPath: output.appendingPathComponent("scroll-finish").path) { break }
            }
        }
        if preparationCheck {
            let stock = TypeScale.shared.content
            defer { TypeScale.shared.content = stock }
            for (phase, size) in [("font_miss", stock + 1), ("font_cached", stock)] {
                preparationPhase = phase
                TypeScale.shared.content = size
                var settled: Double?
                for _ in 0..<200 {
                    try await Task.sleep(for: .milliseconds(50))
                    recordPreparation(window)
                    if MathRendering.isRendering { settled = nil }
                    else if settled == nil { settled = ProcessInfo.processInfo.systemUptime }
                    if let settled, ProcessInfo.processInfo.systemUptime - settled > 0.6 { break }
                }
            }
        }
        var reopenMS: Double = 0
        let beforeReopenCount = MathRendering.typesetCount
        if performance {
            window.close()
            reopenedAt = ProcessInfo.processInfo.systemUptime
            let reopened = manager.makeCaptureWindow(size: NSSize(width: 1320, height: 860), threadControls: true)
            reopened.title = "Chat Session Cached Reopen Acceptance"
            preparationPhase = "cached_reopen"
            reopened.center(); reopened.makeKeyAndOrderFront(nil)
            for _ in 0..<600 {
                try await Task.sleep(for: .milliseconds(50))
                let waiting = preparationCheck && recordPreparation(reopened)
                if !MathRendering.isRendering, !reopenedPaints.isEmpty, !waiting { break }
            }
            reopenMS = (ProcessInfo.processInfo.systemUptime - reopenedAt!) * 1000
            reopened.close()
        }
        await MathRendering.flushDiskCache()
        MathRendering.paintObserver = nil
        ChatMathRenderer.timingObserver = nil
        let report: [String: Any] = ["heartbeats": gaps.count, "widths": performance ? [1320] : [1320, 920, 1320],
                                   "main_actor_gap_ms": gaps, "math_queue_drained": !MathRendering.isRendering,
                                   "cold_ms": (ready - start) * 1000, "cold_typeset": coldCount,
                                   "cold_disk_hits": coldDiskHits, "cold_webview_creations": coldCreations,
                                   "first_queue_idle_ms": firstIdleMS ?? -1, "last_queue_drained_ms": lastIdleMS ?? -1,
                                   "cached_reopen_ms": reopenMS, "reopen_typeset": MathRendering.typesetCount - beforeReopenCount,
                                   "paint_ms": paints.values.sorted(), "reopen_paint_ms": reopenedPaints.values.sorted(), "timeline": timeline,
                                   "renderer_stages": rendererStages,
                                   "preparation": preparations,
                                   "frames": frames, "wheel_events": wheelEvents, "manual_gaps_ms": manualGaps,
                                   "scope": "Production RootView/ThreadRuntime and staged chat, visible isolated window; no live provider"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("replay.json"))
        print("completed"); fflush(stdout)
    }
}
