import AppKit
import CoreText
import SwiftUI

private struct CheckFailure: Error, CustomStringConvertible {
    var description: String
}

@main
private enum MarkdownLayoutChecks {
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(description: message) }
    }

    @MainActor
    private static func attributed(_ source: String, prose: CGFloat = 15, code: CGFloat = 13, codeFont: NSFont? = nil) -> NSAttributedString {
        let parsed = MarkdownInline.parse(source)
        let base = NSFont.systemFont(ofSize: prose)
        let mono = codeFont ?? NSFont.monospacedSystemFont(ofSize: code, weight: .regular)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let string = String(parsed[run.range].characters)
            if run.inlinePresentationIntent?.contains(.code) == true {
                out.append(InlineCodeStyle.attributed(string, font: mono, link: run.link))
            } else {
                out.append(NSAttributedString(string: string, attributes: [.font: base, .foregroundColor: NSColor.labelColor]))
            }
        }
        InlineCodeStyle.balanceSpacing(in: out, pointSize: prose)
        return out
    }

    @MainActor private struct Layout {
        let storage: NSTextStorage
        let manager: NSLayoutManager
        let container: NSTextContainer

        init(_ text: NSAttributedString) {
            storage = NSTextStorage(attributedString: text)
            manager = NSLayoutManager()
            manager.delegate = MarkdownParagraphLayout.layoutDelegate
            container = NSTextContainer(size: NSSize(width: 640, height: 1_000_000))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
        }

        func measure(_ width: CGFloat) -> CGFloat {
            container.containerSize.width = width
            manager.ensureLayout(for: container)
            return ceil(manager.usedRect(for: container).height)
        }

        func ink(_ range: NSRange) -> CGRect {
            var result = CGRect.null
            // Resolve contextual glyphs/fallback fonts in the whole paragraph, then
            // place their outlines at the actual TextKit positions used for display.
            let line = CTLineCreateWithAttributedString(storage)
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                var indices = [CFIndex](repeating: 0, count: count)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                CTRunGetStringIndices(run, CFRange(), &indices)
                CTRunGetGlyphs(run, CFRange(), &glyphs)
                for index in 0..<count where NSLocationInRange(indices[index], range) {
                    let native = manager.glyphIndexForCharacter(at: indices[index])
                    let origin = manager.location(forGlyphAt: native)
                    let fragment = manager.lineFragmentRect(forGlyphAt: native, effectiveRange: nil)
                    var glyph = glyphs[index]
                    let outline = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
                    result = result.union(outline.offsetBy(dx: fragment.minX + origin.x, dy: fragment.minY + origin.y))
                }
            }
            return result
        }
    }

    private static let expectedCodeGaps: [CGFloat: CGFloat] = [12: 4, 15: 5, 18: 6, 21: 7]

    @MainActor
    private static func checkSpacing() throws -> Int {
        let neighbours = ["中", "文", "A", "m", "1", "9", "Ａ", "ｍ", "１", "９",
                          ",", ".", ";", ":", "!", "?", "(", ")", "[", "]",
                          "，", "。", "；", "：", "！", "？", "（", "）", "【", "】", "“", "”", "、", "《", "》",
                          "「", "」", "『", "』", "｛", "｝", "％", "%", "·", "…", "+", "＝", "$", "￥"]
        let tokens = ["make build", "send()", "x", "Ａ１", "中文", "（值）", "e\u{301}", "👨‍👩‍👧‍👦", "a_b", "\"x\"", "_", ".", "，", "“引号”", "｛值｝"]
        var count = 0
        func check(_ left: String, _ token: String, _ right: String, _ before: String, _ after: String,
                   prose: CGFloat = 15, code: CGFloat = 13, font: NSFont? = nil) throws {
            // A literal dollar must be escaped; an unmatched TeX opener followed by
            // an underscore intentionally belongs to the math parser, not inline code.
            let source = (left == "$" ? "\\$" : left) + before + "`" + token + "`" + after + (right == "$" ? "\\$" : right)
            let text = attributed(source, prose: prose, code: code, codeFont: font)
            try expect(InlineCodeStyle.exported(text).string == left + before + token + after + right, "Spacing changed copied text in \(source)")
            let layout = Layout(text)
            _ = layout.measure(640)
            let string = text.string as NSString
            let codeStart = (left as NSString).length + 1
            let codeEnd = codeStart + (token as NSString).length
            let firstCode = string.rangeOfComposedCharacterSequence(at: codeStart)
            let lastCode = string.rangeOfComposedCharacterSequence(at: codeEnd - 1)
            let leading = layout.ink(firstCode).minX - layout.ink(NSRange(location: 0, length: (left as NSString).length)).maxX
            let trailing = layout.ink(NSRange(location: codeEnd + 1, length: (right as NSString).length)).minX - layout.ink(lastCode).maxX
            try expect(abs(leading - trailing) < 0.2, "Uneven visible code gaps in \(source.debugDescription) (\(prose)/\(code)): \(leading), \(trailing)")
            try expect(leading > 0 && trailing > 0, "Code collided with neighbouring ink in \(source)")
            let profile = "\(prose)/\(code)/\(font?.fontName ?? "system")"
            let expected = expectedCodeGaps[prose]!
            try expect(abs(leading - expected) < 0.2, "Code gap differs from \(expected) pt in \(source.debugDescription) (\(profile)): \(leading)")
            count += 1
        }
        for (i, left) in neighbours.enumerated() {
            for (j, right) in neighbours.enumerated() {
                for (k, spaces) in [("", ""), (" ", " "), ("", " "), (" ", ""), ("　", " "), ("  ", "")].enumerated() {
                    try check(left, tokens[(i + j + k) % tokens.count], right, spaces.0, spaces.1)
                }
            }
        }
        for (prose, code) in [(CGFloat(12), CGFloat(11)), (21, 17), (12, 17), (18, 11)] {
            for (i, left) in neighbours.enumerated() {
                try check(left, tokens[i % tokens.count], neighbours[(i + 7) % neighbours.count], "", " ", prose: prose, code: code)
            }
        }
        for name in ["Menlo", "Courier"] {
            guard let font = NSFont(name: name, size: 14) else { throw CheckFailure(description: "Missing fixture font \(name)") }
            for (i, left) in neighbours.enumerated() {
                try check(left, tokens[i % tokens.count], neighbours[(i + 11) % neighbours.count], " ", "", code: 14, font: font)
            }
        }
        return count
    }

    @MainActor
    private static func checkResizing() throws -> Int {
        let samples = [
            ("中", "git status", "文", "", " "),
            ("A", "very_long_identifier_" + String(repeating: "part_", count: 14), "Z", " ", ""),
            ("，", "send()", "。", "", ""),
            ("（", "x", "）", "", ""),
            ("中", "（值）", "文", "  ", ""),
            ("m", "Ａ１", "９", "", " "),
            ("Ａ", "中文", "１", "　", " "),
            ("中", "e\u{301}", "文", " ", ""),
            ("A", "👨‍👩‍👧‍👦", "中", "", " "),
        ]
        var count = 0
        for (prose, code) in [(CGFloat(15), CGFloat(13)), (21, 17), (12, 17)] {
            for (left, token, right, before, after) in samples {
                for prefix in ["", "前缀 prefix １２３ "] {
                    let text = attributed(prefix + left + before + "`" + token + "`" + after + right + " 后续文字 tail。", prose: prose, code: code)
                    let string = text.string as NSString
                    let codeStart = (prefix + left as NSString).length + 1
                    let codeEnd = codeStart + (token as NSString).length
                    let leftRange = NSRange(location: (prefix as NSString).length, length: (left as NSString).length)
                    let firstCode = string.rangeOfComposedCharacterSequence(at: codeStart)
                    let lastCode = string.rangeOfComposedCharacterSequence(at: codeEnd - 1)
                    let rightRange = NSRange(location: codeEnd + 1, length: (right as NSString).length)
                    let layout = Layout(text)
                    var previous: [CGFloat: [CGPoint]] = [:]
                    for width: CGFloat in [76, 110, 140, 180, 280, 440, 640, 440, 280, 180, 140, 110, 76, 640] {
                        _ = layout.measure(width)
                        let positions = (0..<layout.manager.numberOfGlyphs).map { layout.manager.location(forGlyphAt: $0) }
                        if let saved = previous[width] {
                            try expect(positions == saved, "Sidebar width round trip retained stale glyph positions at \(width) for \(text.string)")
                        }
                        previous[width] = positions
                        func line(_ range: NSRange) -> CGRect {
                            layout.manager.lineFragmentRect(forGlyphAt: layout.manager.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
                        }
                        let leadingSameLine = line(leftRange).minY == line(firstCode).minY
                        let trailingSameLine = line(lastCode).minY == line(rightRange).minY
                        if leadingSameLine && trailingSameLine {
                            let leading = layout.ink(firstCode).minX - layout.ink(leftRange).maxX
                            let trailing = layout.ink(rightRange).minX - layout.ink(lastCode).maxX
                            try expect(abs(leading - trailing) < 0.2, "Wrapping changed optical gaps at \(width) for \(text.string): \(leading), \(trailing)")
                        }
                        if !leadingSameLine {
                            let origin = layout.manager.location(forGlyphAt: layout.manager.glyphIndexForCharacter(at: codeStart)).x
                            try expect(abs(origin) < 0.1, "Wrapped code gained a synthetic leading indent at \(width)")
                        }
                        for glyph in 0..<layout.manager.numberOfGlyphs {
                            let used = layout.manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                            try expect(used.maxX <= width + 0.1, "Code overflowed the resized chat column at \(width)")
                        }
                        try expect(layout.storage.string == text.string, "Resizing changed copied code text")
                        count += 1
                    }
                }
            }
        }
        return count
    }

    @MainActor
    private static func checkEnclosedCode() throws -> Int {
        var count = 0
        func check(_ source: String, opening: String, closing: String,
                   first: String = "AppFont.monospaced", last: String = "FilePreviewText",
                   prose: CGFloat = 15, code: CGFloat = 14) throws {
            let text = attributed(source, prose: prose, code: code)
            try expect(InlineCodeStyle.exported(text).string == String(MarkdownInline.parse(source).characters), "Enclosed code changed copied source")
            let string = text.string as NSString
            let left = string.range(of: opening)
            let right = string.range(of: closing, options: .backwards)
            let firstToken = string.range(of: first)
            let lastToken = string.range(of: last)
            try expect([left, right, firstToken, lastToken].allSatisfy { $0.location != NSNotFound }, "Invalid enclosure fixture")
            let firstGlyph = string.rangeOfComposedCharacterSequence(at: firstToken.location)
            let lastGlyph = string.rangeOfComposedCharacterSequence(at: NSMaxRange(lastToken) - 1)
            let layout = Layout(text)
            var previous: [CGFloat: [CGPoint]] = [:]
            for width: CGFloat in [1200, 640, 280, 140, 280, 640, 1200] {
                _ = layout.measure(width)
                let positions = (0..<layout.manager.numberOfGlyphs).map { layout.manager.location(forGlyphAt: $0) }
                if let saved = previous[width] {
                    try expect(positions == saved, "Enclosure width round trip changed glyph positions at \(width)")
                }
                previous[width] = positions
                func line(_ range: NSRange) -> CGFloat {
                    layout.manager.lineFragmentRect(forGlyphAt: layout.manager.glyphIndexForCharacter(at: range.location), effectiveRange: nil).minY
                }
                if line(left) == line(firstGlyph), line(lastGlyph) == line(right) {
                    let leading = layout.ink(firstGlyph).minX - layout.ink(left).maxX
                    let trailing = layout.ink(right).minX - layout.ink(lastGlyph).maxX
                    try expect(abs(leading - trailing) < 0.2, "Uneven enclosure gaps at \(width) in \(source): \(leading), \(trailing)")
                }
                count += 1
            }
        }
        // The reported sentence encloses several code spans separated by prose and
        // ideographic commas; single-span boundary permutations cannot exercise it.
        try check("差异已完全摸清。改动分两类：界面字体调用点恢复系统字体；等宽机制（`AppFont.monospaced`、`customMonospaced`、CSS `--monospaced-font`、`FilePreviewText`）完整保留。开始实施。", opening: "（", closing: "）")
        let pairs = [("（", "）"), ("(", ")"), ("［", "］"), ("[", "]"), ("｛", "｝"), ("{", "}"), ("【", "】"), ("「", "」"), ("“", "”")]
        for (prose, code) in [(CGFloat(15), CGFloat(14)), (18, 17), (12, 17)] {
            for (opening, closing) in pairs {
                for separator in ["、", ",", "，", "；"] {
                    for (before, after) in [("", ""), (" ", "　")] {
                        let source = "等宽机制" + opening + before + "`AppFont.monospaced`" + separator + "`customMonospaced`" + separator + "CSS `--monospaced-font`" + separator + "`FilePreviewText`" + after + closing + "完整保留。"
                        try check(source, opening: opening, closing: closing, prose: prose, code: code)
                    }
                }
            }
            let nested = "外层（`AppFont.monospaced`、内层［`customMonospaced`，CSS `--monospaced-font`］、`FilePreviewText`）保留。"
            try check(nested, opening: "（", closing: "）", prose: prose, code: code)
            try check(nested, opening: "［", closing: "］", first: "customMonospaced", last: "--monospaced-font", prose: prose, code: code)
            for literal in ["literal（", "literal）"] {
                try check("外层（`AppFont.monospaced`、`\(literal)`、`FilePreviewText`）保留。", opening: "（", closing: "）", prose: prose, code: code)
            }
        }
        return count
    }

    @MainActor
    private static func checkCodeConnectors() throws -> Int {
        var count = 0
        func check(_ source: String, first: String, connector: String, last: String,
                   prose: CGFloat = 15, code: CGFloat = 14, font: NSFont? = nil) throws {
            let text = attributed(source, prose: prose, code: code, codeFont: font)
            try expect(InlineCodeStyle.exported(text).string == String(MarkdownInline.parse(source).characters), "Code connector changed copied source")
            let string = text.string as NSString
            let firstToken = string.range(of: first)
            let lastToken = string.range(of: last, options: .backwards)
            try expect(firstToken.location != NSNotFound && lastToken.location > NSMaxRange(firstToken), "Invalid connector fixture")
            let between = NSRange(location: NSMaxRange(firstToken), length: lastToken.location - NSMaxRange(firstToken))
            let middle = string.range(of: connector, range: between)
            try expect(middle.location != NSNotFound, "Missing connector fixture")
            let left = string.rangeOfComposedCharacterSequence(at: NSMaxRange(firstToken) - 1)
            let right = string.rangeOfComposedCharacterSequence(at: lastToken.location)
            let layout = Layout(text)
            var expected: CGFloat?
            var previous: [CGFloat: [CGPoint]] = [:]
            for width: CGFloat in [1200, 640, 280, 140, 76, 140, 280, 640, 1200] {
                _ = layout.measure(width)
                let positions = (0..<layout.manager.numberOfGlyphs).map { layout.manager.location(forGlyphAt: $0) }
                if let saved = previous[width] {
                    try expect(positions == saved, "Connector width round trip changed glyph positions at \(width) in \(source)")
                }
                previous[width] = positions
                func line(_ range: NSRange) -> CGFloat {
                    layout.manager.lineFragmentRect(forGlyphAt: layout.manager.glyphIndexForCharacter(at: range.location), effectiveRange: nil).minY
                }
                let before = line(left) == line(middle) ? layout.ink(middle).minX - layout.ink(left).maxX : nil
                let after = line(middle) == line(right) ? layout.ink(right).minX - layout.ink(middle).maxX : nil
                if let before, let after {
                    try expect(abs(before - after) < 0.2, "Uneven connector gaps at \(width) in \(source): \(before), \(after)")
                    if expected == nil { expected = before }
                }
                if let expected {
                    for gap in [before, after].compactMap({ $0 }) {
                        try expect(abs(gap - expected) < 0.2, "Wrapping changed a connector gap at \(width) in \(source): \(gap), expected \(expected)")
                        try expect(gap > 0, "Connector collided with code in \(source)")
                    }
                }
                for glyph in 0..<layout.manager.numberOfGlyphs {
                    let used = layout.manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                    try expect(used.maxX <= width + 0.1, "Connector overflowed the resized chat column at \(width)")
                }
                count += 1
            }
        }
        try check("( `monospaced` / `customMonospaced`", first: "monospaced", connector: "/", last: "customMonospaced")
        try check("`verification.md` 与 `tests/catalog.py`", first: "verification.md", connector: "与", last: "tests/catalog.py")
        let connectors = ["与", "和", "A", "m", "1", "Ａ", "ｍ", "１", "/", "／", "、", ",", "，", ".", "。", ";", "；", ":", "：",
                          "!", "！", "?", "？", "(", "（", ")", "）", "[", "【", "]", "】", "“", "”", "'", "‘", "’", "+", "＝", "%", "％", "·", "…", "e\u{301}", "👨‍👩‍👧‍👦"]
        let tokens = [("verification.md", "tests/catalog.py"), ("monospaced", "customMonospaced"), ("Ａ１", "中文"), ("（值）", "e\u{301}")]
        for (prose, code) in [(CGFloat(15), CGFloat(14)), (18, 17), (12, 17)] {
            for (index, connector) in connectors.enumerated() {
                let (first, last) = tokens[index % tokens.count]
                for (before, after) in [("", ""), (" ", " "), (" ", ""), ("", " "), ("　", " "), ("  ", "")] {
                    // Asymmetric outer neighbours expose independent code targets;
                    // checking only code–character–code can accidentally pass.
                    let source = "前（`" + first + "`" + before + connector + after + "`" + last + "`后。"
                    try check(source, first: first, connector: connector, last: last, prose: prose, code: code)
                }
            }
        }
        for name in ["Menlo", "Courier"] {
            guard let font = NSFont(name: name, size: 14) else { throw CheckFailure(description: "Missing fixture font \(name)") }
            for connector in ["与", "/", "／", "，", "（", "）", "“", "”"] {
                try check("（`verification.md` \(connector)`tests/catalog.py`后", first: "verification.md", connector: connector, last: "tests/catalog.py", font: font)
            }
        }
        return count
    }

    @MainActor
    private static func checkUniformCodeSpacing() throws -> Int {
        let sources = [
            "保留`--monospaced-font`注入",
            "验证：`make build`通过",
            "保留`--monospaced-font`注入；验证：`make build`通过。",
            "中文`x`正文；English `send()` text；全角Ａ`Ａ１`Ｂ。",
            "。`，`（后续；（`｛值｝`）保留；`e\u{301}`与`👨‍👩‍👧‍👦`。",
            "`x` `[Ａ１]`　`（值）`",
        ]
        var count = 0
        for (prose, code) in [(CGFloat(15), CGFloat(14)), (18, 11), (12, 17)] {
            let expected = expectedCodeGaps[prose]!
            for source in sources {
                let text = attributed(source, prose: prose, code: code)
                try expect(InlineCodeStyle.exported(text).string == String(MarkdownInline.parse(source).characters), "Uniform code spacing changed copied text")
                let string = text.string as NSString
                let layout = Layout(text)
                for width: CGFloat in [640, 280, 140, 76, 140, 280, 640] {
                    _ = layout.measure(width)
                    var gaps: [CGFloat] = []
                    text.enumerateAttribute(InlineCodeStyle.spacingAttribute, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                        guard value != nil else { return }
                        let left = string.rangeOfComposedCharacterSequence(at: range.location - 1)
                        let right = string.rangeOfComposedCharacterSequence(at: NSMaxRange(range))
                        let a = layout.manager.glyphIndexForCharacter(at: left.location)
                        let b = layout.manager.glyphIndexForCharacter(at: right.location)
                        guard layout.manager.lineFragmentRect(forGlyphAt: a, effectiveRange: nil).minY
                            == layout.manager.lineFragmentRect(forGlyphAt: b, effectiveRange: nil).minY else { return }
                        gaps.append(layout.ink(right).minX - layout.ink(left).maxX)
                    }
                    for gap in gaps {
                        try expect(abs(gap - expected) < 0.2, "Code spacing differs from \(expected) pt at \(width) in \(source): \(gap)")
                    }
                    count += 1
                }
            }
        }
        return count
    }

    @MainActor
    private static func checkLinkIconSpacing() throws -> Int {
        var count = 0
        for (leftPixels, rightPixels) in [(0, 0), (2, 1), (4, 0)] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 28, pixelsHigh: 28,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let filled = NSColor(deviceRed: 0.2, green: 0.7, blue: 0.3, alpha: 1)
            let transparent = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0)
            for x in 0..<28 {
                for y in 0..<28 {
                    bitmap.setColor(x >= leftPixels && x < 28 - rightPixels ? filled : transparent, atX: x, y: y)
                }
            }
            let icon = NSImage(size: NSSize(width: 14, height: 14))
            icon.addRepresentation(bitmap)
            for size: CGFloat in [12, 15, 18] {
                let base = NSFont.systemFont(ofSize: size)
                let bold = NSFont.boldSystemFont(ofSize: size)
                for (preceding, label) in ["看", "（", "(", "：", "A", "。", "“", "Ｍ"].flatMap({ value in
                    ["共享讨论文档", "Assignment_1.ipynb"].map { (value, $0) }
                }) {
                    for whitespace in ["", " ", "  "] {
                        let reference = NSMutableAttributedString(string: " ", attributes: [.font: base])
                        reference.append(NSAttributedString(string: label, attributes: [.font: bold]))
                        let referenceLayout = Layout(reference)
                        _ = referenceLayout.measure(640)
                        let originalRightGap = referenceLayout.ink(NSRange(location: 1, length: 1)).minX + CGFloat(rightPixels) / 2
                        let text = NSMutableAttributedString(string: preceding + whitespace, attributes: [.font: base])
                        InlineLinkIconStyle.balanceLeadingSpace(in: text, label: label, font: bold, base: base, icon: icon)
                        let iconIndex = text.length
                        let attachment = NSTextAttachment()
                        attachment.image = icon
                        attachment.bounds = NSRect(x: 0, y: base.descender + 2, width: 14, height: 14)
                        text.append(NSAttributedString(attachment: attachment))
                        text.append(NSAttributedString(string: " ", attributes: [.font: base]))
                        let labelIndex = text.length
                        text.append(NSAttributedString(string: label, attributes: [.font: bold, .link: URL(string: "https://example.invalid")!]))
                        let layout = Layout(text)
                        for width: CGFloat in [640, 220, 640] {
                            _ = layout.measure(width)
                            let glyph = layout.manager.glyphIndexForCharacter(at: iconIndex)
                            let x = layout.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
                                + layout.manager.location(forGlyphAt: glyph).x
                            let left = x + CGFloat(leftPixels) / 2 - layout.ink(NSRange(location: 0, length: (preceding as NSString).length)).maxX
                            let right = layout.ink(NSRange(location: labelIndex, length: 1)).minX - (x + 14 - CGFloat(rightPixels) / 2)
                            try expect(abs(left - right) < 0.2 && right > 0,
                                       "Unequal favicon ink gaps beside \(preceding) at \(size) pt: \(left), \(right)")
                            try expect(abs(right - originalRightGap) < 0.1, "Favicon balancing changed the original right-side gap")
                        }
                        let exported = InlineCodeStyle.exported(text)
                        try expect(exported.string == preceding + whitespace + "\u{FFFC} " + label,
                                   "Favicon display spacing changed copied whitespace")
                        try expect(exported.attribute(.link, at: exported.length - 1, effectiveRange: nil) as? URL == URL(string: "https://example.invalid"),
                                   "Favicon display spacing lost the link target")
                        count += 1
                    }
                }
            }
            for prefix in ["", "\n", "\t"] {
                let text = NSMutableAttributedString(string: prefix, attributes: [.font: NSFont.systemFont(ofSize: 15)])
                InlineLinkIconStyle.balanceLeadingSpace(in: text, label: "Link", font: .boldSystemFont(ofSize: 15), base: .systemFont(ofSize: 15), icon: icon)
                try expect(text.string == prefix, "A favicon gained indentation at a paragraph or tab boundary")
            }
        }
        return count
    }

    @MainActor
    private static func checkHardBreaks() throws {
        let broken = NSMutableAttributedString(string: "•\tfirst\nsecond", attributes: [.font: NSFont.systemFont(ofSize: 15)])
        let style = MarkdownParagraphLayout.paragraphStyle()
        style.headIndent = 18
        style.tabStops = [NSTextTab(textAlignment: .left, location: 18)]
        style.paragraphSpacing = 12
        MarkdownParagraphLayout.apply(style, to: broken)
        let brokenLayout = Layout(broken)
        _ = brokenLayout.measure(280)
        let secondStart = (broken.string as NSString).range(of: "second").location
        let secondGlyph = brokenLayout.manager.glyphIndexForCharacter(at: secondStart)
        let fragment = brokenLayout.manager.lineFragmentRect(forGlyphAt: secondGlyph, effectiveRange: nil)
        try expect(abs(fragment.minX + brokenLayout.manager.location(forGlyphAt: secondGlyph).x - 18) < 0.1, "A hard break lost its list content indentation")
        // A hard break represented by a native paragraph separator must have the
        // same line rhythm as a forced line break inside that paragraph.
        let unspaced = NSMutableAttributedString(string: "•\tfirst\u{2028}second", attributes: [.font: NSFont.systemFont(ofSize: 15)])
        let reference = style.mutableCopy() as! NSMutableParagraphStyle
        reference.paragraphSpacing = 0
        unspaced.addAttribute(.paragraphStyle, value: reference, range: NSRange(location: 0, length: unspaced.length))
        let referenceLayout = Layout(unspaced)
        _ = referenceLayout.measure(280)
        let expectedY = referenceLayout.manager.lineFragmentRect(forGlyphAt: referenceLayout.manager.glyphIndexForCharacter(at: secondStart), effectiveRange: nil).minY
        try expect(abs(fragment.minY - expectedY) < 0.1, "A hard break gained inter-block paragraph spacing")
        try expect(broken.string == "•\tfirst\nsecond", "Hard-break layout changed copied newlines")

        let wrapped = NSMutableAttributedString(string: "first second", attributes: [.font: NSFont.systemFont(ofSize: 15)])
        MarkdownParagraphLayout.apply(MarkdownParagraphLayout.paragraphStyle(), to: wrapped)
        let wrappedLayout = Layout(wrapped)
        _ = wrappedLayout.measure(50)
        let wrappedY = wrappedLayout.manager.lineFragmentRect(forGlyphAt: wrappedLayout.manager.glyphIndexForCharacter(at: 6), effectiveRange: nil).minY
        try expect(abs(wrappedY - expectedY - 1) < 0.1, "Hard breaks should use 2 pt spacing, 1 pt tighter than unchanged automatic wrapping: wrapped=\(wrappedY), manual=\(expectedY)")
        let originalWrap = Layout(wrapped)
        originalWrap.manager.delegate = nil
        _ = originalWrap.measure(50)
        let originalY = originalWrap.manager.lineFragmentRect(forGlyphAt: originalWrap.manager.glyphIndexForCharacter(at: 6), effectiveRange: nil).minY
        try expect(abs(wrappedY - originalY) < 0.1, "Explicit-break handling changed automatic wrapping")

    }

    @MainActor
    static func main() throws {
        try checkHardBreaks()
        let linkIconCases = try checkLinkIconSpacing()
        let uniformCases = try checkUniformCodeSpacing()
        let connectorCases = try checkCodeConnectors()
        let enclosureCases = try checkEnclosedCode()
        for (prose, code) in [(CGFloat(12), CGFloat(11)), (15, 13), (18, 17), (12, 17), (18, 11)] {
            let mono = NSFont.monospacedSystemFont(ofSize: code, weight: .regular)
            for token in ["x", "git_status", "LARGE_CODE", "中文", "e\u{301}", "👨‍👩‍👧‍👦"] {
                let text = attributed("`\(token)` tail", prose: prose, code: code)
                try expect(text.string == token + " tail", "Styling changed copyable Unicode text")
                try expect(text.attribute(.attachment, at: 0, effectiveRange: nil) == nil, "Code became an unwrappable attachment")
                try expect(text.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil, "Code retained a background")
                try expect(text.attribute(.kern, at: 0, effectiveRange: nil) == nil, "Code must keep default kerning: explicit zero breaks CJK boundaries")
                let styled = Layout(text)
                _ = styled.measure(640)
                let plain = Layout(NSAttributedString(string: token + " tail", attributes: [.font: mono, .ligature: 0]))
                _ = plain.measure(640)
                let range = NSRange(location: 0, length: (token as NSString).length)
                let original = plain.manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let actual = styled.manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                try expect(original.length == actual.length, "Spacing changed code glyphs for \(token)")
                for offset in 0..<actual.length {
                    let expected = plain.manager.location(forGlyphAt: original.location + offset).x
                    let measured = styled.manager.location(forGlyphAt: actual.location + offset).x
                    try expect(abs(measured - expected) < 0.1, "Spacing changed an interior code advance for \(token)")
                }
                let url = URL(string: "https://example.com")!
                let linked = InlineCodeStyle.attributed(token, font: mono, link: url)
                try expect(linked.attribute(.link, at: 0, effectiveRange: nil) as? URL == url, "A code-styled link lost its target")
                try expect(linked.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == InlineCodeStyle.foregroundColor, "A code-styled link lost its grey")
            }
        }

        let spacingCases = try checkSpacing()
        let resizingCases = try checkResizing()

        let adjacent = attributed("前`x` `[Ａ１]`　`（值）`后")
        try expect(InlineCodeStyle.exported(adjacent).string == "前x [Ａ１]　（值）后", "Adjacent code changed original whitespace on copy")
        let adjacentLayout = Layout(adjacent)
        _ = adjacentLayout.measure(640)
        let adjacentString = adjacent.string as NSString
        var adjacentGaps: [CGFloat] = []
        adjacent.enumerateAttribute(InlineCodeStyle.spacingAttribute, in: NSRange(location: 0, length: adjacent.length)) { value, range, _ in
            guard value != nil else { return }
            let left = adjacentString.rangeOfComposedCharacterSequence(at: range.location - 1)
            let right = adjacentString.rangeOfComposedCharacterSequence(at: NSMaxRange(range))
            adjacentGaps.append(adjacentLayout.ink(right).minX - adjacentLayout.ink(left).maxX)
        }
        try expect(adjacentGaps.count == 4 && adjacentGaps.allSatisfy { abs($0 - adjacentGaps[0]) < 0.2 }, "Adjacent code doubled a shared gap or lost optical balance")
        let selection = (adjacent.string as NSString).range(of: "x [Ａ１]")
        try expect(InlineCodeStyle.exported(adjacent.attributedSubstring(from: selection)).string == "x [Ａ１]", "Partial code selection lost its authored space")
        // Foundation drops the code intent inside a Markdown link. Exercise the
        // supported native code+link run directly instead of inventing parser output.
        let codeLink = NSMutableAttributedString(string: "前", attributes: [.font: NSFont.systemFont(ofSize: 15)])
        codeLink.append(InlineCodeStyle.attributed("send()", font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), link: URL(string: "https://example.com")!))
        codeLink.append(NSAttributedString(string: "后", attributes: [.font: NSFont.systemFont(ofSize: 15)]))
        InlineCodeStyle.balanceSpacing(in: codeLink, pointSize: 15)
        let linkedCode = InlineCodeStyle.exported(codeLink)
        let linkedRange = (linkedCode.string as NSString).range(of: "send()")
        try expect(linkedCode.attribute(.link, at: linkedRange.location, effectiveRange: nil) as? URL == URL(string: "https://example.com"), "Spacing export lost a code link target")

        // Boundary spacing must never stretch the code's interior advances.
        for (boundary, tail) in [("，`token` 检", "token x"), ("；`token` 检", "token x"), ("；`token`检", "token检")] {
            let marked = attributed(boundary)
            let markedLayout = Layout(marked)
            _ = markedLayout.measure(640)
            let tokenRange = (marked.string as NSString).range(of: "token")
            let glyphs = markedLayout.manager.glyphRange(forCharacterRange: tokenRange, actualCharacterRange: nil)
            let origin = markedLayout.manager.location(forGlyphAt: glyphs.location).x
            let end = markedLayout.manager.location(forGlyphAt: NSMaxRange(glyphs) - 1).x
            let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let reference = Layout(NSAttributedString(string: tail, attributes: [.font: mono]))
            _ = reference.measure(640)
            let natural = reference.manager.location(forGlyphAt: 4).x
            try expect(abs(end - origin - natural) < 0.1, "CJK boundary changed the code span's advances in \(boundary)")
        }

        let source = "运行 `git status` 后，再检查 `very_long_identifier_without_any_spaces_" + String(repeating: "part_", count: 32) + "end`；中文 `路径/文件.swift` 和 `e\u{301}` 均可复制。"
        let text = attributed(source)
        let layout = Layout(text)
        let wide = layout.measure(640)
        let medium = layout.measure(280)
        let narrow = layout.measure(140)
        try expect(narrow > medium && medium > wide, "Long inline code did not reflow with width")
        for width: CGFloat in [640, 280, 140, 280, 640] {
            let height = layout.measure(width)
            let expected = width == 640 ? wide : width == 280 ? medium : narrow
            try expect(height == expected, "Resizing back reused stale layout")
            let baselines = MarkdownBaselineMetrics.measure(layout: layout.manager, container: layout.container)
            try expect(baselines != nil && baselines!.first <= baselines!.last && baselines!.last <= height, "Actual line baselines were lost")
        }
        try expect(layout.storage.string == text.string, "Width changes inserted layout characters")
        let exported = InlineCodeStyle.exported(text)
        let rtf = try exported.data(from: NSRange(location: 0, length: exported.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let pasted = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        try expect(pasted.string == exported.string, "An RTF round trip damaged Unicode code text")

        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        for dark in [false, true] {
            var environment = EnvironmentValues()
            environment.colorScheme = dark ? .dark : .light
            let swiftUIColor = Color(nsColor: InlineCodeStyle.foregroundColor).resolve(in: environment)
            let expected: Float = dark ? 0.72 : 0.35
            try expect(abs(swiftUIColor.red - expected) < 0.01 && abs(swiftUIColor.green - expected) < 0.01 && abs(swiftUIColor.blue - expected) < 0.01, "SwiftUI did not resolve the current appearance's grey")
            var ratio: Double = 0
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                let foreground = InlineCodeStyle.foregroundColor.usingColorSpace(.sRGB)!
                let background = NSColor.textBackgroundColor.usingColorSpace(.sRGB)!
                let alpha = foreground.alphaComponent
                func luminance(_ components: [CGFloat]) -> Double {
                    let linear = components.map { v in v <= 0.04045 ? Double(v / 12.92) : pow(Double((v + 0.055) / 1.055), 2.4) }
                    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
                }
                let bg = [background.redComponent, background.greenComponent, background.blueComponent]
                let fg = zip([foreground.redComponent, foreground.greenComponent, foreground.blueComponent], bg).map { $0 * alpha + $1 * (1 - alpha) }
                let a = luminance(fg), b = luminance(bg)
                ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
            }
            try expect(ratio >= 4.5, "Inline code contrast is too low in \(dark ? "dark" : "light") appearance: \(ratio)")
            print("\(dark ? "Dark" : "Light") appearance contrast: \(String(format: "%.2f", ratio)):1")
            try snapshot(to: root.appendingPathComponent("inline-code-\(dark ? "dark" : "light").png"), dark: dark)
        }
        print("Markdown layout checks passed: \(linkIconCases) favicon ink-gap/copy cases, \(spacingCases) uniform optical boundary combinations, \(uniformCases) cross-span/paragraph width cases, \(resizingCases) sidebar width cases, \(enclosureCases) multi-span enclosure width cases, \(connectorCases) code/character/code width cases, 30 Unicode/font cases, interior glyph advances, baselines, copy and grey links. Offscreen previews: \(root.path)")
    }

    @MainActor
    private static func snapshot(to url: URL, dark: Bool) throws {
        let examples: [(String, CGFloat, CGFloat)] = [
            ("保留`--monospaced-font`注入", 15, 14),
            ("验证：`make build`通过", 15, 14),
            ("等宽机制（`AppFont.monospaced`、`customMonospaced`、CSS `--monospaced-font`、`FilePreviewText`）完整保留。", 15, 14),
            ("最终提交验证：增量 `make build` 通过；`make verify AREAS=\"interactions questions\"` 两项通过；`static:documentation` 通过。", 15, 14),
            ("中文`make build`中文；English`send()`text；全角Ａ`Ａ１`Ｂ。", 15, 13),
            ("（`x`） / (`x`) / ，`send()`。 / ,`send()`. / 【`（值）`】", 15, 13),
            ("行内代码 `git status` 与 `npm install` 使用灰色字体。", 15, 13),
            ("A heading with `inline_code` on its normal baseline", 21, 17),
            ("长路径 `Sources/Markdown/very_long_identifier_without_spaces.swift` 随宽度重新排版。", 15, 13),
            ("中文 `路径/文件.swift`；组合字符 `e\u{301}`；单字 `x`；Emoji `👨‍👩‍👧‍👦`。", 15, 13),
            ("里，`send()` 检测；`send`（）括号与 `send（）` 对齐。", 15, 13),
            ("独立设置：正文 12 pt 与代码 17 pt，`LARGE_CODE`。", 12, 17),
            ("独立设置：正文 18 pt 与代码 11 pt，`small_code`。", 18, 11),
        ]
        let contents = examples.map { attributed($0.0, prose: $0.1, code: $0.2) }
        var png: Data?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let width = 900, height = 1100
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = NSSize(width: width, height: height)
            let cg = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
            cg.translateBy(x: 0, y: CGFloat(height))
            cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            NSColor.textBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            for (x, columnWidth) in [(CGFloat(28), CGFloat(560)), (620, 250)] {
                var y: CGFloat = 28
                for content in contents {
                    let layout = Layout(content)
                    let height = layout.measure(columnWidth)
                    let glyphs = layout.manager.glyphRange(for: layout.container)
                    layout.manager.drawGlyphs(forGlyphRange: glyphs, at: NSPoint(x: x, y: y))
                    y += height + 26
                }
            }
            png = bitmap.representation(using: .png, properties: [:])
        }
        try png!.write(to: url)
    }
}
