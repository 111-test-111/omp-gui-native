import AppKit
import Foundation

private struct PreviewWrapPerformanceFailure: Error, CustomStringConvertible {
    var description: String
}

/// Use the production TextKit stack offscreen. No window, application launch,
/// or event loop is needed to verify viewport-only layout and source reflow.
@main @MainActor enum PreviewWrapPerformanceChecks {
    static func main() async throws { try await run() }
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw PreviewWrapPerformanceFailure(description: message) }
    }

    static func run() async throws {
        let longLine = "\tlet value = \"" + String(repeating: "long_column_", count: 22) + " 中文 😺 e\u{301}\"\n"
        let source = String(repeating: longLine, count: 5_500)
        try expect(source.utf8.count < 2 * 1_024 * 1_024, "The fixture exceeded the preview's complete-source budget")
        let host = PreviewTextHost()
        defer { host.tearDown() }
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        let state = PreviewReaderState()
        let url = URL(fileURLWithPath: "/fixture/wrap-performance.swift")
        func update(wrapping: Bool) {
            state.wrapsLines = wrapping
            host.update(url: url, source: source, revision: "1", location: nil,
                        state: state, wraps: wrapping,
                        findRequest: 0, navigationRequest: 0, onOpen: { _, _ in })
            host.layoutSubtreeIfNeeded()
        }
        func draw() throws {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw PreviewWrapPerformanceFailure(description: "Source viewport rasterization failed")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        update(wrapping: false)
        // Include the production asynchronous syntax pass before timing reflow.
        try await Task.sleep(for: .milliseconds(200))
        try draw()
        guard let layout = host.reader.layoutManager, let container = host.reader.textContainer,
              let storage = host.reader.textStorage else {
            throw PreviewWrapPerformanceFailure(description: "The production source text stack was not retained")
        }
        try expect(layout.allowsNonContiguousLayout && !layout.backgroundLayoutEnabled,
                   "Source preview scheduled whole-document layout on the main thread during idle time")
        try expect(storage.layoutManagers.count == 1, "Wrap performance duplicated the retained TextKit layout cache")

        // Unicode and tabs must remain real source, rather than a shortened
        // display string. The selected composed character survives both modes.
        let selected = (source as NSString).range(of: "😺 e\u{301}")
        host.reader.setSelectedRange(selected)
        var onTimes: [Double] = []
        var offTimes: [Double] = []
        for _ in 0..<3 {
            for wrapping in [true, false] {
                let start = ProcessInfo.processInfo.systemUptime
                update(wrapping: wrapping)
                try draw()
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                if wrapping { onTimes.append(elapsed) } else { offTimes.append(elapsed) }
                try expect(host.reader.string == source && host.reader.selectedRange() == selected,
                           "Wrapping replaced source text or lost its Unicode selection")
                try expect(layout.allowsNonContiguousLayout && !layout.backgroundLayoutEnabled,
                           "Changing wrap mode re-enabled idle whole-file layout")
                try expect(layout.firstUnlaidCharacterIndex() < storage.length / 2,
                           "Changing wrapping laid out the complete large file instead of its viewport")
            }
        }
        // A long unwrapped line must be reachable horizontally, including its
        // Unicode suffix after tabs. Its character/glyph geometry is native.
        let suffix = (source as NSString).range(of: "中文 😺 e\u{301}")
        let glyphs = layout.glyphRange(forCharacterRange: suffix, actualCharacterRange: nil)
        let suffixRect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        try expect(suffixRect.minX > host.contentView.bounds.width,
                   "Unwrapped Unicode/tab source was clipped to the viewport width")
        try expect(host.reader.frame.width >= suffixRect.maxX + host.reader.textContainerInset.width,
                   "The horizontal document frame did not include the complete source line")
        host.contentView.scroll(to: NSPoint(x: suffixRect.minX - 64, y: 0))
        host.reflectScrolledClipView(host.contentView)
        try draw()
        try expect(host.contentView.bounds.origin.x > 0, "The source suffix could not be scrolled into view")

        // Routine SwiftUI updates must preserve the same viewport/glyph cache.
        let firstUnlaid = layout.firstUnlaidCharacterIndex()
        for _ in 0..<20 { update(wrapping: false) }
        try expect(layout.firstUnlaidCharacterIndex() == firstUnlaid,
                   "Unrelated representable updates invalidated native source layout")
        try expect(NSApp?.windows.contains(where: \.isVisible) != true,
                   "Wrap performance checks displayed an application window")

        let onMedian = onTimes.sorted()[onTimes.count / 2]
        let offMedian = offTimes.sorted()[offTimes.count / 2]
        // Keep the guard broad enough for shared CI/load; a half-second native
        // wrap-off stall remains a failure. Printed medians show finer changes.
        try expect(offMedian < 0.25, "Returning to unwrapped source blocked viewport drawing for \(offMedian) seconds")
        print(String(format: "Source reflow checks: %d bytes, wrap %.1f ms, unwrap %.1f ms; lazy native layout, Unicode/tab access and selection passed",
                     source.utf8.count, onMedian * 1_000, offMedian * 1_000))
    }
}
