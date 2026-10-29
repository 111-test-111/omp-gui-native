import SwiftUI

/// Row-local segments keep painting proportional to the visible topology.
/// The node/curve/merge-ring presentation follows Maple; see its MIT notice.
struct GitCommitRow: View {
    static let height: CGFloat = 54
    let commit: GitBrowseCommit
    let graph: GitCommitGraph.Row
    let references: [GitHistoryReference]
    let isHead: Bool
    let graphWidth: CGFloat
    let graphOffset: CGFloat
    let isMatch: Bool
    let isSelected: Bool
    var showsDate = true
    let onSelect: () -> Void
    let onDrag: (CGFloat, Bool) -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 5) {
                Canvas { context, size in
                    for segment in graph.segments {
                        var path = Path()
                        let from = CGPoint(x: x(segment.fromLane), y: size.height * segment.fromY)
                        let to = CGPoint(x: x(segment.toLane), y: size.height * segment.toY)
                        path.move(to: from)
                        if from.x == to.x { path.addLine(to: to) }
                        else {
                            let middle = (from.y + to.y) / 2
                            path.addCurve(to: to, control1: CGPoint(x: from.x, y: middle), control2: CGPoint(x: to.x, y: middle))
                        }
                        context.stroke(path, with: .color(Self.color(segment.colorLane)), lineWidth: 1.7)
                    }
                    let center = CGPoint(x: x(graph.lane), y: size.height / 2)
                    let diameter: CGFloat = graph.isMerge ? 11 : 7
                    let node = Path(ellipseIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
                    if graph.isMerge {
                        // A hollow ring plus inner dot distinguishes a merge
                        // without painting an opaque patch over the backdrop.
                        context.stroke(node, with: .color(Self.color(graph.lane)), lineWidth: 1.8)
                        context.fill(Path(ellipseIn: CGRect(x: center.x - 1.7, y: center.y - 1.7, width: 3.4, height: 3.4)), with: .color(Self.color(graph.lane)))
                    } else { context.fill(node, with: .color(Self.color(graph.lane))) }
                }
                .frame(width: graphWidth, height: Self.height).clipped()
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 6).onChanged {
                    if abs($0.translation.width) > abs($0.translation.height) { onDrag($0.translation.width, false) }
                }.onEnded { onDrag($0.translation.width, true) })
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: String(commit.subject.prefix(512))).font(.ui(.callout)).lineLimit(1).truncationMode(.tail)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if isHead { Text(verbatim: "HEAD").foregroundStyle(Self.color(graph.lane)) }
                        if let ref = references.first {
                            Text(verbatim: ref.title).foregroundStyle(Self.color(graph.lane)).lineLimit(1).truncationMode(.middle)
                            if references.count > 1 { Text(verbatim: "+\(references.count - 1)") }
                        }
                        Text(verbatim: commit.shortID).layoutPriority(1)
                        if references.isEmpty && !isHead {
                            Text(verbatim: commit.author).lineLimit(1).truncationMode(.tail)
                        }
                        if showsDate { GitCommitTimeLabel(date: commit.date) }
                    }
                    .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .opacity(isMatch ? 1 : 0.4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 10)
            }
            .frame(height: Self.height)
            .background(Chrome.overlay(isSelected ? 0.08 : 0))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: commit.subject + "\n" + commit.id + (references.isEmpty ? "" : "\n" + references.map(\.name).joined(separator: "\n"))))
        .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("%@ · %@ · %@ · %lld parents"),
                                                  commit.subject, commit.author, commit.shortID, commit.parents.count)))
    }

    private func x(_ lane: Int) -> CGFloat { 12 + CGFloat(lane) * 14 - graphOffset }
    static func color(_ lane: Int) -> Color { [.blue, .green, .orange, .purple, .cyan, .pink][lane % 6] }
}

/// Observe the shared minute clock in the label alone, preserving the mounted
/// row and graph while keeping elapsed minutes current without second ticks.
private struct GitCommitTimeLabel: View {
    let date: Date

    var body: some View {
        Text(verbatim: RelativeTime.short(date, now: MinuteClock.shared.now)).lineLimit(1)
    }
}

struct GitGraphBoundary: View {
    let parents: [String?]
    let graphOffset: CGFloat
    let graphWidth: CGFloat
    var body: some View {
        Canvas { context, _ in
            for lane in parents.indices where parents[lane] != nil {
                let x = 12 + CGFloat(lane) * 14 - graphOffset
                var path = Path(); path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: 16))
                context.stroke(path, with: .color(GitCommitRow.color(lane)), style: StrokeStyle(lineWidth: 1.7, dash: [3, 3]))
            }
        }
        .frame(width: graphWidth, height: 16).clipped().accessibilityLabel(Text("History continues beyond this page"))
    }
}
