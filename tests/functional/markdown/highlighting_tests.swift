import AppKit
import SwiftUI

// Only unrelated theme/scroll/selection plumbing is substituted; native text storage,
// layout-manager temporary colors and the streaming veil are production APIs.
@MainActor enum Chrome { static var accentNSColor: NSColor { .systemBlue } }
@MainActor final class ScrollActivity {
    static let shared = ScrollActivity()
    var isScrolling = false
}
extension EnvironmentValues { @Entry var markdownDimmed = false }
// SwiftUI selection policy does not participate in this native color/opacity probe.
// Application-linked checks cover owned selection and quoting separately.
struct MarkdownBlockSelection: ViewModifier {
    var isLive = false
    func body(content: Content) -> some View { content }
}

/// Compile the production scanner, fenced-language mapping, style and Markdown
/// parser/veil directly. Snapshots and text-view probes stay offscreen; no
/// application is launched or window shown.
@main
private enum ChatCodeHighlightingChecks {
    @MainActor private static var checks = 0

    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        checks += 1
    }

    private struct Fixture {
        let language: String
        let source: String
        let keyword: String
        let string: String
        let comment: String?
    }

    private static let fixtures: [Fixture] = [
        .init(language: "python", source: "# def ignored = 42\n@cache\nasync def greet(name: str):\n    return \"你好 😺 e\u{301}\"\n", keyword: "def", string: "\"你好 😺 e\u{301}\"", comment: "# def ignored = 42"),
        .init(language: "javascript", source: "// const hidden = 7\nconst answer = async () => { return \"hello\"; };\n", keyword: "const", string: "\"hello\"", comment: "// const hidden = 7"),
        .init(language: "typescript", source: "/* return 123 */\ninterface Person { name: string }\nconst value: Person = { name: \"Ada\" };\n", keyword: "interface", string: "\"Ada\"", comment: "/* return 123 */"),
        .init(language: "swift", source: "// let ignored = 99\nstruct Result {\n    let label = \"中文 👩🏽‍💻\"\n    let count = 42\n}\n", keyword: "struct", string: "\"中文 👩🏽‍💻\"", comment: "// let ignored = 99"),
        .init(language: "bash", source: "# while ignored\nif [ \"$name\" = \"OMP\" ]; then\n    echo \"hello\"\nfi\n", keyword: "if", string: "\"hello\"", comment: "# while ignored"),
        .init(language: "json", source: "{\"name\": \"OMP\", \"enabled\": true, \"count\": 42}\n", keyword: "true", string: "\"OMP\"", comment: nil),
        .init(language: "sql", source: "-- SELECT ignored\nSELECT name FROM users WHERE name = 'Ada';\n", keyword: "SELECT", string: "'Ada'", comment: "-- SELECT ignored"),
    ]

    @MainActor static func main() throws {
        checkStreamingAppearance()
        let aliases: [(String, String)] = [
            ("python", "py"), ("Python3", "py"), ("py", "py"),
            ("javascript", "js"), ("js", "js"),
            ("typescript", "ts"), ("ts", "ts"), ("tsx", "tsx"),
            ("swift", "swift"), ("json", "json"), ("jsonc", "jsonc"),
            ("shell", "sh"), ("sh", "sh"), ("bash", "bash"), ("zsh", "zsh"),
            ("c++", "cpp"), ("c#", "cs"), ("yaml", "yaml"),
            ("node", "js"), ("main.swift", "swift"), ("language-python", "py"),
            ("{.typescript}", "ts"), ("python linenums=1", "py"),
        ]
        for (info, expected) in aliases {
            expect(PreviewSyntaxHighlighter.languageExtension(forFenceInfo: info) == expected,
                "Common Markdown fence language \(info) did not map to \(expected)")
        }
        for info: String? in [nil, "", "text", "plaintext", "plain", "unknown-language"] {
            expect(PreviewSyntaxHighlighter.languageExtension(forFenceInfo: info) == nil,
                "Unspecified/plain/unsupported fence \(String(describing: info)) must remain uncolored")
        }

        for fixture in fixtures {
            guard let ext = PreviewSyntaxHighlighter.languageExtension(forFenceInfo: fixture.language) else {
                fatalError("Missing fixture language \(fixture.language)")
            }
            let spans = PreviewSyntaxHighlighter.spans(in: fixture.source, extension: ext)
            let ns = fixture.source as NSString
            expect(!spans.isEmpty, "\(fixture.language) fence stayed monochrome")
            expect(spans.allSatisfy { $0.range.location != NSNotFound && NSMaxRange($0.range) <= ns.length },
                "Scanner returned a range outside Unicode source")
            let meaningful = spans.filter { span in
                if case .keyword = span.token { return ns.substring(with: span.range) == fixture.keyword }
                return false
            }
            expect(!meaningful.isEmpty, "\(fixture.language) keyword did not receive a keyword token")
            expect(spans.contains { span in
                if case .string = span.token { return ns.substring(with: span.range) == fixture.string }
                return false
            }, "\(fixture.language) string literal did not retain its complete Unicode text")
            if let comment = fixture.comment {
                let range = ns.range(of: comment)
                expect(spans.contains { span in
                    if case .comment = span.token { return span.range == range }
                    return false
                }, "\(fixture.language) comment was not a single protected token")
                expect(!spans.contains { span in
                    if case .keyword = span.token { return NSIntersectionRange(span.range, range).length > 0 }
                    return false
                }, "Keywords inside \(fixture.language) comments were highlighted again")
            }
            let styled = CodeSyntaxStyle.attributedString(source: fixture.source, spans: spans)
            expect(String(styled.characters) == fixture.source, "Highlighting changed source/copy text")
            expect(styled.runs.contains { $0.foregroundColor != nil }, "Scanner tokens did not become foreground colors")
            expect(styled.runs.allSatisfy { $0.link == nil && $0.inlinePresentationIntent == nil && $0.font == nil },
                "Source code gained Markdown/link interpretation")

            // Both ordinary replies and reasoning render through MarkdownParser:
            // a fence is a dedicated code block, including nested quotes/lists,
            // instead of becoming inline prose or a group of colored Markdown runs.
            let markdown = "Before reasoning.\n\n```\(fixture.language)\n\(fixture.source)```\n\nAfter reasoning."
            let blocks = MarkdownParser.parse(markdown)
            expect(blocks.contains { block in
                if case .code(let language, let code) = block {
                    return language == fixture.language && code == String(fixture.source.dropLast())
                }
                return false
            }, "Fenced \(fixture.language) source was lost in chat/reasoning Markdown")
            var text = "", previous: (text: String, parse: MarkdownParser.Parse)?
            for character in markdown {
                text.append(character)
                let parsed = MarkdownParser.parse(text, extending: previous)
                expect(parsed.blocks == MarkdownParser.parse(text), "Streaming fence parse changed at a token boundary")
                previous = (text, parsed)
            }
        }

        checkExtendedLanguages()
        checkThemePalettes()
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        checkMultilineAndIncompleteStrings()
        try checkAppearanceAndSnapshots(root: root)
        checkLargeSourceBounds()
        print("Chat code highlighting checks passed: \(checks). Offscreen light/dark previews: \(root.path)")
    }

    @MainActor private static func checkExtendedLanguages() {
        let files = [
            ("/repo/README.md", "md"), ("guide.markdown", "md"), ("notes.mdx", "md"),
            ("/repo/Makefile", "make"), ("GNUmakefile", "make"), ("Makefile.local", "make"), ("rules.mk", "make"),
            ("CMakeLists.txt", "cmake"), ("cmake/FindOMP.cmake", "cmake"),
            ("Dockerfile", "dockerfile"), ("Containerfile.dev", "dockerfile"), ("build.Dockerfile", "dockerfile"),
            ("/文档/paper.tex", "tex"), ("class.cls", "tex"), ("package.sty", "tex"), ("refs.bib", "bib"),
            (".env", "env"), (".env.production", "env"), (".gitconfig", "ini"), (".zshrc", "zsh"),
            ("main.mjs", "js"), ("main.cts", "ts"), ("types.pyi", "py"), ("data.jsonl", "json"),
            ("main.tfvars", "tf"), ("app.fsx", "fs"), ("logic.svh", "v"), ("numeric.F90", "f90"),
        ]
        for (path, expected) in files {
            expect(PreviewSyntaxHighlighter.languageExtension(forFilePath: path) == expected,
                   "Source/read-tool filename \(path) did not resolve to \(expected)")
            expect(PreviewSyntaxHighlighter.languageExtension(forFenceInfo: path) == expected,
                   "A filename used as fence info diverged from source recognition: \(path)")
        }
        for file in ["README", "notes.txt", "image.png", "program.unknown"] {
            expect(PreviewSyntaxHighlighter.languageExtension(forFilePath: file) == nil,
                   "Unknown/plain file unexpectedly selected a grammar: \(file)")
        }
        for info in ["latex", "{.latex}", "language-tex", "tex linenums=1"] {
            expect(PreviewSyntaxHighlighter.languageExtension(forFenceInfo: info) == "tex", "TeX alias was lost")
        }

        // Each source exercises actual syntax, rather than merely listing accepted extensions.
        let examples: [(String, String, [(String, String)])] = [
            ("markdown", "# 中文 heading\n\n**bold** and `literal *code*`\n- [guide](./guide.md)\n> quote\n<!-- hidden *text* -->\n```swift\nlet value = 1\n```\n",
             [("keyword", "# 中文 heading"), ("type", "**bold**"), ("string", "`literal *code*`"), ("attribute", "[guide](./guide.md)"), ("attribute", "- "), ("attribute", "> "), ("comment", "<!-- hidden *text* -->"), ("string", "```swift\nlet value = 1\n```")]),
            ("makefile", "# include ignored\n.PHONY: all\nFLAGS := -O2\nall: main.c\n\t$(CC) $(FLAGS) $< -o $@\ninclude config.mk\n",
             [("comment", "# include ignored"), ("keyword", ".PHONY"), ("keyword", "include"), ("attribute", "FLAGS"), ("attribute", "$(CC)"), ("attribute", "$@"), ("type", "all")]),
            ("latex", #"\documentclass{article}"# + "\n" + #"100\% visible % \section{hidden}"# + "\n" + #"\verb|% untouched| \section{中文 😺}"#,
             [("keyword", #"\documentclass"#), ("keyword", #"\%"#), ("keyword", #"\section"#), ("comment", #"% \section{hidden}"#), ("string", #"\verb|% untouched|"#)]),
            ("bibtex", "@article{ref,\n title = {中文 title},\n year = 2026\n}\n",
             [("keyword", "@article"), ("attribute", "title"), ("number", "2026")]),
            ("cmake", "#[=[ hidden set(X 1) ]=]\nset(NAME [=[中文 # unchanged]=])\nmessage(${NAME})\n",
             [("comment", "#[=[ hidden set(X 1) ]=]"), ("keyword", "set"), ("string", "[=[中文 # unchanged]=]"), ("attribute", "${NAME}")]),
            ("Dockerfile", "# FROM hidden\nFROM alpine:3 AS builder\nWORKDIR /src\nCOPY --from=builder /src /out\n",
             [("comment", "# FROM hidden"), ("keyword", "FROM"), ("keyword", "WORKDIR"), ("attribute", "--from")]),
            ("ini", "[database]\nport = 5432\n; ignored true\nenabled = true\n",
             [("type", "[database]"), ("attribute", "port"), ("comment", "; ignored true"), ("keyword", "true")]),
            ("dotenv", "API_URL=\"https://example.com/#fragment\"\n# ignored export\nexport ENABLED=true\n",
             [("attribute", "API_URL"), ("string", "\"https://example.com/#fragment\""), ("comment", "# ignored export")]),
            ("terraform", "# resource hidden\nresource \"local_file\" \"doc\" {\n filename = \"doc.txt\"\n}\n",
             [("keyword", "resource"), ("attribute", "filename"), ("string", "\"doc.txt\"")]),
            ("nix", "# let hidden\nlet value = \"中文\"; in { inherit value; }\n", [("keyword", "let"), ("keyword", "inherit"), ("comment", "# let hidden")]),
            ("graphql", "# query hidden\nquery User($id: ID!) { user(id: $id) { name } }", [("keyword", "query"), ("attribute", "$id"), ("comment", "# query hidden")]),
            ("protobuf", "// message hidden\nsyntax = \"proto3\"; message User { optional string name = 1; }", [("keyword", "message"), ("keyword", "optional"), ("string", "\"proto3\"")]),
            ("lua", "--[=[ local hidden ]=]\nlocal value = [=[-- return literal]=]\nreturn value", [("comment", "--[=[ local hidden ]=]"), ("keyword", "local"), ("string", "[=[-- return literal]=]")]),
            ("perl", "# sub hidden\nsub greet { my $value = 'hello'; return $value; }", [("keyword", "sub"), ("keyword", "my"), ("comment", "# sub hidden")]),
            ("r", "# function hidden\nf <- function(x) { if (TRUE) return(x) }", [("keyword", "function"), ("keyword", "TRUE"), ("comment", "# function hidden")]),
            ("julia", "#= function hidden =#\nfunction f(x)\n return nothing\nend", [("keyword", "function"), ("keyword", "nothing"), ("comment", "#= function hidden =#")]),
            ("matlab", "A = matrix'; % function hidden\nfunction y = f(x)\ny = x;\nend", [("keyword", "function"), ("keyword", "end"), ("comment", "% function hidden")]),
            ("php", "<?php # function hidden\nfunction greet($name) { echo \"hello\"; }", [("keyword", "echo"), ("attribute", "$name"), ("comment", "# function hidden")]),
            ("dart", "mixin Named { late String name; }", [("keyword", "mixin"), ("keyword", "late")]),
            ("scala", "object Main { val name = \"OMP\" }", [("keyword", "object"), ("keyword", "val")]),
            ("groovy", "def answer = 42; synchronized (this) { return answer }", [("keyword", "def"), ("keyword", "synchronized")]),
            ("powershell", "<# function hidden #>\nfunction Test { param($Name) return $Name }", [("comment", "<# function hidden #>"), ("keyword", "param"), ("attribute", "$Name")]),
            ("batch", "@REM if hidden\nIF EXIST %PATH% ECHO hello", [("comment", "@REM if hidden"), ("keyword", "IF"), ("attribute", "%PATH%")]),
            ("elixir", "# defmodule hidden\ndefmodule User do\n def name, do: nil\nend", [("keyword", "defmodule"), ("keyword", "end"), ("comment", "# defmodule hidden")]),
            ("erlang", "% receive hidden\nloop() -> receive stop -> ok end.", [("keyword", "receive"), ("keyword", "end"), ("comment", "% receive hidden")]),
            ("haskell", "{- module hidden -}\nmodule Main where\nmain = let x = 1 in x", [("comment", "{- module hidden -}"), ("keyword", "module"), ("keyword", "where")]),
            ("fsharp", "(* let hidden *)\nlet value (x: 'a) = x\nlet result = value 1", [("comment", "(* let hidden *)"), ("keyword", "let")]),
            ("clojure", "; defn hidden\n(defn greet [x] (if x \"hello\" nil))", [("comment", "; defn hidden"), ("keyword", "defn"), ("string", "\"hello\"")]),
            ("lisp", "; defun hidden\n(defun greet (x) 'hello)\n(if x 1 2)", [("keyword", "defun"), ("keyword", "if"), ("comment", "; defun hidden")]),
            ("scheme", "; define hidden\n(define x '(a b))\n(if x 1 2)", [("keyword", "define"), ("keyword", "if"), ("comment", "; define hidden")]),
            ("ocaml", "(* let hidden *)\nlet identity (x: 'a) = x\nlet value = 1", [("comment", "(* let hidden *)"), ("keyword", "let")]),
            ("zig", "// comptime hidden\ncomptime { const value = @sizeOf(u32); }", [("keyword", "comptime"), ("attribute", "@sizeOf"), ("comment", "// comptime hidden")]),
            ("verilog", "// module hidden\nmodule gate(input logic a, output logic y); assign y = a; endmodule", [("keyword", "module"), ("keyword", "assign"), ("keyword", "endmodule")]),
            ("vhdl", "-- entity hidden\nENTITY gate IS PORT(a: IN bit); END gate;", [("comment", "-- entity hidden"), ("keyword", "ENTITY"), ("keyword", "PORT")]),
            ("fortran", "! program hidden\nPROGRAM hello\nIMPLICIT NONE\nPRINT *, 'hello'\nEND PROGRAM", [("comment", "! program hidden"), ("keyword", "PROGRAM"), ("keyword", "IMPLICIT")]),
            ("assembly", "; mov hidden\nsection .text\nMOV eax, 42\nret", [("comment", "; mov hidden"), ("keyword", "MOV"), ("keyword", "section")]),
            ("diff", "--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old value\n+new value\n", [("comment", "--- a/file"), ("type", "@@ -1 +1 @@"), ("keyword", "-old value"), ("string", "+new value")]),
        ]
        func name(_ token: PreviewSyntaxHighlighter.Token) -> String {
            switch token {
            case .comment: "comment"
            case .string: "string"
            case .keyword: "keyword"
            case .number: "number"
            case .type: "type"
            case .attribute: "attribute"
            }
        }
        for (language, source, expected) in examples {
            let spans = PreviewSyntaxHighlighter.spans(in: source, extension: language)
            let text = source as NSString
            for (token, literal) in expected {
                expect(spans.contains { name($0.token) == token && text.substring(with: $0.range) == literal },
                       "\(language) did not color \(literal) as \(token)")
            }
            var end = 0
            for span in spans {
                expect(span.range.location >= end && Range(span.range, in: source) != nil,
                       "\(language) produced overlapping or invalid Unicode tokens")
                end = NSMaxRange(span.range)
            }
            expect(String(CodeSyntaxStyle.attributedString(source: source, spans: spans).characters) == source,
                   "\(language) changed selectable/copyable source")
        }
        for (language, source, literal) in [
            ("tex", #"\begin{verbatim}\section{hidden} % literal"#, #"\begin{verbatim}\section{hidden} % literal"#),
            ("cmake", "set(VALUE [==[if # literal", "[==[if # literal"),
            ("lua", "local value = [==[return -- literal", "[==[return -- literal"),
        ] {
            let spans = PreviewSyntaxHighlighter.spans(in: source, extension: language)
            expect(spans.contains { name($0.token) == "string" && (source as NSString).substring(with: $0.range) == literal },
                   "Unfinished \(language) literal leaked apparent keywords or comments")
        }
    }

    @MainActor private static func resolved(_ color: Color, _ environment: EnvironmentValues) -> String {
        let value = color.resolve(in: environment)
        return String(format: "%.4f,%.4f,%.4f,%.4f", value.red, value.green, value.blue, value.opacity)
    }

    @MainActor private static func resolved(_ color: NSColor, _ appearance: NSAppearance) -> String {
        var converted = color
        appearance.performAsCurrentDrawingAppearance { converted = color.usingColorSpace(.sRGB) ?? color }
        let rgb = converted.usingColorSpace(.sRGB) ?? converted
        return String(format: "%.4f,%.4f,%.4f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }

    /// Native and WebKit share these cached colors. Exercise every selectable
    /// family in both appearances, proving that the cache follows appearance,
    /// that selecting a theme changes visible ink, and that the attributed
    /// string honors an explicit theme instead of only the shared selection.
    @MainActor private static func checkThemePalettes() {
        let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
        let tokens: [PreviewSyntaxHighlighter.Token] = [.comment, .string, .keyword, .number, .type, .attribute]
        let source = fixtures[3].source
        let spans = PreviewSyntaxHighlighter.spans(in: source, extension: "swift")
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        var darkEnvironment = EnvironmentValues()
        darkEnvironment.colorScheme = .dark
        var lightPalettes: [String] = [], darkPalettes: [String] = []
        var plainForegrounds: [String] = [], styledPalettes: [String] = []
        for theme in CodeHighlightTheme.allCases {
            let cached = tokens.map { CodeSyntaxStyle.color(for: $0, theme: theme) }
            let lightPalette = cached.map { resolved($0, light) }
            let darkPalette = cached.map { resolved($0, dark) }
            // Resolve the identical cached objects again in both appearances:
            // a dynamic palette must not freeze at the first caller's context.
            expect(cached.map { resolved($0, light) } == lightPalette,
                "\(theme.title) syntax colors froze at their first resolved appearance")
            expect(lightPalette != darkPalette, "\(theme.title) did not adapt its syntax colors to light/dark")
            lightPalettes.append(lightPalette.joined(separator: "|"))
            darkPalettes.append(darkPalette.joined(separator: "|"))

            let plain = CodeSyntaxStyle.attributedString(source: source, spans: [], theme: theme)
            let plainColors = plain.runs.compactMap { $0.foregroundColor }
            guard let foreground = plainColors.first else {
                fatalError("\(theme.title) applied no foreground to unhighlighted code")
            }
            expect(Set(plainColors.map { resolved($0, environment) }).count == 1,
                "\(theme.title) mixed foregrounds on unhighlighted code")
            let plainInk = resolved(foreground, environment)
            expect(plainInk != resolved(foreground, darkEnvironment),
                "\(theme.title) unhighlighted code did not adapt to dark appearance")
            plainForegrounds.append(plainInk)

            let styled = CodeSyntaxStyle.attributedString(source: source, spans: spans, theme: theme)
            let lightRuns = styled.runs.compactMap { run in run.foregroundColor.map { resolved($0, environment) } }
            let darkRuns = styled.runs.compactMap { run in run.foregroundColor.map { resolved($0, darkEnvironment) } }
            expect(Set(lightRuns).count >= 4, "\(theme.title) collapsed highlighted code into monochrome")
            expect(lightRuns != darkRuns, "\(theme.title) highlighted code did not adapt to light/dark appearance")
            styledPalettes.append(lightRuns.joined(separator: "|"))
        }
        let count = CodeHighlightTheme.allCases.count
        expect(Set(lightPalettes).count == count, "Selecting a theme did not change the light syntax palette")
        expect(Set(darkPalettes).count == count, "Selecting a theme did not change the dark syntax palette")
        expect(Set(plainForegrounds).count == count, "Selecting a theme did not change code foreground colors")
        expect(Set(styledPalettes).count == count, "Attributed code ignored the requested theme")
    }

    @MainActor private static func checkStreamingAppearance() {
        let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
        for startsDark in [true, false] {
            let storage = NSTextStorage()
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 600, height: 1000))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 100), textContainer: container)
            view.isEditable = false
            view.appearance = startsDark ? dark : light
            let veil = LinkTextVeil()
            defer { veil.detach(view) }
            let start = Date(timeIntervalSinceReferenceDate: 1000)
            let font = NSFont.systemFont(ofSize: 15)
            storage.setAttributedString(NSAttributedString(string: "Existing text ", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            veil.update(view, active: true, at: start)
            var probes: [(index: Int, color: NSColor)] = []
            for (text, color, link) in [
                ("中文 e\u{301} 👩🏽‍💻 ", NSColor.labelColor, false),
                ("link ", NSColor.systemBlue, true),
                ("grey_code ", NSColor.secondaryLabelColor, true),
                ("dimmed ", NSColor(srgbRed: 0.7, green: 0.5, blue: 0.3, alpha: 0.6), false),
            ] {
                probes.append((storage.length, color))
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                if link { attributes[.link] = URL(string: "https://example.invalid/fixture")! }
                storage.append(NSAttributedString(string: text, attributes: attributes))
            }
            let original = NSAttributedString(attributedString: storage)
            view.setSelectedRange(NSRange(location: 1, length: 3))
            // A display callback can execute under the app's default appearance,
            // different from a conversation that explicitly uses dark/light mode.
            (startsDark ? light : dark).performAsCurrentDrawingAppearance {
                veil.update(view, active: true, at: start.addingTimeInterval(0.04))
                for (frame, appearance) in [view.appearance!, startsDark ? light : dark, view.appearance!].enumerated() {
                    view.appearance = appearance
                    veil.update(view, active: true, at: start.addingTimeInterval(0.08 + Double(frame) * 0.05))
                    view.effectiveAppearance.performAsCurrentDrawingAppearance {
                        var fade: CGFloat?
                        for probe in probes {
                            guard let actual = (layout.temporaryAttribute(.foregroundColor, atCharacterIndex: probe.index, effectiveRange: nil) as? NSColor)?.usingColorSpace(.deviceRGB),
                                  let expected = probe.color.usingColorSpace(.deviceRGB) else {
                                fatalError("Streaming text lost its temporary foreground")
                            }
                            expect(abs(actual.redComponent - expected.redComponent) < 0.001
                                && abs(actual.greenComponent - expected.greenComponent) < 0.001
                                && abs(actual.blueComponent - expected.blueComponent) < 0.001,
                                "Streaming foreground used the callback appearance or replaced a run's own color (dark=\(startsDark), frame=\(frame), offset=\(probe.index))")
                            let factor = actual.alphaComponent / expected.alphaComponent
                            expect(factor > 0 && factor < 1, "Streaming fade lost its intermediate opacity")
                            if let fade {
                                expect(abs(fade - factor) < 0.001, "Streaming fade replaced a run's existing alpha instead of multiplying it")
                            } else { fade = factor }
                        }
                    }
                    expect(storage.isEqual(to: original) && view.selectedRange() == NSRange(location: 1, length: 3),
                        "A color-only stream update changed text, fonts, links or selection")
                }
                veil.update(view, active: false, at: start.addingTimeInterval(1))
                expect(probes.allSatisfy { layout.temporaryAttribute(.foregroundColor, atCharacterIndex: $0.index, effectiveRange: nil) == nil },
                    "Finishing a stream left temporary colors over settled text")
            }
            veil.detach(view)
            veil.update(view, active: true, at: start.addingTimeInterval(2))
            expect(probes.allSatisfy { layout.temporaryAttribute(.foregroundColor, atCharacterIndex: $0.index, effectiveRange: nil) == nil },
                "Reattaching a paragraph re-veiled existing text")
        }
    }

    @MainActor private static func checkMultilineAndIncompleteStrings() {
        for (ext, source, literal) in [
            ("py", "def doc():\n    \"\"\"import 12\nreturn False\"\"\"\n    return 1", "\"\"\"import 12\nreturn False\"\"\""),
            ("py", "value = '''def\nreturn True'''", "'''def\nreturn True'''"),
            ("js", "const text = `return\n123`;", "`return\n123`"),
            ("swift", "let text = \"return 12", "\"return 12"),
            ("swift", "let text = \"return if\\", "\"return if\\"),
            ("py", "value = \"\"\"return if\\", "\"\"\"return if\\"),
        ] {
            let ns = source as NSString
            let spans = PreviewSyntaxHighlighter.spans(in: source, extension: ext)
            let range = ns.range(of: literal)
            expect(spans.contains { span in
                if case .string = span.token { return span.range == range }
                return false
            }, "A multiline/open \(ext) string split into apparent code tokens")
            expect(!spans.contains { span in
                if case .keyword = span.token { return NSIntersectionRange(span.range, range).length > 0 }
                return false
            }, "A keyword inside an incomplete/multiline string gained keyword color")
        }
        for source in [
            "fn read<'a>(x: &'a str) -> &'a str { return x; }",
            "let value: &'static str = \"ok\"; return value;",
            "let marker = 'x'; return marker;",
        ] {
            let ns = source as NSString
            let spans = PreviewSyntaxHighlighter.spans(in: source, extension: "rs")
            expect(spans.contains { span in
                if case .keyword = span.token { return ns.substring(with: span.range) == "return" }
                return false
            }, "Rust lifetime/character literal swallowed later return keyword")
            expect(!spans.contains { span in
                if case .string = span.token {
                    let value = ns.substring(with: span.range)
                    return value.contains("'a") || value.contains("'static") || value.contains("return")
                }
                return false
            }, "Rust lifetime became an unterminated string")
            if source.contains("'x'") {
                expect(spans.contains { span in
                    if case .string = span.token { return ns.substring(with: span.range) == "'x'" }
                    return false
                }, "Rust character literals lost string color")
            }
        }
    }

    @MainActor private static func checkLargeSourceBounds() {
        let source = String(repeating: "// 中文 👩🏽‍💻\nlet value = \"not return\" + 123\n", count: 20_000)
        let spans = PreviewSyntaxHighlighter.spans(in: source, extension: "swift")
        expect(spans.count <= PreviewSyntaxHighlighter.maximumSpans, "Large chat code exceeded token bound")
        expect(spans.allSatisfy { NSMaxRange($0.range) <= PreviewSyntaxHighlighter.maximumUTF16Length },
            "Large chat code scanned beyond its bounded prefix")
        expect(PreviewSyntaxHighlighter.spans(in: source, extension: "not-supported").isEmpty,
            "Unsupported languages trigger a large syntax scan")
        expect(String(CodeSyntaxStyle.attributedString(source: source, spans: spans).characters) == source,
            "Bounded highlighting truncated the actual copied source")
    }

    @MainActor private static func checkAppearanceAndSnapshots(root: URL) throws {
        // Reuse one attributed value across both environments: caching must not
        // freeze the first appearance's foreground colors.
        let fixture = fixtures[3]
        let spans = PreviewSyntaxHighlighter.spans(in: fixture.source, extension: "swift")
        let styled = CodeSyntaxStyle.attributedString(source: fixture.source, spans: spans)
        var palettes: [[String]] = []
        for dark in [false, true] {
            var environment = EnvironmentValues()
            environment.colorScheme = dark ? .dark : .light
            var palette: [String] = []
            for token in [PreviewSyntaxHighlighter.Token.comment, .string, .keyword, .number, .type, .attribute] {
                let dynamic = Color(nsColor: CodeSyntaxStyle.color(for: token)).resolve(in: environment)
                palette.append(String(format: "%.4f,%.4f,%.4f", dynamic.red, dynamic.green, dynamic.blue))
            }
            expect(Set(palette).count >= 5, "\(dark ? "Dark" : "Light") syntax colors collapsed into monochrome")
            palettes.append(palette)
            let colors = styled.runs.compactMap { $0.foregroundColor?.resolve(in: environment) }
            expect(Set(colors.map { String(format: "%.4f,%.4f,%.4f", $0.red, $0.green, $0.blue) }).count >= 4,
                "Cached attributed code did not retain distinct themed token colors")
            try snapshot(to: root.appendingPathComponent("chat-code-\(dark ? "dark" : "light").png"), dark: dark)
        }
        expect(palettes[0] != palettes[1], "Code syntax palette did not adapt between light/dark appearance")
    }

    @MainActor private static func snapshot(to url: URL, dark: Bool) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var png: Data?
        appearance.performAsCurrentDrawingAppearance {
            let width = 1080, height = 950
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = NSSize(width: width, height: height)
            let cg = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
            cg.translateBy(x: 0, y: CGFloat(height))
            cg.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            NSColor.textBackgroundColor.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            var y: CGFloat = 24
            for fixture in fixtures {
                let title = NSAttributedString(string: fixture.language + " — chat/reasoning shared code styling", attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.labelColor,
                ])
                title.draw(at: NSPoint(x: 24, y: y))
                y += 26
                let source = NSMutableAttributedString(string: fixture.source, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.labelColor, .ligature: 0,
                ])
                let ext = PreviewSyntaxHighlighter.languageExtension(forFenceInfo: fixture.language)!
                let spans = PreviewSyntaxHighlighter.spans(in: fixture.source, extension: ext)
                let styled = CodeSyntaxStyle.attributedString(source: fixture.source, spans: spans)
                var environment = EnvironmentValues()
                environment.colorScheme = dark ? .dark : .light
                for run in styled.runs {
                    guard let color = run.foregroundColor else { continue }
                    let resolved = color.resolve(in: environment)
                    let range = NSRange(location: String(styled[..<run.range.lowerBound].characters).utf16.count,
                        length: String(styled[run.range].characters).utf16.count)
                    source.addAttribute(.foregroundColor, value: NSColor(srgbRed: CGFloat(resolved.red),
                        green: CGFloat(resolved.green), blue: CGFloat(resolved.blue), alpha: CGFloat(resolved.opacity)), range: range)
                }
                let storage = NSTextStorage(attributedString: source)
                let manager = NSLayoutManager()
                let container = NSTextContainer(size: NSSize(width: 1032, height: 1_000_000))
                container.lineFragmentPadding = 0
                storage.addLayoutManager(manager)
                manager.addTextContainer(container)
                manager.ensureLayout(for: container)
                let actual = manager.usedRect(for: container)
                manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: NSPoint(x: 24, y: y))
                y += ceil(actual.height) + 22
            }
            png = bitmap.representation(using: .png, properties: [:])
        }
        try png!.write(to: url)
    }
}
