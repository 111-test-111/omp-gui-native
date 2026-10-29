import Foundation
import SwiftUI

private enum TokenActivityStyle {
    /// Gap between cells, both axes.
    static let cellGap: CGFloat = 4
    static let cellRadius: CGFloat = 2
    /// Height of the month label strip.
    static let labelHeight: CGFloat = 18
    /// Narrowest a month label may squeeze before its neighbors hide it.
    static let minLabelAdvance: CGFloat = 30

    /// Five-step intensity ladder: empty, then four steps of the theme's
    /// accent (the system accent for System/Light/Dark), so the grid wears
    /// whatever the rest of the window wears. A day still to come is fainter
    /// than a quiet one, so the year keeps its shape without reading as data.
    static func color(for value: Int, maxValue: Int, future: Bool) -> Color {
        if future { return Chrome.overlay(0.035) }
        guard value > 0, maxValue > 0 else { return Chrome.overlay(0.07) }
        let accent = Chrome.accent
        let fraction = Double(value) / Double(maxValue)
        switch fraction {
        case ..<0.25: return accent.opacity(0.32)
        case ..<0.5: return accent.opacity(0.55)
        case ..<0.75: return accent.opacity(0.8)
        default: return accent
        }
    }
}

/// Annual activity stays independent of the dashboard's shorter date range.
struct TokenActivitySection: View {
    let dailyTotals: [String: Int]
    let yearTotal: Int
    var presentationID: UInt64 = 0
    var isActive = true
    @State private var mode: TokenActivityMode = .daily
    @State private var hoveredDate: Date?
    @State private var grid = TokenActivityGrid.build(daily: [:], mode: .daily)

    private struct GridKey: Equatable {
        var daily: [String: Int]
        var mode: TokenActivityMode
    }

    private struct RevealKey: Equatable {
        let presentation: UInt64
        let mode: TokenActivityMode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            UsageSectionHeader(title: "Token activity") { modePicker }

            heatmap(grid: grid)
            monthStrip(grid: grid)
            legend
        }
        .onChange(of: GridKey(daily: dailyTotals, mode: mode), initial: true) { _, key in
            grid = TokenActivityGrid.build(daily: key.daily, mode: key.mode)
        }
    }

    private var modePicker: some View {
        Picker("Activity grouping", selection: $mode) {
            ForEach(TokenActivityMode.allCases, id: \.self) { option in
                Text(verbatim: Chrome.localized(option.title)).tag(option)
            }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .help(Text(verbatim: Chrome.localized(Self.modeHelp(mode))))
    }

    /// Equal-width week columns of square cells. Each column takes an equal
    /// share of the width and each cell squares off to its column, so the grid
    /// fills any Settings width without clipping or scrolling. One canvas draws
    /// every cell: as a stack of some 360 shape views this was the heaviest
    /// layout in Settings, felt each time General opened.
    private func heatmap(grid: TokenActivityGrid) -> some View {
        HeatmapCanvas(grid: grid, hoveredDate: $hoveredDate)
            .usageReveal(trigger: RevealKey(presentation: presentationID, mode: mode), active: isActive,
                         style: .sweep, delay: 0.1)
            .accessibilityHidden(true)
    }

    /// Month names pinned to the column holding each month's first day.
    /// Labels that would land closer than a readable advance are dropped,
    /// so a narrow window shows fewer months instead of overlapping them.
    private func monthStrip(grid: TokenActivityGrid) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(height: TokenActivityStyle.labelHeight)
            GeometryReader { proxy in
                let columnCount = max(grid.columns.count, 1)
                let stride = (proxy.size.width + TokenActivityStyle.cellGap) / CGFloat(columnCount)
                let placed = placedTicks(grid.monthTicks, stride: stride)
                ForEach(placed.indices, id: \.self) { index in
                    Text(verbatim: placed[index].label)
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                        .fixedSize()
                        .position(
                            x: min(
                                max(CGFloat(placed[index].column) * stride, 12),
                                proxy.size.width - 12
                            ),
                            y: TokenActivityStyle.labelHeight / 2
                        )
                }
            }
        }
    }

    private var legend: some View {
        let date = hoveredDate
        let value = date.map { dailyTotals[UsageCalendar.dayKey($0)] ?? 0 } ?? yearTotal
        let period = date?.formatted(date: .abbreviated, time: .omitted) ?? Date.now.formatted(.dateTime.year())
        let summary = String(format: Chrome.localized("%@ · %@ tokens"), period, value.formatted())
        return HStack(spacing: 8) {
            Text(verbatim: summary)
                .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText).lineLimit(1)
            Spacer(minLength: 12)
            Text("Less").font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
            ForEach(Array(Self.ladder.enumerated()), id: \.offset) { _, step in
                RoundedRectangle(cornerRadius: TokenActivityStyle.cellRadius, style: .continuous)
                    .fill(step).frame(width: 10, height: 10)
            }
            Text("More").font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Token activity"))
        .accessibilityValue(Text(verbatim: summary))
    }

    /// The five steps `TokenActivityStyle.color(for:maxValue:future:)` paints, as a ladder.
    private static var ladder: [Color] {
        [0, 1, 3, 5, 7].map { TokenActivityStyle.color(for: $0, maxValue: 8, future: false) }
    }

    private static func modeHelp(_ mode: TokenActivityMode) -> String {
        switch mode {
        case .daily: "Each day on its own, against the busiest day of the year"
        case .weekly: "Each week as one shade, against the busiest week"
        case .cumulative: "The running total, so the year fills as it goes"
        }
    }

    private func placedTicks(_ ticks: [(label: String, column: Int)], stride: CGFloat) -> [(label: String, column: Int)] {
        var placed: [(label: String, column: Int)] = []
        var lastX = -TokenActivityStyle.minLabelAdvance
        for tick in ticks {
            let x = CGFloat(tick.column) * stride
            guard x - lastX >= TokenActivityStyle.minLabelAdvance else { continue }
            placed.append(tick)
            lastX = x
        }
        return placed
    }
}

/// One bounded drawing pass; no per-cell views or continuous animation.
private struct HeatmapCanvas: View {
    let grid: TokenActivityGrid
    @Binding var hoveredDate: Date?
    @State private var width: CGFloat = 0

    var body: some View {
        let columns = CGFloat(max(grid.columns.count, 1))
        let gap = TokenActivityStyle.cellGap
        let cell = max(0, (width - gap * (columns - 1)) / columns)
        Canvas { context, size in
            let cellWidth = max(0, (size.width - gap * (columns - 1)) / columns)
            let pitch = cellWidth + gap
            for c in grid.columns.indices {
                for r in 0..<TokenActivityGrid.rows {
                    guard let date = grid.columns[c][r] else { continue }
                    let color = TokenActivityStyle.color(for: grid.values[c][r], maxValue: grid.maxValue, future: date >= grid.tomorrow)
                    let rect = CGRect(x: CGFloat(c) * pitch, y: CGFloat(r) * pitch, width: cellWidth, height: cellWidth)
                    context.fill(Path(roundedRect: rect, cornerRadius: TokenActivityStyle.cellRadius), with: .color(color))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: max(1, cell * CGFloat(TokenActivityGrid.rows) + gap * CGFloat(TokenActivityGrid.rows - 1)))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let pitch = cell + gap
                let c = Int(location.x / max(1, pitch))
                let r = Int(location.y / max(1, pitch))
                if grid.columns.indices.contains(c), (0..<TokenActivityGrid.rows).contains(r),
                   let date = grid.columns[c][r], date < grid.tomorrow {
                    hoveredDate = date
                } else { hoveredDate = nil }
            case .ended: hoveredDate = nil
            }
        }
    }
}
