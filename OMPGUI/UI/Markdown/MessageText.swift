import Foundation

/// The message as plain text for the clipboard: one walk over the app's own blocks,
/// no styling. Headings as their text, code blocks verbatim, links as `title (url)`,
/// the delegation block left out. Used by the row menu's Copy message (see
/// `AssistantMessageRow.messageActions`). The file keeps the name of the selectable text
/// view it used to hold, which left with the whole-reply drag mode; this enum is all that
/// stayed.
enum MessageText {
    static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        var first = true
        for block in MarkdownParser.parse(markdown) {
            if !first { lines.append("") }
            first = false
            append(block, to: &lines)
        }
        return lines.joined(separator: "\n")
    }

    private static func append(_ block: MarkdownBlock, to lines: inout [String]) {
        switch block {
        case .heading(_, let text):
            lines.append(inline(text))
        case .paragraph(let text):
            lines.append(inline(text))
        case .code(let language, let code):
            guard language?.lowercased() != "hydra", !code.isEmpty else { return }
            lines.append(code)
        case .math(let formula):
            lines.append(formula.source)
        case .list(let ordered, let start, let items):
            for (index, item) in items.enumerated() {
                let marker: String
                if let checked = item.checked {
                    marker = checked ? "☑ " : "☐ "
                } else if ordered {
                    marker = "\(start + index).  "
                } else {
                    marker = "•  "
                }
                if !item.text.isEmpty { lines.append(marker + inline(item.text)) }
                for child in item.children { append(child, to: &lines) }
            }
        case .quote(let inner):
            for child in inner { append(child, to: &lines) }
        case .alert(let kind, let inner):
            lines.append("[!\(kind.rawValue.uppercased())]")
            for child in inner { append(child, to: &lines) }
        case .table(let header, let rows, _):
            lines.append(header.map(inline).joined(separator: "  "))
            for row in rows { lines.append(row.map(inline).joined(separator: "  ")) }
        case .rule:
            break
        }
    }

    /// Links as `title (url)` when the title differs, the bare URL otherwise.
    private static func inline(_ source: String) -> String {
        let parsed = MarkdownInline.parse(source)
        var output = ""
        var pendingURL: URL?
        var label = ""
        func flushLink() {
            guard let url = pendingURL else { return }
            output += label == url.absoluteString ? label : "\(label) (\(url.absoluteString))"
            pendingURL = nil
            label = ""
        }
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            if let url = run.link {
                if pendingURL != url { flushLink(); pendingURL = url }
                label += text
            } else {
                flushLink()
                output += text
            }
        }
        flushLink()
        return output
    }
}
