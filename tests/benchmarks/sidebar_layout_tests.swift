import AppKit
import SwiftUI
@testable import OMPGUI

private struct SidebarBenchmarkContent: View {
    let source: String
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                MarkdownView(text: source)
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity)
            }
            TextField("", text: .constant("Native composer content"))
                .padding(16)
        }
    }
}

@main private enum SidebarLayoutBenchmark {
    @MainActor private static func paragraphs(in view: NSView) -> [LinkTextView] {
        (view as? LinkTextView).map { [$0] } ?? view.subviews.flatMap { paragraphs(in: $0) }
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        let source = (0..<80).map { index in
            "## Section \(index)\n\nA long reply with **formatted text**, 中文段落和 Unicode 👩🏽‍💻. Sidebar motion keeps `inline code` and native selection stable.\n\n- The first item wraps at narrow widths.\n- The second item preserves indentation and enough text to occupy several lines."
        }.joined(separator: "\n\n")
        let baseline = FrameHostingView(rootView: AnyView(SidebarBenchmarkContent(source: source)))
        let candidate = FrameHostingView(rootView: AnyView(SidebarBenchmarkContent(source: source)))
        let clip = SidebarChatClip(chat: candidate)
        func window(_ content: NSView) -> NSWindow {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 700),
                                 styleMask: .borderless, backing: .buffered, defer: false)
            value.isReleasedWhenClosed = false
            value.contentView = content
            return value
        }
        let previous = window(baseline), improved = window(clip)
        defer { previous.close(); improved.close() }
        clip.layOutChat(width: 940, height: 700)
        baseline.layoutSubtreeIfNeeded(); clip.layoutSubtreeIfNeeded()
        precondition(!paragraphs(in: baseline).isEmpty && !paragraphs(in: candidate).isEmpty,
                     "The offscreen benchmark must lay out actual native Markdown views")

        var samples: [[String: Any]] = []
        let directions: [(CGFloat, CGFloat)] = [(940, 660), (660, 940)]
        for _ in 0..<3 {
            for (from, to) in directions {
                var values: [String: Any] = ["from": from, "to": to, "frames": 28]
                for useClip in [false, true] {
                    let active = useClip ? improved : previous
                    active.setContentSize(NSSize(width: from, height: 700))
                    if useClip { clip.layOutChat(width: from, height: 700) }
                    active.contentView!.layoutSubtreeIfNeeded()
                    var nativeWidths: Set<CGFloat> = []
                    let start = DispatchTime.now().uptimeNanoseconds
                    for frame in 1...28 {
                        let width = from + (to - from) * CGFloat(frame) / 28
                        active.setContentSize(NSSize(width: width, height: 700))
                        if useClip { clip.layOutChat(width: to, height: 700) }
                        active.contentView!.layoutSubtreeIfNeeded()
                        for paragraph in paragraphs(in: useClip ? candidate : baseline) {
                            nativeWidths.insert(paragraph.textContainer!.containerSize.width)
                        }
                    }
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    let key = useClip ? "fixed_host" : "resized_host"
                    values[key + "_ms"] = elapsed
                    values[key + "_native_widths"] = nativeWidths.count
                    precondition(useClip ? nativeWidths.count == 1 : nativeWidths.count > 1,
                                 "Sidebar comparison did not exercise its real content-layout path")
                }
                samples.append(values)
            }
        }
        let result: [String: Any] = [
            "scope": "offscreen Markdown/composer native host layout; includes the destination reflow; excludes drawing, GPU presentation and complete GUI interaction",
            "source_utf8_bytes": source.utf8.count, "samples": samples,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: CaptureRun.outputDirectory!.appendingPathComponent("sidebar-layout.json"))
        for sample in samples { print(sample) }
        precondition(!previous.isVisible && !improved.isVisible, "Benchmark displayed a GUI window")
    }
}
