import AppKit
import SwiftUI

/// Shared with source previews and expanded tool output. Only foreground colors
/// change, so coloring code never changes its metrics, selection or copied text.
@MainActor
enum CodeSyntaxStyle {
    private struct Ink {
        let native: NSColor
        let text: Color

        init(light: UInt32, dark: UInt32) {
            let lightColor = NSColor(srgbRed: CGFloat((light >> 16) & 255) / 255,
                green: CGFloat((light >> 8) & 255) / 255, blue: CGFloat(light & 255) / 255, alpha: 1)
            let darkColor = NSColor(srgbRed: CGFloat((dark >> 16) & 255) / 255,
                green: CGFloat((dark >> 8) & 255) / 255, blue: CGFloat(dark & 255) / 255, alpha: 1)
            native = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
            }
            text = Color(nsColor: native)
        }
    }

    private struct Inks {
        let foreground, comment, string, keyword, number, type, attribute: Ink

        init(theme: CodeHighlightTheme) {
            let light = theme.palette(dark: false), dark = theme.palette(dark: true)
            foreground = Ink(light: light.foreground, dark: dark.foreground)
            comment = Ink(light: light.comment, dark: dark.comment)
            string = Ink(light: light.string, dark: dark.string)
            keyword = Ink(light: light.keyword, dark: dark.keyword)
            number = Ink(light: light.number, dark: dark.number)
            type = Ink(light: light.type, dark: dark.type)
            attribute = Ink(light: light.attribute, dark: dark.attribute)
        }

        func ink(for token: PreviewSyntaxHighlighter.Token) -> Ink {
            switch token {
            case .comment: comment
            case .string: string
            case .keyword: keyword
            case .number: number
            case .type: type
            case .attribute: attribute
            }
        }
    }

    // Allocate native/dynamic colors once per selected theme, never per token.
    private static var palettes: [CodeHighlightTheme: Inks] = [:]

    private static func inks(for theme: CodeHighlightTheme) -> Inks {
        if let cached = palettes[theme] { return cached }
        let inks = Inks(theme: theme)
        palettes[theme] = inks
        return inks
    }

    static func color(for token: PreviewSyntaxHighlighter.Token,
                      theme: CodeHighlightTheme = CodeHighlighting.shared.theme) -> NSColor {
        inks(for: theme).ink(for: token).native
    }

    static func foregroundColor(theme: CodeHighlightTheme = CodeHighlighting.shared.theme) -> NSColor {
        inks(for: theme).foreground.native
    }

    static func attributedString(source: String, spans: [PreviewSyntaxHighlighter.Span],
                                 theme: CodeHighlightTheme = CodeHighlighting.shared.theme) -> AttributedString {
        var text = AttributedString(source)
        let inks = inks(for: theme)
        text.foregroundColor = inks.foreground.text
        let length = (source as NSString).length
        for span in spans where span.range.location != NSNotFound
            && span.range.location >= 0 && span.range.length > 0
            && span.range.location <= length && span.range.length <= length - span.range.location {
            guard let characters = Range(span.range, in: source), let range = Range(characters, in: text) else { continue }
            // AppKit-only colors do not survive as SwiftUI Text attributes.
            text[range].foregroundColor = inks.ink(for: span.token).text
        }
        return text
    }
}
