import AppKit
import SwiftUI

/// Keep AppKit's editing, secure input and search cells while giving the preview
/// fields the same noninteractive glass surface as the SwiftUI input controls.
@MainActor
final class PreviewGlassInputSurface: NSView {
    private let field: NSTextField
    private let glass = NSGlassEffectView()
    private let content = NSView()
    private var performanceMode: Bool?

    init(field: NSTextField) {
        self.field = field
        super.init(frame: .zero)
        wantsLayer = true
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        glass.style = .regular
        content.addSubview(field)
        update(performanceMode: (CaptureRun.defaults ?? .standard).bool(forKey: "performanceMode"))
    }

    required init?(coder: NSCoder) { nil }

    func update(performanceMode: Bool) {
        glass.tintColor = NSColor(Chrome.glassTint).withAlphaComponent(0.3)
        if self.performanceMode != performanceMode {
            // Reuse the field itself when changing the material so its delegate,
            // target and secure value stay with the existing reader.
            let editor = field.currentEditor()
            let wasEditing = editor != nil && window?.firstResponder === editor
            let selection = (editor as? NSTextView)?.selectedRange()
            if performanceMode {
                glass.contentView = nil
                glass.removeFromSuperview()
                addSubview(content)
            } else {
                content.removeFromSuperview()
                glass.contentView = content
                addSubview(glass)
            }
            self.performanceMode = performanceMode
            needsLayout = true
            if wasEditing {
                window?.makeFirstResponder(field)
                if let selection { (field.currentEditor() as? NSTextView)?.setSelectedRange(selection) }
            }
        }
        refreshFallback()
    }

    private func refreshFallback() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer?.backgroundColor = performanceMode == true
                ? NSColor(Chrome.panelControlFill(isDark: isDark)).cgColor : nil
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshFallback()
    }

    override func layout() {
        super.layout()
        let radius = min(bounds.width, bounds.height) / 2
        layer?.cornerRadius = radius
        glass.cornerRadius = radius
        glass.frame = bounds
        content.frame = bounds
        let height = min(22, bounds.height)
        field.frame = NSRect(x: 6, y: floor((bounds.height - height) / 2),
                             width: max(0, bounds.width - 12), height: height)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }
}

@MainActor
enum PreviewNativeGlass {
    static func update(_ button: NSButton, performanceMode: Bool) {
        button.bezelStyle = performanceMode ? .rounded : .glass
        button.isBordered = true
    }
}
