import SwiftUI

extension Font {
    /// Conversation text at the Content size. Stock Content keeps the macOS point
    /// size for the style, so the stock setting leaves today's type alone.
    @MainActor static func chat(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        typeScaled(size: TypeScale.shared.content(TypeScale.stockPointSize(style)), style: style, weight: weight, design: design)
    }

    @MainActor static func chat(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        AppFont.swiftUI(size: TypeScale.shared.content(size), weight: weight, design: design)
    }

    /// Code defaults to monospaced. A callout matches the configured Code size;
    /// other styles and raw stock sizes retain their relative point offsets.
    @MainActor static func code(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .monospaced) -> Font {
        typeScaled(size: TypeScale.shared.code(TypeScale.stockPointSize(style)), style: style, weight: weight, design: design)
    }

    @MainActor static func code(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .monospaced) -> Font {
        AppFont.swiftUI(size: TypeScale.shared.code(size), weight: weight, design: design)
    }
}
