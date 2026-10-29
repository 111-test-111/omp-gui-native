import AppKit
import SwiftUI

private struct PreviewTextLayoutFailure: Error, CustomStringConvertible {
    var description: String
}

/// Exercise the actual TextKit/ruler drawing, not just its string model. AppKit
/// may initialize NSApplication internally; no window or event loop is started.
@MainActor enum PreviewTextLayoutChecks {
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw PreviewTextLayoutFailure(description: message) }
    }

    static func run() async throws {
        try await checkSourceLanguageSelection()
        let pane = FrameHostingView(rootView: AnyView(Color.clear))
        pane.frame = NSRect(x: 0, y: 0, width: 480, height: 700)
        try expect(pane.safeAreaRegions.isEmpty && pane.sizingOptions.isEmpty,
                   "The shared chat/preview host added safe-area or intrinsic-size constraints")

        let source = "name: OMP GUI\noptions:\n  deploymentTarget: '26.0'\ntargets:\n  OMPGUI:\n    type: application\n"
            + "    description: '" + String(repeating: "sample words ", count: 80) + "'\n"
            + String(repeating: "    # Sample source line\n", count: 55)
        let host = PreviewTextHost()
        host.appearance = NSAppearance(named: .aqua)
        defer { host.tearDown() }
        let state = PreviewReaderState()
        func update(_ location: FilePreviewLocation? = nil) {
            host.update(url: URL(fileURLWithPath: "/fixture/project.yml"), source: source, revision: "1", location: location,
                        state: state, wraps: state.wrapsLines, findRequest: 0,
                        navigationRequest: state.navigationRequest, onOpen: { _, _ in })
        }
        // Representables receive their first update before they have a frame.
        update()
        resize(host, width: 480)
        try await Task.sleep(for: .milliseconds(100))
        try checkViewport(host, wrapping: false)
        let original = try capture(host)
        try checkPixels(original, points: host.bounds.size)
        if let output = CommandLine.arguments.dropFirst().first,
           let data = original.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: output))
        }

        // Width changes must update the document minimum in both source modes.
        for width: CGFloat in [320, 680] {
            resize(host, width: width)
            try checkViewport(host, wrapping: false)
            let unscrolled = try capture(host)
            try checkPixels(unscrolled, points: host.bounds.size)
            try checkHorizontalScrolling(host, original: unscrolled)
        }
        state.wrapsLines = true
        update()
        resize(host, width: 320)
        try checkViewport(host, wrapping: true)
        try checkPixels(capture(host), points: host.bounds.size)
        state.wrapsLines = false
        update()
        resize(host, width: 480)
        try checkViewport(host, wrapping: false)

        state.navigationRequest += 1
        let location = FilePreviewLocation(line: 50)
        update(location)
        let offset = PreviewSourcePositions.offset(in: source, lineStarts: PreviewSourcePositions.lineStarts(in: source), location: location)
        try expect(host.reader.selectedRange().location == offset, "Source layout lost line navigation after resizing/wrapping")
        try await checkFontChanges(host) { update() }
        try await checkThemeChanges(host, source: source) { update() }

        // A native sibling represents the toolbar/tab strip. A large parent
        // dirty rect must not let the scroll view or ruler paint over its area.
        let canvas = PreviewTextTestCanvas(frame: NSRect(x: 0, y: 0, width: 480, height: 700))
        host.frame = NSRect(x: 0, y: 100, width: 480, height: 600)
        canvas.addSubview(host)
        canvas.layoutSubtreeIfNeeded()
        let composed = try capture(canvas)
        let scale = CGFloat(composed.pixelsWide) / canvas.bounds.width
        let header = composed.colorAt(x: Int(200 * scale), y: Int(20 * scale))?.usingColorSpace(.deviceRGB)
        try expect(header.map { $0.greenComponent > $0.redComponent + 0.2 && $0.greenComponent > $0.blueComponent + 0.2 } == true,
                   "Source/ruler drawing covered a sibling toolbar")
        // Both the source viewport and its native ruler must reveal the
        // surrounding surface, including when its appearance/backdrop changes.
        for (appearance, background) in [
            (NSAppearance.Name.aqua, NSColor(srgbRed: 0.85, green: 0.72, blue: 0.56, alpha: 1)),
            (.darkAqua, NSColor(srgbRed: 0.12, green: 0.16, blue: 0.20, alpha: 1))
        ] {
            canvas.appearance = NSAppearance(named: appearance)
            canvas.background = background
            canvas.needsDisplay = true
            let bitmap = try capture(canvas)
            let expected = background.usingColorSpace(.deviceRGB)!
            for x in [3, 450] {
                let actual = bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(650 * scale))?.usingColorSpace(.deviceRGB)
                try expect(actual.map {
                    abs($0.redComponent - expected.redComponent) < 0.04
                        && abs($0.greenComponent - expected.greenComponent) < 0.04
                        && abs($0.blueComponent - expected.blueComponent) < 0.04
                } == true, "Source or ruler obscured the shared backdrop in \(appearance.rawValue)")
            }
        }
        try expect(NSApp?.windows.contains(where: \.isVisible) != true, "Native layout checks presented a window")
    }

    private static func checkSourceLanguageSelection() async throws {
        let samples = [("Makefile", "include config.mk\n", "include"),
                       ("paper.tex", #"\section{中文 😺}"#, #"\section"#),
                       ("README.md", "# 中文 heading\n\n**bold** and `code`", "# 中文 heading")]
        let host = PreviewTextHost()
        host.appearance = NSAppearance(named: .aqua)
        defer { host.tearDown() }
        for (filename, source, keyword) in samples {
            let state = PreviewReaderState()
            let range = (source as NSString).range(of: keyword)
            // Seed the reader's normal asynchronous restoration; selecting
            // before that restoration would deliberately be overwritten.
            state.source.selectionLocation = range.location
            state.source.selectionLength = range.length
            host.update(url: URL(fileURLWithPath: "/fixture/" + filename), source: source, revision: "1", location: nil,
                        state: state, wraps: false, findRequest: 0, navigationRequest: 0, onOpen: { _, _ in })
            let storage = host.reader.textStorage!
            try expect((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == CGFloat(TypeScale.shared.code),
                       "The \(filename) source size must equal the configured Code size")
            let expected = CodeSyntaxStyle.color(for: .keyword)
            func hasColor() -> Bool {
                let actual = storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
                return actual.map { sameInk($0, expected, host.effectiveAppearance) } == true
            }
            for _ in 0..<50 {
                if hasColor() { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            try expect(hasColor(), "The real native source host left \(filename) monochrome")
            try expect(storage.string == source && host.reader.selectedRange() == range,
                       "Async \(filename) coloring changed source or selection")
        }
    }

    private static func checkFontChanges(_ host: PreviewTextHost, update: () -> Void) async throws {
        let originalName = TypeScale.shared.monospacedFontName
        let originalCode = TypeScale.shared.code
        let originalUI = TypeScale.shared.ui
        let originalContent = TypeScale.shared.content
        defer {
            TypeScale.shared.monospacedFontName = originalName
            TypeScale.shared.code = originalCode
            TypeScale.shared.ui = originalUI
            TypeScale.shared.content = originalContent
            update()
        }
        TypeScale.shared.monospacedFontName = "Menlo"
        update()
        guard let first = host.reader.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
            throw PreviewTextLayoutFailure(description: "Source reader did not install its font")
        }
        let selection = NSRange(location: host.reader.selectedRange().location, length: 12)
        host.reader.setSelectedRange(selection)
        let origin = host.contentView.bounds.origin
        let storage = host.reader.textStorage
        let color = storage?.attribute(.foregroundColor, at: selection.location, effectiveRange: nil) as? NSColor
        TypeScale.shared.monospacedFontName = "Courier"
        update()
        try await Task.sleep(for: .milliseconds(50))
        let changed = host.reader.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        try expect(changed?.familyName == AppFont.monospacedName && changed?.fontName != first.fontName
                   && changed?.pointSize == first.pointSize, "Same-size source font switch did not change the family")
        try expect(host.reader.selectedRange() == selection, "Source font switch lost the selected range")
        try expect(abs(host.contentView.bounds.origin.x - origin.x) < 1 && abs(host.contentView.bounds.origin.y - origin.y) < 1,
                   "Source font switch moved the scroll position")
        try expect(host.reader.textStorage === storage
                   && storage?.attribute(.foregroundColor, at: selection.location, effectiveRange: nil) as? NSColor == color,
                   "Source font switch replaced text storage or syntax colors")

        // A size-only change must bypass the face-revision cache, update the
        // existing reader and remain independent of the other size settings.
        TypeScale.shared.ui = TypeScale.uiRange.upperBound
        TypeScale.shared.content = TypeScale.contentRange.lowerBound
        for size in [TypeScale.codeRange.lowerBound, TypeScale.defaultCode, TypeScale.codeRange.upperBound] {
            TypeScale.shared.code = size
            update()
            let font = storage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            try expect(font?.pointSize == CGFloat(size) && font?.fontName == changed?.fontName,
                       "Source font size must equal Code \(size) pt without a face change")
            try expect(host.reader.textStorage === storage && host.reader.selectedRange() == selection
                       && storage?.attribute(.foregroundColor, at: selection.location, effectiveRange: nil) as? NSColor == color,
                       "A size-only update replaced source storage, syntax colors or selection")
            try checkViewport(host, wrapping: false)
        }
    }

    /// The source reader shares its syntax colors with chat code. Changing the
    /// shared theme must recolor the existing document in place: same storage,
    /// same source, selection and scroll, while the cached inks keep resolving
    /// for the appearance that actually draws the text.
    private static func checkThemeChanges(_ host: PreviewTextHost, source: String, update: () -> Void) async throws {
        let originalTheme = CodeHighlighting.shared.theme
        let originalAppearance = host.appearance
        let light = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!
        defer {
            CodeHighlighting.shared.theme = originalTheme
            host.appearance = originalAppearance
            update()
        }
        let spans = PreviewSyntaxHighlighter.spans(in: source, extension: "yml")
        guard let comment = spans.first(where: {
                  if case .comment = $0.token { return true }
                  return false
              }), let storage = host.reader.textStorage else {
            throw PreviewTextLayoutFailure(description: "The source fixture has no comment token to recolor")
        }
        host.appearance = light
        update()
        // This small fixture must have a real scroll range after the font probe.
        // Noncontiguous production layout intentionally leaves unseen lines lazy.
        host.reader.layoutManager!.ensureLayout(for: host.reader.textContainer!)
        host.reader.sizeToFit()
        host.layoutSubtreeIfNeeded()
        let selection = NSRange(location: comment.range.location, length: min(comment.range.length, 12))
        host.reader.setSelectedRange(selection)
        let target = host.contentView.constrainBoundsRect(NSRect(origin: NSPoint(x: 48, y: 120),
                                                                size: host.contentView.bounds.size))
        host.contentView.scroll(to: target.origin)
        host.reflectScrolledClipView(host.contentView)
        let origin = host.contentView.bounds.origin
        try expect(origin.x > 20 && origin.y > 20, "The source fixture did not expose a real horizontal and vertical scroll range")
        func storedInk() -> NSColor? {
            guard NSMaxRange(comment.range) <= storage.length else { return nil }
            return storage.attribute(.foregroundColor, at: comment.range.location, effectiveRange: nil) as? NSColor
        }

        var inks: [String] = []
        for theme in CodeHighlightTheme.allCases {
            CodeHighlighting.shared.theme = theme
            update()
            let expected = CodeSyntaxStyle.color(for: .comment, theme: theme)
            var applied = storedInk()
            for _ in 0..<50 {
                if let applied, sameInk(applied, expected, host.effectiveAppearance) { break }
                try await Task.sleep(for: .milliseconds(20))
                applied = storedInk()
            }
            try expect(applied.map { sameInk($0, expected, host.effectiveAppearance) } == true,
                "The source reader did not apply \(theme.title) to unchanged source")
            try expect(host.reader.textStorage === storage && storage.string == source,
                "A theme switch replaced the source document")
            try expect(host.reader.selectedRange() == selection, "A theme switch lost the selected source range")
            let moved = host.contentView.bounds.origin
            try expect(abs(moved.x - origin.x) < 1 && abs(moved.y - origin.y) < 1,
                "A \(theme.title) switch moved the source scroll position: \(origin) → \(moved)")
            inks.append(applied.map { inkKey($0, light) } ?? "")
        }
        try expect(Set(inks).count == CodeHighlightTheme.allCases.count,
            "Every theme resolved the same source comment color")

        // The recolored attribute must keep both appearances, without a reset.
        let last = CodeHighlightTheme.allCases[CodeHighlightTheme.allCases.count - 1]
        CodeHighlighting.shared.theme = last
        update()
        host.appearance = dark
        update()
        let expected = CodeSyntaxStyle.color(for: .comment, theme: last)
        let darkInk = storedInk()
        try expect(darkInk.map { sameInk($0, expected, dark) } == true,
            "Dark source appearance ignored the selected theme's dark palette")
        try expect(darkInk.map { inkKey($0, dark) } != inks.last,
            "Dark source appearance reused the light syntax palette")
        try expect(storage.string == source, "An appearance switch replaced the source document")
        try expect(host.reader.selectedRange() == selection, "An appearance switch lost the selected source range")
        let moved = host.contentView.bounds.origin
        try expect(abs(moved.x - origin.x) < 1 && abs(moved.y - origin.y) < 1,
            "An appearance switch moved the source scroll position")
    }

    private static func inkComponents(_ color: NSColor, _ appearance: NSAppearance) -> (CGFloat, CGFloat, CGFloat) {
        var converted = color
        appearance.performAsCurrentDrawingAppearance { converted = color.usingColorSpace(.sRGB) ?? color }
        let rgb = converted.usingColorSpace(.sRGB) ?? converted
        return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }

    private static func sameInk(_ lhs: NSColor, _ rhs: NSColor, _ appearance: NSAppearance) -> Bool {
        let a = inkComponents(lhs, appearance), b = inkComponents(rhs, appearance)
        return abs(a.0 - b.0) < 0.002 && abs(a.1 - b.1) < 0.002 && abs(a.2 - b.2) < 0.002
    }

    private static func inkKey(_ color: NSColor, _ appearance: NSAppearance) -> String {
        let value = inkComponents(color, appearance)
        return String(format: "%.3f,%.3f,%.3f", value.0, value.1, value.2)
    }

    private static func resize(_ host: PreviewTextHost, width: CGFloat) {
        host.setFrameSize(NSSize(width: width, height: 600))
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
    }

    private static func checkViewport(_ host: PreviewTextHost, wrapping: Bool) throws {
        let reader = host.reader
        let insets = host.contentView.contentInsets
        let width = host.contentView.bounds.width - insets.left - insets.right
        let height = host.contentView.bounds.height - insets.top - insets.bottom
        try expect(reader.frame.width >= width - 1 && reader.minSize.width >= width - 1 && reader.minSize.height >= height - 1,
                   "The document did not cover its actual viewport after native resizing")
        if wrapping {
            try expect(abs(reader.frame.width - width) < 1 && abs((reader.textContainer?.containerSize.width ?? 0) - (width - 32)) < 1,
                       "Wrapped source used the gutter width as part of its text viewport")
        }
        try expect(reader.textContainer?.widthTracksTextView == wrapping && reader.layoutManager?.allowsNonContiguousLayout == true,
                   "Source resizing changed wrapping mode or forced contiguous document layout")
        try expect(reader.frame.width.isFinite && reader.frame.height.isFinite && reader.frame.width < 10_000_000,
                   "The source view acquired an unbounded frame")
    }

    private static func checkHorizontalScrolling(_ host: PreviewTextHost, original: NSBitmapImageRep) throws {
        let clip = host.contentView
        let origin = clip.bounds.origin
        defer {
            clip.scroll(to: origin)
            host.reflectScrolledClipView(clip)
        }
        let scale = CGFloat(original.pixelsWide) / host.bounds.width
        guard let ruler = host.verticalRulerView else {
            throw PreviewTextLayoutFailure(description: "The scrolling fixture has no line-number gutter")
        }
        let gutter = host.convert(ruler.bounds, from: ruler).intersection(host.bounds)
        let gutterStart = max(1, Int(gutter.minX * scale))
        let gutterEnd = Int((gutter.maxX - 2) * scale)
        try expect(gutterEnd - gutterStart > 20, "The scrolling fixture has no visible line-number gutter")
        for offset: CGFloat in [32, 240] {
            let proposed = NSRect(x: origin.x + offset, y: origin.y, width: clip.bounds.width, height: clip.bounds.height)
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
            host.reflectScrolledClipView(clip)
            try expect(clip.bounds.minX > origin.x + 20, "The fixture did not actually scroll horizontally")
            let scrolled = try capture(host)
            for y in 0..<min(original.pixelsHigh, scrolled.pixelsHigh) {
                for x in gutterStart..<gutterEnd {
                    guard let before = original.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          let after = scrolled.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                        throw PreviewTextLayoutFailure(description: "The gutter pixels could not be read")
                    }
                    try expect(abs(before.alphaComponent - after.alphaComponent) < 0.01
                               && abs(before.redComponent - after.redComponent) < 0.01
                               && abs(before.greenComponent - after.greenComponent) < 0.01
                               && abs(before.blueComponent - after.blueComponent) < 0.01,
                               "Horizontal scrolling painted source over the line-number gutter at (\(x), \(y)); clip \(clip.frame), insets \(clip.contentInsets)")
                }
            }
        }
    }

    private static func capture(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw PreviewTextLayoutFailure(description: "Native source rasterization failed")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private static func checkPixels(_ bitmap: NSBitmapImageRep, points: NSSize) throws {
        try expect(bitmap.pixelsWide >= Int(points.width) && bitmap.pixelsHigh >= Int(points.height), "The source bitmap collapsed")
        try expect(ink(bitmap, left: 2, right: 40, points: points) > 30, "The source gutter did not paint its line numbers")
        try expect(ink(bitmap, left: 62, right: min(points.width - 5, 280), points: points) > 100,
                   "The source gutter background erased the actual text pixels")
    }

    private static func ink(_ bitmap: NSBitmapImageRep, left: CGFloat, right: CGFloat, points: NSSize) -> Int {
        let scale = CGFloat(bitmap.pixelsWide) / points.width
        let start = max(0, min(bitmap.pixelsWide, Int(left * scale)))
        let end = max(start, min(bitmap.pixelsWide, Int(right * scale)))
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in start..<end {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.1,
                   min(color.redComponent, color.greenComponent, color.blueComponent) < 0.85 { count += 1 }
            }
        }
        return count
    }
}

private final class PreviewTextTestCanvas: NSView {
    var background: NSColor = .systemGreen
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
    }
}
