// Historical SwiftMath baseline, frozen from fd7776e for comparison only.
import AppKit
import CoreText
import SwiftMath

extension NSAttributedString.Key {
    static let mathSource = Self("omp.math.source")
    static let mathLatex = Self("omp.math.latex")
}

/// Only completed formulas reach SwiftMath. Width and appearance are deliberately
/// absent from the cache key: vector geometry is reused on resize and theme changes.
@MainActor
enum MathRendering {
    static let fontName = "Asana-Math"
    enum Result {
        case ready(Layout)
        case failure(String)
        case pending
    }
    @MainActor final class Layout {
        let label: MTMathUILabel
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
        var size: NSSize { NSSize(width: ceil(width) + 4, height: ceil(ascent + descent) + 4) }

        init(label: MTMathUILabel, display: MTMathListDisplay) {
            self.label = label
            width = display.width; ascent = display.ascent; descent = display.descent
        }

        func draw(in rect: NSRect, context: CGContext, flipped: Bool, color: NSColor) {
            context.saveGState()
            defer { context.restoreGState() }
            if flipped {
                context.translateBy(x: rect.minX + 2, y: rect.maxY - 2)
                context.scaleBy(x: 1, y: -1)
            } else {
                context.translateBy(x: rect.minX + 2, y: rect.minY + 2)
            }
            // TextKit leaves a flipped text matrix on the context. SwiftMath's
            // CoreText display list expects ordinary Cartesian text coordinates.
            context.textMatrix = .identity
            // Colour is applied at drawing time, including the streaming veil.
            let resolved = color.usingColorSpace(.sRGB) ?? color
            if label.textColor != resolved { label.textColor = resolved }
            label.displayList?.draw(context)
        }
    }
    private final class Entry: NSObject { let result: Result; init(_ result: Result) { self.result = result } }
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 256
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()
    private static let glyphs: CFCharacterSet = {
        // Avoid asking SwiftMath to register an already-installed font: its
        // registration helper treats CoreText's duplicate-registration error as fatal.
        let postScriptName = "Asana-Math"
        let installed = CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? []
        let font = installed.contains(postScriptName)
            ? CTFontCreateWithName(postScriptName as CFString, 15, nil)
            : MathFont.asanaFont.ctFont(withSize: 15)
        return CTFontCopyCharacterSet(font)
    }()
    private static let fontManager = MTFontManager()
    private(set) static var typesetCount = 0

    static func result(for formula: MarkdownFormula, pointSize: CGFloat) -> Result {
        guard formula.complete else { return .pending }
        let key = "\(formula.mode.rawValue):\(pointSize):\(formula.latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.result }
        let result = build(formula, pointSize: pointSize)
        cache.setObject(Entry(result), forKey: key, cost: formula.latex.utf8.count * 8 + 2048)
        return result
    }

    private static func build(_ formula: MarkdownFormula, pointSize: CGFloat) -> Result {
        guard pointSize.isFinite, pointSize > 0, formula.latex.utf8.count <= 16_384 else { return .failure("Formula is too complex") }
        var depth = 0, slash = false
        for scalar in formula.latex.unicodeScalars {
            if scalar.value > 127, !CharacterSet.whitespacesAndNewlines.contains(scalar), !CFCharacterSetIsLongCharacterMember(glyphs, scalar.value) {
                return .failure("The math font does not contain these characters")
            }
            if !slash {
                if scalar == "{" { depth += 1 }
                if scalar == "}" { depth -= 1 }
                if depth > 64 { return .failure("Formula is too complex") }
            }
            slash = scalar == "\\" && !slash
        }
        guard !formula.latex.isEmpty else { return .failure("Empty formula") }
        typesetCount += 1
        let label = MTMathUILabel()
        label.displayErrorInline = false
        label.font = fontManager.font(withName: fontName, size: pointSize)
        label.fontSize = pointSize
        label.labelMode = formula.mode == .display ? .display : .text
        label.textAlignment = .left
        label.latex = formula.latex
        if label.error != nil { return .failure("Unsupported or invalid LaTeX") }
        let measured = label.fittingSize
        guard measured.width.isFinite, measured.height.isFinite, measured.width > 0, measured.height > 0 else {
            return .failure("The math font does not contain these characters")
        }
        // Stable macOS SwiftMath centres labels at a minimum half-em height. Make
        // that its bounds too, so its public display list has the exact baseline.
        label.frame = NSRect(x: 0, y: 0, width: measured.width, height: max(measured.height, pointSize / 2))
        label.layout()
        guard let display = label.displayList else { return .failure("Unable to render formula") }
        return .ready(Layout(label: label, display: display))
    }

    static func attributed(_ formula: MarkdownFormula, pointSize: CGFloat, color: NSColor) -> NSAttributedString {
        switch result(for: formula, pointSize: pointSize) {
        case .ready(let layout):
            let attachment = NSTextAttachment()
            attachment.bounds = NSRect(x: 0, y: -layout.descent - 2, width: layout.size.width, height: layout.size.height)
            attachment.attachmentCell = MathAttachmentCell(layout: layout, color: color, source: formula.source)
            let text = NSMutableAttributedString(attachment: attachment)
            text.addAttributes([.mathSource: formula.source, .mathLatex: formula.latex, .foregroundColor: color, .font: NSFont.systemFont(ofSize: pointSize)], range: NSRange(location: 0, length: text.length))
            return text
        case .failure(let message):
            return NSAttributedString(string: formula.source, attributes: [
                .font: AppFont.monospaced(size: pointSize),
                .foregroundColor: color,
                .toolTip: Bundle.main.localizedString(forKey: message, value: message, table: "Localizable"),
            ])
        case .pending:
            return NSAttributedString(string: formula.source, attributes: [.font: NSFont.systemFont(ofSize: pointSize), .foregroundColor: color])
        }
    }

    /// Export selected attachments as the original delimited TeX, preserving all
    /// neighbouring Unicode, links and line endings in both plain and rich copy.
    static func exported(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        var replacements: [(NSRange, String, [NSAttributedString.Key: Any])] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { original, range, _ in
            guard original[.attachment] is NSTextAttachment, let source = original[.mathSource] as? String else { return }
            var attributes = original
            attributes.removeValue(forKey: .attachment)
            attributes.removeValue(forKey: .mathSource)
            attributes.removeValue(forKey: .mathLatex)
            replacements.append((range, String(repeating: source, count: range.length), attributes))
        }
        for (range, source, attributes) in replacements.reversed() {
            out.replaceCharacters(in: range, with: NSAttributedString(string: source, attributes: attributes))
        }
        return out
    }

    static func overflowWidth(storage: NSTextStorage, layout: NSLayoutManager, container: NSTextContainer, minimum: CGFloat) -> CGFloat {
        var width = minimum
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            width = max(width, fragment.minX + layout.location(forGlyphAt: glyph).x + attachment.bounds.maxX)
        }
        return ceil(width)
    }
}

private final class MathAttachmentCell: NSTextAttachmentCell {
    private let rendering: MathRendering.Layout
    private let color: NSColor
    nonisolated private let dimensions: NSSize
    nonisolated private let baseline: NSPoint

    init(layout: MathRendering.Layout, color: NSColor, source: String) {
        rendering = layout; self.color = color
        dimensions = layout.size; baseline = NSPoint(x: 0, y: -layout.descent - 2)
        super.init(textCell: "")
        setAccessibilityLabel(source)
    }
    required init(coder: NSCoder) { fatalError("Math cells are created from Markdown source") }
    nonisolated override func cellSize() -> NSSize { dimensions }
    nonisolated override func cellBaselineOffset() -> NSPoint { baseline }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(withFrame: cellFrame, in: controlView, characterIndex: NSNotFound)
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex: Int) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let storage = (controlView as? NSTextView)?.textStorage
        let foreground = characterIndex >= 0 && characterIndex < (storage?.length ?? 0)
            ? storage?.attribute(.foregroundColor, at: characterIndex, effectiveRange: nil) as? NSColor : nil
        let textView = controlView as? NSTextView
        let selected = textView?.selectedRanges.contains { NSLocationInRange(characterIndex, $0.rangeValue) } == true
        let selectedColor = textView?.selectedTextAttributes[.foregroundColor] as? NSColor ?? .selectedTextColor
        rendering.draw(in: cellFrame, context: context, flipped: controlView?.isFlipped ?? NSGraphicsContext.current!.isFlipped, color: selected ? selectedColor : foreground ?? color)
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView, characterIndex: characterIndex)
    }
}
