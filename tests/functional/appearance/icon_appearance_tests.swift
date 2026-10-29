import AppKit
import SwiftUI
@testable import OMPGUI

@main
private enum IconAppearanceChecks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }

    @MainActor private static func fixture(color: NSColor, whitePlate: Bool = false, hole: Bool = false, touchesEdge: Bool = false) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 28, pixelsHigh: 28,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let clear = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0)
        let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        let rgb = color.usingColorSpace(.deviceRGB)!
        let ink = NSColor(deviceRed: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
        for y in 0..<28 {
            for x in 0..<28 {
                let isMark = x >= (touchesEdge ? 0 : 4) && x < 24 && y >= 4 && y < 24
                let isHole = hole && (6..<22).contains(x) && (6..<22).contains(y)
                bitmap.setColor(isHole ? white : isMark ? ink : whitePlate ? white : clear, atX: x, y: y)
            }
        }
        return bitmap.representation(using: .png, properties: [:])!
    }

    @MainActor private static func pixel(_ image: NSImage, x: Int = 7, y: Int = 7) -> NSColor {
        let bitmap = image.representations.compactMap { $0 as? NSBitmapImageRep }.first
            ?? NSBitmapImageRep(data: image.tiffRepresentation!)!
        return bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    }

    @MainActor private static func drawing(_ cell: AdaptiveIconAttachmentCell, in view: NSTextView, dark: Bool) -> NSImage {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.textContainerInset = .zero
        view.textContainer!.lineFragmentPadding = 0
        view.textContainer!.containerSize = NSSize(width: 40, height: 40)
        let existing = view.textStorage?.length == 1
            ? view.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment : nil
        if existing?.attachmentCell as? AdaptiveIconAttachmentCell !== cell {
            let attachment = NSTextAttachment()
            attachment.attachmentCell = cell
            attachment.bounds = NSRect(origin: cell.cellBaselineOffset(), size: cell.cellSize())
            view.textStorage!.setAttributedString(NSAttributedString(attachment: attachment))
        }
        let layout = view.layoutManager!
        layout.ensureLayout(for: view.textContainer!)
        let glyphs = NSRange(location: 0, length: 1)
        let bounds = layout.boundingRect(forGlyphRange: glyphs, in: view.textContainer!)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 28, pixelsHigh: 28,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current!.cgContext.scaleBy(x: 2, y: 2)
        (dark ? NSColor(deviceWhite: 0.08, alpha: 1) : NSColor.white).setFill()
        NSRect(x: 0, y: 0, width: 14, height: 14).fill()
        let context = NSGraphicsContext.current!.cgContext
        context.translateBy(x: -bounds.minX, y: 14 + bounds.minY)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        // The global drawing context deliberately disagrees with the actual view.
        NSAppearance(named: dark ? .aqua : .darkAqua)!.performAsCurrentDrawingAppearance {
            layout.drawGlyphs(forGlyphRange: glyphs, at: .zero)
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 14, height: 14))
        image.addRepresentation(bitmap)
        return image
    }

    @MainActor private static func luminance(_ color: NSColor) -> CGFloat {
        (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }

    @MainActor private static func popover(_ image: NSImage, dark: Bool) -> NSImage {
        let view = PopoverItem("Fixture", image: image) {}
            .frame(width: 220)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color.black : Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.nsImage!
    }

    /// Measure actual attachment ink against neighbouring text, rather than
    /// trusting stored bounds or cropping away a misplaced baseline.
    @MainActor private static func inlinePlacement(_ icon: NSImage, font: NSFont, offset: CGFloat, adaptive: Bool, dark: Bool) -> (image: NSImage, bottom: CGFloat) {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 40))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.textContainerInset = .zero
        view.textContainer!.lineFragmentPadding = 0
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1),
        ]
        let text = NSMutableAttributedString(string: "中文（", attributes: attributes)
        let index = text.length
        let attachment = NSTextAttachment()
        if adaptive {
            attachment.attachmentCell = AdaptiveIconAttachmentCell(image: icon, baselineOffset: offset, dimmed: false)
        } else {
            attachment.image = icon
        }
        attachment.bounds = NSRect(x: 0, y: offset, width: 14, height: 14)
        text.append(NSAttributedString(attachment: attachment))
        let labelIndex = text.length
        text.append(NSAttributedString(string: " Assignment_1.ipynb）", attributes: attributes))
        view.textStorage!.setAttributedString(text)
        let layout = view.layoutManager!
        let container = view.textContainer!
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: index)
        let labelGlyph = layout.glyphIndexForCharacter(at: labelIndex)
        let iconX = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + layout.location(forGlyphAt: glyph).x
        let baseline = layout.lineFragmentRect(forGlyphAt: labelGlyph, effectiveRange: nil).minY + layout.location(forGlyphAt: labelGlyph).y
        let scale: CGFloat = 4
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1360, pixelsHigh: 160,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.clear(CGRect(x: 0, y: 0, width: 1360, height: 160))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: 40)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        layout.drawGlyphs(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs), at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        var inkBottom: CGFloat = -.infinity
        for y in 0..<bitmap.pixelsHigh {
            for x in Int(ceil(iconX * scale))..<Int(floor((iconX + 14) * scale)) {
                let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if color.alphaComponent > 0.5 {
                    inkBottom = max(inkBottom, CGFloat(y + 1) / scale)
                }
            }
        }
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return (image, baseline - inkBottom)
    }

    @MainActor private static func checkToolRowSymbols() {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bundle = Bundle(url: repo.appendingPathComponent("build.noindex/development/Build/Products/Debug/OMP GUI Dev.app"))!
        let kinds: [ToolCall.Kind] = [.command, .read, .edit, .search, .web, .mcp, .agent, .other]
        let symbols = Set(OMPTool.allCases.map { OMPToolSymbols.symbol(for: $0) }
            + kinds.map { OMPToolSymbols.symbol(for: $0) } + ["photo", "powerplug"]
            + TimelineRowIcon.allCases.map { .system($0.rawValue) })
        for symbol in symbols {
            let source: NSImage? = switch symbol {
            case .system(let name): NSImage(systemSymbolName: name, accessibilityDescription: nil)
            case .custom(let name): bundle.image(forResource: name)
            }
            guard let image = source?
                    .withSymbolConfiguration(.init(pointSize: TimelineIconMetrics.pointSize, weight: .regular)),
                  let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else {
                fatalError("Native tool-row symbol is missing or cannot render: \(symbol)")
            }
            expect(image.isTemplate, "Tool-row symbols must follow semantic foreground colours: \(symbol)")
            var hasInk = false
            var hasTransparency = false
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let alpha = bitmap.colorAt(x: x, y: y)!.alphaComponent
                    hasInk = hasInk || alpha > 0.25
                    hasTransparency = hasTransparency || alpha < 0.05
                }
            }
            expect(hasInk && hasTransparency, "Tool-row strokes or transparent canvas were lost: \(symbol)")
        }
        let native = ToolCall(kind: .command, title: "An unrelated caption", toolName: "read")
        let mounted = ToolCall(kind: .edit, title: "Another caption", toolName: "write", toolDevice: "read")
        let unknown = ToolCall(kind: .read, title: "read", toolName: "fixture_extension")
        let legacy = ToolCall(kind: .read, title: "grep")
        expect(OMPToolSymbols.symbol(for: native) == OMPToolSymbols.symbol(for: OMPTool.read),
               "Native tool identity must take precedence over transport kind and caption")
        expect(OMPToolSymbols.symbol(for: mounted) == OMPToolSymbols.symbol(for: native),
               "Mounted device identity must take precedence over the write transport")
        expect(OMPToolSymbols.symbol(for: unknown) == OMPToolSymbols.symbol(for: .other),
               "An unknown named extension must not inherit a built-in icon from its caption or kind")
        expect(OMPToolSymbols.symbol(for: legacy) == OMPToolSymbols.symbol(for: ToolCall.Kind.read),
               "An archive without native identity must retain its category fallback")
        expect(OMPToolSymbols.symbol(for: OMPTool.read) == "text.menu",
               "Read rows must use the owner-selected text menu")
        expect(OMPToolSymbols.symbol(for: OMPTool.find) == .custom("tool-find-folder"),
               "Find rows must use the custom folder and upper-right magnifying glass")
        let find = ToolCall(kind: .search, title: "Search", toolName: "find")
        let mountedFind = ToolCall(kind: .edit, title: "Find", toolName: "write", toolDevice: "find")
        expect(OMPToolSymbols.symbol(for: find) == OMPToolSymbols.symbol(for: mountedFind),
               "Direct and mounted find calls must resolve the same custom symbol")
        expect(ToolPresentation.symbol(for: native) == OMPToolSymbols.symbol(for: native),
               "Tool presentations must share the same exact native identity mapping")
        print("PASS SF tool rows: \(OMPTool.allCases.count) native IDs, \(symbols.count) renderable symbols and identity/fallback boundaries")
    }

    @MainActor static func main() throws {
        guard CaptureRun.isEnabled, let output = CaptureRun.outputDirectory else { fatalError("Require isolated capture storage") }
        _ = NSApplication.shared // Native drawing only; no application launch or visible window.
        checkToolRowSymbols()
        let darkMark = NSColor(deviceRed: 0.14, green: 0.16, blue: 0.18, alpha: 1)
        let whiteMark = NSColor(deviceWhite: 1, alpha: 1)
        let brand = NSColor(deviceRed: 0.1, green: 0.65, blue: 0.3, alpha: 1)
        let neutral = FaviconCache.preparedImage(fixture(color: darkMark))!
        let white = FaviconCache.preparedImage(fixture(color: whiteMark, touchesEdge: true))!
        let hollow = FaviconCache.preparedImage(fixture(color: darkMark, whitePlate: true, hole: true))!
        let colour = FaviconCache.preparedImage(fixture(color: brand))!
        for size: CGFloat in [12, 15, 18] {
            let font = NSFont.systemFont(ofSize: size)
            let offset = font.descender + 1
            for (name, icon) in [("neutral", neutral), ("colour", colour)] {
                for dark in [false, true] {
                    let original = inlinePlacement(icon, font: font, offset: offset, adaptive: false, dark: dark)
                    let current = inlinePlacement(icon, font: font, offset: offset, adaptive: true, dark: dark)
                    let metrics = "\(name), \(size) pt, dark=\(dark): static=\(original.bottom), adaptive=\(current.bottom)"
                    if size == 15 {
                        try current.image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }!
                            .write(to: output.appendingPathComponent("inline-\(name)-\(dark ? "dark" : "light").png"))
                    }
                    expect(abs(current.bottom - original.bottom) <= 0.25,
                           "Adaptive drawing changed native image placement: \(metrics)")
                }
            }
        }
        let preparation = [("neutral", neutral), ("white", white), ("hollow", hollow)].map { name, icon in
            let bitmap = icon.representations.compactMap { $0 as? NSBitmapImageRep }.first
            return "\(name): template=\(icon.isTemplate), raster=\(bitmap?.pixelsWide ?? 0)x\(bitmap?.pixelsHigh ?? 0), pixel=\(pixel(icon))"
        }.joined(separator: "; ")
        expect(neutral.isTemplate && white.isTemplate && hollow.isTemplate, "Neutral dark/white marks were not prepared as adaptive templates: \(preparation)")
        expect(!colour.isTemplate, "Colour artwork was converted into a monochrome template")
        expect(pixel(hollow, x: 0, y: 0).alphaComponent < 0.02, "A white favicon plate survived normalization")
        expect(pixel(hollow, x: 14, y: 14).alphaComponent < 0.02, "Template preparation filled a white cutout")
        expect(pixel(white, x: 0, y: 14).alphaComponent > 0.95, "White foreground touching an edge was erased as a background")
        expect(pixel(neutral).alphaComponent > 0.95, "A dark grey mark lost its opaque coverage")
        expect(neutral.size == NSSize(width: 14, height: 14), "Appearance adaptation changed favicon dimensions")
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        let baseline = NSFont.systemFont(ofSize: 15).descender + 1
        let cell = AdaptiveIconAttachmentCell(image: neutral, baselineOffset: baseline, dimmed: false)
        let light = drawing(cell, in: view, dark: false)
        let dark = drawing(cell, in: view, dark: true)
        let lightAgain = drawing(cell, in: view, dark: false)
        for (name, image) in [("native-light", light), ("native-dark", dark)] {
            try image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }!
                .write(to: output.appendingPathComponent(name + ".png"))
        }
        expect(luminance(pixel(light)) < 0.25 && luminance(pixel(dark)) > 0.75,
               "Native attachments did not resolve the actual text view's appearance: light=\(pixel(light)), dark=\(pixel(dark))")
        expect(abs(luminance(pixel(light)) - luminance(pixel(lightAgain))) < 0.01,
               "A cached attachment kept its previous appearance after switching back")
        let whiteCell = AdaptiveIconAttachmentCell(image: white, baselineOffset: baseline, dimmed: false)
        expect(luminance(pixel(drawing(whiteCell, in: view, dark: false))) < 0.25,
               "A white source mark disappeared in light appearance")
        let colourCell = AdaptiveIconAttachmentCell(image: colour, baselineOffset: baseline, dimmed: false)
        for dark in [false, true] {
            let actual = pixel(drawing(colourCell, in: view, dark: dark))
            expect(abs(actual.greenComponent - brand.greenComponent) < 0.03 && abs(actual.redComponent - brand.redComponent) < 0.03,
                   "Native icon drawing recoloured a brand mark")
            let menu = popover(neutral, dark: dark)
            let sample = pixel(menu, x: 24, y: 20)
            expect(dark ? luminance(sample) > 0.75 : luminance(sample) < 0.25,
                   "The shared link popover ignored template icon appearance")
            try menu.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }!
                .write(to: output.appendingPathComponent("popover-\(dark ? "dark" : "light").png"))
        }
        print("PASS adaptive icons: \(checks) checks for neutral/colour artwork, white foreground, cutouts, fractional inline placement, cached native theme round trips and shared popover rendering. Offscreen previews: \(output.path)")
    }
}
