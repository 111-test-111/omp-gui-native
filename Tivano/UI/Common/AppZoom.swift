import SwiftUI

/// The app-wide zoom: the window's content is laid out in the space the window has divided
/// by the scale, then drawn back up, so a bigger zoom shows less at once instead of clipping.
enum AppZoom {
    static let levels = [75, 90, 100, 110, 125, 150, 175, 200]

    static func normalized(_ percent: Int) -> Int {
        levels.contains(percent) ? percent : 100
    }

    static func next(_ percent: Int, increasing: Bool) -> Int {
        let current = normalized(percent)
        return increasing ? (levels.first { $0 > current } ?? current) : (levels.last { $0 < current } ?? current)
    }
}

struct AppZoomModifier: ViewModifier {
    let percent: Int

    func body(content: Content) -> some View {
        let scale = CGFloat(AppZoom.normalized(percent)) / 100
        ZoomLayout(scale: scale) {
            content.scaleEffect(scale, anchor: .topLeading)
        }
    }
}

/// Proposes the unscaled viewport so forms reflow and keep their scrollbars inside the
/// window; a bare `scaleEffect` would clip the enlarged content.
private struct ZoomLayout: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(unscaled(proposal))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: unscaled(ProposedViewSize(bounds.size))
        )
    }

    private func unscaled(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width.map { $0 / scale }, height: proposal.height.map { $0 / scale })
    }
}
