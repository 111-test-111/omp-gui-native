import AppKit
import CoreText

/// Resolve grey at drawing time: applying alpha to a cached system colour can freeze
/// its first appearance. Both native and SwiftUI text use this dynamic colour.
enum InlineCodeStyle {
    static let spacingAttribute = NSAttributedString.Key("OMPGUIInlineCodeSpacing")
    private static let codeAttribute = NSAttributedString.Key("OMPGUIInlineCode")
    private static let negativeAdvanceAttribute = NSAttributedString.Key("OMPGUIInlineCodeNegativeAdvance")
    @MainActor private static let spaceFont = NSFont(descriptor: NSFont.systemFont(ofSize: 1).fontDescriptor
        .addingAttributes([.matrix: NSAffineTransform()]), size: 1)!
    @MainActor private static let space = NSAttributedString(string: " ", attributes: [.font: spaceFont])
    @MainActor private static let spaceWidth = CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(space), nil, nil, nil))
    @MainActor private static var negativeSpaceFonts: [Int: NSFont] = [:]
    static let foregroundColor = NSColor(name: "OMP GUI Inline Code") { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(srgbRed: dark ? 0.72 : 0.35, green: dark ? 0.72 : 0.35, blue: dark ? 0.72 : 0.35, alpha: 1)
    }

    @MainActor
    static func attributed(_ text: String, font: NSFont, link: URL? = nil) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            codeAttribute: true,
            .font: font,
            .foregroundColor: foregroundColor,
            .ligature: 0,
        ]
        if let link { attributes[.link] = link }
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// Real whitespace separates the scripts before shaping, so CJK punctuation cannot
    /// consume the boundary adjustment. Its original attributed text is retained for
    /// copy/export; the source and the code's own characters never change.
    @MainActor
    static func balanceSpacing(in text: NSMutableAttributedString, pointSize: CGFloat) {
        let string = text.string as NSString
        struct Boundary {
            let left: NSRange
            let right: NSRange
            var whitespace: NSRange { NSRange(location: NSMaxRange(left), length: right.location - NSMaxRange(left)) }
        }
        var boundaries: [Boundary] = []
        var seen: Set<Int> = []
        func isSpace(_ range: NSRange) -> Bool {
            text.attribute(codeAttribute, at: range.location, effectiveRange: nil) as? Bool != true
                && string.substring(with: range).unicodeScalars.allSatisfy {
                    CharacterSet.whitespaces.contains($0) && $0 != "\t"
                }
        }
        func visible(_ range: NSRange) -> Bool {
            !string.substring(with: range).unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) || $0.properties.generalCategory == .control
            }
        }
        func add(left: NSRange, right: NSRange) {
            guard seen.insert(right.location).inserted,
                  text.attribute(.font, at: left.location, effectiveRange: nil) is NSFont,
                  text.attribute(.font, at: right.location, effectiveRange: nil) is NSFont,
                  text.attribute(.attachment, at: left.location, effectiveRange: nil) == nil,
                  text.attribute(.attachment, at: right.location, effectiveRange: nil) == nil else { return }
            boundaries.append(Boundary(left: left, right: right))
        }
        text.enumerateAttribute(codeAttribute, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value as? Bool == true else { return }
            let first = string.rangeOfComposedCharacterSequence(at: range.location)
            let last = string.rangeOfComposedCharacterSequence(at: NSMaxRange(range) - 1)
            if first.location == range.location, visible(first) {
                var start = range.location
                while start > 0 {
                    let previous = string.rangeOfComposedCharacterSequence(at: start - 1)
                    if isSpace(previous) { start = previous.location; continue }
                    if visible(previous) { add(left: previous, right: first) }
                    break
                }
            }
            if NSMaxRange(last) == NSMaxRange(range), visible(last) {
                var end = NSMaxRange(range)
                while end < string.length {
                    let next = string.rangeOfComposedCharacterSequence(at: end)
                    if isSpace(next) { end = NSMaxRange(next); continue }
                    if visible(next) { add(left: last, right: next) }
                    break
                }
            }
        }
        guard !boundaries.isEmpty else { return }
        // One third of the prose em: 5 pt at the default 15 pt body size.
        let targetGap = pointSize / 3
        // Delimiters still need stable shaping at wrapped line edges, even though
        // spacing no longer depends on enclosure matching or code-span groups.
        var stableDelimiters: Set<Int> = []
        for boundary in boundaries {
            for neighbour in [boundary.left, boundary.right]
                where text.attribute(codeAttribute, at: neighbour.location, effectiveRange: nil) as? Bool != true {
                let category = string.substring(with: neighbour).unicodeScalars.first!.properties.generalCategory
                if category == .openPunctuation || category == .closePunctuation
                    || category == .initialPunctuation || category == .finalPunctuation {
                    stableDelimiters.insert(neighbour.location)
                }
            }
        }
        // CJK punctuation otherwise changes its advance at a wrapped line's edge.
        // Stabilize just these prose delimiters before measuring their glyphs; leave
        // the code fonts and their internal kerning untouched.
        for location in stableDelimiters {
            let range = string.rangeOfComposedCharacterSequence(at: location)
            let category = string.substring(with: range).unicodeScalars.first!.properties.generalCategory
            if category == .openPunctuation || category == .closePunctuation {
                text.addAttribute(.kern, value: CGFloat(0), range: range)
            }
        }
        if !stableDelimiters.isEmpty {
            // CJK quotes can resolve to different fallback faces in CoreText and
            // TextKit. Pin the measured face, including its traits and size, so the
            // actual glyph ink agrees with the spacing calculation in both engines.
            let line = CTLineCreateWithAttributedString(text)
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let range = CTRunGetStringRange(run)
                let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                for location in range.location..<(range.location + range.length) where stableDelimiters.contains(location) {
                    text.addAttribute(.font, value: font as NSFont, range: string.rangeOfComposedCharacterSequence(at: location))
                }
            }
        }
        boundaries.sort { $0.whitespace.location < $1.whitespace.location }
        var shifts = [0]
        for boundary in boundaries { shifts.append(shifts.last! + 1 - boundary.whitespace.length) }
        for boundary in boundaries.reversed() {
            let spacer = NSMutableAttributedString(attributedString: space)
            spacer.addAttribute(spacingAttribute, value: text.attributedSubstring(from: boundary.whitespace), range: NSRange(location: 0, length: 1))
            text.replaceCharacters(in: boundary.whitespace, with: spacer)
        }
        func shifted(_ range: NSRange) -> NSRange {
            var low = 0, high = boundaries.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(boundaries[middle].whitespace) <= range.location { low = middle + 1 }
                else { high = middle }
            }
            return NSRange(location: range.location + shifts[low], length: range.length)
        }
        // One complete shaping pass preserves contextual glyphs, fallback fonts and
        // composed characters. Never lay out each code span independently.
        let ink = glyphInk(in: CTLineCreateWithAttributedString(text))
        func bounds(_ range: NSRange) -> CGRect? {
            let range = shifted(range)
            let result = (range.location..<NSMaxRange(range)).compactMap { ink[$0] }.reduce(CGRect.null) { $0.union($1) }
            return result.isNull ? nil : result
        }
        for (index, boundary) in boundaries.enumerated() {
            guard let left = bounds(boundary.left), let right = bounds(boundary.right) else { continue }
            let advance = targetGap - (right.minX - left.maxX - spaceWidth)
            let range = NSRange(location: boundary.whitespace.location + shifts[index], length: 1)
            if advance < 0 {
                // TextKit clamps negative tracking on ordinary whitespace. A signed
                // advance on the inkless spacer compensates wide punctuation bearings
                // without touching real glyphs, code kerning or the shared target.
                text.addAttribute(.font, value: negativeSpaceFont(advance: advance), range: range)
                text.addAttribute(negativeAdvanceAttribute, value: advance, range: range)
            } else {
                text.addAttribute(.tracking, value: advance - spaceWidth, range: range)
            }
        }
    }

    /// TextKit clamps a glyph origin at the line's left edge even when its ink
    /// remains inside the line. Restore the signed spacer's position, not its font
    /// or the code's interior advances. Never carry a spacer across a line break.
    static func restoreClampedOrigins(in layout: NSLayoutManager, container: NSTextContainer) {
        guard let storage = layout.textStorage else { return }
        let glyphs = layout.glyphRange(for: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(negativeAdvanceAttribute, in: characters) { value, range, _ in
            guard let advance = value as? CGFloat, NSMaxRange(range) < NSMaxRange(characters) else { return }
            let spacer = layout.glyphIndexForCharacter(at: range.location)
            let next = layout.glyphIndexForCharacter(at: NSMaxRange(range))
            guard layout.lineFragmentRect(forGlyphAt: spacer, effectiveRange: nil).minY
                == layout.lineFragmentRect(forGlyphAt: next, effectiveRange: nil).minY else { return }
            var location = layout.location(forGlyphAt: next)
            let expected = layout.location(forGlyphAt: spacer).x + advance
            guard location.x == 0, expected < 0 else { return }
            location.x = expected
            layout.setLocation(location, forStartOfGlyphRange: NSRange(location: next, length: 1))
        }
    }

    @MainActor
    private static func negativeSpaceFont(advance: CGFloat) -> NSFont {
        // Quantize below a display pixel to avoid distinct fonts for floating-point
        // noise in paragraph positions; retain only a bounded set of spacer faces.
        let key = Int((advance * 1024).rounded())
        if let cached = negativeSpaceFonts[key] { return cached }
        let matrix = NSAffineTransform(transform: AffineTransform(scaleByX: CGFloat(key) / 1024 / spaceWidth, byY: 1))
        let font = NSFont(descriptor: spaceFont.fontDescriptor.addingAttributes([.matrix: matrix]), size: 1)!
        if negativeSpaceFonts.count >= 128 { negativeSpaceFonts.removeAll(keepingCapacity: true) }
        negativeSpaceFonts[key] = font
        return font
    }

    /// Shared display-only spacing for inline attachments. Export restores the
    /// original whitespace through the same mapping used by inline code.
    @MainActor
    static func displaySpace(advance: CGFloat, original: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: space)
        let range = NSRange(location: 0, length: result.length)
        result.addAttribute(spacingAttribute, value: original, range: range)
        if advance < 0 {
            result.addAttribute(.font, value: negativeSpaceFont(advance: advance), range: range)
        } else {
            result.addAttribute(.tracking, value: advance - spaceWidth, range: range)
        }
        return result
    }

    static func exported(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        var originals: [(NSRange, NSAttributedString)] = []
        text.enumerateAttribute(spacingAttribute, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let original = value as? NSAttributedString { originals.append((range, original)) }
        }
        for (range, original) in originals.reversed() { result.replaceCharacters(in: range, with: original) }
        return result
    }

    private static func glyphInk(in line: CTLine) -> [Int: CGRect] {
        var result: [Int: CGRect] = [:]
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            var bounds = [CGRect](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            CTRunGetStringIndices(run, CFRange(), &indices)
            CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, &bounds, count)
            for index in 0..<count where !bounds[index].isEmpty {
                let rect = bounds[index].offsetBy(dx: positions[index].x, dy: positions[index].y)
                result[indices[index]] = (result[indices[index]] ?? .null).union(rect)
            }
        }
        return result
    }
}

/// SwiftUI may evaluate alignment guides off the main thread. Measurements come from
/// the native text view's actual lines, read through this lock-protected box.
final class MarkdownBaselineMetrics: @unchecked Sendable {
    struct Snapshot: Sendable {
        let first: CGFloat
        let last: CGFloat
    }
    private let lock = NSLock()
    private var snapshot: Snapshot?

    func store(_ value: Snapshot) { lock.withLock { snapshot = value } }
    func load() -> Snapshot? { lock.withLock { snapshot } }

    static func measure(layout: NSLayoutManager, container: NSTextContainer) -> Snapshot? {
        let glyphs = layout.glyphRange(for: container)
        guard glyphs.length > 0 else { return nil }
        func baseline(at glyph: Int) -> CGFloat {
            layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + layout.location(forGlyphAt: glyph).y
        }
        return .init(first: baseline(at: glyphs.location), last: baseline(at: NSMaxRange(glyphs) - 1))
    }
}
