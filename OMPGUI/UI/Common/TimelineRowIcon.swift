import SwiftUI

enum TimelineIconMetrics {
    static let size: CGFloat = 16
    static let pointSize: CGFloat = 12
}

/// Literal names refer to system symbols; exported SF Symbol assets are explicit.
enum SFSymbolResource: Hashable, ExpressibleByStringLiteral {
    case system(String)
    case custom(String)

    init(stringLiteral value: String) { self = .system(value) }

    var image: Image {
        switch self {
        case .system(let name): Image(systemName: name)
        case .custom(let name): Image(name).renderingMode(.template)
        }
    }
}

/// Shared native sizing for tool, thinking, notice and plan content glyphs.
struct TimelineSymbolIcon: View {
    let symbol: SFSymbolResource

    init(_ symbol: SFSymbolResource) { self.symbol = symbol }
    init(_ systemName: String) { symbol = .system(systemName) }

    var body: some View {
        symbol.image
            .font(.system(size: TypeScale.shared.content(TimelineIconMetrics.pointSize)))
            .symbolRenderingMode(.monochrome)
            .frame(width: TimelineIconMetrics.size, height: TimelineIconMetrics.size)
    }
}

/// Leading content glyphs for notice and plan rows, sharing the tool-row style.
/// Disclosure arrows, controls and status overlays keep their existing symbols.
enum TimelineRowIcon: String, CaseIterable, View {
    case information = "info.circle"
    case warning = "exclamationmark.triangle"
    case error = "exclamationmark.square"
    case plan = "list.bullet.clipboard"

    init(noticeLevel: Notice.Level) {
        self = switch noticeLevel {
        case .info: .information
        case .warning: .warning
        case .error: .error
        }
    }

    var body: some View {
        TimelineSymbolIcon(rawValue)
            .accessibilityLabel(Text(verbatim: Chrome.localized(accessibilityTitle)))
    }

    private var accessibilityTitle: String {
        switch self {
        case .information: "Information"
        case .warning: "Warning"
        case .error: "Error"
        case .plan: "Plan"
        }
    }
}
