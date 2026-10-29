import AppKit
import SwiftUI

/// A plain multiline native field. The containing view supplies its
/// surface; neither the scroll view nor the text view paints an opaque panel.
struct ChromeTextEditor: NSViewRepresentable {
    @Binding var text: String
    let label: String
    var placeholder: String? = nil
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let editor = ChromeEditorTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 6, height: 6)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.delegate = context.coordinator
        scroll.documentView = editor
        update(editor)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if let editor = scroll.documentView as? ChromeEditorTextView { update(editor) }
    }

    private func update(_ editor: ChromeEditorTextView) {
        editor.isEditable = isEnabled
        editor.isSelectable = true
        let font = NSFont.systemFont(ofSize: TypeScale.shared.ui(TypeScale.stockPointSize(.callout)))
        if editor.font != font { editor.font = font }
        editor.textColor = .labelColor
        editor.insertionPointColor = Chrome.accentNSColor
        editor.setAccessibilityLabel(Chrome.localized(label))
        editor.placeholder = placeholder.map { Chrome.localized($0) }
        // Do not interrupt an in-progress input-method composition. Normal
        // typing already agrees with the binding and retains native undo/caret.
        if !editor.hasMarkedText(), editor.string != text {
            let selected = editor.selectedRange()
            editor.string = text
            let count = (text as NSString).length
            let start = min(selected.location, count)
            editor.setSelectedRange(NSRange(location: start, length: min(selected.length, count - start)))
            editor.needsDisplay = true
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.documentView as? NSTextView)?.delegate = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChromeTextEditor
        init(_ parent: ChromeTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

/// Draw the hint outside text storage so it never enters the binding, selection,
/// undo history or submitted message. It shares the native text's inset and font.
private final class ChromeEditorTextView: NSTextView {
    var placeholder: String? {
        didSet {
            guard placeholder != oldValue else { return }
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }

    private var showsPlaceholder: Bool {
        string.isEmpty && !hasMarkedText() && placeholder?.isEmpty == false
    }
    private var placeholderShown = false

    override func didChangeText() {
        super.didChangeText()
        if showsPlaceholder != placeholderShown { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        placeholderShown = showsPlaceholder
        guard placeholderShown, let placeholder else { return }
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        let rect = NSRect(x: origin.x + padding, y: origin.y,
                          width: max(0, bounds.width - 2 * (origin.x + padding)),
                          height: max(0, bounds.height - 2 * origin.y))
        (placeholder as NSString).draw(in: rect, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ])
    }
}
