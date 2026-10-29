import Foundation

struct MarkdownFormula: Hashable, Sendable {
    enum Mode: String, Hashable, Sendable { case inline, display }
    let source: String
    let latex: String
    let mode: Mode
    let complete: Bool
}

enum MarkdownFormulaAttribute: AttributedStringKey {
    typealias Value = MarkdownFormula
    static let name = "omp.markdown.formula"
}

/// Adjacent equal formulas must remain separate runs and attachments.
private enum MarkdownFormulaOccurrenceAttribute: AttributedStringKey {
    typealias Value = Int
    static let name = "omp.markdown.formula.occurrence"
}

/// Protect TeX before Foundation parses Markdown. In particular, backslashes,
/// underscores and stars in formulas must never become Markdown formatting.
enum MarkdownMath {
    struct Span {
        let range: Range<String.Index>
        let formula: MarkdownFormula
    }

    struct Protected {
        let text: String
        let formulas: [(marker: String, formula: MarkdownFormula)]

        func restored(_ text: String) -> String {
            formulas.reduce(text) { $0.replacingOccurrences(of: $1.marker, with: $1.formula.source) }
        }

        func restored(_ parsed: AttributedString) -> AttributedString {
            var result = parsed
            for (occurrence, entry) in formulas.enumerated() {
                let (marker, formula) = entry
                let plain = String(result.characters)
                guard let range = plain.range(of: marker) else { continue }
                let start = result.characters.index(result.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound))
                let end = result.characters.index(start, offsetBy: marker.count)
                var replacement = AttributedString(formula.source)
                replacement.setAttributes(result[start..<end].runs.first?.attributes ?? AttributeContainer())
                replacement[MarkdownFormulaAttribute.self] = formula
                replacement[MarkdownFormulaOccurrenceAttribute.self] = occurrence
                result.replaceSubrange(start..<end, with: replacement)
            }
            return result
        }
    }

    static func contains(_ source: String) -> Bool {
        guard source.contains("$") || source.contains("\\(") || source.contains("\\[") else { return false }
        return !spans(in: source).isEmpty
    }

    static func protect(_ source: String) -> Protected {
        let spans = spans(in: source)
        guard !spans.isEmpty else { return Protected(text: source, formulas: []) }
        var prefix = "\u{E000}ompMath"
        while source.contains(prefix) { prefix += "M" }
        var text = "", cursor = source.startIndex
        var formulas: [(String, MarkdownFormula)] = []
        for (index, span) in spans.enumerated() {
            let marker = prefix + String(index) + "\u{E001}"
            text += source[cursor..<span.range.lowerBound] + marker
            formulas.append((marker, span.formula))
            cursor = span.range.upperBound
        }
        text += source[cursor...]
        return Protected(text: text, formulas: formulas)
    }

    static func displayOpener(_ line: String) -> (open: String, close: String)? {
        if line.hasPrefix("$$") { return ("$$", "$$") }
        if line.hasPrefix("\\[") { return ("\\[", "\\]") }
        return nil
    }

    static func closingRange(_ close: String, in source: String, from start: String.Index) -> Range<String.Index>? {
        var cursor = start
        while cursor < source.endIndex, let range = source.range(of: close, range: cursor..<source.endIndex) {
            if !escaped(source, at: range.lowerBound) { return range }
            cursor = range.upperBound
        }
        return nil
    }

    private static func escaped(_ text: String, at index: String.Index) -> Bool {
        var cursor = index, count = 0
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous] == "\\" else { break }
            count += 1; cursor = previous
        }
        return count % 2 == 1
    }

    static func spans(in source: String) -> [Span] {
        guard source.contains("$") || source.contains("\\(") || source.contains("\\[") else { return [] }
        var spans: [Span] = [], index = source.startIndex
        while index < source.endIndex {
            let char = source[index]
            // Consume escape pairs once. Looking backwards at every backslash
            // would make a long escaped input quadratic.
            if char == "\\", !source[index...].hasPrefix("\\("), !source[index...].hasPrefix("\\[") {
                index = source.index(after: index)
                if index < source.endIndex { index = source.index(after: index) }
                continue
            }
            if char == "`" {
                let end = source[index...].prefix { $0 == "`" }.endIndex
                let ticks = String(source[index..<end])
                var search = end, closure: Range<String.Index>?
                while search < source.endIndex, let candidate = source.range(of: ticks, range: search..<source.endIndex) {
                    let extraBefore = candidate.lowerBound > end && source[source.index(before: candidate.lowerBound)] == "`"
                    let extraAfter = candidate.upperBound < source.endIndex && source[candidate.upperBound] == "`"
                    if !extraBefore && !extraAfter { closure = candidate; break }
                    search = candidate.upperBound
                }
                // An unfinished code span owns the rest of the streamed paragraph.
                index = closure?.upperBound ?? source.endIndex
                continue
            }
            // Destinations and autolinks are data, including their literal dollars.
            if char == "(", index > source.startIndex, source[source.index(before: index)] == "]" {
                var depth = 1; index = source.index(after: index)
                while index < source.endIndex, depth > 0 {
                    if source[index] == "\\" {
                        index = source.index(after: index)
                        if index < source.endIndex { index = source.index(after: index) }
                        continue
                    }
                    if source[index] == "(" { depth += 1 }
                    if source[index] == ")" { depth -= 1 }
                    index = source.index(after: index)
                }
                continue
            }
            if char == "<", let end = source[index...].firstIndex(of: ">") {
                index = source.index(after: end); continue
            }
            if source[index...].hasPrefix("https://") || source[index...].hasPrefix("http://") {
                while index < source.endIndex, !source[index].isWhitespace { index = source.index(after: index) }
                continue
            }
            let opener: String, closer: String, mode: MarkdownFormula.Mode
            if source[index...].hasPrefix("$$") { opener = "$$"; closer = "$$"; mode = .display }
            else if source[index...].hasPrefix("\\(") { opener = "\\("; closer = "\\)"; mode = .inline }
            else if source[index...].hasPrefix("\\[") { opener = "\\["; closer = "\\]"; mode = .display }
            else if char == "$" { opener = "$"; closer = "$"; mode = .inline }
            else { index = source.index(after: index); continue }
            let body = source.index(index, offsetBy: opener.count)
            if opener == "$", body == source.endIndex || source[body].isWhitespace {
                index = body; continue
            }
            var closure = closingRange(closer, in: source, from: body)
            if opener == "$", let candidate = closure {
                let previous = source.index(before: candidate.lowerBound)
                let after = candidate.upperBound
                if previous < body || source[previous].isWhitespace || (after < source.endIndex && source[after].isNumber) { closure = nil }
            }
            if let closure {
                let latex = String(source[body..<closure.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let formula = MarkdownFormula(source: String(source[index..<closure.upperBound]), latex: latex, mode: mode, complete: true)
                spans.append(Span(range: index..<closure.upperBound, formula: formula))
                index = closure.upperBound
            } else {
                let remaining = String(source[body...])
                // Currency stays ordinary Markdown; explicit delimiters and clearly
                // mathematical unfinished spans remain literal until they close.
                let pending = opener != "$" || (closure == nil && !remaining.contains("$") && remaining.contains { "\\_^=+{}".contains($0) })
                if pending {
                    let formula = MarkdownFormula(source: String(source[index...]), latex: remaining, mode: mode, complete: false)
                    spans.append(Span(range: index..<source.endIndex, formula: formula))
                    break
                }
                index = body
            }
        }
        return spans
    }
}
