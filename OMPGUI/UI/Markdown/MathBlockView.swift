import AppKit
import SwiftUI

struct MathBlockView: View {
    let formula: MarkdownFormula
    @Environment(\.markdownPointSize) private var pointSize
    @Environment(\.markdownDimmed) private var dimmed

    var body: some View {
        let size = pointSize == 0 ? TypeScale.shared.content(13) : pointSize
        Group {
            if formula.complete {
                MathBlockRepresentable(formula: formula, pointSize: size, dimmed: dimmed)
                    .padding(.vertical, 4)
            } else {
                fallback
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Copy LaTeX") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(formula.latex, forType: .string)
            }
        }
    }

    private var fallback: some View {
        Text(verbatim: formula.source)
            .font(AppFont.swiftUI(size: pointSize == 0 ? TypeScale.shared.content(13) : pointSize))
            .lineSpacing(MarkdownParagraphLayout.lineSpacing)
            .foregroundStyle(dimmed ? Chrome.secondaryText : Chrome.primaryText)
            .modifier(MarkdownBlockSelection())
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MathBlockRepresentable: NSViewRepresentable {
    let formula: MarkdownFormula
    let pointSize: CGFloat
    let dimmed: Bool
    final class Coordinator {
        var formula: MarkdownFormula?
        var pointSize: CGFloat = 0
        var dimmed = false
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MathParagraphHost { MathParagraphHost() }
    func updateNSView(_ view: MathParagraphHost, context: Context) {
        view.paragraph.mathPreparation = context.environment.markdownVeiled ? nil : context.environment.chatMathPreparation
        let previous = context.coordinator
        guard previous.formula != formula || previous.pointSize != pointSize || previous.dimmed != dimmed else { return }
        previous.formula = formula; previous.pointSize = pointSize; previous.dimmed = dimmed
        let text = NSMutableAttributedString(attributedString: MathRendering.attributed(formula, pointSize: pointSize, color: dimmed ? .secondaryLabelColor : .labelColor))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        view.paragraph.render(text)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MathParagraphHost, context: Context) -> CGSize? {
        let natural = nsView.paragraph.textStorage.map { MathRendering.formulaWidth(in: $0) } ?? 0
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? natural
        return nsView.measure(width: width, contentWidth: max(width, natural))
    }
    static func dismantleNSView(_ view: MathParagraphHost, coordinator: Coordinator) {
        MathRendering.detach(from: view.paragraph)
    }
}
