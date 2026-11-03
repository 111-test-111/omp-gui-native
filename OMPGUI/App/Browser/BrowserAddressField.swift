import AppKit
import SwiftUI

/// A dedicated field editor handles clicks even when AppKit routes them past
/// NSTextField directly. Selection never escapes into SwiftUI's text state.
struct BrowserAddressField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let focusRequest: Int
    let onSubmit: () -> Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> BrowserAddressTextField {
        let field = BrowserAddressTextField(frame: .zero)
        field.delegate = context.coordinator
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: BrowserAddressTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = isEnabled
        let font = NSFont.systemFont(ofSize: TypeScale.shared.ui(TypeScale.stockPointSize(.callout)))
        if field.font != font { field.font = font }
        field.textColor = .labelColor
        let label = BrowserLocalization.localized("Search or enter web address")
        field.placeholderString = label
        field.setAccessibilityLabel(label)
        // Resign before replacing a submitted query with its longer URL, so
        // the old editor selection cannot highlight a prefix of the new text.
        if !isFocused { field.updateFocus(false) }
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != text {
            field.stringValue = text
        }
        if isFocused {
            let selectAll = focusRequest > 0 && focusRequest != context.coordinator.lastFocusRequest
            field.updateFocus(true, selectAll: selectAll)
        }
        context.coordinator.lastFocusRequest = focusRequest
    }

    static func dismantleNSView(_ field: BrowserAddressTextField, coordinator: Coordinator) {
        field.delegate = nil
        field.updateFocus(false)
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate, BrowserAddressTextFieldDelegate {
        var parent: BrowserAddressField
        var lastFocusRequest = 0
        init(_ parent: BrowserAddressField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            addressFieldDidChangeFocus(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            addressFieldDidChangeFocus(false)
        }

        func addressFieldDidChangeFocus(_ focused: Bool) {
            if parent.isFocused != focused { parent.isFocused = focused }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() else { return false }
            parent.text = textView.string
            if parent.onSubmit() {
                (control as? BrowserAddressTextField)?.updateFocus(false)
                if parent.isFocused { parent.isFocused = false }
            }
            return true
        }
    }
}

@MainActor protocol BrowserAddressTextFieldDelegate: AnyObject {
    func addressFieldDidChangeFocus(_ focused: Bool)
}

final class BrowserAddressTextField: NSTextField {
    private var wantsFocus = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = BrowserAddressTextFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        cell = BrowserAddressTextFieldCell(textCell: stringValue)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus { updateFocus(true) }
    }

    func updateFocus(_ focused: Bool, selectAll: Bool = false) {
        wantsFocus = focused
        guard let window else { return }
        if focused {
            if currentEditor() == nil {
                if window.makeFirstResponder(self) {
                    selectText(nil)
                    (currentEditor() as? BrowserAddressEditor)?.selectAllAfterClick = false
                }
            } else if selectAll {
                currentEditor()?.selectAll(nil)
                (currentEditor() as? BrowserAddressEditor)?.selectAllAfterClick = false
            }
            if currentEditor() != nil { reportFocus(true) }
        } else if let editor = currentEditor() {
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
            window.makeFirstResponder(nil)
            reportFocus(false)
        }
    }

    fileprivate func reportFocus(_ focused: Bool) {
        (delegate as? BrowserAddressTextFieldDelegate)?.addressFieldDidChangeFocus(focused)
    }
}

private final class BrowserAddressTextFieldCell: NSTextFieldCell {
    private let addressEditor = BrowserAddressEditor(frame: .zero)

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        guard let field = controlView as? BrowserAddressTextField else { return nil }
        addressEditor.owner = field
        addressEditor.isFieldEditor = true
        addressEditor.isRichText = false
        addressEditor.drawsBackground = false
        addressEditor.allowsUndo = true
        return addressEditor
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        if event?.type == .leftMouseDown {
            (textObj as? BrowserAddressEditor)?.selectAllAfterClick = true
        }
        super.edit(withFrame: rect, in: controlView, editor: textObj, delegate: delegate, event: event)
    }
}

private final class BrowserAddressEditor: NSTextView {
    weak var owner: BrowserAddressTextField?
    var selectAllAfterClick = false

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            // AppKit may establish the editor before delivering mouseDown.
            selectAllAfterClick = selectAllAfterClick || NSApp.currentEvent?.type == .leftMouseDown
            owner?.reportFocus(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            selectAllAfterClick = false
            owner?.reportFocus(false)
        }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let shouldSelect = selectAllAfterClick
        selectAllAfterClick = false
        // Let AppKit finish click tracking first. Preserve deliberate drags,
        // double clicks and ordinary caret placement after the first click.
        if shouldSelect, event.clickCount == 1, selectedRange().length == 0 { selectAll(nil) }
    }
}
