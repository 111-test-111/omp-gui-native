#!/usr/bin/env swift
import AppKit

// Derived asset only: the current release AppIcon and archived artwork stay unchanged.
// Keep the full-bleed System-Masked input; never add an outer rounded mask here.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Tivano/Resources/Assets.xcassets/AppIcon.appiconset")
let output = root.appendingPathComponent("Tivano/Resources/Assets.xcassets/AppIconDev.appiconset")
let metadata = try Data(contentsOf: source.appendingPathComponent("Contents.json"))
let catalog = try JSONSerialization.jsonObject(with: metadata) as! [String: Any]
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for entry in catalog["images"] as! [[String: String]] {
    let name = entry["filename"]!
    let input = source.appendingPathComponent(name)
    let image = NSImage(contentsOf: input)!
    let original = NSBitmapImageRep(data: try Data(contentsOf: input))!
    let width = original.pixelsWide
    let height = original.pixelsHigh
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
    let w = CGFloat(width), h = CGFloat(height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
    let badge = NSRect(x: w * 0.58, y: h * 0.09, width: w * 0.33, height: h * 0.19)
    NSColor(srgbRed: 0.97, green: 0.54, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: badge, xRadius: w * 0.035, yRadius: h * 0.035).fill()
    let text = NSAttributedString(string: "DEV", attributes: [
        .font: NSFont.systemFont(ofSize: w * 0.10, weight: .heavy),
        .foregroundColor: NSColor(srgbRed: 0.13, green: 0.16, blue: 0.13, alpha: 1),
    ])
    let size = text.size()
    text.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
try metadata.write(to: output.appendingPathComponent("Contents.json"))
print("Generated AppIconDev with DEV badge; release icon unchanged.")
