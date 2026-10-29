import Foundation

/// Foundation owns inline syntax and code-span whitespace. Its inline mode preserves
/// literal line endings, so resolve paragraph breaks using the parsed intents: soft
/// breaks become spaces; a backslash or two trailing ASCII spaces produces a hard break.
enum MarkdownInline {
    static func parse(_ source: String, streaming: Bool = false) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let protected = MarkdownMath.protect(source)
        let markup = streaming ? StreamMend.mended(protected.text) : protected.text
        let compatible = strongCompatibility(markup)
        var inline = (try? AttributedString(markdown: compatible.text, options: options)) ?? AttributedString(compatible.text)
        for (start, end) in compatible.markers {
            guard let opening = inline.range(of: start), let closing = inline.range(of: end), opening.upperBound <= closing.lowerBound else { continue }
            // Foundation drops even standard strong intents inside link labels.
            // Retain the link and all nested intents while restoring this span.
            for run in Array(inline[opening.upperBound..<closing.lowerBound].runs) {
                var intent = run.inlinePresentationIntent ?? []
                intent.insert(.stronglyEmphasized)
                inline[run.range].inlinePresentationIntent = intent
            }
            inline.removeSubrange(closing)
            inline.removeSubrange(opening)
        }
        let parsed = protected.restored(inline)
        guard source.contains("\n") else { return parsed }
        let characters = Array(parsed.characters)
        let indices = Array(parsed.characters.indices) + [parsed.endIndex]
        func intent(at offset: Int) -> InlinePresentationIntent {
            parsed[indices[offset]..<indices[offset + 1]].inlinePresentationIntent ?? []
        }
        func isWhitespace(at offset: Int) -> Bool {
            (characters[offset] == " " || characters[offset] == "\t") && !intent(at: offset).contains(.code)
                && parsed[indices[offset]..<indices[offset + 1]][MarkdownFormulaAttribute.self] == nil
        }
        var result = parsed
        for offset in characters.indices.reversed() where characters[offset] == "\n" && !intent(at: offset).contains(.code)
            && parsed[indices[offset]..<indices[offset + 1]][MarkdownFormulaAttribute.self] == nil {
            var left = offset
            var right = offset + 1
            while left > 0, isWhitespace(at: left - 1) { left -= 1 }
            while right < characters.count, isWhitespace(at: right) { right += 1 }
            // Paragraph separation is decided by the block parser. Keep any explicit
            // empty lines supplied by other inline consumers rather than merging them.
            if left > 0, characters[left - 1] == "\n" { continue }
            if right < characters.count, characters[right] == "\n" { continue }
            var spaces = 0
            var cursor = offset
            while cursor > left, characters[cursor - 1] == " " { spaces += 1; cursor -= 1 }
            let hard = intent(at: offset).contains(.lineBreak) || spaces >= 2
            var replacement = AttributedString(hard ? "\n" : " ")
            replacement.setAttributes(parsed[indices[offset]..<indices[offset + 1]].runs.first?.attributes ?? AttributeContainer())
            var presentation = replacement.inlinePresentationIntent ?? []
            presentation.remove(.softBreak)
            if hard { presentation.insert(.lineBreak) } else { presentation.remove(.lineBreak) }
            replacement.inlinePresentationIntent = presentation.isEmpty ? nil : presentation
            result.replaceSubrange(indices[left]..<indices[right], with: replacement)
        }
        return result
    }

    /// CommonMark's punctuation flanking rules reject `**中文：**后文` and
    /// whitespace inside a delimiter. Make paired strong spans word-flanking
    /// during parsing, then remove the sentinels without changing their content
    /// or nested Markdown attributes. Code, escapes and link targets are data.
    private static func strongCompatibility(_ source: String) -> (text: String, markers: [(String, String)]) {
        guard source.contains("**") else { return (source, []) }
        let chars = Array(source)
        var pairs: [(Int, Int)] = [], open: Int?, index = 0, ticks = 0
        while index < chars.count {
            let c = chars[index]
            if c == "\\", ticks == 0 { index += 2; continue }
            if c == "`" {
                var end = index + 1
                while end < chars.count, chars[end] == c { end += 1 }
                let count = end - index
                if ticks == 0 { ticks = count } else if ticks == count { ticks = 0 }
                index = end; continue
            }
            guard ticks == 0 else { index += 1; continue }
            if c == "(", index > 0, chars[index - 1] == "]" {
                var depth = 1; index += 1
                while index < chars.count, depth > 0 {
                    if chars[index] == "\\" { index += 2; continue }
                    if chars[index] == "(" { depth += 1 }
                    if chars[index] == ")" { depth -= 1 }
                    index += 1
                }
                continue
            }
            if c == "<" {
                if let end = chars[index...].firstIndex(of: ">") { index = end + 1; continue }
            }
            if c == "h", String(chars[index..<min(index + 8, chars.count)]).hasPrefix("https://")
                || c == "h" && String(chars[index..<min(index + 7, chars.count)]).hasPrefix("http://") {
                while index < chars.count, !chars[index].isWhitespace { index += 1 }
                continue
            }
            if c == "\n", index > 0, chars[index - 1] == "\n" { open = nil }
            guard c == "*" else { index += 1; continue }
            var end = index + 1
            while end < chars.count, chars[end] == "*" { end += 1 }
            // Leave triple/nested delimiter runs to Foundation's normal parser.
            if end - index == 2 {
                if let start = open {
                    if chars[(start + 2)..<index].contains(where: { !$0.isWhitespace }) { pairs.append((start + 2, index)) }
                    open = nil
                } else { open = index }
            }
            index = end
        }
        guard !pairs.isEmpty else { return (source, []) }
        var prefix = "\u{E002}ompStrong"
        while source.contains(prefix) { prefix += "S" }
        var boundaries: [Int: String] = [:], markers: [(String, String)] = []
        for (id, pair) in pairs.enumerated() {
            let start = prefix + "s\(id)\u{E003}", end = prefix + "e\(id)\u{E003}"
            boundaries[pair.0] = start; boundaries[pair.1] = end
            markers.append((start, end))
        }
        var text = ""
        for i in chars.indices {
            if let marker = boundaries[i] { text += marker }
            text.append(chars[i])
        }
        return (text, markers)
    }
}
