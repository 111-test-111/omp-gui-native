import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    var description: String
}

@main
private enum MarkdownParserChecks {
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(description: message) }
    }

    static func main() throws {
        let cases: [(String, [MarkdownBlock])] = [
            ("标题\n===", [.heading(level: 1, text: "标题")]),
            ("First\nsecond\n---", [.heading(level: 2, text: "First\nsecond")]),
            ("foo\n-", [.heading(level: 2, text: "foo")]),
            ("foo\n\n---", [.paragraph("foo"), .rule]),
            ("===", [.paragraph("===")]),
            ("foo\n= =", [.paragraph("foo\n= =")]),
            ("    Heading\n---", [.code(language: nil, code: "Heading"), .rule]),
            ("   foo\n   ===", [.heading(level: 1, text: "foo")]),
            ("    let x = 1\n    \tprint(x)\n\n    next\n\nplain", [.code(language: nil, code: "let x = 1\n\tprint(x)\n\nnext"), .paragraph("plain")]),
            (" \tcode", [.code(language: nil, code: "code")]),
            ("\t\tcode", [.code(language: nil, code: "\tcode")]),
            ("    ```swift\n    raw\n    ```", [.code(language: nil, code: "```swift\nraw\n```")]),
            ("paragraph\n    continuation", [.paragraph("paragraph\n    continuation")]),
            ("  ```swift\n  first\n    ```\n  ```", [.code(language: "swift", code: "first\n  ```")]),
            ("> foo\n> ===", [.quote([.heading(level: 1, text: "foo")])]),
            ("> foo\n---", [.quote([.paragraph("foo")]), .rule]),
            (">     code\n>     next", [.quote([.code(language: nil, code: "code\nnext")])]),
            ("> [!NOTE]\n> text", [.alert(kind: .note, blocks: [.paragraph("text")])]),
            ("> [!UNKNOWN]\n> text", [.quote([.paragraph("[!UNKNOWN]\ntext")])]),
            ("> [!NOTE] trailing\n> text", [.quote([.paragraph("[!NOTE] trailing\ntext")])]),
            ("| left | middle | right |\n| :--- | :---: | ---: |\n| a | b | c |", [.table(header: ["left", "middle", "right"], rows: [["a", "b", "c"]], alignments: [.left, .center, .right])]),
            ("| a | b |\n| --- | --- |\n| x\\|y | `a\\|b` |\n| one |\n| a | b | excess |", [.table(header: ["a", "b"], rows: [["x|y", "`a|b`"], ["one", ""], ["a", "b"]], alignments: [.left, .left])]),
            ("a | b\n--- | ---\nx\\\\|y", [.table(header: ["a", "b"], rows: [["x\\\\", "y"]], alignments: [.left, .left])]),
            ("| a | b |\n| -- | ---x |", [.paragraph("| a | b |\n| -- | ---x |")]),
            ("| a | b |\n| --- |\ntext", [.paragraph("| a | b |\n| --- |\ntext")]),
            ("| a |\n| --- |\ntext\n\nend", [.table(header: ["a"], rows: [["text"]], alignments: [.left]), .paragraph("end")]),
        ]
        for (source, expected) in cases {
            let blocks = MarkdownParser.parse(source)
            try expect(blocks == expected, "Block parsing differs for \(source.debugDescription): \(blocks)")
        }
        for kind in MarkdownAlertKind.allCases {
            let source = "> [!\(kind.rawValue.uppercased())]\n> body"
            try expect(MarkdownParser.parse(source) == [.alert(kind: kind, blocks: [.paragraph("body")])], "A supported alert kind remained an ordinary quote")
        }
        try expect(MarkdownParser.parse("- title\n  ===").first?.isProseOnly == false, "A list's first heading would acquire a separate empty bullet paragraph")

        let listSource = "- item\n\n      code\n      next\n\n- title\n  ===\n- [x] checked\n- child\n  - nested\n-\tTabbed\n\tcontinuation"
        guard case .list(_, _, let items) = MarkdownParser.parse(listSource).first else { throw CheckFailure(description: "List disappeared") }
        try expect(items.count == 5, "Child blocks consumed a neighbouring list item")
        try expect(items[0].text == "item" && items[0].children == [.code(language: nil, code: "code\nnext")], "Indented code inside a list lost its relative indentation")
        try expect(items[1].text.isEmpty && items[1].children == [.heading(level: 1, text: "title")], "Setext inside a list became ordinary text")
        try expect(items[2].checked == true && items[2].text == "checked", "Task list styling regressed")
        try expect(items[3].children.count == 1 && items[4].text == "Tabbed\ncontinuation", "Nested or tabbed lists lost text")
        try expect(MarkdownParser.parse(listSource).first?.isProseOnly == false, "Prose grouping would hide a list's code child")

        let inlineCases = [
            ("soft\nbreak", "soft break"),
            ("hard  \nbreak", "hard\nbreak"),
            ("hard\\\nbreak", "hard\nbreak"),
            ("a \n  b  \n   c\\\n d", "a b\nc\nd"),
            ("`multi\nline`\nnext", "multi line next"),
            ("` a  `\nnext", "a  next"),
            ("a\\\\\nnext", "a\\ next"),
            ("a\n\nb", "a\n\nb"),
        ]
        for (source, expected) in inlineCases {
            let parsed = MarkdownInline.parse(source)
            try expect(String(parsed.characters) == expected, "Inline line-break semantics differ for \(source.debugDescription): \(String(parsed.characters).debugDescription)")
        }
        let linked = MarkdownInline.parse("[**first**  \nsecond](https://example.com)")
        try expect(linked.runs.contains { $0.link != nil && $0.inlinePresentationIntent?.contains(.lineBreak) == true }, "A hard break lost its link attributes")
        try expect(MessageText.plain("[**first** second](https://example.com)") == "first second (https://example.com)", "Copy split a link into duplicate targets")
        try expect(MessageText.plain("soft\nbreak\n\nhard  \nbreak") == "soft break\n\nhard\nbreak", "Copy differs from rendered line breaks")
        try expect(MessageText.plain("> [!WARNING]\n> text") == "[!WARNING]\ntext", "Copy dropped the alert kind")

        for (source, content) in [("**符号模板：**先将 inequality 化成", "符号模板："),
                                  ("前文**“中文标点”**后文", "“中文标点”"),
                                  ("** 符号模板： **", " 符号模板： "),
                                  ("**符号模板： **", "符号模板： "),
                                  ("[**标题：**正文](https://example.com)", "标题："),
                                  ("**bold *nested*：**后文", "bold nested：")] {
            let parsed = MarkdownInline.parse(source)
            let strong = parsed.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
                .map { String(parsed[$0.range].characters) }.joined()
            try expect(strong == content, "CJK/whitespace strong span failed: \(source), got \(strong.debugDescription)")
            try expect(!String(parsed.characters).contains("ompStrong"), "Strong sentinel leaked into display/copy")
        }
        for source in [#"\*\*符号模板：\*\*"#, "`**符号模板：**`", "``** 空格 **``", "** **", "unclosed **标点："] {
            let parsed = MarkdownInline.parse(source)
            try expect(!parsed.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "Literal strong markers were interpreted: \(source)")
        }
        let mathStrong = MarkdownInline.parse(#"**公式：\(x^{**}\)**后文"#)
        try expect(mathStrong.runs.contains { $0[MarkdownFormulaAttribute.self]?.latex == "x^{**}" && $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }, "Strong compatibility changed protected TeX")
        let strongLink = MarkdownInline.parse("[**标签：**](https://example.com/**raw**)")
        try expect(strongLink.runs.contains { $0.link?.absoluteString == "https://example.com/**raw**" }, "Strong compatibility changed a link destination")

        var corpus = cases.map(\.0) + [listSource, "> [!TIP]\n> one  \n> two\n>\n>     code\n\n## After", "Intro\n\n| a | b |\n| :--- | ---: |\n| first | second |\n\nAfter\n\n---", "Opening\n\n  ```swift\n  中文\n  body\n  ```\n\nEnding"]
        corpus.append(corpus.joined(separator: "\n\n"))
        var prefixes = 0
        for source in corpus {
            var text = ""
            var previous: (text: String, parse: MarkdownParser.Parse)?
            for character in source {
                text.append(character)
                let incremental = MarkdownParser.parse(text, extending: previous)
                try expect(incremental.blocks == MarkdownParser.parse(text), "Streaming differs from full parse at \(text.debugDescription)")
                previous = (text, incremental)
                prefixes += 1
            }
        }
        print("Markdown parser checks passed: phase-one block cases, nested code, line breaks, copy and \(prefixes) streaming prefixes.")
    }
}
