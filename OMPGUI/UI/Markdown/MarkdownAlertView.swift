import SwiftUI

struct MarkdownAlertView: View {
    let kind: MarkdownAlertKind
    let blocks: [MarkdownBlock]

    var body: some View {
        ChromeCard {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: MarkdownParagraphLayout.containedBlockSpacing) {
                    Label {
                        Text(verbatim: Chrome.localized(kind.title))
                    } icon: {
                        Image(systemName: symbol)
                    }
                    .font(.chat(.subheadline, weight: .semibold))
                    .foregroundStyle(color)
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        MarkdownBlockView(block: block).equatable()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
    }

    private var color: Color {
        switch kind {
        case .note, .important: Chrome.accent
        case .tip: Chrome.success
        case .warning: Chrome.warning
        case .caution: Chrome.danger
        }
    }

    private var symbol: String {
        switch kind {
        case .note: "info.circle"
        case .tip: "lightbulb"
        case .important: "exclamationmark.circle"
        case .warning: "exclamationmark.triangle"
        case .caution: "exclamationmark.square"
        }
    }
}
