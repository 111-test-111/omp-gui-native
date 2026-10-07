#!/usr/bin/env swift
// Renders the Droppy Code installer (DMG) window background at 1x and 2x, plus a
// preview composite that mimics how Finder lays out the two icons on top of it.
//
// Usage: swift generate_installer_background.swift <output-directory> [path/to/AppIcon.icns]
//
// The geometry here is the single source of truth shared with the pre-baked
// .DS_Store (see release/dmg/README.md). If any of these constants change, the
// .DS_Store must be re-baked so Finder's icon positions match the artwork:
//   window content size: 660x370
//   Droppy Code.app icon center: (165, 208)   Applications icon center: (495, 208)
//   icon size: 128
import AppKit

// Canvas + layout (points, top-left origin)
let canvasW: CGFloat = 660
let canvasH: CGFloat = 370
// The exported image carries extra flat-color bleed below the composition so
// that no interpretation of Finder's WindowBounds (with or without titlebar
// chrome) can ever expose an unpainted strip, which would render white in
// light mode. Finder anchors backgrounds top-left, so the bleed only shows if
// the content area is taller than the designed 370pt, and then it is just
// more of the same flat color.
let exportBleed: CGFloat = 60
let appIconCenter = CGPoint(x: 165, y: 208)
let applicationsIconCenter = CGPoint(x: 495, y: 208)
let iconSize: CGFloat = 128

// Brand tokens (website styles).
let backgroundColor = NSColor(srgbRed: 0x0b / 255.0, green: 0x0e / 255.0, blue: 0x14 / 255.0, alpha: 1)
let textPrimary = NSColor(srgbRed: 0xe8 / 255.0, green: 0xea / 255.0, blue: 0xed / 255.0, alpha: 1)
let accent = NSColor(srgbRed: 0x4f / 255.0, green: 0x9c / 255.0, blue: 0xff / 255.0, alpha: 1)
let wordmark = "Droppy Code"
let outputStem = "installer-background"

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: generate_installer_background.swift <output-directory> [path/to/AppIcon.icns]\n".utf8))
    exit(64)
}
let outputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func notchPath(centerX: CGFloat, width: CGFloat, height: CGFloat, cornerRadius: CGFloat, filletRadius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let left = centerX - width / 2
    let right = centerX + width / 2
    path.move(to: CGPoint(x: left - filletRadius, y: 0))
    path.addQuadCurve(to: CGPoint(x: left, y: filletRadius), control: CGPoint(x: left, y: 0))
    path.addLine(to: CGPoint(x: left, y: height - cornerRadius))
    path.addArc(tangent1End: CGPoint(x: left, y: height), tangent2End: CGPoint(x: left + cornerRadius, y: height), radius: cornerRadius)
    path.addLine(to: CGPoint(x: right - cornerRadius, y: height))
    path.addArc(tangent1End: CGPoint(x: right, y: height), tangent2End: CGPoint(x: right, y: height - cornerRadius), radius: cornerRadius)
    path.addLine(to: CGPoint(x: right, y: filletRadius))
    path.addQuadCurve(to: CGPoint(x: right + filletRadius, y: 0), control: CGPoint(x: right, y: 0))
    path.closeSubpath()
    return path
}

func drawText(_ string: String, font: NSFont, color: NSColor, center: CGPoint) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let attributed = NSAttributedString(string: string, attributes: attributes)
    let size = attributed.size()
    attributed.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
}

func drawBackground(into context: CGContext) {
    // Flat base, matching the site's near-black canvas
    context.setFillColor(backgroundColor.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH + exportBleed))

    // One soft accent glow bleeding out from under the notch
    context.saveGState()
    let glowColors = [accent.withAlphaComponent(0.16).cgColor, accent.withAlphaComponent(0).cgColor] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: glowColors, locations: [0, 1]) {
        context.translateBy(x: canvasW / 2, y: 4)
        context.scaleBy(x: 1, y: 0.42)
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 210, options: [])
    }
    context.restoreGState()

    // The notch silhouette, hanging from the top edge with outward fillets
    context.setFillColor(NSColor.black.cgColor)
    context.addPath(notchPath(centerX: canvasW / 2, width: 150, height: 27, cornerRadius: 10, filletRadius: 7))
    context.fillPath()

    // Wordmark
    drawText(wordmark, font: .systemFont(ofSize: 31, weight: .semibold), color: textPrimary, center: CGPoint(x: canvasW / 2, y: 88))

    // A quiet straight arrow on the icons' centerline. Painted-pixel
    // clearance is an equal 34pt on both sides, measured against each icon's
    // VISUAL edge at this height (app icon case right edge x = 215.5, folder
    // body left edge x = 431 + 5 = 436), with the 1.25pt round-cap overhang
    // accounted for.
    let arrowColor = NSColor(white: 1, alpha: 0.32)
    let arrowY = appIconCenter.y
    let arrowStart: CGFloat = 250.75
    let arrowEnd: CGFloat = 400.75
    // Shaft and chevron stroked as ONE path in ONE operation: with the
    // translucent stroke color, separate strokes would double the alpha
    // where they overlap at the vertex and render a brighter blob on the tip.
    let arrowPath = CGMutablePath()
    arrowPath.move(to: CGPoint(x: arrowStart, y: arrowY))
    arrowPath.addLine(to: CGPoint(x: arrowEnd, y: arrowY))
    arrowPath.move(to: CGPoint(x: arrowEnd - 11, y: arrowY - 9))
    arrowPath.addLine(to: CGPoint(x: arrowEnd, y: arrowY))
    arrowPath.addLine(to: CGPoint(x: arrowEnd - 11, y: arrowY + 9))
    context.setStrokeColor(arrowColor.cgColor)
    context.setLineWidth(2.5)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(arrowPath)
    context.strokePath()

    // Helper caption under the arrow
    drawText("Drag to install", font: .systemFont(ofSize: 12, weight: .medium), color: NSColor(white: 1, alpha: 0.40), center: CGPoint(x: canvasW / 2, y: 246))
}

func render(scale: CGFloat, height: CGFloat = canvasH, drawExtras: ((CGContext) -> Void)? = nil) -> NSBitmapImageRep {
    let pixelW = Int(canvasW * scale)
    let pixelH = Int(height * scale)
    guard let context = CGContext(
        data: nil, width: pixelW, height: pixelH, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Could not create bitmap context") }
    // Flip to top-left origin so layout constants read naturally
    context.translateBy(x: 0, y: CGFloat(pixelH))
    context.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    drawBackground(into: context)
    drawExtras?(context)
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let cgImage = context.makeImage() else { fatalError("Could not snapshot bitmap context") }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: canvasW, height: height)
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encode failed") }
    try data.write(to: url)
}

// 1x + 2x background layers (combined into a hidpi TIFF by the caller)
try writePNG(render(scale: 1, height: canvasH + exportBleed), to: outputDir.appendingPathComponent("\(outputStem).png"))
try writePNG(render(scale: 2, height: canvasH + exportBleed), to: outputDir.appendingPathComponent("\(outputStem)@2x.png"))

// Preview composite: what the mounted window should look like, with icons and
// Finder-style labels at the exact .DS_Store positions.
func drawIcon(_ image: NSImage?, center: CGPoint, label: String, in context: CGContext) {
    let rect = CGRect(x: center.x - iconSize / 2, y: center.y - iconSize / 2, width: iconSize, height: iconSize)
    image?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    drawText(label, font: .systemFont(ofSize: 12), color: textPrimary, center: CGPoint(x: center.x, y: center.y + iconSize / 2 + 12))
}
// The preview's app icon: an optional third argument names an .icns, else the installed Droppy Code's.
let previewIconPath = CommandLine.arguments.dropFirst(2).first { $0.hasSuffix(".icns") }
let appIcon = previewIconPath.flatMap { NSImage(contentsOfFile: $0) }
    ?? NSImage(contentsOfFile: "/Applications/Droppy Code.app/Contents/Resources/AppIcon.icns")
    ?? NSWorkspace.shared.icon(forFile: "/Applications/Droppy Code.app")
let applicationsIcon = NSWorkspace.shared.icon(forFile: "/Applications")
let preview = render(scale: 2) { context in
    drawIcon(appIcon, center: appIconCenter, label: wordmark, in: context)
    drawIcon(applicationsIcon, center: applicationsIconCenter, label: "Applications", in: context)
}
try writePNG(preview, to: outputDir.appendingPathComponent("preview-mock.png"))
print("Rendered installer background + preview into \(outputDir.path)")
