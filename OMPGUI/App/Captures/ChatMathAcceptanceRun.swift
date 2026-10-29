#if DEBUG
import AppKit
import ScreenCaptureKit

/// Opt-in, owner-authorized real-chat inspection. The existing isolated native
/// launcher supplies a loopback SSE provider; this is outside the check registry.
@MainActor enum ChatMathAcceptanceRun {
    static var enabled: Bool { CommandLine.arguments.contains("--omp-chat-math-acceptance") }
    private final class Samples {
        var last = ProcessInfo.processInfo.systemUptime
        var ticks: [Double] = []
        var paints: [String: Double] = [:]
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func scroll(in window: NSWindow) -> NSScrollView? {
        guard let root = window.contentView else { return nil }
        return descendants(root).compactMap { $0 as? NSScrollView }
            .filter { $0.bounds.width > 450 && $0.bounds.height > 250 && ($0.documentView?.bounds.height ?? 0) > $0.bounds.height * 1.2 }
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }
    private static func snapshot(_ window: NSWindow, output: URL, name: String) async throws {
        // Layer-backed SwiftUI can produce an empty cacheDisplay bitmap. Capture
        // this process's exact WindowServer surface, never another app/display.
        let content = try await SCShareableContent.currentProcess
        guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw NSError(domain: "Missing owned chat-math window", code: 1)
        }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * window.backingScaleFactor)
        config.height = Int(window.frame.height * window.backingScaleFactor)
        config.showsCursor = false; config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
    }
    private static func state(_ name: String, output: URL, values: [String: Any] = [:]) throws {
        var fields = values
        fields["phase"] = name; fields["time"] = ProcessInfo.processInfo.systemUptime
        fields["worker_loaded"] = ChatMathRenderer.shared.isLoaded
        fields["typeset_count"] = MathRendering.typesetCount
        try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("math-state.json"), options: .atomic)
        let journal = output.appendingPathComponent("math-phases.jsonl")
        let line = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) + Data([10])
        if FileManager.default.fileExists(atPath: journal.path) {
            let handle = try FileHandle(forWritingTo: journal)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: line)
        } else { try line.write(to: journal) }
    }
    private static func widths(_ window: NSWindow) -> [[String: Double]] {
        descendants(window.contentView!).compactMap { $0 as? MathParagraphHost }.map { host in
            ["viewport": host.bounds.width, "text_container": host.paragraph.textContainer?.containerSize.width ?? 0,
             "document": host.paragraph.frame.width, "height": host.frame.height].mapValues(Double.init)
        }
    }
    private static func awaitInput(_ marker: String, phase: String, output: URL) async throws {
        try state(phase, output: output)
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        while !FileManager.default.fileExists(atPath: output.appendingPathComponent(marker).path) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NSError(domain: "Missing manual input: " + marker, code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private struct ReadingAnchor { let token: String; let y: CGFloat }
    private static func readingAnchor(in window: NSWindow, matching token: String? = nil) -> ReadingAnchor? {
        guard let timeline = scroll(in: window) else { return nil }
        let pattern = try! NSRegularExpression(pattern: "历史段落 [0-9]+：")
        var anchors: [ReadingAnchor] = []
        for view in descendants(window.contentView!).compactMap({ $0 as? LinkTextView }) {
            guard let storage = view.textStorage, let layout = view.layoutManager, let container = view.textContainer else { continue }
            let text = storage.string as NSString
            let ranges = token.map { [text.range(of: $0)] } ?? pattern.matches(in: storage.string, range: NSRange(location: 0, length: text.length)).map(\.range)
            for range in ranges where range.location != NSNotFound {
                let glyph = layout.glyphIndexForCharacter(at: range.location)
                let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let y = view.convert(NSPoint(x: 0, y: rect.minY + view.textContainerOrigin.y), to: timeline.contentView).y - timeline.contentView.bounds.minY
                if token != nil || (y >= 64 && y < timeline.contentView.bounds.height - 64) {
                    anchors.append(ReadingAnchor(token: text.substring(with: range), y: y))
                }
            }
        }
        return anchors.min { $0.y < $1.y }
    }
    private static func selectVisibleMath(in window: NSWindow, output: URL) async throws -> Bool {
        guard let timeline = scroll(in: window) else { return false }
        let clip = timeline.contentView
        let native = descendants(window.contentView!).compactMap { $0 as? LinkTextView }.first { view in
            let rect = view.convert(view.bounds, to: clip)
            guard rect.minY > clip.bounds.minY + 50, rect.maxY < clip.bounds.maxY - 80,
                  let storage = view.textStorage else { return false }
            var hasMath = false
            storage.enumerateAttribute(.mathSource, in: NSRange(location: 0, length: storage.length)) { value, _, _ in if value != nil { hasMath = true } }
            return hasMath
        }
        guard let native else { return false }
        native.passesProseThrough = false
        let focused = window.makeFirstResponder(native)
        native.setSelectedRange(NSRange(location: 0, length: native.string.utf16.count))
        native.needsDisplay = true
        try await Task.sleep(for: .milliseconds(250))
        try await snapshot(window, output: output, name: "math-selected-light")
        let selected = focused && native.selectedRange().length > 0
        native.setSelectedRange(NSRange(location: 0, length: 0))
        return selected
    }
    static func run(runtime: ThreadRuntime, window: NSWindow, output: URL) async throws {
        if CommandLine.arguments.contains("--omp-chat-math-selection-only") {
            CaptureRun.defaults?.set("light", forKey: "appTheme")
            window.appearance = NSAppearance(named: .aqua)
            try await Task.sleep(for: .milliseconds(800))
            let selected = try await selectVisibleMath(in: window, output: output)
            try JSONSerialization.data(withJSONObject: ["status": selected ? "passed" : "failed", "visible_native_selection": selected], options: [.prettyPrinted])
                .write(to: output.appendingPathComponent("math-selection-checks.json"))
            try "Focused selection inspection completed.\n".write(to: output.appendingPathComponent("finish"), atomically: true, encoding: .utf8)
            return
        }
        let samples = Samples()
        let measurementStart = ProcessInfo.processInfo.systemUptime
        MathRendering.paintObserver = { key, milliseconds, requestedAt in
            if requestedAt >= measurementStart, samples.paints[key] == nil { samples.paints[key] = milliseconds }
        }
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                let now = ProcessInfo.processInfo.systemUptime
                samples.ticks.append((now - samples.last) * 1000); samples.last = now
            }
        }
        defer { heartbeat.cancel(); MathRendering.paintObserver = nil }
        try await Task.sleep(for: .milliseconds(500))
        try await snapshot(window, output: output, name: "math-history-dark")
        let start = ProcessInfo.processInfo.systemUptime
        let initialTypesets = MathRendering.typesetCount
        runtime.draft = ComposerDraft(text: "Q_MATH_STREAM")
        runtime.send()
        try state("stream-bottom", output: output)
        try await Task.sleep(for: .seconds(2))
        try await snapshot(window, output: output, name: "math-stream-bottom")
        guard let timeline = scroll(in: window), let document = timeline.documentView else {
            throw NSError(domain: "Chat math acceptance could not find the production timeline", code: 1)
        }
        // The timeline unpins only on real wheel/scroll-phase input. A direct
        // bounds mutation tests neither the user's gesture nor its routing.
        try await awaitInput("math-scrolled", phase: "needs-user-scroll", output: output)
        let scrolledDuringStream = runtime.phase != .idle
        try await Task.sleep(for: .seconds(1))
        let heldY = timeline.contentView.bounds.minY
        let heldAnchor = readingAnchor(in: window)
        try await snapshot(window, output: output, name: "math-reading-start")
        try state("stream-reading-history", output: output, values: ["offset": heldY])
        // Arrival runs on an independent SSE clock, including while scrolled up.
        let deadline = ProcessInfo.processInfo.systemUptime + 35
        while runtime.phase != .idle || MathRendering.isRendering {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NSError(domain: "Chat math stream timed out", code: 1) }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(350))
        let settledY = timeline.contentView.bounds.minY
        let settledAnchor = heldAnchor.flatMap { readingAnchor(in: window, matching: $0.token) }
        let drift = heldAnchor.flatMap { before in settledAnchor.map { abs($0.y - before.y) } } ?? -1
        let streamSeconds = ProcessInfo.processInfo.systemUptime - start
        let streamTypesets = MathRendering.typesetCount - initialTypesets
        let streamingPaints = Array(samples.paints.values)
        let streamingTicks = samples.ticks
        try await snapshot(window, output: output, name: "math-reading-history")
        try state("stream-completed", output: output, values: ["scroll_drift_points": drift])
        timeline.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - timeline.contentView.bounds.height)))
        timeline.reflectScrolledClipView(timeline.contentView)
        try await Task.sleep(for: .milliseconds(350))
        try await snapshot(window, output: output, name: "math-finished-dark")
        let beforeAppearance = MathRendering.typesetCount
        CaptureRun.defaults?.set("light", forKey: "appTheme")
        window.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(350))
        try await snapshot(window, output: output, name: "math-finished-light")
        let appearanceTypesets = MathRendering.typesetCount - beforeAppearance
        let selectedNative = try await selectVisibleMath(in: window, output: output)
        let originalSize = window.frame.size
        let wideGeometry = widths(window)
        let beforeWidth = MathRendering.typesetCount
        window.setContentSize(NSSize(width: 920, height: 760))
        try await Task.sleep(for: .milliseconds(350))
        let narrowGeometry = widths(window)
        try await snapshot(window, output: output, name: "math-narrow-15pt")
        try await awaitInput("math-sidebar-checked", phase: "needs-sidebar-width-check", output: output)
        var horizontalEnds: [Double] = []
        for host in descendants(window.contentView!).compactMap({ $0 as? MathParagraphHost }) where host.hasHorizontalScroller {
            let end = max(0, host.paragraph.frame.width - host.contentView.bounds.width)
            host.contentView.scroll(to: NSPoint(x: end, y: 0)); host.reflectScrolledClipView(host.contentView)
            horizontalEnds.append(Double(abs(end - host.contentView.bounds.minX)))
        }
        try await snapshot(window, output: output, name: "math-narrow-horizontal-end")
        for host in descendants(window.contentView!).compactMap({ $0 as? MathParagraphHost }) {
            host.contentView.scroll(to: .zero); host.reflectScrolledClipView(host.contentView)
        }
        let widthTypesets = MathRendering.typesetCount - beforeWidth
        TypeScale.shared.content = 18
        try await Task.sleep(for: .milliseconds(800))
        try await snapshot(window, output: output, name: "math-narrow-18pt")
        window.setContentSize(NSSize(width: originalSize.width, height: 860))
        TypeScale.shared.content = 15
        CaptureRun.defaults?.set("dark", forKey: "appTheme")
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(500))
        try await snapshot(window, output: output, name: "math-restored-dark")
        let creations = ChatMathRenderer.shared.creationCount
        try state("idle", output: output)
        try await Task.sleep(for: .seconds(ChatMathRenderer.idleSeconds + 2))
        let released = !ChatMathRenderer.shared.isLoaded
        try state("idle-released", output: output)
        func p95(_ numbers: [Double]) -> Double { numbers.sorted()[min(numbers.count - 1, Int(Double(numbers.count) * 0.95))] }
        let result: [String: Any] = [
            "status": released && scrolledDuringStream && drift >= 0 && drift < 8 && appearanceTypesets == 0 && widthTypesets == 0 && selectedNative && !streamingPaints.isEmpty ? "passed" : "needs-review",
            "scope": "Actual native OMP / production chat / independent local SSE arrival. Own WindowServer captures; paint callback precedes screen compositing. Heartbeat is main-run-loop scheduling, not frame rate.",
            "stream_seconds": streamSeconds,
            "formula_request_to_visible_draw_ms": streamingPaints,
            "formula_request_to_visible_draw_p95_ms": streamingPaints.isEmpty ? NSNull() : p95(streamingPaints),
            "main_16ms_heartbeat_p95_ms": streamingTicks.isEmpty ? NSNull() : p95(streamingTicks),
            "main_16ms_heartbeat_max_ms": streamingTicks.max() ?? 0,
            "scroll_drift_points": drift, "appearance_typesets": appearanceTypesets,
            "scroll_offset_drift_points": abs(settledY - heldY),
            "reading_anchor": heldAnchor?.token ?? "missing",
            "reading_anchor_start_y": heldAnchor?.y ?? -1, "reading_anchor_end_y": settledAnchor?.y ?? -1,
            "stream_typesets": streamTypesets,
            "webview_creations_before_idle": creations, "idle_webview_released": released,
            "backing_scale": window.backingScaleFactor, "selection_view_found": selectedNative,
            "real_scroll_during_stream": scrolledDuringStream,
            "wide_geometry": wideGeometry, "narrow_geometry": narrowGeometry,
            "width_only_typesets": widthTypesets, "horizontal_end_error_points": horizontalEnds,
            "unmeasured": ["Physical display change above 2x", "GPU presentation latency", "External model/account latency"]
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("math-checks.json"), options: .atomic)
        try await Task.sleep(for: .seconds(12))
        try "Completed the focused math inspection.\n".write(to: output.appendingPathComponent("finish"), atomically: true, encoding: .utf8)
    }
}
#endif
