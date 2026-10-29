import AppKit
import SwiftUI
@testable import OMPGUI

@main
private enum WallpaperChecks {
    @MainActor private static var checks = 0

    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }

    private static func fixture(white: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: 512, height: 256, bitsPerComponent: 8, bytesPerRow: 2048,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: white ? 1 : 0, green: 1, blue: white ? 1 : 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 256))
        if !white {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 128, y: 0, width: 128, height: 256))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 256, y: 0, width: 128, height: 256))
            // Fine detail near the top, separated from the broad colour regions below.
            for x in stride(from: 128, to: 384, by: 8) {
                context.setFillColor((x / 8).isMultiple(of: 2)
                    ? CGColor(red: 1, green: 0, blue: 0, alpha: 1)
                    : CGColor(red: 0, green: 0, blue: 1, alpha: 1))
                context.fill(CGRect(x: x, y: 176, width: 8, height: 64))
            }
        }
        return context.makeImage()!
    }

    @MainActor private static func render(_ picture: CGImage?, opacity: Double, dark: Bool, softness: Double = 0.5,
                                          detail: Bool = false, reduced: Bool = false,
                                          size: CGSize = CGSize(width: 512, height: 256)) -> NSBitmapImageRep {
        let image = picture.map {
            let prepared = WallpaperEffect.current.prepare($0, softness: softness)!
            return NSImage(cgImage: prepared, size: NSSize(width: prepared.width, height: prepared.height))
        }
        let content = Color.clear
            .overlay {
                if detail { Color.clear.detailSheet() }
            }
            .background {
                if reduced {
                    // macOS exposes this accessibility environment value read-only.
                    // Draw its production fallback without changing system preferences.
                    WindowBackdropSurface(opacity: opacity, wallpaper: image, usesSolidFallback: true)
                } else {
                    WindowBackdrop(opacity: opacity, wallpaper: image)
                }
            }
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(red: 0, green: 1, blue: 0))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let rendered = renderer.cgImage else { preconditionFailure("The production backdrop must render offscreen") }
        return NSBitmapImageRep(cgImage: rendered)
    }

    private static func color(_ bitmap: NSBitmapImageRep, x: Int, y: Int = 160) -> NSColor {
        bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    }

    // A softened picture must keep broad regions while suppressing small line details.
    private static func contrast(_ bitmap: NSBitmapImageRep, redX: Int = 208, blueX: Int = 304, y: Int = 160) -> CGFloat {
        let red = color(bitmap, x: redX, y: y)
        let blue = color(bitmap, x: blueX, y: y)
        return min(red.redComponent - blue.redComponent, blue.blueComponent - red.blueComponent)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return linear(color.redComponent) * 0.2126 + linear(color.greenComponent) * 0.7152 + linear(color.blueComponent) * 0.0722
    }

    @MainActor static func main() throws {
        guard CaptureRun.isEnabled, let output = CaptureRun.outputDirectory, let defaults = CaptureRun.defaults else {
            fatalError("Require isolated capture storage and preferences")
        }
        _ = NSApplication.shared // Offscreen image drawing only; no visible application window.
        defaults.removePersistentDomain(forName: CaptureRun.suiteName)
        defer { defaults.removePersistentDomain(forName: CaptureRun.suiteName) }
        defaults.set(false, forKey: "performanceMode")
        let picture = fixture()
        for dark in [false, true] {
            ThemeManager.current = dark ? .dark : .light
            for detail in [false, true] {
                let transparent = render(picture, opacity: 0, dark: dark, detail: detail)
                let stock = render(picture, opacity: AppSettings.defaultBackdropOpacity, dark: dark, detail: detail)
                let solid = render(picture, opacity: 1, dark: dark, detail: detail)
                let sharp = render(picture, opacity: 1, dark: dark, softness: 0, detail: detail)
                expect(abs(contrast(transparent)) < 0.01, "Zero opacity must reveal the desktop without wallpaper detail")
                expect(contrast(stock) > 0.06,
                       "Gaussian blur must preserve broad image regions at the default transparency, including behind the content surface (dark=\(dark), detail=\(detail), contrast=\(contrast(stock)))")
                expect(contrast(solid) > contrast(stock) + 0.04,
                       "Increasing opacity must strengthen the processed picture without changing its treatment")
                expect(abs(contrast(solid, redX: 196, blueX: 204, y: 40)) < 0.08,
                       "Positive softness must suppress distracting fine lines")
                expect(contrast(sharp, redX: 196, blueX: 204, y: 40) > contrast(sharp) * 0.8,
                       "Zero softness at full opacity must preserve fine detail without a mandatory blur, including behind content surfaces")
                try stock.representation(using: .png, properties: [:])!
                    .write(to: output.appendingPathComponent("wallpaper-\(dark ? "dark" : "light")-\(detail ? "content" : "sidebar").png"))
            }

            let square = render(picture, opacity: 1, dark: dark, size: CGSize(width: 256, height: 256))
            expect(square.pixelsWide == 256 && square.pixelsHigh == 256, "Aspect fill must keep the assigned viewport")
            for x in [32, 224] {
                let edge = color(square, x: x, y: 160)
                expect(max(edge.redComponent, edge.blueComponent) > edge.greenComponent + 0.12,
                       "A square window must crop the green outer margins and keep image pixels at both edges")
            }

            let baseEdge = contrast(render(picture, opacity: 1, dark: dark, softness: 0), redX: 248, blueX: 264)
            let gentleEdge = contrast(render(picture, opacity: 1, dark: dark, softness: 0.25), redX: 248, blueX: 264)
            let softerEdge = contrast(render(picture, opacity: 1, dark: dark, softness: 1), redX: 248, blueX: 264)
            expect(gentleEdge < baseEdge - 0.03,
                   "Moving right from zero must gradually soften the sharp picture (sharp=\(baseEdge), gentle=\(gentleEdge))")
            expect(softerEdge < gentleEdge - 0.03,
                   "Moving farther right must increase Gaussian softness (gentle=\(gentleEdge), soft=\(softerEdge))")

            if dark {
                let bright = render(fixture(white: true), opacity: 1, dark: true)
                let background = color(bright, x: 208)
                let foreground = NSColor(deviceRed: 0.85 + 0.15 * background.redComponent,
                                         green: 0.85 + 0.15 * background.greenComponent,
                                         blue: 0.85 + 0.15 * background.blueComponent, alpha: 1)
                expect((luminance(foreground) + 0.05) / (luminance(background) + 0.05) >= 4.5,
                       "Bright wallpapers must keep dark-mode light text readable at the opaque endpoint")
            }
            let reduced = render(picture, opacity: 0.5, dark: dark, reduced: true)
            let reducedEmpty = render(nil, opacity: 0.5, dark: dark, reduced: true)
            defaults.set(true, forKey: "performanceMode")
            let performance = render(picture, opacity: 0.5, dark: dark)
            let performanceEmpty = render(nil, opacity: 0.5, dark: dark)
            for x in [4, 208, 304, 508] {
                expect(color(reduced, x: x) == color(reducedEmpty, x: x),
                       "Reduce Transparency must use the solid fallback regardless of the chosen image")
                expect(color(performance, x: x) == color(performanceEmpty, x: x),
                       "Performance mode must use the solid fallback regardless of the chosen image")
            }
            defaults.set(false, forKey: "performanceMode")
        }
        print("PASS wallpaper: \(checks) checks for the sharp endpoint, gradual Gaussian smoothing, broad image regions, opacity, content surfaces, fill crop, dark contrast and solid fallbacks. Offscreen previews: \(output.path)")
    }
}
