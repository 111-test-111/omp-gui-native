import AppKit
import CoreText

/// Match the existing gap after a favicon using visible image/glyph edges,
/// including asymmetric transparent pixels and CJK punctuation bearings.
enum InlineLinkIconStyle {
    private struct EdgeKey: Hashable { let text: String; let font: NSFont }
    private struct Edges { let leading: CGFloat; let trailing: CGFloat; let advance: CGFloat }
    @MainActor private static var edgeCache: [EdgeKey: Edges] = [:]
    @MainActor private static var imageCache: [ObjectIdentifier: (NSImage, CGFloat, CGFloat)] = [:]

    @MainActor
    static func balanceLeadingSpace(in text: NSMutableAttributedString, label: String, font: NSFont, base: NSFont, icon: NSImage) {
        let string = text.string as NSString
        var end = string.length
        while end > 0 {
            let previous = string.rangeOfComposedCharacterSequence(at: end - 1)
            let scalars = string.substring(with: previous).unicodeScalars
            if scalars.allSatisfy({ CharacterSet.whitespaces.contains($0) && $0 != "\t" }) { end = previous.location }
            else { break }
        }
        guard end > 0, !label.isEmpty else { return }
        let previous = string.rangeOfComposedCharacterSequence(at: end - 1)
        let preceding = string.substring(with: previous)
        guard !preceding.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              text.attribute(.attachment, at: previous.location, effectiveRange: nil) == nil,
              let precedingFont = text.attribute(.font, at: previous.location, effectiveRange: nil) as? NSFont else { return }
        let first = String(label.prefix(1))
        let following = edges(first, font: font)
        let before = edges(preceding, font: precedingFont)
        let (leftInset, rightInset) = imageInsets(icon)
        let rightGap = rightInset + edges(" ", font: base).advance + following.leading
        let advance = rightGap - leftInset - before.trailing
        let whitespace = NSRange(location: end, length: text.length - end)
        let original = text.attributedSubstring(from: whitespace)
        text.replaceCharacters(in: whitespace, with: InlineCodeStyle.displaySpace(advance: advance, original: original))
    }

    @MainActor private static func edges(_ string: String, font: NSFont) -> Edges {
        let key = EdgeKey(text: string, font: font)
        if let cached = edgeCache[key] { return cached }
        let source = NSAttributedString(string: string, attributes: [.font: font])
        let storage = NSTextStorage(attributedString: source)
        // TextKit's fallback punctuation advances differ from CTLine's. Use
        // the display engine's positions without changing the prose's kerning.
        storage.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 1)]))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 1_000_000, height: 1_000_000))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let advance = layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: source.length)).x
        var ink = CGRect.null
        for run in CTLineGetGlyphRuns(CTLineCreateWithAttributedString(source)) as! [CTRun] {
            let face = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetStringIndices(run, CFRange(), &indices)
            for index in 0..<count {
                var glyph = glyphs[index]
                let bounds = CTFontGetBoundingRectsForGlyphs(face, .horizontal, &glyph, nil, 1)
                let x = layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: indices[index])).x
                if !bounds.isEmpty { ink = ink.union(bounds.offsetBy(dx: x, dy: 0)) }
            }
        }
        let result = Edges(leading: ink.isNull ? 0 : ink.minX, trailing: ink.isNull ? 0 : advance - ink.maxX, advance: advance)
        if edgeCache.count >= 512 { edgeCache.removeAll(keepingCapacity: true) }
        if string.utf8.count <= 128 { edgeCache[key] = result }
        return result
    }

    @MainActor private static func imageInsets(_ image: NSImage) -> (CGFloat, CGFloat) {
        let key = ObjectIdentifier(image)
        if let cached = imageCache[key] { return (cached.1, cached.2) }
        guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              bitmap.pixelsWide > 0 else { return (0, 0) }
        var first = bitmap.pixelsWide, last = -1
        for x in 0..<bitmap.pixelsWide {
            if (0..<bitmap.pixelsHigh).contains(where: { (bitmap.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.05 }) {
                first = min(first, x)
                last = x
            }
        }
        guard last >= first else { return (0, 0) }
        let scale = 14 / CGFloat(bitmap.pixelsWide)
        let left = CGFloat(first) * scale
        let right = CGFloat(bitmap.pixelsWide - last - 1) * scale
        if imageCache.count >= 128 { imageCache.removeAll(keepingCapacity: true) }
        imageCache[key] = (image, left, right)
        return (left, right)
    }
}
