import AppKit

/// Turn neutral downloaded marks into alpha templates once, preserving colour
/// artwork and the original raster geometry. Appearance is resolved at drawing.
enum AdaptiveIconImage {
    @MainActor
    static func prepared(_ image: NSImage) -> NSImage {
        guard !image.isTemplate,
              let source = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              source.pixelsWide > 0, source.pixelsHigh > 0,
              source.pixelsWide <= 64, source.pixelsHigh <= 64 else { return image }
        var weight: CGFloat = 0, brightness: CGFloat = 0
        var edgeWeight: CGFloat = 0, edgeBrightness: CGFloat = 0
        var minimum: CGFloat = 1, maximum: CGFloat = 0
        for y in 0..<source.pixelsHigh {
            for x in 0..<source.pixelsWide {
                guard let color = source.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.05 else { continue }
                let low = min(color.redComponent, color.greenComponent, color.blueComponent)
                let high = max(color.redComponent, color.greenComponent, color.blueComponent)
                // A coloured detail belongs to the site's artwork too.
                guard high - low <= 0.1 else { return image }
                let luminance = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                weight += color.alphaComponent
                brightness += luminance * color.alphaComponent
                let touchesTransparency = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)].contains { point in
                    point.0 < 0 || point.0 >= source.pixelsWide || point.1 < 0 || point.1 >= source.pixelsHigh
                        || (source.colorAt(x: point.0, y: point.1)?.alphaComponent ?? 0) <= 0.05
                }
                if touchesTransparency {
                    edgeWeight += color.alphaComponent
                    edgeBrightness += luminance * color.alphaComponent
                }
                minimum = min(minimum, luminance)
                maximum = max(maximum, luminance)
            }
        }
        guard weight > 0,
              let mask = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.pixelsWide, pixelsHigh: source.pixelsHigh,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        // The outer mark, rather than the area of its white cutouts, decides
        // polarity. Outlined neutral logos can have mostly empty interiors.
        let darkMark = (edgeWeight > 0 ? edgeBrightness / edgeWeight : brightness / weight) <= 0.5
        let normalization = max(0.01, darkMark ? 1 - minimum : maximum)
        for y in 0..<source.pixelsHigh {
            for x in 0..<source.pixelsWide {
                let color = source.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .clear
                let luminance = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                let coverage = min(1, max(0, (darkMark ? 1 - luminance : luminance) / normalization))
                mask.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: color.alphaComponent * coverage), atX: x, y: y)
            }
        }
        let result = NSImage(size: image.size)
        result.addRepresentation(mask)
        result.isTemplate = true
        return result
    }
}

/// TextKit does not apply SwiftUI's template tint to image attachments. Resolve
/// the actual text view's appearance on every draw, including cached paragraphs.
final class AdaptiveIconAttachmentCell: NSTextAttachmentCell {
    private let icon: NSImage
    private let dimmed: Bool
    nonisolated private let dimensions: NSSize
    nonisolated private let baseline: NSPoint

    init(image: NSImage, baselineOffset: CGFloat, dimmed: Bool) {
        icon = image
        self.dimmed = dimmed
        dimensions = NSSize(width: 14, height: 14)
        baseline = NSPoint(x: 0, y: baselineOffset)
        super.init(textCell: "")
    }

    required init(coder: NSCoder) { fatalError("Icon cells are created from Markdown source") }
    nonisolated override func cellSize() -> NSSize { dimensions }
    nonisolated override func cellBaselineOffset() -> NSPoint { baseline }

    nonisolated override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        // Preserve fractional baseline placement instead of rounding it down
        // to whole points, matching native image attachments.
        var frame = super.cellFrame(for: textContainer, proposedLineFragment: lineFrag, glyphPosition: position, characterIndex: charIndex)
        frame.origin.y += baseline.y - floor(baseline.y)
        return frame
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(withFrame: cellFrame, in: controlView, characterIndex: NSNotFound)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex: Int) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let appearance = controlView?.effectiveAppearance ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            context.saveGState()
            context.beginTransparencyLayer(in: cellFrame, auxiliaryInfo: nil)
            icon.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            if icon.isTemplate {
                let view = controlView as? NSTextView
                let selected = view?.selectedRanges.contains { NSLocationInRange(characterIndex, $0.rangeValue) } == true
                let color = selected ? view?.selectedTextAttributes[.foregroundColor] as? NSColor ?? .selectedTextColor : .labelColor
                (dimmed ? color.withAlphaComponent(color.alphaComponent * 0.7) : color).setFill()
                cellFrame.fill(using: .sourceAtop)
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex: Int, layoutManager: NSLayoutManager) {
        // Layout-manager drawing can omit controlView even for a live text
        // view. Resolve that host rather than using an unrelated global theme.
        var host = controlView
        if host == nil, characterIndex >= 0, characterIndex < (layoutManager.textStorage?.length ?? 0) {
            let glyph = layoutManager.glyphIndexForCharacter(at: characterIndex)
            host = layoutManager.textContainer(forGlyphAt: glyph, effectiveRange: nil)?.textView
        }
        draw(withFrame: cellFrame, in: host, characterIndex: characterIndex)
    }
}
