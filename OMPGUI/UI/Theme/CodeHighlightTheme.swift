import Foundation
import Observation

/// Syntax-color families shared by native code rendering and the Markdown preview.
///
/// Colors are the upstream palettes, not approximations:
/// - GitHub: `primer/github-vscode-theme` 6.3.5 (`src/theme.js`) over
///   `@primer/primitives` 7.10.0 `prettylights.syntax`; the theme's `fg.default`
///   overrides give `#1f2328` light and `#e6edf3` dark.
///   https://github.com/primer/github-vscode-theme/tree/cd78e5e4e7bcf132a6f428ae0f32264bb1b729cf
/// - Atom One: `atom/one-light-syntax` (`d845790`) and `atom/one-dark-syntax`
///   (`9c96f44`), `styles/colors.less` and `styles/syntax/_base.less`.
///   https://github.com/atom/one-light-syntax/tree/d84579027410c576086dfca14d934c4bd74b0438
///   https://github.com/atom/one-dark-syntax/tree/9c96f4454362267ac45322063e193ccf9d2debb1
/// - Solarized: `altercation/solarized` (`62f656a`), README palette and
///   `vim-colors-solarized`. Decorators follow the official IntelliJ port's
///   `PY.DECORATOR` blue.
///   https://github.com/altercation/solarized/tree/62f656a02f93c5190a8753159e34b385588d5ff3
/// - Catppuccin: `catppuccin/palette` 1.8.0 and `catppuccin/vscode` 3.19.0
///   `tokenColors` (`text`, `overlay2`, `green`, `mauve`, `peach`, `yellow`).
///   https://github.com/catppuccin/palette/tree/07d02aa110ef9eb7e7427afca5c73ba9cf7f8ebd
///   https://github.com/catppuccin/vscode/tree/befc9e6fc41980f4241408f7049755d47c06ff45
///
/// `attribute` is the highlighter's `@Decorator` token, so it uses each
/// family's decorator/annotation hue rather than its HTML attribute-name hue.
enum CodeHighlightTheme: String, CaseIterable, Identifiable, Sendable {
    case github
    case atomOne
    case solarized
    case catppuccin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .github: "GitHub"
        case .atomOne: "Atom One"
        case .solarized: "Solarized"
        case .catppuccin: "Catppuccin"
        }
    }

    /// A cached value; switching themes never rebuilds a palette.
    func palette(dark: Bool) -> CodeHighlightPalette {
        switch (self, dark) {
        case (.github, false): Self.githubLight
        case (.github, true): Self.githubDark
        case (.atomOne, false): Self.atomOneLight
        case (.atomOne, true): Self.atomOneDark
        case (.solarized, false): Self.solarizedLight
        case (.solarized, true): Self.solarizedDark
        case (.catppuccin, false): Self.catppuccinLight
        case (.catppuccin, true): Self.catppuccinDark
        }
    }

    // GitHub Light Default. constant → number, entity.name → type,
    // entity.name.function (decorator) → attribute.
    private static let githubLight = CodeHighlightPalette(
        foreground: 0x1F2328, comment: 0x6E7781, string: 0x0A3069,
        keyword: 0xCF222E, number: 0x0550AE, type: 0x953800, attribute: 0x8250DF
    )

    // GitHub Dark Default, same scopes.
    private static let githubDark = CodeHighlightPalette(
        foreground: 0xE6EDF3, comment: 0x8B949E, string: 0xA5D6FF,
        keyword: 0xFF7B72, number: 0x79C0FF, type: 0xFFA657, attribute: 0xD2A8FF
    )

    // One Light: mono-1/mono-3, hue-4 string, hue-3 keyword, hue-6 constant,
    // hue-6-2 type, hue-2 decorator (entity.name.function).
    private static let atomOneLight = CodeHighlightPalette(
        foreground: 0x383A42, comment: 0xA0A1A7, string: 0x50A14F,
        keyword: 0xA626A4, number: 0x986801, type: 0xC18401, attribute: 0x4078F2
    )

    // One Dark: the same syntax variables in the dark palette.
    private static let atomOneDark = CodeHighlightPalette(
        foreground: 0xABB2BF, comment: 0x5C6370, string: 0x98C379,
        keyword: 0xC678DD, number: 0xD19A66, type: 0xE5C07B, attribute: 0x61AFEF
    )

    // Solarized Light: base00 text, base1 comments, cyan constant/string,
    // green statement, yellow type, blue decorator.
    private static let solarizedLight = CodeHighlightPalette(
        foreground: 0x657B83, comment: 0x93A1A1, string: 0x2AA198,
        keyword: 0x859900, number: 0x2AA198, type: 0xB58900, attribute: 0x268BD2
    )

    // Solarized Dark: base0 text, base01 comments; accents are shared.
    private static let solarizedDark = CodeHighlightPalette(
        foreground: 0x839496, comment: 0x586E75, string: 0x2AA198,
        keyword: 0x859900, number: 0x2AA198, type: 0xB58900, attribute: 0x268BD2
    )

    // Catppuccin Latte: text, overlay2, green, mauve, peach, yellow, peach.
    private static let catppuccinLight = CodeHighlightPalette(
        foreground: 0x4C4F69, comment: 0x7C7F93, string: 0x40A02B,
        keyword: 0x8839EF, number: 0xFE640B, type: 0xDF8E1D, attribute: 0xFE640B
    )

    // Catppuccin Mocha: the same roles from the Mocha flavor.
    private static let catppuccinDark = CodeHighlightPalette(
        foreground: 0xCDD6F4, comment: 0x9399B2, string: 0xA6E3A1,
        keyword: 0xCBA6F7, number: 0xFAB387, type: 0xF9E2AF, attribute: 0xFAB387
    )
}

/// The seven foregrounds a code block paints. Backgrounds stay transparent so
/// the glass, selection and layout are unchanged.
struct CodeHighlightPalette: Sendable {
    let foreground: UInt32
    let comment: UInt32
    let string: UInt32
    let keyword: UInt32
    let number: UInt32
    let type: UInt32
    let attribute: UInt32

    /// Built once with the palette: the static values below cache the formatted
    /// map, so applying a theme never formats or allocates colors again.
    let cssVariables: [String: String]

    init(foreground: UInt32, comment: UInt32, string: UInt32, keyword: UInt32,
         number: UInt32, type: UInt32, attribute: UInt32) {
        self.foreground = foreground
        self.comment = comment
        self.string = string
        self.keyword = keyword
        self.number = number
        self.type = type
        self.attribute = attribute
        cssVariables = [
            "code-foreground": Self.css(foreground),
            "code-comment": Self.css(comment),
            "code-string": Self.css(string),
            "code-keyword": Self.css(keyword),
            "code-number": Self.css(number),
            "code-type": Self.css(type),
            "code-attribute": Self.css(attribute),
        ]
    }

    private static func css(_ value: UInt32) -> String {
        String(format: "#%06x", value)
    }
}

/// The selected syntax family. Mirrored from `AppSettings`, which is the source
/// of truth; rendered text re-reads this through Observation.
@MainActor @Observable
final class CodeHighlighting {
    static let shared = CodeHighlighting()

    var theme: CodeHighlightTheme = .github

    private init() {}
}
