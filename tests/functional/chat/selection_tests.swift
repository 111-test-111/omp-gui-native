import AppKit
import Foundation
@testable import OMPGUI

@main
struct SelectionChecks {
    @MainActor static var checks = 0
    @MainActor static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        checks += 1
    }
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let view = LinkTextView()
        let owner = UUID()
        view.selectionOwner = owner
        let first = NSAttributedString(string: "First 中文 fragment", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        view.render(first)
        view.setSelectedRange(NSRange(location: 6, length: 2))
        let selection = SelectionCopy()
        selection.capture(from: view, owner: owner)
        expect(selection.text == "中文", "Quotes use the selected native text")
        view.render(NSAttributedString(string: "First 中文 fragment plus tail", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        expect(view.selectedRange() == NSRange(location: 6, length: 2), "Appending identical attributed text preserves the selection")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        expect(selection.text == "中文", "An open menu keeps its original selection snapshot")
        let other = SelectionCopy()
        other.capture(from: view, owner: UUID())
        expect(other.text == nil, "Another message's selection is never borrowed")
        view.isEditable = true
        other.capture(from: view, owner: owner)
        expect(other.text == nil, "An editable composer cannot provide a message quote")
        view.isEditable = false
        let invalid = NSRange(location: 0, length: 0)
        view.setSelectedRange(invalid)
        other.capture(from: view, owner: owner)
        expect(other.text == nil, "An empty selection falls back to the full message")
        let app = AppModel()
        let task = app.newThread(affiliation: .standalone)!
        let runtime = app.runtime(for: task.id)
        func quote(_ value: SelectionCopy) {
            let actions = AssistantMessageRow.messageActions(text: "Whole message", code: nil, runtime: runtime, selection: value)
            actions.first { $0.title == "Add to reply" }!.action()
        }
        quote(selection)
        quote(selection)
        expect(runtime.draft.quotes.map(\.text) == ["中文"], "Duplicate fragments are ignored")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        let next = SelectionCopy(); next.capture(from: view, owner: owner)
        quote(next)
        expect(runtime.draft.quotes.map(\.text) == ["中文", "First"], "Different fragments from one message can be quoted separately")
        quote(other)
        expect(runtime.draft.quotes.last?.text == "Whole message", "No valid selection quotes the full message")
        let before = NSPasteboard.general.changeCount
        next.capture(from: view, owner: owner)
        expect(NSPasteboard.general.changeCount == before, "Capturing a quote does not touch the system clipboard")
        view.render(NSAttributedString(string: view.string + "!", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)]))
        expect((view.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 18,
               "A prefix restyled by closing Markdown is replaced rather than appended with stale attributes")
        let veil = StreamVeil()
        let now = Date()
        veil.advance("e", at: now)
        veil.advance("e\u{301}", at: now.addingTimeInterval(0.01))
        expect(veil.spans(at: now.addingTimeInterval(0.02)).allSatisfy { $0.range == 0..<1 }, "Combining-character appends keep valid grapheme ranges")
        veil.advance("e\u{301} 👩", at: now.addingTimeInterval(0.03))
        veil.advance("e\u{301} 👩‍💻", at: now.addingTimeInterval(0.04))
        expect(veil.spans(at: now.addingTimeInterval(0.05)).allSatisfy { $0.range.upperBound <= 3 }, "ZWJ emoji appends cannot produce out-of-range fading spans")
        let original = "A heading\n=========\n\ntext"
        _ = MarkdownView.streamingParse(for: original)
        expect(MarkdownView.blocks(for: original) == MarkdownParser.parse(original), "Finished replies reuse a correct streaming parse")
        print("Selection checks passed: \(checks)")
    }
}
