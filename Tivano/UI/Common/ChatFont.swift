import SwiftUI

extension Font {
    /// A text style in the conversation's own weight, so the chat reads as the app's type
    /// and not a second scale. The app-wide zoom scales the window, not the type.
    static func chat(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        let resolvedWeight = weight ?? (style == .headline ? .semibold : nil)
        let font = Font.system(style, design: design)
        return resolvedWeight.map { font.weight($0) } ?? font
    }
}
