import AppKit
import SwiftUI

// The native helper checks compile the production renderers without the app's
// settings/theme graph or the SwiftMath package. Native views/fonts and the
// actual Chrome controls are exercised offscreen; no application window or
// real formula layout is created.
// The full build verifies the theme graph and SwiftMath implementation.
enum ThemeManager {
    struct Spec {
        var accent: Color? { nil }
        var success: Color { .green }
        var warning: Color { .orange }
        var danger: Color { .red }
        var surface: Color { .white }
    }
    static let spec = Spec()
}
enum CaptureRun { static var defaults: UserDefaults? { nil } }

extension NSAttributedString.Key {
    static let mathSource = Self("omp.math.source")
    static let mathLatex = Self("omp.math.latex")
}

@MainActor enum MathRendering {
    @MainActor final class Layout {
        var size: NSSize { NSSize(width: 20, height: 20) }
        var descent: CGFloat { 4 }
        func draw(in rect: NSRect, context: CGContext, flipped: Bool, color: NSColor) {}
    }
    enum Result { case ready(Layout), pending }
    static func result(for formula: MarkdownFormula, pointSize: CGFloat) -> Result { .pending }
    static func attributed(_ formula: MarkdownFormula, pointSize: CGFloat, color: NSColor) -> NSAttributedString { NSAttributedString(string: formula.source) }
    static func exported(_ text: NSAttributedString) -> NSAttributedString { text }
}
