import AppKit
import SwiftUI
@testable import OMPGUI

struct CheckFailure: Error, CustomStringConvertible { let description: String }
@MainActor func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

@MainActor
func attributed(_ source: String, size: CGFloat = 15) -> NSAttributedString {
    let out = NSMutableAttributedString()
    let parsed = MarkdownInline.parse(source)
    for run in parsed.runs {
        if let formula = run[MarkdownFormulaAttribute.self] {
            out.append(MathRendering.attributed(formula, pointSize: size, color: .labelColor))
        } else {
            out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor]))
        }
    }
    return out
}

@MainActor
func waitForMath() async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 30
    while MathRendering.isRendering {
        try expect(ProcessInfo.processInfo.systemUptime < deadline, "Shared MathJax job timed out")
        try await Task.sleep(for: .milliseconds(5))
    }
    await Task.yield()
}

@MainActor final class Layout {
    let view = LinkTextView()
    var storage: NSTextStorage { view.textStorage! }
    var manager: NSLayoutManager { view.layoutManager! }
    var container: NSTextContainer { view.textContainer! }
    init(_ text: NSAttributedString) { view.render(text) }
    func measure(_ width: CGFloat) -> NSSize {
        view.wrappingWidth = width
        let height = view.height(forWidth: width)
        let expanded = MathRendering.overflowWidth(storage: storage, layout: manager, container: container, minimum: width)
        view.frame = NSRect(x: 0, y: 0, width: expanded, height: height)
        return NSSize(width: expanded, height: height)
    }
}

@MainActor
func snapshot(root: URL, dark: Bool) async throws {
    let examples = [
        "若把 $x,z$ **jointly minimize**，",
        "**失败：** $x>0$ 明明严格可行。",
        "**符号模板：**先将 inequality 化成 $g_i \\le 0$。",
        "短公式 $x_i^2 + \\sqrt{1+x^2}$ 与中文 English 正文对齐。",
        "高分数 $\\frac{a+b}{c+d}$，下一行仍保持正常段落间距。",
        #"量子相位 $F_2\ket\chi=\frac1{\sqrt2}(e^{\ii\pi/4}\ket0+e^{-\ii\pi/4}\ket1)$。"#,
        "长公式 $" + (1...20).map { "a_{\($0)}" }.joined(separator: "+") + "=S$，后续正文仍按可见宽度重排。",
        "代码 `a_b` 与公式 $a_b$；硬换行  \n下一行。",
        "未知命令 $\\unknownMacro{x}$；中文 $\\text{中文}$ 保留原文。",
        "未完成 $\\frac{a_b}{",
    ]
    for source in examples { _ = attributed(source) }
    _ = MathRendering.result(for: MarkdownFormula(source: "$$\\sum_{i=1}^{n} x_i^2$$", latex: "\\sum_{i=1}^{n} x_i^2", mode: .display, complete: true), pointSize: 18)
    try await waitForMath()
    var png: Data?
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        let width = 1120, height = 680
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: width, height: height)
        let cg = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        cg.translateBy(x: 0, y: CGFloat(height)); cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        NSColor.textBackgroundColor.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (x, available) in [(CGFloat(24), CGFloat(660)), (760, 280)] {
            var y: CGFloat = 24
            for source in examples {
                let layout = Layout(LinkParagraphView.attributed(source: source, pointSize: 15, dimmed: false))
                let size = layout.measure(available)
                cg.saveGState(); cg.clip(to: NSRect(x: x, y: y, width: available, height: size.height))
                layout.manager.drawGlyphs(forGlyphRange: layout.manager.glyphRange(for: layout.container), at: NSPoint(x: x, y: y))
                cg.restoreGState()
                y += size.height + 20
            }
            let formula = MarkdownFormula(source: "$$\\sum_{i=1}^{n} x_i^2$$", latex: "\\sum_{i=1}^{n} x_i^2", mode: .display, complete: true)
            let text = NSMutableAttributedString(attributedString: MathRendering.attributed(formula, pointSize: 18, color: .labelColor))
            let style = NSMutableParagraphStyle(); style.alignment = .center
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            let layout = Layout(text); _ = layout.measure(available)
            layout.manager.drawGlyphs(forGlyphRange: layout.manager.glyphRange(for: layout.container), at: NSPoint(x: x, y: y))
        }
        png = bitmap.representation(using: .png, properties: [:])
    }
    try png!.write(to: root.appendingPathComponent("math-\(dark ? "dark" : "light").png"))
}

@MainActor
func checks() async throws {
    _ = NSApplication.shared
    let root = CaptureRun.outputDirectory!
    let fixture = CommandLine.arguments.firstIndex(of: "--fixture")!
    ChatMathRenderer.shared.resourceRoot = URL(fileURLWithPath: CommandLine.arguments[fixture + 1], isDirectory: true)
    // A first capture must contain the same ink as a repeat after its font has
    // loaded. A nonempty image alone misses operators, braces and indicator 1s.
    for latex in [#"\sum_{i=1}^n x_i^2"#, #"\bm{\alpha+x}"#, #"\mathbbm{1}_A"#, #"\mathds{1}_A"#, #"\begin{dcases}x&x>0\\0&x\le0\end{dcases}"#] {
        let input = MarkdownFormula(source: "$$\(latex)$$", latex: latex, mode: .display, complete: true)
        let first = try await ChatMathRenderer.shared.render([input], pointSize: 15, scale: 2)[0]
        let repeated = try await ChatMathRenderer.shared.render([input], pointSize: 15, scale: 2)[0]
        try expect(first != nil && repeated != nil, "A first-use font failed: \(latex)")
        try expect(first!.size == repeated!.size && first!.mask.dataProvider!.data! as Data == repeated!.mask.dataProvider!.data! as Data,
                   "First-use fonts lost formula ink: \(latex)")
    }
    let inline = ["$x_i^2$", "\\(x_i^2\\)", "$\\frac{a+b}{c+d}$", "**value $a_b$**", "[value $x$](https://example.com)"]
    for source in inline {
        let parsed = MarkdownInline.parse(source)
        try expect(parsed.runs.contains { $0[MarkdownFormulaAttribute.self]?.complete == true }, "Formula delimiters were not recognized: \(source)")
        try expect(String(parsed.characters).contains("$a_b$") || !source.contains("a_b"), "Markdown altered TeX underscores")
    }
    for source in ["`$x$`", "``$x$``", "\\$x$", "Cost $20 and $30.", "[link](https://example.com/$x$)", "https://example.com/$x$", "<https://example.com/$x$>"] {
        try expect(!MarkdownMath.contains(source), "Code, currency or a URL became a formula: \(source)")
    }
    try expect(MarkdownMath.spans(in: "Cost $20 plus $x$.").count == 1, "Currency swallowed a later formula")
    try expect(MarkdownMath.spans(in: #"\\$x$ and \\\(y\)"#).count == 2, "Escape parity changed math delimiters")
    try expect(MarkdownMath.spans(in: String(repeating: "\\", count: 100_000) + "$x$").count == 1, "Long escaped input lost its final formula")
    let pending = "**Before $\\frac{a_b}{"
    let streamed = MarkdownInline.parse(pending, streaming: true)
    let unfinished = streamed.runs.compactMap { $0[MarkdownFormulaAttribute.self] }.first!
    try expect(unfinished.source == "$\\frac{a_b}{" && !unfinished.complete, "Streaming repair changed unfinished TeX")
    try await waitForMath()
    let before = MathRendering.typesetCount
    _ = MathRendering.result(for: unfinished, pointSize: 15)
    try await waitForMath()
    try expect(MathRendering.typesetCount == before, "Unclosed math triggered typesetting")

    let blockSources = ["$$\\frac{a}{b}$$", "\\[\n\\sum_{i=1}^{n}x_i\n\\]", "> \\[\n> x^2\n> \\]", "- item\n  $$\n  x_i^2\n  $$\n\nAfter", "| value |\n| --- |\n| $|x|$ |\n\n$$x$$", "Intro\n\n$$\nx^2", "```latex\n$$x$$\n```", "    $$x$$", "- item\n  ```latex\n  $$\n  x_i\n  ```\nAfter", "Intro\n$$x$$ trailing prose\nAfter", "$$\nx^2\n$$ trailing prose\nAfter\n\n# Next\n\nMore", "Intro\n\n\\[\nx_i^2\n\\] trailing prose\nAfter\n\n# Next\n\nMore"]
    guard case .math(let block) = MarkdownParser.parse(blockSources[0]).first else { throw CheckFailure(description: "Display formula became prose") }
    try expect(block.complete && block.latex == "\\frac{a}{b}", "Display source was lost")
    guard case .table(_, let rows, _) = MarkdownParser.parse(blockSources[4]).first else { throw CheckFailure(description: "Table disappeared") }
    try expect(rows == [["$|x|$"]], "Pipes inside math split table cells")
    guard case .list(_, _, let items) = MarkdownParser.parse(blockSources[8]).first,
          case .code(_, let body) = items.first?.children.first else { throw CheckFailure(description: "List code fence became math") }
    try expect(body == "$$\nx_i", "Math changed fenced code in a list")
    for source in blockSources {
        var previous: (text: String, parse: MarkdownParser.Parse)?
        var text = ""
        for character in source {
            text.append(character)
            let incremental = MarkdownParser.parse(text, extending: previous)
            try expect(incremental.blocks == MarkdownParser.parse(text), "Streaming differs at \(text.debugDescription)")
            previous = (text, incremental)
        }
    }
    for source in ["$$x_i^2$$", "value $\\frac{a}{b}$", "value \\(x_i^2\\)"] {
        try expect(MessageText.plain(source) == source, "Message copy changed TeX: \(source)")
    }
    let multiline = "$$\n\\begin{aligned}a &= b+c \\\\\n d &= e+f\\end{aligned}\n$$"
    try expect(ProseReflow.reflowed(multiline) == multiline && MessageText.plain(multiline) == multiline, "Whole-message copy reflowed formula source")
    let formula = MarkdownFormula(source: "$\\frac{a+b}{c+d}$", latex: "\\frac{a+b}{c+d}", mode: .inline, complete: true)
    let adjacent = "$x$$x$ and $y$$z$"
    let adjacentText = attributed(adjacent)
    try expect(adjacentText.string.filter { $0 == "\u{FFFC}" }.count == 4 && MathRendering.exported(adjacentText).string == adjacent, "Adjacent formulas were merged or lost during copy")
    let repeated = MathRendering.attributed(formula, pointSize: 15, color: .labelColor)
    let repeatedSelection = NSMutableAttributedString(attributedString: repeated)
    repeatedSelection.append(repeated)
    try expect(MathRendering.exported(repeatedSelection).string == formula.source + formula.source, "Adjacent equal attachments lost a formula during copy")
    try await waitForMath()
    let cachedBefore = MathRendering.typesetCount
    for _ in 0..<100 { _ = MathRendering.result(for: formula, pointSize: 16) }
    try await waitForMath()
    try expect(MathRendering.typesetCount - cachedBefore == 1, "Repeated formula typeset again")
    for latex in ["\\unknownMacro{x}", "", String(repeating: "{", count: 70)] {
        let input = MarkdownFormula(source: "$\(latex)$", latex: latex, mode: .inline, complete: true)
        _ = MathRendering.result(for: input, pointSize: 15)
        try await waitForMath()
        if case .failure = MathRendering.result(for: input, pointSize: 15) {} else { throw CheckFailure(description: "Unsupported input silently dropped content") }
        let fallback = MathRendering.attributed(input, pointSize: 15, color: .labelColor)
        try expect(MathRendering.exported(fallback).string == input.source, "Error fallback lost original TeX")
        try expect(fallback.attribute(.attachment, at: 0, effectiveRange: nil) == nil
                   && fallback.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == NSFont.systemFont(ofSize: 15),
                   "Unsupported formulas must use ordinary prose text")
    }
    for size: CGFloat in [12, 15, 18, 22] {
        let copySource = "中文 $\\frac{a+b}{c+d}$ English $x_i^2$ e\u{301}，继续检查同一段正文的换行与基线。"
        let text = attributed(copySource, size: size)
        let export = MathRendering.exported(text)
        try expect(export.string == copySource, "Selected math copy lost Unicode or delimiters")
        let rtf = try export.data(from: NSRange(location: 0, length: export.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let pasted = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        try expect(pasted.string == export.string, "RTF copy lost TeX")
        try await waitForMath()
        let layout = Layout(text)
        let wide = layout.measure(520), narrow = layout.measure(140)
        let restored = layout.measure(520)
        try expect(narrow.height > wide.height && restored == wide, "Formula paragraph did not reflow at \(size) pt: wide=\(wide), narrow=\(narrow), restored=\(restored)")
    }
    let long = Layout(attributed("定义 $" + (1...25).map { "a_{\($0)}" }.joined(separator: "+") + "=S$，正文仍重排。"))
    try await waitForMath()
    let expanded = long.measure(140)
    try expect(expanded.width > 140 && long.container.containerSize.width == 140, "An oversized attachment clipped or widened prose layout")
    try await snapshot(root: root, dark: false); try await snapshot(root: root, dark: true)
    try await imageChecks(root: root)
    try await widthChecks(root: root)
    print("Math checks passed: native TextKit + shared offline MathJax, parsing/copy, alpha, centre alignment, tint/selection, size/scale, cache and idle release.")
}
@MainActor private func imageChecks(root: URL) async throws {
    func formula(_ latex: String) -> MarkdownFormula { MarkdownFormula(source: "$\(latex)$", latex: latex, mode: .inline, complete: true) }
    func image(_ latex: String, size: CGFloat = 15, scale: CGFloat = 2) async throws -> ChatMathRenderer.Image {
        let input = formula(latex)
        _ = MathRendering.result(for: input, pointSize: size, scale: scale)
        try await waitForMath()
        guard case .ready(let image) = MathRendering.result(for: input, pointSize: size, scale: scale) else {
            throw CheckFailure(description: "MathJax failed valid input: \(latex); worker: \(MathRendering.lastFailure ?? "none")")
        }
        return image
    }
    func pixels(_ image: ChatMathRenderer.Image, color: NSColor, selected: Bool) throws -> [UInt8] {
        let width = image.mask.width, height = image.mask.height
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.scaleBy(x: image.scale, y: image.scale)
        image.draw(at: .zero, context: context, flipped: false, color: color, selected: selected)
        let bytes = Array(UnsafeBufferPointer(start: context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4), count: width * height * 4))
        try expect(bytes[3] == 0 && bytes[(width * height - 1) * 4 + 3] == 0, "Formula image has an opaque background")
        try expect(stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 200 }, "Formula mask inverted or contains no ink")
        return bytes
    }
    let latex = #"\frac{a+b}{\sqrt{1+x^2}}"#
    let raster = try await image(latex)
    var notation: [ChatMathRenderer.Image] = []
    for sample in MathCompatibility.samples {
        notation.append(try await image(sample.latex))
        let input = formula(sample.latex)
        try expect(MathRendering.exported(MathRendering.attributed(input, pointSize: 15, color: .labelColor)).string == input.source,
                   "Notation copy lost original TeX: \(sample.name)")
    }
    // The shared worker retains loaded extensions across formulas. Exercise the
    // same inputs again without the image cache, after every package has loaded.
    let warmNotation = try await ChatMathRenderer.shared.render(MathCompatibility.samples.map { formula($0.latex) }, pointSize: 15, scale: 2)
    var geometryErrors: [String] = []
    for (index, sample) in MathCompatibility.samples.enumerated() {
        guard let warm = warmNotation[index] else { throw CheckFailure(description: "Warm notation failed: \(sample.name)") }
        if warm.size != notation[index].size || abs(warm.descent - notation[index].descent) >= 0.01 {
            geometryErrors.append("\(sample.name), cold=\(notation[index].size)/\(notation[index].descent)@\(notation[index].scale), warm=\(warm.size)/\(warm.descent)@\(warm.scale)")
            for (label, image) in [("cold", notation[index]), ("warm", warm)] {
                let bytes = try pixels(image, color: .systemBlue, selected: false)
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.mask.width, pixelsHigh: image.mask.height,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: image.mask.width * 4, bitsPerPixel: 32)!
                bytes.withUnsafeBytes { _ = memcpy(bitmap.bitmapData!, $0.baseAddress!, bytes.count) }
                try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("notation-\(sample.name)-\(label).png"))
            }
        }
    }
    try expect(geometryErrors.isEmpty, "Loaded extensions changed notation geometry: \(geometryErrors)")
    let division = try await image(#"a\div b"#), arithmetic = try await image(#"a\mathbin{÷}b"#)
    try expect(division.size == arithmetic.size && division.mask.dataProvider!.data! as Data == arithmetic.mask.dataProvider!.data! as Data,
               "Physics changed the arithmetic division symbol")
    let defaults = try await ChatMathRenderer.shared.render([formula(#"\renewcommand{\ii}{j}\ii"#), formula(#"\ii"#)], pointSize: 15, scale: 2)
    let imaginary = try await image(#"\mathrm{i}"#)
    try expect(defaults.allSatisfy { $0 != nil } && defaults[1]!.size == imaginary.size,
               "A local definition replaced the configured imaginary-unit default")
    print("Native notation compatibility: \(MathCompatibility.samples.count) cold/warm samples passed.")
    for size: CGFloat in [12, 15, 18, 22] {
        let image = try await image(latex, size: size)
        let text = MathRendering.attributed(formula(latex), pointSize: size, color: .labelColor)
        let attachment = text.attribute(.attachment, at: 0, effectiveRange: nil) as! NSTextAttachment
        try expect(abs(attachment.bounds.minY + image.descent + image.axis - NSFont.systemFont(ofSize: size).capHeight / 2) < 0.01, "Inline mathematical axis is not aligned with native text")
    }
    // Compare the actual first x's alpha pixels, after the native baseline
    // transform. Punctuation/scripts must not move x up or down in the line.
    let x = try await image("x")
    func firstGlyphInk(_ image: ChatMathRenderer.Image) -> ClosedRange<CGFloat> {
        let bytes = image.mask.dataProvider!.data! as Data
        let columns = min(image.mask.width, Int((x.size.width - 1) * image.scale))
        var top = image.mask.height, bottom = 0
        for y in 0..<image.mask.height {
            for col in 0..<columns where bytes[y * image.mask.bytesPerRow + col] > 32 {
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        let origin = NSFont.systemFont(ofSize: 15).capHeight / 2 - image.axis - image.descent
        return (origin + image.size.height - CGFloat(bottom + 1) / image.scale)...(origin + image.size.height - CGFloat(top) / image.scale)
    }
    let referenceInk = firstGlyphInk(x)
    for source in ["x,z", "x>0", "x_i", "x^2", "x,"] {
        let ink = firstGlyphInk(try await image(source))
        try expect(abs(ink.lowerBound - referenceInk.lowerBound) <= 0.6 && abs(ink.upperBound - referenceInk.upperBound) <= 0.6,
                   "Punctuation/scripts moved the base variable: \(source), \(ink), reference \(referenceInk)")
    }
    let separated = try await image(#"w=\sum_i\lambda_i y_i s^i,\qquad y^\top\lambda=0."#)
    let oneEm = try await image(#"w=\sum_i\lambda_i y_i s^i,\quad y^\top\lambda=0."#)
    try expect(abs(separated.size.width - oneEm.size.width) <= 1, "Chat's wide equation separator was not tightened to 1 em")
    let isolated = [#"\newcommand{\ompLeak}{x}\ompLeak"#, #"\ompLeak"#, #"\gdef\ompGlobal{y}\ompGlobal"#, #"\ompGlobal"#]
        .map(formula)
    let sandbox = try await ChatMathRenderer.shared.render(isolated, pointSize: 15, scale: 2)
    try expect(sandbox[0] != nil && sandbox[1] == nil && sandbox[2] != nil && sandbox[3] == nil, "A formula leaked local/global macro definitions into the next formula")
    // One very wide valid expression must not strand an otherwise small cold
    // history when the combined atlas exceeds the 16 MP export budget.
    let mixed = (0..<40).map { i -> (MarkdownFormula, CGFloat) in
        let source = i == 8 ? #"\rule{6000px}{8px}+x"# : #"\frac{cold_{"# + "\(i)" + #"}+1}{\sqrt{1+x^2}}"#
        return (formula(source), i < 8 ? 20 : 21)
    }
    let priorBatches = ChatMathRenderer.shared.batchCount
    for (formula, size) in mixed { _ = MathRendering.result(for: formula, pointSize: size) }
    try await waitForMath()
    for (formula, size) in mixed {
        guard case .ready = MathRendering.result(for: formula, pointSize: size) else { throw CheckFailure(description: "A mixed oversized atlas stranded a valid formula") }
    }
    try expect(ChatMathRenderer.shared.batchCount - priorBatches < 15, "Mixed atlas fallback discarded batching for every sibling")
    let red = try pixels(raster, color: .red, selected: false)
    try expect(stride(from: 0, to: red.count, by: 4).allSatisfy { red[$0 + 1] == 0 && red[$0 + 2] == 0 }, "Native foreground tint was not applied")
    let white = try pixels(raster, color: .white, selected: false)
    try expect(stride(from: 0, to: white.count, by: 4).allSatisfy { white[$0] == white[$0 + 3] }, "Dark appearance lost alpha or glyph edges")
    let colored = try await image(#"x+\color{blue}{y}"#)
    let normal = try pixels(colored, color: .red, selected: false)
    try expect(stride(from: 0, to: normal.count, by: 4).contains { normal[$0 + 2] > 200 }, "Explicit TeX colour disappeared")
    let selected = try pixels(colored, color: .green, selected: true)
    try expect(stride(from: 0, to: selected.count, by: 4).allSatisfy { selected[$0] == 0 && selected[$0 + 2] == 0 }, "Selection did not tint every glyph")
    let high = try await image(latex, scale: 3)
    try expect(high.scale >= 3 && high.scale < 3.1 && high.mask.width > raster.mask.width, "Higher screen scale did not produce more image pixels: scale=\(high.scale), width=\(high.mask.width), baseline=\(raster.scale)/\(raster.mask.width)")
    try expect(abs(high.size.width - raster.size.width) <= 1 && abs(high.size.height - raster.size.height) <= 1, "Backing scale changed formula point geometry")
    for original in [raster, colored, high] {
        let restored = try ChatMathRenderer.Image(archive: original.archive())
        try expect(restored.size == original.size && restored.descent == original.descent && restored.axis == original.axis,
                   "Cached image lost size, baseline or mathematical axis")
        for selected in [false, true] {
            let restoredPixels = try pixels(restored, color: .red, selected: selected)
            let originalPixels = try pixels(original, color: .red, selected: selected)
            try expect(restoredPixels == originalPixels,
                       "Cached image changed transparency, explicit colour or selection pixels")
        }
    }
    let wide = try await image((0..<60).map { "a_{\($0)}" }.joined(separator: "+") + #"+\color{red}{Z_{tail}}"#)
    try expect(wide.size.width > 720, "Wide formula was cropped to the worker's default viewport")
    let widePixels = try pixels(wide, color: .black, selected: false)
    let redTail = stride(from: 0, to: widePixels.count, by: 4).contains { index in
        let x = (index / 4) % wide.mask.width
        return x > wide.mask.width * 3 / 4 && widePixels[index] > 200 && widePixels[index + 1] < 20 && widePixels[index + 2] < 20
    }
    try expect(redTail, "The far end of a wide formula is missing from the attachment pixels")
    let wideSource = (0..<60).map { "a_{\($0)}" }.joined(separator: "+") + #"+\color{red}{Z_{tail}}"#
    let nativeWide = Layout(MathRendering.attributed(formula(wideSource), pointSize: 15, color: .black))
    let nativeSize = nativeWide.measure(280)
    let tailX = wide.size.width - 100
    let visibleTail = nativeWide.manager.glyphRange(forBoundingRect: NSRect(x: tailX, y: 0, width: 100, height: nativeSize.height), in: nativeWide.container)
    try expect(NSLocationInRange(0, visibleTail), "TextKit culled the wide inline attachment after horizontal scrolling")
    try expect(MathRendering.overflowHit(at: NSPoint(x: tailX + 50, y: nativeSize.height / 2), in: nativeWide.view)?.location == 0,
               "The scrolled formula's native hit rectangle misses its visible tail")
    func drawNativeTail(selected: Bool) -> [UInt8] {
        let width = 200, height = Int(ceil(nativeSize.height * 2))
        let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        cg.translateBy(x: -tailX * 2, y: CGFloat(height)); cg.scaleBy(x: 2, y: -2)
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        nativeWide.view.selectedTextAttributes = [.foregroundColor: NSColor.green, .backgroundColor: NSColor.blue]
        nativeWide.view.setSelectedRange(NSRange(location: 0, length: selected ? 1 : 0))
        nativeWide.view.draw(NSRect(x: tailX, y: 0, width: 100, height: nativeSize.height))
        return Array(UnsafeBufferPointer(start: cg.data!.bindMemory(to: UInt8.self, capacity: width * height * 4), count: width * height * 4))
    }
    let tail = drawNativeTail(selected: false)
    try expect(stride(from: 0, to: tail.count, by: 4).contains { tail[$0] > 200 && tail[$0 + 1] < 20 }, "Native drawing lost the wide inline formula's red tail")
    let selectedTail = drawNativeTail(selected: true)
    try expect(stride(from: 0, to: selectedTail.count, by: 4).contains { selectedTail[$0 + 1] > 200 && selectedTail[$0 + 2] < 20 }, "Selection colour did not reach the formula's scrolled tail")
    try expect(stride(from: 0, to: selectedTail.count, by: 4).contains { selectedTail[$0 + 2] > 200 && selectedTail[$0 + 1] < 20 }, "Selection background did not reach the formula's scrolled tail")
    let tall = try await image(#"\begin{matrix}"# + (0..<70).map(String.init).joined(separator: #"\\"#) + #"\\\color{red}{Z}\end{matrix}"#)
    try expect(tall.size.height > 900 && tall.explicitColors != nil, "A tall formula lost its final row below the worker's default viewport")
    for latex in [#"x+\text{中文}"#, #"\begin{aligned}a&=b+c\\d&=e\end{aligned}"#, #"\ce{H2O}"#, #"\dv{x}{t}"#, #"\mathbb{R}\coloneqq\{x\mid x>0\}"#] {
        _ = try await image(latex)
    }
    let before = MathRendering.typesetCount
    ChatMathRenderer.shared.recycleAfterIdle(seconds: 0.1)
    try await Task.sleep(for: .milliseconds(200))
    try expect(!ChatMathRenderer.shared.isLoaded, "The shared WebView survived idle reclamation")
    let cached = try await image(latex)
    try expect(cached === raster && MathRendering.typesetCount == before && !ChatMathRenderer.shared.isLoaded, "Cached native images restarted the idle WebView")
    // A history larger than the old cache must complete exactly once even when
    // rows ask repeatedly before images are ready, then survive a process cache miss.
    let history = (0..<320).map { formula("h_{\($0)}+x^2") }
    let coldCount = MathRendering.typesetCount
    for _ in 0..<2 { for item in history { _ = MathRendering.result(for: item, pointSize: 13) } }
    try await waitForMath()
    try expect(MathRendering.typesetCount - coldCount == history.count, "Large history lost or duplicated pending formula jobs")
    for item in history {
        guard case .ready = MathRendering.result(for: item, pointSize: 13) else { throw CheckFailure(description: "Large history evicted a pending formula") }
    }
    try await MathRendering.flushDiskCache()
    let readyCount = MathRendering.typesetCount, diskCount = MathRendering.diskHitCount
    MathRendering.discardMemoryCache(); ChatMathRenderer.shared.release()
    for item in history { _ = MathRendering.result(for: item, pointSize: 13) }
    try await waitForMath()
    try expect(MathRendering.typesetCount == readyCount && MathRendering.diskHitCount - diskCount == history.count
               && !ChatMathRenderer.shared.isLoaded, "Persisted history reran MathJax or started WebKit")
    let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("math-cache/mathjax-4.1.3-images-v2"), includingPropertiesForKeys: nil)
    for file in files { try Data("corrupt cache".utf8).write(to: file) }
    MathRendering.discardMemoryCache()
    _ = MathRendering.result(for: history[0], pointSize: 13)
    try await waitForMath()
    guard case .ready = MathRendering.result(for: history[0], pointSize: 13) else { throw CheckFailure(description: "Damaged disk cache broke valid math") }
    try expect(MathRendering.typesetCount == readyCount + 1, "Damaged cache did not fall back to one fresh render")
    _ = try await image("z_{new}+42")
    try expect(ChatMathRenderer.shared.isLoaded, "New math could not restart the shared worker")
    ChatMathRenderer.shared.release()
}

@MainActor private func widthChecks(root: URL) async throws {
    let long = (1...32).map { "a_{\($0)}" }.joined(separator: "+")
    let source = "宽度变化时，普通中文与 English 正文继续换行。行内 $\(long)=S$；后续正文应按可见宽度排版。\n\n短公式 $x_i^2$ 不产生多余横向范围。"
    let block = MarkdownFormula(source: "$$\(long)=S$$", latex: long + "=S", mode: .display, complete: true)
    let rootView = VStack(alignment: .leading, spacing: 16) {
        ProseRunView(blocks: MarkdownParser.parse(source))
        MathBlockView(formula: block)
        MathParagraphView(paragraph: LinkParagraphView(source: source, pointSize: 15))
        MathBlockView(formula: MarkdownFormula(source: "$$E=mc^2$$", latex: "E=mc^2", mode: .display, complete: true))
    }.frame(maxWidth: .infinity, alignment: .topLeading)
    let host = NSHostingView(rootView: rootView)
    host.sizingOptions = []
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close(); ChatMathRenderer.shared.release() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    var heights: [CGFloat: [CGFloat]] = [:]
    var readyTypesets: Int?
    for width: CGFloat in [760, 280, 540, 280, 760] {
        window.setContentSize(NSSize(width: width, height: 800))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        try await waitForMath()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        let paragraphs = descendants(host).compactMap { $0 as? MathParagraphHost }
        try expect(paragraphs.count == 4, "Cold prose, streaming paragraph or display math lost its horizontal host")
        let measured = paragraphs.map(\.frame.height)
        if let old = heights[width] {
            try expect(zip(old, measured).allSatisfy { abs($0 - $1) <= 1 }, "Width round trip changed stable paragraph heights: \(old) / \(measured)")
        }
        heights[width] = measured
        for paragraph in paragraphs {
            let viewport = paragraph.bounds.width
            try expect(abs(viewport - width) <= 1, "Math widened the page outside its viewport")
            try expect(paragraph.paragraph.frame.width < 4000, "Centred math inherited phantom width from an intrinsic probe")
            if paragraph.paragraph.textStorage?.attribute(.mathLatex, at: 0, effectiveRange: nil) as? String == "E=mc^2" {
                try expect(!paragraph.hasHorizontalScroller, "A short centred formula has unnecessary horizontal scrolling")
                let manager = paragraph.paragraph.layoutManager!, container = paragraph.paragraph.textContainer!
                let box = manager.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
                if abs(box.midX - viewport / 2) > 2, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("math-width-failure.png"))
                }
                try expect(abs(box.midX - viewport / 2) <= 2, "Display math lost horizontal centring after a width change: box=\(box), viewport=\(viewport), container=\(container.containerSize), wrap=\(paragraph.paragraph.wrappingWidth ?? 0)")
                continue
            }
            var widest: CGFloat = 0
            let storage = paragraph.paragraph.textStorage!
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let attachment = value as? NSTextAttachment { widest = max(widest, attachment.bounds.width) }
            }
            try expect(paragraph.hasHorizontalScroller == (widest > viewport + 0.5), "Formula overflow did not follow available width: viewport=\(viewport), formula=\(widest), document=\(paragraph.paragraph.frame.width)")
            let end = paragraph.paragraph.frame.width - paragraph.contentView.bounds.width
            paragraph.contentView.scroll(to: NSPoint(x: end, y: 0))
            paragraph.reflectScrolledClipView(paragraph.contentView)
            try expect(abs(paragraph.contentView.bounds.minX - end) <= 1, "The end of a long formula is unreachable")
            paragraph.contentView.scroll(to: .zero)
            if storage.length > 1 {
                try expect(paragraph.paragraph.textContainer?.containerSize.width == width, "Overflow widened surrounding prose's text container")
            }
            let expectedHeight = paragraph.paragraph.height(forWidth: paragraph.paragraph.wrappingWidth ?? width) + (paragraph.hasHorizontalScroller ? 14 : 0)
            try expect(abs(paragraph.frame.height - expectedHeight) <= 1, "Async math height was not propagated to the page layout")
        }
        if let before = readyTypesets { try expect(MathRendering.typesetCount == before, "Width changes rerasterized existing formulas") }
        else { readyTypesets = MathRendering.typesetCount }
        if width == 280, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("math-width-280.png"))
        }
    }
}

@main private enum MathChecks {
    @MainActor static func main() async throws { try await checks() }
}
