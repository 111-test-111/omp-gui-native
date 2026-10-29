import SwiftUI

/// One retained overview serves both sidebar drill-down and fullscreen columns.
/// The session owns the fraction so unmounting a tab cannot reset its divider.
struct WorkspaceDetailColumns<Overview: View, Detail: View>: View {
    let isFullscreen: Bool
    let hasDetail: Bool
    @Binding var fraction: CGFloat
    var minimumSplitWidth: CGFloat = 0
    var minimumOverviewWidth: CGFloat = 240
    var minimumDetailWidth: CGFloat = 240
    @ViewBuilder let overview: (CGFloat) -> Overview
    @ViewBuilder let detail: () -> Detail
    @State private var dragOrigin: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let isSplit = isFullscreen && hasDetail && geometry.size.width >= minimumSplitWidth
            let showsOverview = isSplit || !hasDetail
            let available = max(0, geometry.size.width - 1)
            let leading = leadingWidth(available, fraction: fraction)
            ZStack(alignment: .topLeading) {
                overview(isSplit ? leading : geometry.size.width)
                    .frame(width: isSplit ? leading : geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .opacity(showsOverview ? 1 : 0)
                    .disabled(!showsOverview)
                    .allowsHitTesting(showsOverview)
                    .accessibilityHidden(!showsOverview)
                detail()
                    .frame(width: isSplit ? available - leading : geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .offset(x: isSplit ? leading + 1 : 0)
                    .opacity(hasDetail ? 1 : 0)
                    .disabled(!hasDetail)
                    .allowsHitTesting(hasDetail)
                    .accessibilityHidden(!hasDetail)
                if isSplit {
                    Rectangle().fill(Chrome.overlay(0.12))
                        .frame(width: 1, height: geometry.size.height).offset(x: leading)
                        .accessibilityHidden(true)
                    DragHandle(axis: .horizontal,
                               grip: .init(restLength: 10, shownLength: 22, thickness: 2.5, refreshesHoverOnLayout: true),
                               cursor: .columnResize,
                               onBegin: { dragOrigin = leading },
                               onChange: { delta in
                                   guard available > 0 else { return }
                                   let proposed = ((dragOrigin ?? leading) + delta.width) / available
                                   fraction = leadingWidth(available, fraction: proposed) / available
                               },
                               onEnd: { dragOrigin = nil })
                        .frame(width: 9, height: geometry.size.height)
                        .offset(x: leading - 4)
                        .accessibilityLabel(Text("Resize detail columns"))
                        .accessibilityValue(Text(leading / max(1, available), format: .percent.precision(.fractionLength(0))))
                        .accessibilityAdjustableAction { direction in
                            guard available > 0 else { return }
                            let delta: CGFloat = direction == .increment ? 0.05 : -0.05
                            fraction = leadingWidth(available, fraction: fraction + delta) / available
                        }
                        .accessibilityIdentifier("workspace.detail-divider")
                }
            }
            .animation(nil, value: isSplit)
            .onChange(of: isSplit) { dragOrigin = nil }
        }
    }

    private func leadingWidth(_ available: CGFloat, fraction: CGFloat) -> CGFloat {
        let leadingMinimum = min(minimumOverviewWidth, available / 2)
        let trailingMinimum = min(minimumDetailWidth, available / 2)
        return min(max(leadingMinimum, available * fraction), available - trailingMinimum)
    }
}
