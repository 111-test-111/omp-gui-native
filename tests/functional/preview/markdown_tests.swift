import AppKit
import Foundation
import ImageIO
import WebKit

/// One rendered sample of the Markdown preview's syntax ink. Components are
/// 0...255 sRGB values read back from WebKit's computed styles.
private struct ThemeProbe: Decodable {
    var comment: [Double]
    var keyword: [Double]
    var string: [Double]
    var number: [Double]
    var type: [Double]
    var plain: [Double]
    var tokensTransparent: Bool
    var documentTransparent: Bool
}

/// Production renderer in an unshown window. Does not launch/install the GUI,
/// change application data, or fetch web assets. An optional paper path is read
/// in place; the copyrighted paper and its figures are not copied into the repo.
@main @MainActor
struct MarkdownPreviewChecks {
    static func main() async {
        do { try await run() } catch { print("CHECK FAILED:", error); exit(1) }
    }
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String = "Expectation failed") throws {
        guard condition() else { throw NSError(domain: message, code: 1) }
    }
    static func run() async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
        let processStarted = ProcessInfo.processInfo.systemUptime
        var host: PreviewMarkdownHost? = PreviewMarkdownHost(resourceRoot: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host!.frame = window.contentView!.bounds
        host!.layoutSubtreeIfNeeded()
        // The document and rubber-band canvas must both reveal the shared
        // native backdrop, while semantic text still follows the appearance.
        host!.appearance = NSAppearance(named: .darkAqua)
        var state = PreviewReaderState(), revision = 0
        let fixtureURL = output.appendingPathComponent("fixture.md")
        var opened: [String] = []
        func js(_ script: String) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                host!.web.evaluateJavaScript(script) { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else {
                        let data = try? JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed, .sortedKeys])
                        continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) } ?? "null")
                    }
                }
            }
        }
        func check(_ script: String, _ message: String) async throws {
            let result = try await js(script)
            guard result == "true" else { throw NSError(domain: message, code: 1) }
        }
        func asyncJSON(_ script: String, arguments: [String: Any] = [:]) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                host!.web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
                    switch result {
                    case .success(let value):
                        if let value = value as? String { continuation.resume(returning: value) }
                        else { continuation.resume(throwing: NSError(domain: "Expected JSON string", code: 1)) }
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }
        func render(_ source: String, url: URL? = nil, freshState: Bool = true) async throws {
            if freshState { state = PreviewReaderState() }
            revision += 1
            host!.update(url: url ?? fixtureURL, source: source, revision: String(revision), state: state, findRequest: 0) { ref, _ in opened.append(ref.path) }
            for _ in 0..<400 {
                if !host!.renderedToken.isEmpty { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            print("Failed resources:", host!.resources.failedPaths); fflush(nil)
            print("Page:", try await js("document.body.innerText")); fflush(nil)
            print("Diagnostics:", try await js("JSON.stringify({phase:document.documentElement.dataset.phase,fonts:document.fonts.status,faces:[...document.fonts].map(f=>[f.family,f.status]),requests:performance.getEntriesByType('resource').map(r=>r.name)})")); fflush(nil)
            print("Runtime:", try await js("JSON.stringify({preview:typeof preview,mathjax:typeof MathJax,startup:!!window.MathJax?.startup})")); fflush(nil)
            throw NSError(domain: "Markdown render timed out", code: 1)
        }
        @discardableResult func snapshot(_ name: String) async throws -> NSBitmapImageRep {
            let config = WKSnapshotConfiguration()
            config.rect = host!.web.bounds
            let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                host!.web.takeSnapshot(with: config) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? NSError(domain: "Snapshot", code: 1)) }
                }
            }
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            let data = bitmap.representation(using: .png, properties: [:])!
            try data.write(to: output.appendingPathComponent(name + ".png"))
            return bitmap
        }
        if args.last == "--benchmark", args.count > 4 {
            let paperURL = URL(fileURLWithPath: args[3])
            let paper = try String(contentsOf: paperURL, encoding: .utf8)
            try await render(paper, url: paperURL)
            func report(_ value: [String: Any]) throws {
                print(String(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!)
                fflush(nil)
            }
            try report(["phase": "cold", "wall_ms": (ProcessInfo.processInfo.systemUptime - processStarted) * 1000,
                        "javascript_ms": host!.renderMilliseconds, "formulas": host!.formulaCount, "errors": host!.formulaErrors])
            try await Task.sleep(for: .seconds(3))
            var times: [Double] = []
            for _ in 0..<10 { try await render(paper, url: paperURL); times.append(host!.renderMilliseconds) }
            try report(["phase": "warm", "javascript_ms": times,
                        "stylesheets": try await js("document.styleSheets.length"), "resources": host!.resources.servedPaths.count])
            try await Task.sleep(for: .seconds(3))
            // Exercise the native image path separately from viewport-lazy
            // decoding, using five batches of the paper's five figures.
            let imageReport = try await asyncJSON("""
                const images = [...document.querySelectorAll('img')];
                const started = performance.now();
                let bytes = 0;
                for (let n = 0; n < 5; n++) {
                    const sizes = await Promise.all(images.map(async i => (await (await fetch(i.src)).arrayBuffer()).byteLength));
                    bytes += sizes.reduce((a,b) => a+b, 0);
                }
                return JSON.stringify({phase:'images', milliseconds:performance.now()-started, requests:images.length*5, bytes});
                """)
            print(imageReport); fflush(nil)
            try await Task.sleep(for: .seconds(3))
            weak let released = host
            host!.tearDown(); window.contentView = nil; host = nil
            try await Task.sleep(for: .milliseconds(200))
            try expect(released == nil)
            try report(["phase": "released"])
            try await Task.sleep(for: .seconds(3))
            return
        }
        let textOnly = "# Plain document\n\nText and [a reference][ref]. Inline `AffjTy中文汉字测试😀`.\n\n```\nAffjTy中文汉字测试😀\n```\n\n| Header |\n| --- |\n| Cell |\n\nFootnote[^size].\n\n[^size]: Footnote text.\n\n[ref]: ./notes.md\n"
        try await render(textOnly)
        let originalMonospacedName = TypeScale.shared.monospacedFontName
        let originalUI = TypeScale.shared.ui
        let originalCode = TypeScale.shared.code
        let originalContent = TypeScale.shared.content
        defer {
            TypeScale.shared.monospacedFontName = originalMonospacedName
            TypeScale.shared.ui = originalUI
            TypeScale.shared.code = originalCode
            TypeScale.shared.content = originalContent
            host?.updateFonts(revision: AppFont.revision)
        }
        let fontToken = host!.renderedToken
        _ = try await js("""
            window.fontDocument = document.getElementById('document');
            window.fontHeading = document.querySelector('h1');
            const range = document.createRange();
            range.selectNodeContents(window.fontHeading);
            getSelection().removeAllRanges();
            getSelection().addRange(range);
            window.fontSelection = getSelection().toString();
            window.fontBodySize = getComputedStyle(document.documentElement).fontSize;
            window.fontCodeSize = getComputedStyle(document.querySelector('code')).fontSize;
            """)
        func checkFontDocument() async throws {
            try expect(host!.renderedToken == fontToken, "A font-only update re-rendered the Markdown document")
            try await check("""
                document.getElementById('document') === window.fontDocument
                && document.querySelector('h1') === window.fontHeading
                && getSelection().toString() === window.fontSelection
                && getSelection().anchorNode === window.fontHeading
                && getSelection().focusNode === window.fontHeading
                && getComputedStyle(document.documentElement).fontSize === window.fontBodySize
                && getComputedStyle(document.querySelector('code')).fontSize === window.fontCodeSize
                """, "A font-only update replaced DOM nodes, changed sizes, or lost the selection")
        }
        for monospacedName in ["Menlo-Italic", "Menlo-Bold"] {
            TypeScale.shared.monospacedFontName = monospacedName
            try expect(AppFont.monospacedPostScriptName == monospacedName,
                       "Specific-face fixtures must resolve installed PostScript names")
            let nativeMonospaced = AppFont.monospaced(size: 13)
            try expect(nativeMonospaced.fontName == monospacedName,
                       "Native text did not retain the selected face")
            let trait: NSFontTraitMask = monospacedName.hasSuffix("Italic") ? .italicFontMask : .boldFontMask
            try expect(NSFontManager.shared.traits(of: nativeMonospaced).contains(trait),
                       "Specific-face fixtures must retain their italic/bold traits")
            host!.update(url: fixtureURL, source: textOnly, revision: String(revision), state: state,
                         findRequest: 0) { ref, _ in opened.append(ref.path) }
            let loaded = try await asyncJSON("""
                const alias = 'omp-preview-monospaced';
                const reference = new FontFace('font-reference', 'local(' + JSON.stringify(monospacedName) + ')');
                const regular = new FontFace('font-regular', 'local("Menlo-Regular")');
                try {
                    await Promise.all([reference, regular].map(async face => {
                        await face.load();
                        document.fonts.add(face);
                    }));
                    const faces = await document.fonts.load('48px "' + alias + '"');
                    const context = document.createElement('canvas').getContext('2d');
                    const metrics = family => {
                        context.font = '48px "' + family + '"';
                        return ['AffjTy', 'Wavy glyphs / fj', '0123456789'].flatMap(text => {
                            const m = context.measureText(text);
                            return [m.width, m.actualBoundingBoxLeft, m.actualBoundingBoxRight,
                                    m.actualBoundingBoxAscent, m.actualBoundingBoxDescent];
                        });
                    };
                    const same = (a, b) => a.every((value, i) => Math.abs(value - b[i]) < 0.001);
                    const actual = metrics(alias);
                    const matches = same(actual, metrics(reference.family))
                        && !same(actual, metrics(regular.family));
                    return JSON.stringify(matches && faces.length === 1
                        && faces[0].status === 'loaded' && faces[0].family.replace(/["']/g, '') === alias
                        && getComputedStyle(document.documentElement).fontFamily === '-apple-system, BlinkMacSystemFont, sans-serif'
                        && getComputedStyle(document.querySelector('code')).fontFamily.includes(alias)
                        && getComputedStyle(document.documentElement).fontStyle === 'normal'
                        && getComputedStyle(document.documentElement).fontWeight === '400');
                } finally {
                    [reference, regular].forEach(face => document.fonts.delete(face));
                }
                """, arguments: ["monospacedName": nativeMonospaced.fontName])
            try expect(loaded == "true", "WebKit did not load the same specific local face as native text")
            try await checkFontDocument()
        }
        for name in [" \n ", "omp-nonexistent-font-face"] {
            TypeScale.shared.monospacedFontName = name
            host!.updateFonts(revision: AppFont.revision)
            try expect(AppFont.monospacedPostScriptName == nil,
                       "Blank/invalid font names must resolve to the defaults")
            try await check("""
                ![...document.fonts].some(face => face.family.includes('omp-preview-'))
                && getComputedStyle(document.documentElement).fontFamily === '-apple-system, BlinkMacSystemFont, sans-serif'
                && getComputedStyle(document.querySelector('code')).fontFamily === 'ui-monospace, Menlo, monospace'
                """, "Blank/invalid names did not restore the Markdown fallback stacks")
            try await checkFontDocument()
        }
        TypeScale.shared.code = TypeScale.codeRange.upperBound
        TypeScale.shared.content = TypeScale.contentRange.lowerBound
        for size in [TypeScale.uiRange.lowerBound, TypeScale.defaultUI, TypeScale.uiRange.upperBound] {
            TypeScale.shared.ui = size
            host!.update(url: fixtureURL, source: textOnly, revision: String(revision), state: state,
                         findRequest: 0) { ref, _ in opened.append(ref.path) }
            try await check("""
                parseFloat(getComputedStyle(document.documentElement).fontSize) === \(size)
                && [...document.querySelectorAll('p, pre, code, table, th, td, .footnotes')]
                    .every(node => parseFloat(getComputedStyle(node).fontSize) === \(size))
                """, "Markdown body, code, tables and footnotes must equal Interface \(size) pt")
            _ = try await js("""
                window.fontBodySize = '\(size)px';
                window.fontCodeSize = '\(size)px';
                """)
            try await checkFontDocument()
        }
        TypeScale.shared.ui = originalUI
        TypeScale.shared.code = originalCode
        TypeScale.shared.content = originalContent
        TypeScale.shared.monospacedFontName = originalMonospacedName
        host!.updateFonts(revision: AppFont.revision)
        _ = try await js("getSelection().removeAllRanges()")
        func checkCanvas(_ name: String) async throws {
            try expect(host!.web.underPageBackgroundColor.alphaComponent == 0, "The over-scroll canvas must reveal the shared backdrop")
            try await check("[document.documentElement,document.body].every(e => getComputedStyle(e).backgroundColor === 'rgba(0, 0, 0, 0)')", "Document backgrounds must stay transparent")
            let bitmap = try await snapshot(name)
            try expect((bitmap.colorAt(x: 5, y: bitmap.pixelsHigh - 5)?.alphaComponent ?? 1) < 0.05,
                       "WebKit painted an opaque canvas behind the transparent document")
        }
        try await checkCanvas("transparent-dark")
        let darkText = try await js("getComputedStyle(document.querySelector('h1')).color")
        host!.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(100))
        try await checkCanvas("transparent-light")
        let lightText = try await js("getComputedStyle(document.querySelector('h1')).color")
        try expect(darkText != lightText, "Transparent Markdown must retain appearance-aware text")
        host!.appearance = nil
        try await check("document.querySelector('h1').textContent === 'Plain document' && document.querySelector('a').getAttribute('href') === './notes.md'", "Document/reference parse")
        try expect(!host!.resources.servedPaths.contains { $0.contains("mathjax") }, "Plain Markdown must not load MathJax")
        // The renderer stays WebKit; verify the actual bundled grammars and
        // fence aliases after sanitization, including verbatim copy and limits.
        let syntaxExamples = [
            ("Makefile", ".PHONY: all\nCC := clang\nall: main.c\n\t$(CC) $< -o $@"),
            ("{.latex}", #"\documentclass{article}"# + "\n" + #"\section{中文} % comment"#),
            ("paper.tex", #"\begin{document}Hello\end{document}"#),
            ("references.bib", "@article{ref, title = {中文}, year = 2026}"),
            ("CMakeLists.txt", "cmake_minimum_required(VERSION 3.20)\nset(NAME \"OMP\")"),
            ("Dockerfile.dev", "FROM alpine:3\nWORKDIR /src"),
            (".env.production", "API_URL=\"https://example.com\""),
            ("main.tf", "resource \"local_file\" \"doc\" { filename = \"doc.txt\" }"),
            ("shell.nix", "let x = 1; in { inherit x; }"),
            ("query.gql", "query User { user { name } }"),
            ("schema.proto", "syntax = \"proto3\"; message User { string name = 1; }"),
            ("lua", "local value = 'hello'\nreturn value"),
            ("perl", "sub greet { my $name = 'hello'; return $name; }"),
            ("r", "f <- function(x) { return(x) }"),
            ("julia", "function f(x)\n return nothing\nend"),
            ("matlab", "function y = f(x)\ny = x;\nend"),
            ("php", "<?php function greet() { echo 'hello'; }"),
            ("dart", "mixin Named { late String name; }"),
            ("scala", "object Main { val x = 42 }"),
            ("build.gradle", "def answer = 42"),
            ("pwsh", "function Test { param($Name) return $Name }"),
            ("cmd", "IF EXIST %PATH% ECHO hello"),
            ("elixir", "defmodule User do\n def name, do: nil\nend"),
            ("erlang", "loop() -> receive stop -> ok end."),
            ("haskell", "module Main where\nmain = let x = 1 in x"),
            ("app.fsx", "let value (x: 'a) = x"),
            ("clojure", "(defn greet [x] (if x \"hello\" nil))"),
            ("lisp", "(defun greet (x) 'hello)"),
            ("scheme", "(define x '(a b))"),
            ("ocaml", "let identity (x: 'a) = x"),
            ("main.zig", "pub fn main() void { const n = @sizeOf(u32); }"),
            ("logic.sv", "module gate(input logic a); endmodule"),
            ("vhdl", "ENTITY gate IS PORT(a: IN bit); END gate;"),
            ("numeric.F90", "PROGRAM hello\nIMPLICIT NONE\nEND PROGRAM"),
            ("assembly", "section .text\nMOV eax, 42\nret"),
            ("patch", "--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old value\n+new value"),
        ]
        let fences = syntaxExamples.map { "```\($0.0)\n\($0.1)\n```" }.joined(separator: "\n\n")
        try await render(fences)
        let expectedSyntax = String(data: try JSONSerialization.data(withJSONObject: syntaxExamples.map { $0.1 + "\n" }), encoding: .utf8)!
        try await check("""
            (() => {
                const expected = \(expectedSyntax);
                const blocks = [...document.querySelectorAll('pre code')];
                return blocks.length === expected.length && blocks.every((code, i) =>
                    code.querySelector('span[class^="hljs-"]') && code.textContent === expected[i]);
            })()
            """, "An extended offline grammar or filename alias stayed monochrome or changed copied source")
        try await check("""
            [...document.querySelectorAll('pre code')][0].querySelector('.hljs-variable')?.textContent.includes('CC')
            && [...document.querySelectorAll('pre code')][1].querySelector('.hljs-keyword')?.textContent === '\\\\documentclass'
            """, "Makefile variables or LaTeX commands did not receive syntax colors")
        try await check("""
            (() => {
                const code = document.querySelector('pre code');
                const plain = getComputedStyle(code).color;
                return ['.hljs-variable', '.hljs-section'].every(selector => {
                    const token = code.querySelector(selector);
                    return token && getComputedStyle(token).color !== plain;
                });
            })()
            """, "Makefile variables or targets inherited plain text despite having syntax tokens")
        let oversizedCode = String(repeating: "x", count: 65_537)
        try await render("```text\nconst plain = 1\n```\n\n```unknown-language\nreturn literal\n```\n\n```latex\n\(oversizedCode)\n```")
        try await check("[...document.querySelectorAll('pre code')].length === 3 && !document.querySelector('pre code span')",
                        "Plain, unknown or over-budget fences gained syntax scanning")
        try expect(!host!.resources.servedPaths.contains { $0.contains("mathjax") }, "Code-only fences loaded MathJax")
        let themeSource = "# Code theme\n\n```javascript\n// FIXTURE comment\nconst count = 42;\nconst message = \"hello\";\nclass Box {}\n```\n\n"
            + String(repeating: "Filler paragraph for scroll retention.\n\n", count: 40)
        func nativeInk(_ color: NSColor, _ appearance: NSAppearance) -> [Double] {
            var converted = color
            appearance.performAsCurrentDrawingAppearance { converted = color.usingColorSpace(.sRGB) ?? color }
            let rgb = converted.usingColorSpace(.sRGB) ?? converted
            return [Double(rgb.redComponent * 255), Double(rgb.greenComponent * 255), Double(rgb.blueComponent * 255)]
        }
        func checkCodeThemes() async throws {
            let originalTheme = CodeHighlighting.shared.theme
            let originalAppearance = host!.appearance
            try await render(themeSource)
            let themeToken = host!.renderedToken
            _ = try await js("""
                (() => {
                    window.themeDocument = document.getElementById('document');
                    window.themeCode = document.querySelector('pre code');
                    window.themeTokens = {};
                    for (const name of ['comment', 'keyword', 'string', 'number', 'type']) {
                        const element = document.querySelector(name === 'type' ? '.hljs-title' : '.hljs-' + name);
                        if (!element) throw new Error('missing syntax token ' + name);
                        window.themeTokens[name] = element;
                    }
                    window.themeKeyword = window.themeTokens.keyword.textContent;
                    window.scrollTo(0, 180);
                    const range = document.createRange();
                    range.selectNodeContents(window.themeTokens.keyword);
                    getSelection().removeAllRanges();
                    getSelection().addRange(range);
                    window.themeSelection = getSelection().toString();
                    window.themeScroll = scrollY;
                })()
                """)
            try await check("window.themeKeyword.length > 0 && window.themeSelection.length > 0 && window.themeScroll > 0",
                            "Theme fixture did not expose tokens, selection, or a scrollable document")
            func expectedInk(_ theme: CodeHighlightTheme, _ dark: Bool) -> [String: [Double]] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                return [
                    "comment": nativeInk(CodeSyntaxStyle.color(for: .comment, theme: theme), appearance),
                    "keyword": nativeInk(CodeSyntaxStyle.color(for: .keyword, theme: theme), appearance),
                    "string": nativeInk(CodeSyntaxStyle.color(for: .string, theme: theme), appearance),
                    "number": nativeInk(CodeSyntaxStyle.color(for: .number, theme: theme), appearance),
                    "type": nativeInk(CodeSyntaxStyle.color(for: .type, theme: theme), appearance),
                    "plain": nativeInk(CodeSyntaxStyle.foregroundColor(theme: theme), appearance),
                ]
            }
            func sampled(_ probe: ThemeProbe) -> [String: [Double]] {
                ["comment": probe.comment, "keyword": probe.keyword, "string": probe.string,
                 "number": probe.number, "type": probe.type, "plain": probe.plain]
            }
            func agrees(_ probe: ThemeProbe, _ expected: [String: [Double]]) -> Bool {
                sampled(probe).allSatisfy { name, values in
                    guard let target = expected[name], values.count == target.count else { return false }
                    return zip(values, target).allSatisfy { pair in abs(pair.0 - pair.1) <= 1.5 }
                }
            }
            var previous: [String: [Double]]?
            for theme in CodeHighlightTheme.allCases {
                for dark in [false, true] {
                    CodeHighlighting.shared.theme = theme
                    host!.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host!.update(url: fixtureURL, source: themeSource, revision: String(revision), state: state,
                                 findRequest: 0) { ref, _ in opened.append(ref.path) }
                    let expected = expectedInk(theme, dark)
                    var probe: ThemeProbe?
                    for _ in 0..<60 {
                        let json = try await asyncJSON("""
                            const context = document.createElement('canvas').getContext('2d');
                            const rgb = element => {
                                context.fillStyle = '#000000';
                                context.fillStyle = getComputedStyle(element).color;
                                const value = context.fillStyle;
                                if (value.charAt(0) === '#') {
                                    return [1, 3, 5].map(index => parseInt(value.substr(index, 2), 16));
                                }
                                return (value.match(/[\\d.]+/g) || []).slice(0, 3).map(Number);
                            };
                            const tokens = window.themeTokens;
                            return JSON.stringify({
                                comment: rgb(tokens.comment), keyword: rgb(tokens.keyword),
                                string: rgb(tokens.string), number: rgb(tokens.number), type: rgb(tokens.type),
                                plain: rgb(window.themeCode),
                                tokensTransparent: ['comment', 'keyword', 'string', 'number', 'type'].every(
                                    name => getComputedStyle(tokens[name]).backgroundColor === 'rgba(0, 0, 0, 0)'),
                                documentTransparent: ['documentElement', 'body'].every(
                                    name => getComputedStyle(document[name]).backgroundColor === 'rgba(0, 0, 0, 0)')
                            });
                            """)
                        let sampledProbe = try JSONDecoder().decode(ThemeProbe.self, from: Data(json.utf8))
                        probe = sampledProbe
                        if agrees(sampledProbe, expected) { break }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    guard let probe else { throw NSError(domain: "Theme probe missing", code: 1) }
                    let actual = sampled(probe)
                    for (name, target) in expected {
                        let values = actual[name] ?? []
                        try expect(values.count == target.count
                                   && zip(values, target).allSatisfy { pair in abs(pair.0 - pair.1) <= 1.5 },
                                   "WebKit \(name) ink for \(theme.title) \(dark ? "dark" : "light") diverged from native: \(values) vs \(target)")
                    }
                    try expect(probe.tokensTransparent, "A syntax token painted an opaque background")
                    try expect(probe.documentTransparent && host!.web.underPageBackgroundColor.alphaComponent == 0,
                               "A theme switch painted an opaque preview canvas")
                    try expect(Set(actual.values.map { $0.map { String(format: "%.1f", $0) }.joined(separator: ",") }).count >= 4,
                               "WebKit collapsed \(theme.title) syntax colors into monochrome")
                    if let previous {
                        try expect(actual != previous, "Switching theme/appearance left WebKit syntax ink unchanged")
                    }
                    previous = actual
                    try expect(host!.renderedToken == themeToken, "A theme/appearance switch re-rendered the document")
                    try await check("""
                        document.getElementById('document') === window.themeDocument
                        && ['comment', 'keyword', 'string', 'number', 'type'].every(
                            name => document.querySelector(name === 'type' ? '.hljs-title' : '.hljs-' + name) === window.themeTokens[name])
                        && window.themeTokens.keyword.textContent === window.themeKeyword
                        && getSelection().toString() === window.themeSelection
                        && Math.abs(scrollY - window.themeScroll) < 1
                        """, "A theme/appearance switch replaced DOM nodes, selection, or scroll")
                }
            }
            CodeHighlighting.shared.theme = originalTheme
            host!.appearance = originalAppearance
            host!.update(url: fixtureURL, source: themeSource, revision: String(revision), state: state,
                         findRequest: 0) { ref, _ in opened.append(ref.path) }
        }
        try await checkCodeThemes()
        _ = try await js("getSelection().removeAllRanges()")
        _ = try await js("window.blockedNetworkRequests=[];document.addEventListener('securitypolicyviolation',e=>{if(/^https?:/.test(e.blockedURI))blockedNetworkRequests.push(e.blockedURI)})")
        let fixture = #"""
        ---
        title: Metadata must not become a heading
        authors: A, B
        ---

        # Regression

        > First quote line
        > Second quote line
        >
        > > Nested first
        > > Nested second

        Ordinary paragraph first line
        ordinary paragraph second line.

        ---

        ***

        A footnote[^one] and a reference [file][file]. Inline $q \cdot k = \sum_{i=1}^{d_k} q_i k_i$.

        | Author | Right |
        | :--- | ---: |
        | A<sup>*</sup>[^one] | $x^2$ |

        - [x] Complete
        - [ ] Pending

        $$\operatorname{Attention}(Q,K,V)=\mathrm{softmax}\left(\frac{QK^T}{\sqrt{d_k}}\right)V\tag{1}$$

        \[\boxed{x=1}\quad\text{中文条件}\]

        \begin{align}a&=b+c\\d&=e+f\end{align}

        ```markdown
        [^raw]: literal $not_math$
        ```

        Escaped \$5 and $10, incomplete $x_{1.

        [file]: ./notes.md#L7
        [^one]: FOOTNOTE_UNIQUE with $k$.

            Second paragraph of the note.

        <script>window.untrustedCodeRan=true</script>
        <img src="https://example.invalid/tracker.png" onerror="window.untrustedCodeRan=true">
        """#
        try await render(fixture)
        print("Synthetic render: \(host!.renderMilliseconds) ms, \(host!.formulaCount) formulas, \(host!.formulaErrors) errors"); fflush(nil)
        try await check("document.querySelectorAll('.frontmatter').length === 1 && document.querySelectorAll('h1').length === 1 && !document.querySelector('h2')", "Frontmatter must not become Setext")
        try await check("document.querySelector('pre.frontmatter').textContent.includes('title: Metadata') && !document.querySelector('.frontmatter summary,.frontmatter details')", "Metadata must be visible without a disclosure control")
        try await check("document.querySelector('blockquote > p').querySelectorAll('br').length === 1 && !!document.querySelector('blockquote blockquote p br')", "Quoted lines and nested quotes must break")
        try await check("[...document.querySelectorAll('#document > p')].find(p=>p.textContent.startsWith('Ordinary paragraph')).querySelectorAll('br').length === 0", "Ordinary paragraph soft breaks must remain unchanged")
        try await check("!document.querySelector('hr + hr')", "Consecutive separators must collapse")
        try await check("document.querySelectorAll('.footnote-item').length === 1 && document.querySelector('#document').textContent.split('FOOTNOTE_UNIQUE').length === 2", "Footnotes must appear once")
        try await check("document.querySelectorAll('mjx-container').length === 6 && !document.querySelector('.math-error')", "MathJax must render all delimiters and note formulas")
        try await check("document.querySelector('pre code').textContent.includes('$not_math$') && document.querySelectorAll('input:disabled').length === 2 && !!document.querySelector('td[align=right]')", "Code, tasks and table alignment")
        try await check("!window.untrustedCodeRan && !document.querySelector('#document script') && !document.querySelector('[onerror]')", "Inert document HTML")
        try await check("(() => { const r=document.createRange();r.selectNodeContents(document.querySelector('#document'));getSelection().removeAllRanges();getSelection().addRange(r);return preview.selectedText().includes('$$\\\\operatorname') })()", "Selection must preserve original TeX delimiters")
        _ = try await js("getSelection().removeAllRanges();document.querySelector('a[href=\"./notes.md#L7\"]').click()")
        try await Task.sleep(for: .milliseconds(100))
        try expect(opened.last == "file:./notes.md#L7", "Local links must return to the preview router")
        try await snapshot("synthetic")
        var compatibilityErrors: [String] = []
        // Each new document gets a fresh input jax: a preceding formula must not
        // hide a missing extension trigger by loading that package first.
        for sample in MathCompatibility.samples {
            try await render("$$" + sample.latex + "$$")
            if host!.formulaCount != 1 || host!.formulaErrors != 0 {
                let errors = try await js("[...document.querySelectorAll('.math-error')].map(e => e.dataset.mathError)")
                compatibilityErrors.append(sample.name + ": " + errors)
            } else if let canonical = sample.canonical {
                let equivalent = try await asyncJSON("""
                    const normalize = mml => {
                        const tree = new DOMParser().parseFromString(mml, 'application/xml');
                        // MathJax preserves original TeX for copying. Compare
                        // mathematical structure without that source metadata.
                        for (const node of tree.querySelectorAll('*')) {
                            node.removeAttribute('data-latex'); node.removeAttribute('data-latex-item');
                        }
                        return new XMLSerializer().serializeToString(tree);
                    };
                    const actual = normalize(await MathJax.tex2mmlPromise(latex, {display:true}));
                    const expected = normalize(await MathJax.tex2mmlPromise(canonical, {display:true}));
                    return JSON.stringify({equivalent:actual === expected, actual, expected});
                    """, arguments: ["latex": sample.latex, "canonical": canonical])
                struct Equivalence: Decodable { let equivalent: Bool }
                let decoded = try JSONDecoder().decode(Equivalence.self, from: Data(equivalent.utf8))
                try expect(decoded.equivalent,
                           "Notation changed meaning: \(sample.name): \(equivalent)")
            }
        }
        print("Notation compatibility: \(MathCompatibility.samples.count) samples; errors: \(compatibilityErrors)"); fflush(nil)
        try expect(compatibilityErrors.isEmpty, "Common notation failed: \(compatibilityErrors)")
        try await render(MathCompatibility.samples.prefix(10).map { "$$" + $0.latex + "$$" }.joined(separator: "\n\n"))
        try expect(host!.formulaErrors == 0, "Common notation failed in a mixed document")
        try await snapshot("quantum-notation")
        try await render(#"$\renewcommand{\ii}{j}\ii$"#)
        try expect(host!.formulaErrors == 0, "A document cannot override the imaginary-unit default")
        try await render(#"$\ii$"#)
        try await check("document.querySelector('mjx-container').textContent === 'i' && !document.querySelector('.math-error')", "The imaginary-unit default was lost on document reuse")
        try await render("| Text | Value |\n| --- | --- |\n| " + String(repeating: "Long prose should wrap at a readable width. ", count: 30) + " | 1 |")
        // Auto table layout may distribute extra viewport space beyond the
        // preferred cell width, but must not grow to the full prose width.
        try await check("document.querySelector('td').clientWidth <= Math.max(36*parseFloat(getComputedStyle(document.documentElement).fontSize)+25,document.querySelector('.table-scroll').clientWidth) && document.querySelector('td').clientHeight > 40", "Very long table prose must still wrap at a bounded width")
        func imageFixture(_ name: String, type: String, width: Int = 128, height: Int = 96, orientation: Int = 1, frames: Int = 1) throws -> URL {
            let file = output.appendingPathComponent(name)
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = context.makeImage()!
            let destination = CGImageDestinationCreateWithURL(file as CFURL, type as CFString, frames, nil)!
            for _ in 0..<frames { CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary) }
            try expect(CGImageDestinationFinalize(destination), "Image fixture must encode")
            return file
        }
        let imageFiles = try [
            imageFixture("small.jpg", type: "public.jpeg"),
            imageFixture("rotated.jpg", type: "public.jpeg", orientation: 6),
            imageFixture("large.png", type: "public.png", width: 4096, height: 1024),
            imageFixture("animated.gif", type: "com.compuserve.gif", frames: 2),
        ]
        try await render(imageFiles.map { "![fixture](" + $0.lastPathComponent + ")" }.joined(separator: "\n\n"))
        let imagesJSON = try await asyncJSON("""
            return JSON.stringify(await Promise.all([...document.querySelectorAll('img')].map(async image => {
                image.loading = 'eager'; await image.decode();
                const response = await fetch(image.src);
                return {width:image.naturalWidth, height:image.naturalHeight,
                        mime:response.headers.get('Content-Type'), bytes:(await response.arrayBuffer()).byteLength};
            })));
            """)
        struct LoadedImage: Decodable { let width: Int, height: Int, bytes: Int; let mime: String }
        let images = try JSONDecoder().decode([LoadedImage].self, from: Data(imagesJSON.utf8))
        try expect(images.count == 4)
        let jpegBytes = try Data(contentsOf: imageFiles[0]).count
        try expect(images[0].mime == "image/jpeg" && images[0].bytes == jpegBytes, "Small JPEG must bypass native re-encoding")
        try expect(images[1].mime == "image/png" && images[1].width == 96 && images[1].height == 128, "Rotated image must preserve orientation")
        try expect(images[2].width == 2048 && images[2].height == 512, "Large inline image must retain its decode bound")
        try expect(images[3].mime == "image/png" && images[3].width == 128, "Animated inline image must remain a static first frame")
        _ = try await js("window.firstOutputJax=MathJax.startup.output;true")
        try await render(#"$\newcommand{\localmacro}{x}\localmacro$"#)
        try expect(host!.formulaErrors == 0)
        try await render(#"$\localmacro$"#)
        try expect(host!.formulaErrors == 1, "Macros must not leak between documents")

        struct Formula: Decodable { var id: String; var latex: String; var valid: Bool }
        let corpus = try JSONDecoder().decode([Formula].self, from: Data(contentsOf: output.appendingPathComponent("corpus.json")))
        let valid = corpus.filter(\.valid)
        try await render(valid.map { "## " + $0.id + "\n\n$$\n" + $0.latex + "\n$$\n" }.joined(separator: "\n"))
        let failed = try await js("[...document.querySelectorAll('.math-error')].map(e => [e.dataset.latex,e.dataset.mathError])")
        print("Compatibility corpus: \(host!.formulaCount) formulas; errors: \(failed)"); fflush(nil)
        try expect(host!.formulaCount == valid.count && host!.formulaErrors == 0, "Valid TeX compatibility corpus")

        try await render(#"$$\ce{H2O} + \dv{f}{x} + A\xleftrightarrow{}B$$"#)
        try expect(host!.formulaErrors == 0, "Loaded extensions must survive document reuse")
        try await render(#"$$\require{bbm}\require{bboldx}\require{dsfont}\mathbbm{R}+\mathbb{Q}+\mathds{N}$$"#)
        try expect(host!.formulaErrors == 0, "Explicit font extensions must load offline")

        let invalid = corpus.filter { !$0.valid }
        try await render(invalid.map { "$$\n" + $0.latex + "\n$$\n" }.joined(separator: "\n"))
        try expect(host!.formulaErrors == invalid.count, "Malformed formulas must retain their source")
        try await check("[...document.querySelectorAll('.math-error')].every(e=>e.textContent===e.dataset.source)", "Fallback must preserve the complete original input")
        try await render(#"""
        Inline $\unknownMacro{x}$ and display:

        $$\unknownMacro{y}$$
        """#)
        try expect(host!.formulaErrors == 2, "Inline/display unsupported notation did not use the fallback")
        try await check("[...document.querySelectorAll('.math-error')].every(e=>getComputedStyle(e).fontFamily===getComputedStyle(e.parentElement).fontFamily && !e.closest('code,pre'))", "Unsupported formulas must use the surrounding prose font")

        if args.count > 3 {
            let paperURL = URL(fileURLWithPath: args[3])
            let paper = try String(contentsOf: paperURL, encoding: .utf8)
            let started = ProcessInfo.processInfo.systemUptime
            try await render(paper, url: paperURL)
            let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
            print("Paper: \(paper.utf8.count) bytes, \(host!.formulaCount) formulas, \(host!.formulaErrors) errors; JS \(host!.renderMilliseconds) ms, observed \(elapsed) ms"); fflush(nil)
            try expect(host!.formulaErrors == 0)
            try await check("document.querySelector('h1').textContent === 'Attention Is All You Need' && document.querySelectorAll('.footnote-item').length === 4", "Paper headings and four footnotes")
            try await check("document.querySelector('table').rows.length === 9 && document.querySelectorAll('img').length === 5", "Paper authors and figures")
            try await check("[...document.querySelectorAll('img')].every(i=>i.width>0 && i.height>0 && i.src.startsWith('omp-preview://image/'))", "Local image metadata and routing")
            try await check("document.querySelector('#document').textContent.split('To illustrate why the dot products get large').length === 2", "Paper footnote duplication")
            try await check("document.querySelector('blockquote > p').querySelectorAll('br').length === 2 && !document.querySelector('hr + hr')", "Paper quote lines and footnote separator")
            try await snapshot("paper-top")
            _ = try await js("document.querySelector('blockquote').scrollIntoView()")
            try await snapshot("paper-quote")
            _ = try await js("[...document.querySelectorAll('td')].find(c=>c.textContent.includes('positional embedding instead of sinusoids')).scrollIntoView({block:'center'})")
            try await check("(() => {const c=[...document.querySelectorAll('td')].find(c=>c.textContent.includes('positional embedding instead of sinusoids'));return c.clientWidth>240 && c.clientHeight<80 && c.closest('.table-scroll').scrollWidth>c.closest('.table-scroll').clientWidth})()", "Long table cell must use available horizontal space")
            try await snapshot("paper-table")
            _ = try await js("document.getElementById('321-scaled-dot-product-attention').scrollIntoView()")
            try await Task.sleep(for: .milliseconds(250))
            try await snapshot("paper-math")
            // Force each lazy figure into view and wait for actual decoded pixels.
            for i in 0..<5 {
                _ = try await js("document.querySelectorAll('img')[\(i)].scrollIntoView()")
                for _ in 0..<100 {
                    if try await js("document.querySelectorAll('img')[\(i)]?.naturalWidth > 0") == "true" { break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                try await check("document.querySelectorAll('img')[\(i)]?.naturalWidth > 0", "Figure \(i) must decode")
                if i == 1 { try await snapshot("paper-figure") }
            }
            // These source PNGs are already below the decode bound; the native
            // handler must send their original compressed bytes unchanged.
            let files = try FileManager.default.contentsOfDirectory(at: paperURL.deletingLastPathComponent().appendingPathComponent("images"), includingPropertiesForKeys: nil)
            let originalSizes = try files.filter { $0.pathExtension == "png" }.map { try Data(contentsOf: $0).count }.sorted()
            let sizesJSON = try await asyncJSON("return JSON.stringify(await Promise.all([...document.querySelectorAll('img')].map(async i=>(await (await fetch(i.src)).arrayBuffer()).byteLength)))")
            let receivedSizes = try JSONDecoder().decode([Int].self, from: Data(sizesJSON.utf8))
            try expect(receivedSizes.sorted() == originalSizes, "Small paper figures must bypass native re-encoding")
            let savedToken = host!.renderedToken
            window.setContentSize(NSSize(width: 340, height: 900)); host!.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            try expect(host!.renderedToken == savedToken, "Resize must not reparse Markdown or TeX")
            try await check("document.documentElement.scrollWidth <= innerWidth + 1", "Narrow document must not overflow horizontally")
            host!.appearance = NSAppearance(named: .darkAqua)
            try await Task.sleep(for: .milliseconds(100))
            _ = try await js("document.getElementById('321-scaled-dot-product-attention').scrollIntoView()")
            try await Task.sleep(for: .milliseconds(100))
            try await snapshot("paper-narrow-dark")
            _ = try await js("window.scrollTo(0,2500);preview.position()")
            try await Task.sleep(for: .milliseconds(120))
            try expect(state.document.y > 2400)
            try await render(paper, url: paperURL, freshState: false)
            try await check("Math.abs(scrollY-2500)<5", "Reading position must survive revision refresh")
            _ = try await js("window.scrollTo(0,2700)")
            let paperState = state
            try await render("# Another document", url: fixtureURL)
            try expect(abs(paperState.document.y - 2700) < 5, "Immediate tab switch must capture the outgoing position")
            state = paperState
            try await render(paper, url: paperURL, freshState: false)
            try await check("Math.abs(scrollY-2700)<5", "Switching back must restore the document position")
            let config = WKFindConfiguration()
            let found = await withCheckedContinuation { continuation in
                host!.web.find("self-attention", configuration: config) { continuation.resume(returning: $0.matchFound) }
            }
            try expect(found, "Native WebKit find must search the paper")
        }
        try await render(String(repeating: "$x^2$ ", count: 180))
        try expect(host!.formulaCount == 180 && host!.formulaErrors == 0, "No 128-formula cutoff")
        try await check("document.querySelectorAll('mjx-container').length === 180", "All formulas must have layout")
        // A superseded document must never replace the latest requested source.
        host!.update(url: fixtureURL, source: String(repeating: "$x^2$ ", count: 300), revision: "stale", state: state, findRequest: 0) { _, _ in }
        try await render("# Latest revision")
        try await check("document.querySelector('h1').textContent === 'Latest revision' && !document.querySelector('mjx-container')", "Latest revision wins")
        try await check("MathJax.startup.output === firstOutputJax", "Document switches must reuse the output jax and font metrics")
        try await check("blockedNetworkRequests.length === 0", "Bundled libraries must never try to fetch network resources")
        try expect(host!.resources.servedPaths.contains { $0.hasSuffix(".woff2") }, "Math fonts must load from the offline bundle")
        print("Failed resources:", host!.resources.failedPaths); fflush(nil)
        try expect(host!.resources.failedPaths.isEmpty, "All dynamically requested MathJax resources must be bundled")
        weak let released = host
        host!.tearDown(); window.contentView = nil; host = nil
        try await Task.sleep(for: .milliseconds(100))
        try expect(released == nil, "Host must release after teardown")
        print("Markdown document checks passed"); fflush(nil)
    }
}
