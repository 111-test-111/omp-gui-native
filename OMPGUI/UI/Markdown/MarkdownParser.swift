import Foundation

/// Block-level Markdown for agent output. Inline styling is handled by `AttributedString`.
enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String)
    case math(MarkdownFormula)
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case quote([MarkdownBlock])
    case alert(kind: MarkdownAlertKind, blocks: [MarkdownBlock])
    case table(header: [String], rows: [[String]], alignments: [MarkdownTableAlignment])
    case rule

    var isProseOnly: Bool {
        switch self {
        // Inline math is a native attachment now, so it can share continuous
        // selectable text instead of creating a scroll host per paragraph/item.
        case .heading, .paragraph: true
        case .list(_, _, let items): items.allSatisfy {
            !($0.text.isEmpty && !$0.children.isEmpty) && $0.children.allSatisfy(\.isProseOnly)
        }
        // Quotes keep their native container's rule and inset even when their
        // paragraphs can otherwise join a run.
        case .quote, .code, .math, .table, .rule, .alert: false
        }
    }
}

enum MarkdownTableAlignment: String, Hashable, Sendable {
    case left, center, right
}

enum MarkdownAlertKind: String, CaseIterable, Hashable, Sendable {
    case note, tip, important, warning, caution

    var title: String {
        switch self {
        case .note: "Note"
        case .tip: "Tip"
        case .important: "Important"
        case .warning: "Warning"
        case .caution: "Caution"
        }
    }
}

struct MarkdownListItem: Hashable, Sendable {
    var text: String
    var checked: Bool?
    var children: [MarkdownBlock]
}

enum MarkdownParser {
    /// A parse, with how much of it survives the text growing by appending, as a streaming
    /// reply does. The parser decides each line from that line and the next, so with `m` the
    /// index of the last line (the one still being written), every decision up to a block
    /// that starts at line `m - 2` or earlier is final: the blocks before it are `stable`,
    /// and a longer text is parsed again from `restart`, that block's UTF-8 offset (see
    /// `parse(_:extending:)`). With no such block, nothing is reused.
    struct Parse: Equatable, Sendable {
        var blocks: [MarkdownBlock]
        var stable: Int
        var restart: Int
        var openFence: OpenFence? = nil
    }

    struct OpenFence: Equatable, Sendable {
        var marker: String
        var language: String?
        var completed: String
        var completedLines: Int
        var partial: String
        var indent: Int
    }

    static func parse(_ text: String) -> [MarkdownBlock] {
        parse(text[...]).blocks
    }

    /// The parse of `text` given `previous`, the parse of an earlier text. When `text` merely
    /// extends it, the stable blocks are reused and only the tail is parsed.
    static func parse(_ text: String, extending previous: (text: String, parse: Parse)?) -> Parse {
        if let previous, var fence = previous.parse.openFence,
           text.utf8.count > previous.text.utf8.count,
           text.utf8.starts(with: previous.text.utf8) {
            let start = text.utf8.index(text.utf8.startIndex, offsetBy: previous.text.utf8.count)
            let added = String(decoding: text.utf8[start...], as: UTF8.self)
            let pieces = (fence.partial + added).components(separatedBy: "\n")
            var closed = false
            for (index, raw) in pieces.enumerated() {
                let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                let candidate = trimmed(line)
                if indentation(line) < 4, candidate.hasPrefix(fence.marker), candidate.allSatisfy({ $0 == fence.marker.first }) {
                    closed = true
                    break
                }
                if index < pieces.count - 1 {
                    if fence.completedLines > 0 { fence.completed += "\n" }
                    fence.completed += droppingIndent(line, columns: fence.indent)
                    fence.completedLines += 1
                }
            }
            if !closed {
                fence.partial = pieces.last ?? ""
                let partial = fence.partial.hasSuffix("\r") ? String(fence.partial.dropLast()) : fence.partial
                let code = fence.completed + (fence.completedLines > 0 ? "\n" : "") + droppingIndent(partial, columns: fence.indent)
                var result = previous.parse
                result.blocks[result.blocks.count - 1] = .code(language: fence.language, code: code)
                result.openFence = fence
                return result
            }
        }
        guard let previous, previous.parse.stable > 0,
              text.utf8.count > previous.text.utf8.count, text.utf8.starts(with: previous.text.utf8) else {
            return parse(text[...])
        }
        let restart = previous.parse.restart
        let tail = parse(text[text.utf8.index(text.utf8.startIndex, offsetBy: restart)...])
        return Parse(
            blocks: Array(previous.parse.blocks[..<previous.parse.stable]) + tail.blocks,
            stable: previous.parse.stable + tail.stable,
            restart: restart + tail.restart,
            openFence: tail.openFence
        )
    }

    /// Splits on `\n`, dropping a `\r` before it, without a whole-text copy first.
    private static func parse(_ text: Substring) -> Parse {
        let utf8 = text.utf8
        let pieces = utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
        var lines: [String] = []
        lines.reserveCapacity(pieces.count)
        var starts: [Int] = []
        starts.reserveCapacity(pieces.count)
        for piece in pieces {
            starts.append(utf8.distance(from: utf8.startIndex, to: piece.startIndex))
            lines.append(String(Substring(piece.last == 0x0D ? piece.dropLast() : piece)))
        }
        let parsed = parse(lines[...])
        // The last block that starts at least two lines above the last line: the decisions
        // that end everything before it never read the line still being written.
        var openFence: OpenFence?
        if let opening = parsed.blockLines.last, let lastBlock = parsed.blocks.last, case .code(let language, _) = lastBlock,
           opening + 1 < lines.count, indentation(lines[opening]) < 4, let marker = fenceMarker(trimmed(lines[opening])) {
            let body = lines[(opening + 1)...]
            let hasClosure = body.contains { line in
                let candidate = trimmed(line)
                return indentation(line) < 4 && candidate.hasPrefix(marker) && candidate.allSatisfy { $0 == marker.first }
            }
            if !hasClosure {
                let rawPartial = String(decoding: pieces.last ?? utf8[utf8.endIndex...], as: UTF8.self)
                openFence = OpenFence(marker: marker, language: language,
                    completed: body.dropLast().map { droppingIndent($0, columns: indentation(lines[opening])) }.joined(separator: "\n"),
                    completedLines: body.count - 1, partial: rawPartial, indent: indentation(lines[opening]))
            }
        }
        guard var stable = parsed.blockLines.lastIndex(where: { $0 <= lines.count - 3 }) else {
            return Parse(blocks: parsed.blocks, stable: 0, restart: 0, openFence: openFence)
        }
        // Several blocks can share a line; restart before all of them.
        while stable > 0, parsed.blockLines[stable - 1] == parsed.blockLines[stable] { stable -= 1 }
        return Parse(blocks: parsed.blocks, stable: stable, restart: starts[parsed.blockLines[stable]], openFence: openFence)
    }

    /// Quotes and list items nest by recursion, one level per `>` or indent step, which model
    /// output decides. Past this many levels the inner lines are paragraph text.
    private static let maxDepth = 8

    /// The blocks of `lines`, and the line each top-level block starts on.
    private static func parse(_ lines: ArraySlice<String>, depth: Int = 0) -> (blocks: [MarkdownBlock], blockLines: [Int]) {
        var blocks: [MarkdownBlock] = []
        var blockLines: [Int] = []
        var index = lines.startIndex
        var paragraph: [String] = []
        var paragraphStart = index

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.paragraph(text))
                blockLines.append(paragraphStart)
            }
            paragraph.removeAll()
        }

        while index < lines.endIndex {
            let line = lines[index]
            let trimmed = self.trimmed(line)
            let indent = indentation(line)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if paragraph.isEmpty, indent >= 4 {
                blockLines.append(index)
                var code: [String] = []
                var pendingBlanks: [String] = []
                while index < lines.endIndex {
                    let candidate = lines[index]
                    if self.trimmed(candidate).isEmpty {
                        pendingBlanks.append(droppingIndent(candidate, columns: 4))
                    } else if indentation(candidate) >= 4 {
                        code.append(contentsOf: pendingBlanks)
                        pendingBlanks.removeAll()
                        code.append(droppingIndent(candidate, columns: 4))
                    } else {
                        break
                    }
                    index += 1
                }
                blocks.append(.code(language: nil, code: code.joined(separator: "\n")))
                continue
            }

            if !paragraph.isEmpty, indent < 4, let level = setextLevel(trimmed) {
                let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                blocks.append(.heading(level: level, text: text))
                blockLines.append(paragraphStart)
                paragraph.removeAll()
                index += 1
                continue
            }

            if indent < 4, let opener = MarkdownMath.displayOpener(trimmed) {
                flushParagraph()
                let openingLine = index
                var source = trimmed
                let bodyStart = source.index(source.startIndex, offsetBy: opener.open.count)
                var closing = MarkdownMath.closingRange(opener.close, in: source, from: bodyStart)
                while closing == nil, index + 1 < lines.endIndex {
                    index += 1
                    source += "\n" + lines[index]
                    closing = MarkdownMath.closingRange(opener.close, in: source, from: bodyStart)
                }
                let end = closing?.lowerBound ?? source.endIndex
                let formulaSource = String(source[..<(closing?.upperBound ?? source.endIndex)])
                let latex = String(source[bodyStart..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                blocks.append(.math(MarkdownFormula(source: formulaSource, latex: latex, mode: .display, complete: closing != nil)))
                blockLines.append(openingLine)
                if let closing {
                    let tail = String(source[closing.upperBound...]).trimmingCharacters(in: .whitespaces)
                    // Reparse from the opener: the closing line also owns this
                    // prose, so restarting at it would mistake it for new math.
                    if !tail.isEmpty { paragraphStart = openingLine; paragraph.append(tail) }
                }
                index += 1
                continue
            }

            if indent < 4, let fence = fenceMarker(trimmed) {
                flushParagraph()
                blockLines.append(index)
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.endIndex {
                    let candidate = self.trimmed(lines[index])
                    if indentation(lines[index]) < 4, candidate.hasPrefix(fence), candidate.allSatisfy({ $0 == fence.first }) { index += 1; break }
                    code.append(droppingIndent(lines[index], columns: indent))
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")))
                continue
            }

            if indent < 4, let heading = headingLevel(trimmed) {
                flushParagraph()
                blockLines.append(index)
                let content = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: heading, text: content.trimmingCharacters(in: CharacterSet(charactersIn: "# "))))
                index += 1
                continue
            }

            if indent < 4, isRule(trimmed) {
                flushParagraph()
                blockLines.append(index)
                blocks.append(.rule)
                index += 1
                continue
            }

            if indent < 4, trimmed.hasPrefix(">"), depth < maxDepth {
                flushParagraph()
                blockLines.append(index)
                var quoted: [String] = []
                while index < lines.endIndex {
                    let candidate = lines[index]
                    let indent = indentation(candidate)
                    guard indent < 4 else { break }
                    let unindented = droppingIndent(candidate, columns: indent)
                    guard unindented.hasPrefix(">") else { break }
                    let content = String(unindented.dropFirst())
                    quoted.append(droppingIndent(content, columns: 1, startingColumn: indent + 1))
                    index += 1
                }
                if depth == 0, let marker = quoted.first,
                   let kind = MarkdownAlertKind.allCases.first(where: { self.trimmed(marker) == "[!\($0.rawValue.uppercased())]" }) {
                    blocks.append(.alert(kind: kind, blocks: parse(quoted.dropFirst(), depth: depth + 1).blocks))
                } else {
                    blocks.append(.quote(parse(quoted[...], depth: depth + 1).blocks))
                }
                continue
            }

            if indent < 4, index + 1 < lines.endIndex, indentation(lines[index + 1]) < 4,
               let alignments = tableDelimiter(lines[index + 1]),
               hasTablePipe(line) || hasTablePipe(lines[index + 1]), tableCells(line).count == alignments.count {
                flushParagraph()
                blockLines.append(index)
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.endIndex {
                    let candidate = self.trimmed(lines[index])
                    guard !candidate.isEmpty, !interruptsParagraph(lines[index]) else { break }
                    let cells = tableCells(candidate)
                    rows.append(Array(cells.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - cells.count)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows, alignments: alignments))
                continue
            }

            if depth < maxDepth, let marker = listMarker(line), paragraph.isEmpty || !marker.ordered || marker.start == 1 {
                flushParagraph()
                blockLines.append(index)
                let (list, next) = parseList(lines, from: index, depth: depth)
                blocks.append(list)
                index = next
                continue
            }

            if paragraph.isEmpty { paragraphStart = index }
            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return (blocks, blockLines)
    }

    private struct ListMarker {
        var indent: Int
        var ordered: Bool
        var start: Int
        var contentOffset: Int
        var content: String
    }

    private static func parseList(_ lines: ArraySlice<String>, from start: Int, depth: Int) -> (MarkdownBlock, Int) {
        guard let first = listMarker(lines[start]) else { return (.paragraph(lines[start]), start + 1) }
        var items: [MarkdownListItem] = []
        var index = start
        var itemLines: [String] = []
        var hasItem = false
        var contentOffset = first.contentOffset
        var canContinueParagraph = false
        var openFence: String?
        var openMath: String?

        func appendLine(_ line: String) {
            itemLines.append(line)
            let candidate = trimmed(line)
            if let marker = openFence {
                if indentation(line) < 4, candidate.hasPrefix(marker), candidate.allSatisfy({ $0 == marker.first }) { openFence = nil }
                canContinueParagraph = false
            } else if let closing = openMath {
                if MarkdownMath.closingRange(closing, in: line, from: line.startIndex) != nil { openMath = nil }
                canContinueParagraph = false
            } else if indentation(line) < 4, let opener = MarkdownMath.displayOpener(candidate) {
                let body = candidate.index(candidate.startIndex, offsetBy: opener.open.count)
                if MarkdownMath.closingRange(opener.close, in: candidate, from: body) == nil { openMath = opener.close }
                canContinueParagraph = false
            } else if indentation(line) < 4, let marker = fenceMarker(candidate) {
                openFence = marker
                canContinueParagraph = false
            } else {
                canContinueParagraph = !candidate.isEmpty && indentation(line) < 4 && !interruptsParagraph(line) && setextLevel(candidate) == nil
            }
        }

        func flushItem() {
            guard hasItem else { return }
            var children = parse(itemLines[...], depth: depth + 1).blocks
            var text = ""
            if let first = children.first, case .paragraph(let content) = first {
                text = content
                children.removeFirst()
            }
            var checked: Bool?
            if text.hasPrefix("[ ] ") {
                checked = false
                text.removeFirst(4)
            } else if text.lowercased().hasPrefix("[x] ") {
                checked = true
                text.removeFirst(4)
            }
            items.append(MarkdownListItem(text: text, checked: checked, children: children))
            itemLines.removeAll()
            openFence = nil
            openMath = nil
            canContinueParagraph = false
        }

        while index < lines.endIndex {
            let line = lines[index]
            let trimmed = self.trimmed(line)
            if trimmed.isEmpty {
                var next = index + 1
                while next < lines.endIndex, self.trimmed(lines[next]).isEmpty { next += 1 }
                let continuesItem = next < lines.endIndex && indentation(lines[next]) >= contentOffset
                let continuesList = next < lines.endIndex && listMarker(lines[next]).map { $0.indent == first.indent && $0.ordered == first.ordered } == true
                if continuesItem || continuesList {
                    appendLine("")
                    index += 1
                    continue
                }
                break
            }
            if let marker = listMarker(line), marker.indent <= first.indent {
                guard marker.indent == first.indent, marker.ordered == first.ordered else { break }
                flushItem()
                hasItem = true
                contentOffset = marker.contentOffset
                appendLine(marker.content)
                index += 1
                continue
            }
            if indentation(line) >= contentOffset {
                appendLine(droppingIndent(line, columns: contentOffset))
                index += 1
                continue
            }
            if canContinueParagraph, !interruptsParagraph(line), setextLevel(trimmed) == nil {
                appendLine(trimmed)
                index += 1
                continue
            }
            break
        }
        flushItem()
        return (.list(ordered: first.ordered, start: first.start, items: items), index)
    }

    /// `trimmingCharacters(in: .whitespaces)`, skipped for the usual line that starts and ends
    /// with printable ASCII: no space or tab there, and no lead byte of a Unicode space either.
    private static func trimmed(_ line: String) -> String {
        if let first = line.utf8.first, let last = line.utf8.last,
           first > 0x20, first < 0x7F, last > 0x20, last < 0x7F { return line }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func listMarker(_ line: String) -> ListMarker? {
        let indent = indentation(line)
        let body = droppingIndent(line, columns: indent)[...]
        func marker(ordered: Bool, start: Int, width: Int, rest: Substring) -> ListMarker? {
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            let whitespace = indentation(String(rest), startingColumn: indent + width)
            let padding = (1...4).contains(whitespace) ? whitespace : 1
            let content = droppingIndent(String(rest), columns: padding, startingColumn: indent + width)
            return ListMarker(indent: indent, ordered: ordered, start: start, contentOffset: indent + width + padding, content: content)
        }
        if let first = body.first, "-*+".contains(first) {
            return marker(ordered: false, start: 1, width: 1, rest: body.dropFirst())
        }
        let digits = body.prefix(while: { $0.isASCII && $0 >= "0" && $0 <= "9" })
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let rest = body.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
        return marker(ordered: true, start: Int(digits) ?? 1, width: digits.count + 1, rest: rest.dropFirst())
    }

    private static func indentation(_ line: String, startingColumn: Int = 0) -> Int {
        var column = startingColumn
        for character in line {
            if character == " " { column += 1 } else if character == "\t" { column += 4 - column % 4 } else { break }
        }
        return column - startingColumn
    }

    /// Tabs advance to four-column stops. Removing a container's non-multiple-of-four
    /// indent expands remaining leading tabs so nested code retains its visual columns.
    private static func droppingIndent(_ line: String, columns: Int, startingColumn: Int = 0) -> String {
        guard columns > 0 else { return line }
        let target = startingColumn + columns
        var column = startingColumn
        var index = line.startIndex
        while index < line.endIndex, column < target {
            let character = line[index]
            if character == " " { column += 1 }
            else if character == "\t" { column += 4 - column % 4 }
            else { break }
            index = line.index(after: index)
        }
        var remaining = String(repeating: " ", count: max(0, column - target))
        if target % 4 != 0 {
            while index < line.endIndex {
                let character = line[index]
                if character == " " { remaining += " "; column += 1 }
                else if character == "\t" {
                    let width = 4 - column % 4
                    remaining += String(repeating: " ", count: width)
                    column += width
                } else { break }
                index = line.index(after: index)
            }
        }
        return remaining + line[index...]
    }

    private static func setextLevel(_ line: String) -> Int? {
        guard let marker = line.first, marker == "=" || marker == "-", line.allSatisfy({ $0 == marker }) else { return nil }
        return marker == "=" ? 1 : 2
    }

    private static func interruptsParagraph(_ line: String) -> Bool {
        guard indentation(line) < 4 else { return false }
        let content = trimmed(line)
        if MarkdownMath.displayOpener(content) != nil || headingLevel(content) != nil || fenceMarker(content) != nil || isRule(content) || content.hasPrefix(">") { return true }
        return listMarker(line).map { !$0.content.isEmpty && (!$0.ordered || $0.start == 1) } ?? false
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            guard let fenceCharacter = marker.first else { continue }
            return String(trimmed.prefix(while: { $0 == fenceCharacter }))
        }
        return nil
    }

    private static func headingLevel(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        return rest.isEmpty || rest.hasPrefix(" ") ? hashes : nil
    }

    /// Three or more of one of `-`, `*`, `_`, spaces between them allowed. Every bullet line
    /// starts with one of those, so this checks bytes rather than building a string.
    private static func isRule(_ trimmed: String) -> Bool {
        guard let first = trimmed.utf8.first, first == 0x2D || first == 0x2A || first == 0x5F else { return false }
        var count = 0
        for byte in trimmed.utf8 {
            if byte == first { count += 1 } else if byte != 0x20 { return false }
        }
        return count >= 3
    }

    private static func tableDelimiter(_ line: String) -> [MarkdownTableAlignment]? {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return nil }
        var alignments: [MarkdownTableAlignment] = []
        for cell in cells {
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            var hyphens = cell[...]
            if left { hyphens = hyphens.dropFirst() }
            if right { hyphens = hyphens.dropLast() }
            guard !hyphens.isEmpty, hyphens.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(left && right ? .center : right ? .right : .left)
        }
        return alignments
    }

    private static func tableCells(_ line: String) -> [String] {
        let protected = MarkdownMath.protect(trimmed(line))
        let content = protected.text
        var cells: [String] = []
        var cell = ""
        var backslashes = 0
        var trailingPipe = false
        for character in content {
            trailingPipe = false
            if character == "|" {
                if backslashes % 2 == 1 {
                    cell.removeLast()
                    cell.append(character)
                } else {
                    cells.append(cell.trimmingCharacters(in: .whitespaces))
                    cell = ""
                    trailingPipe = true
                }
            } else {
                cell.append(character)
            }
            backslashes = character == "\\" ? backslashes + 1 : 0
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if content.hasPrefix("|") { cells.removeFirst() }
        if trailingPipe { cells.removeLast() }
        return cells.map { protected.restored($0) }
    }

    private static func hasTablePipe(_ line: String) -> Bool {
        let line = MarkdownMath.protect(line).text
        var backslashes = 0
        for character in line {
            if character == "|", backslashes % 2 == 0 { return true }
            backslashes = character == "\\" ? backslashes + 1 : 0
        }
        return false
    }
}
