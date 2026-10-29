import Charts
import SwiftUI

struct UsageSettingsPage: View {
    @Environment(AppModel.self) private var model
    let store: UsageSettingsStore
    let refreshID: Int
    @State private var range: UsageRange = .month

    private struct RefreshKey: Equatable {
        let visible: Bool
        let threads: UInt64
        let usage: UInt64
        let projects: [Project]
        let range: UsageRange
        let refresh: Int
    }

    private var refreshKey: RefreshKey {
        let navigation = SettingsNavigation.shared
        return RefreshKey(visible: navigation.isPresented && navigation.page == .usage,
                          threads: model.threadsRevision, usage: model.usageRevision,
                          projects: model.projects, range: range, refresh: refreshID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            UsagePeriodHeader(range: $range)
            if store.loadedAt == nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading OMP usage…").foregroundStyle(Chrome.secondaryText)
                }.frame(maxWidth: .infinity, minHeight: 160)
            } else {
                if store.unreadableFiles > 0 || store.limited || store.statistics.invalidReports > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        if store.unreadableFiles > 0 {
                            Text(verbatim: String(format: Chrome.localized("%lld usage files could not be read. Totals cover the available records."), store.unreadableFiles))
                        }
                        if store.limited {
                            Text("This library exceeds the reading limit. Statistics cover the loaded records.")
                        }
                        if store.statistics.invalidReports > 0 {
                            Text("Some invalid usage records were excluded from these statistics.")
                        }
                    }
                    .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
                }
                UsageDashboard(statistics: store.statistics, range: store.loadedRange,
                               revision: store.snapshotRevision, presentationID: store.presentationRevision,
                               isActive: refreshKey.visible)
            }
        }
        .foregroundStyle(Chrome.primaryText)
        .task(id: refreshKey) {
            guard refreshKey.visible else { return }
            await store.refresh(model: model, range: range, forceID: refreshID)
        }
    }
}

struct UsagePeriodHeader: View {
    @Binding var range: UsageRange

    var body: some View {
        UsageSectionHeader(title: "Usage") {
            Picker("Usage period", selection: $range) {
                ForEach(UsageRange.allCases, id: \.self) { option in
                    Text(verbatim: Chrome.localized(option.title)).tag(option)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct UsageRefreshButton: View {
    let loadedAt: Date?
    let isLoading: Bool
    let action: () -> Void

    private var freshness: String {
        if isLoading { return Chrome.localized("Updating…") }
        guard let loadedAt else { return "" }
        return String(format: Chrome.localized("Updated %@"), loadedAt.formatted(date: .omitted, time: .shortened))
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise").font(Chrome.inlineIconFont)
                Text("Refresh").font(.ui(size: 12.5, weight: .medium))
                if !freshness.isEmpty {
                    Text(verbatim: freshness)
                        .font(.ui(.caption)).monospacedDigit().foregroundStyle(Chrome.secondaryText)
                }
            }
            .lineLimit(1)
            .foregroundStyle(Chrome.primaryText)
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .padding(.vertical, Chrome.capsuleVerticalPadding)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(isLoading).fixedSize()
        .chromeGlassCapsule()
        .help(Text("Refresh usage"))
        .accessibilityLabel(Text("Refresh usage"))
        .accessibilityValue(Text(verbatim: freshness))
        .background { NoWindowDragArea() }
    }
}

/// Kept independent of loading so every chart uses exactly the same accepted snapshot.
struct UsageDashboard: View {
    let statistics: UsageStatistics
    let range: UsageRange
    var revision: UInt64 = 0
    var presentationID: UInt64 = 0
    var isActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            metrics
            if statistics.amounts.total > 0 {
                UsageTrendChart(days: statistics.days, range: range, revision: revision,
                                presentationID: presentationID, isActive: isActive)
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        composition.frame(minWidth: 285)
                        activitySummary.frame(minWidth: 200)
                    }
                    VStack(alignment: .leading, spacing: 24) { composition; activitySummary }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 30, weight: .light))
                    Text("No recorded usage in this period").font(.ui(.body, weight: .medium))
                    Text("OMP usage appears here after a model response is recorded.")
                        .font(.ui(.subheadline)).multilineTextAlignment(.center)
                }
                .foregroundStyle(Chrome.secondaryText).frame(maxWidth: .infinity, minHeight: 160)
                .usageReveal(trigger: presentationID, active: isActive)
            }
            Divider()
            TokenActivitySection(dailyTotals: statistics.yearDaily, yearTotal: statistics.yearTotal,
                                 presentationID: presentationID, isActive: isActive)
            if statistics.amounts.total > 0 {
                Divider()
                UsageRankingSection(title: "Usage by model", rows: statistics.models, total: statistics.amounts.total,
                                    presentationID: presentationID, isActive: isActive)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        providerRanking.frame(minWidth: 260)
                        projectRanking.frame(minWidth: 260)
                    }
                    VStack(alignment: .leading, spacing: 24) { providerRanking; projectRanking }
                }
            }
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], spacing: 12) {
            UsageMetric(title: "Total tokens", value: UsagePanel.tokens(statistics.amounts.total),
                        detail: comparison, symbol: "chart.bar.fill", tint: Chrome.accent,
                        presentationID: presentationID, isActive: isActive)
            UsageMetric(title: "Reported output", value: statistics.amounts.outputReports > 0 ? UsagePanel.tokens(statistics.amounts.output) : "—",
                        detail: Chrome.localized("Generated tokens"), symbol: "text.alignleft", tint: Chrome.blue,
                        presentationID: presentationID, isActive: isActive)
            UsageMetric(title: "Cache hit rate", value: statistics.amounts.cacheHitRate.map(UsageStyle.percent) ?? "—",
                        detail: Chrome.localized("Of reported input"), symbol: "arrow.trianglehead.2.clockwise.rotate.90", tint: UsageStyle.cacheColor,
                        presentationID: presentationID, isActive: isActive)
            UsageMetric(title: "Active days", value: statistics.activeDays.formatted(),
                        detail: Chrome.localized("Days with token usage"), symbol: "calendar", tint: Chrome.orange,
                        presentationID: presentationID, isActive: isActive)
        }
    }

    private var comparison: String {
        guard let previous = statistics.previousTotal else { return Chrome.localized("Across recorded history") }
        guard previous > 0 else { return Chrome.localized("No usage in previous period") }
        let change = Double(statistics.amounts.total - previous) / Double(previous)
        return String(format: Chrome.localized("%@ vs. previous period"),
                      change.formatted(.percent.sign(strategy: .always()).precision(.fractionLength(0))))
    }

    private var composition: some View {
        VStack(alignment: .leading, spacing: 16) {
            UsageSectionTitle(title: "Token breakdown")
            HStack(spacing: 20) {
                Chart(UsageLane.allCases.filter { statistics.amounts[$0] > 0 }) { lane in
                    SectorMark(angle: .value(Chrome.localized("Tokens"), statistics.amounts[lane]),
                               innerRadius: .ratio(0.76), angularInset: 2)
                        .foregroundStyle(UsageStyle.color(lane))
                        .cornerRadius(3)
                        .accessibilityLabel(Chrome.localized(lane.title))
                        .accessibilityValue(statistics.amounts[lane].formatted())
                }
                .chartLegend(.hidden)
                .animation(reduceMotion || performanceMode ? nil : .smooth(duration: 0.4), value: revision)
                .frame(width: 118, height: 118)
                .usageReveal(trigger: presentationID, active: isActive, style: .ring, delay: 0.08)
                .overlay {
                    VStack(spacing: 3) {
                        Text(verbatim: UsagePanel.tokens(statistics.amounts.total)).font(.ui(.title3, weight: .semibold))
                        Text("Tokens").font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                    }.accessibilityHidden(true)
                }
                VStack(spacing: 11) {
                    ForEach(UsageLane.allCases.filter { statistics.amounts[$0] > 0 }) { lane in
                        HStack(spacing: 6) {
                            Circle().fill(UsageStyle.color(lane)).frame(width: 6, height: 6)
                            Text(verbatim: Chrome.localized(lane.title)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(verbatim: UsagePanel.tokens(statistics.amounts[lane])).monospacedDigit()
                        }
                        .font(.ui(.subheadline))
                        .help(Text(verbatim: statistics.amounts[lane].formatted()))
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activitySummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            UsageSectionTitle(title: "Activity summary")
            VStack(spacing: 10) {
                summaryRow("Conversations", statistics.sessionCount.formatted())
                summaryRow("Recorded turns", statistics.turnCount.formatted())
                summaryRow("Models used", statistics.modelCount.formatted())
                summaryRow("Daily average", UsagePanel.tokens(statistics.dailyAverage))
                summaryRow("Subagent share", UsageStyle.percent(Double(statistics.subagentTokens) / Double(max(1, statistics.amounts.total))))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(verbatim: Chrome.localized(title)).foregroundStyle(Chrome.secondaryText)
            Spacer(minLength: 12)
            Text(verbatim: value).monospacedDigit()
        }.font(.ui(.subheadline))
    }

    private var providerRanking: some View {
        UsageRankingSection(title: "Usage by provider", rows: statistics.providers, total: statistics.amounts.total,
                            presentationID: presentationID, isActive: isActive)
    }

    private var projectRanking: some View {
        UsageRankingSection(title: "Usage by project", rows: statistics.projects, total: statistics.amounts.total,
                            presentationID: presentationID, isActive: isActive)
    }
}

private struct UsageMetric: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color
    let presentationID: UInt64
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(verbatim: Chrome.localized(title)).foregroundStyle(Chrome.secondaryText)
            }.font(.ui(.subheadline)).lineLimit(1)
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: value).font(.ui(.largeTitle, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .contentTransition(reduceMotion || performanceMode ? .identity : .numericText())
                    .animation(reduceMotion || performanceMode ? nil : .smooth(duration: 0.35), value: value)
                Text(verbatim: detail).font(.ui(.caption))
                    .foregroundStyle(Chrome.secondaryText).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .usageReveal(trigger: presentationID, active: isActive, style: .text)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Chrome.overlay(0.035), in: RoundedRectangle(cornerRadius: Chrome.cardCornerRadius))
        .accessibilityElement(children: .combine)
    }
}

private struct UsageSectionTitle: View {
    let title: String
    var body: some View {
        Text(verbatim: Chrome.localized(title)).font(.ui(.body, weight: .semibold))
            .foregroundStyle(Chrome.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }
}

struct UsageSectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                UsageSectionTitle(title: title).fixedSize()
                Spacer(minLength: 12)
                accessory
            }
            VStack(alignment: .leading, spacing: 10) {
                UsageSectionTitle(title: title)
                HStack { Spacer(minLength: 0); accessory }
            }
        }
    }
}

private struct UsageTrendChart: View {
    let days: [UsageDay]
    let range: UsageRange
    let revision: UInt64
    let presentationID: UInt64
    let isActive: Bool
    @State private var selected: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                UsageSectionTitle(title: "Daily usage")
                if range == .all {
                    Text("90 days").font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                }
                Spacer(minLength: 8)
            }.frame(minHeight: 20)
            UsageTrendPlot(days: days, revision: revision, presentationID: presentationID,
                           isActive: isActive, selected: $selected)
            .frame(height: 200)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(UsageLane.allCases) { lane in
                    HStack(spacing: 5) {
                        Circle().fill(UsageStyle.color(lane)).frame(width: 6, height: 6)
                        Text(verbatim: Chrome.localized(lane.title))
                    }
                }
            }.font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
        }
        .onChange(of: range) { selected = nil }
        .onChange(of: presentationID) { selected = nil }
        .onChange(of: isActive) { if !isActive { selected = nil } }
    }

}

/// The plot accepts selection independently of the section so its rendering and
/// native date-axis hit testing share one path.
struct UsageTrendPlot: View {
    let days: [UsageDay]
    var revision: UInt64 = 0
    var presentationID: UInt64 = 0
    var isActive = true
    @Binding var selected: Date?
    @State private var hovered: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    private var focused: UsageDay? {
        guard let date = selected ?? hovered else { return nil }
        return days.first { UsageCalendar.calendar.isDate($0.date, inSameDayAs: date) }
    }

    var body: some View {
        let focused = self.focused
        Chart {
            ForEach(days) { day in
                ForEach(UsageLane.allCases) { lane in
                    BarMark(x: .value(Chrome.localized("Date"), day.date, unit: .day),
                            y: .value(Chrome.localized("Tokens"), day.amounts[lane]), width: .ratio(UsageBarGeometry.widthRatio))
                        .foregroundStyle(by: .value(Chrome.localized("Token breakdown"), lane.rawValue))
                        .accessibilityLabel(Text(verbatim: "\(day.date.formatted(date: .abbreviated, time: .omitted)), \(Chrome.localized(lane.title))"))
                        .accessibilityValue(day.amounts[lane].formatted())
                }
            }
            if let focused {
                RuleMark(x: .value(Chrome.localized("Date"), focused.date, unit: .day))
                    .foregroundStyle(Chrome.secondaryText.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
                RectangleMark(x: .value(Chrome.localized("Date"), focused.date, unit: .day),
                              yStart: .value(Chrome.localized("Tokens"), 0),
                              yEnd: .value(Chrome.localized("Tokens"), focused.amounts.total),
                              width: .ratio(UsageBarGeometry.widthRatio))
                    .foregroundStyle(.black.opacity(0.16))
                    .accessibilityHidden(true)
            }
        }
        .chartForegroundStyleScale(domain: UsageLane.allCases.map(\.rawValue), range: UsageLane.allCases.map(UsageStyle.color))
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.usageReveal(trigger: presentationID, active: isActive, style: .bars, delay: 0.04)
        }
        .animation(reduceMotion || performanceMode ? nil : .smooth(duration: 0.4), value: revision)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Chrome.overlay(0.08))
                AxisValueLabel {
                    if let count = value.as(Int.self) { Text(verbatim: UsagePanel.tokens(count)) }
                }.foregroundStyle(Chrome.secondaryText)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) {
                AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(Chrome.secondaryText)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let frame = geometry[anchor]
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { selected = nil }
                        ForEach(days.filter { $0.amounts.total > 0 }) { day in
                            if let bounds = UsageBarGeometry.bounds(for: day, proxy: proxy) {
                                barButton(day: day, bounds: bounds, plot: frame)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hovered = UsageBarGeometry.hoveredDay(at: location, in: frame, proxy: proxy, days: days)
                        case .ended: hovered = nil
                        }
                    }
                }
            }
        }
        .onChange(of: presentationID) { hovered = nil }
        .onChange(of: isActive) { if !isActive { hovered = nil } }
        .onDisappear { selected = nil; hovered = nil }
    }

    private func barButton(day: UsageDay, bounds: CGRect, plot: CGRect) -> some View {
        Button {
            selected = day.date
        } label: {
            Rectangle().fill(.clear).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: bounds.width, height: bounds.height)
        .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("Details for %@"),
                                                  day.date.formatted(date: .abbreviated, time: .omitted))))
        .accessibilityValue(Text(verbatim: day.amounts.total.formatted()))
        .chromePopover(
            isPresented: Binding(get: { selected == day.date }, set: { presented in
                if !presented, selected == day.date { selected = nil; hovered = nil }
            }),
            // Attach to the upper part of the actual column, keeping short and
            // tall bars equally easy to associate with their native popover.
            attachmentAnchor: .rect(.rect(CGRect(x: 0, y: 0, width: bounds.width, height: min(24, bounds.height)))),
            arrowEdge: bounds.midX < plot.width / 2 ? .trailing : .leading
        ) {
            UsageDayDetail(day: day)
        }
        .position(x: plot.minX + bounds.midX, y: plot.minY + bounds.midY)
    }
}

/// Shares the visible bar width with hit testing; gaps and the space above a bar stay inert.
enum UsageBarGeometry {
    static let widthRatio: CGFloat = 0.76

    static func bounds(for day: UsageDay, proxy: ChartProxy) -> CGRect? {
        // positionRange(forX:) returns a zero-width range on a continuous date
        // axis. A day-mark instead spans its calendar interval, including DST.
        guard let interval = UsageCalendar.calendar.dateInterval(of: .day, for: day.date),
              let start = proxy.position(forX: interval.start),
              let end = proxy.position(forX: interval.end),
              let top = proxy.position(forY: day.amounts.total),
              let baseline = proxy.position(forY: 0) else { return nil }
        return bounds(bucket: min(start, end)...max(start, end), top: top, baseline: baseline)
    }

    static func hoveredDay(at location: CGPoint, in frame: CGRect, proxy: ChartProxy, days: [UsageDay]) -> Date? {
        guard frame.contains(location),
              let date = proxy.value(atX: location.x - frame.minX, as: Date.self),
              let day = days.first(where: { UsageCalendar.calendar.isDate($0.date, inSameDayAs: date) }),
              day.amounts.total > 0,
              let bounds = bounds(for: day, proxy: proxy) else { return nil }
        return bounds.offsetBy(dx: frame.minX, dy: frame.minY).contains(location) ? day.date : nil
    }

    static func bounds(bucket: ClosedRange<CGFloat>, top: CGFloat, baseline: CGFloat) -> CGRect {
        let width = (bucket.upperBound - bucket.lowerBound) * widthRatio
        return CGRect(x: (bucket.lowerBound + bucket.upperBound - width) / 2,
                      y: min(top, baseline), width: width, height: abs(baseline - top))
    }
}

struct UsageDayDetail: View {
    let day: UsageDay

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: day.date.formatted(date: .abbreviated, time: .omitted))
                .font(.ui(.subheadline, weight: .semibold))
            HStack {
                Text("Total tokens").foregroundStyle(Chrome.secondaryText)
                Spacer(minLength: 8)
                Text(verbatim: day.amounts.total.formatted()).fontWeight(.semibold)
            }
            Divider()
            ForEach(UsageLane.allCases.filter { day.amounts[$0] > 0 }) { lane in
                HStack(spacing: 6) {
                    Circle().fill(UsageStyle.color(lane)).frame(width: 5, height: 5)
                    Text(verbatim: Chrome.localized(lane.title)).foregroundStyle(Chrome.secondaryText)
                    Spacer(minLength: 8)
                    Text(verbatim: day.amounts[lane].formatted())
                }
            }
        }
        .font(.ui(.caption)).monospacedDigit().foregroundStyle(Chrome.primaryText)
        .padding(14).frame(width: 228).fixedSize(horizontal: false, vertical: true)
    }
}

private struct UsageRankingSection: View {
    let title: String
    let rows: [UsageRank]
    let total: Int
    let presentationID: UInt64
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            UsageSectionTitle(title: title)
            VStack(spacing: 14) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 10) {
                            Text(verbatim: row.localized ? Chrome.localized(row.name) : row.name)
                                .lineLimit(1).truncationMode(.middle)
                                .help(Text(verbatim: row.localized ? Chrome.localized(row.name) : row.name))
                            Spacer(minLength: 0)
                            Text(verbatim: UsagePanel.tokens(row.tokens)).monospacedDigit()
                            Text(verbatim: UsageStyle.percent(Double(row.tokens) / Double(max(1, total))))
                                .monospacedDigit().foregroundStyle(Chrome.secondaryText).frame(width: 48, alignment: .trailing)
                        }.font(.ui(.subheadline))
                        GeometryReader { geometry in
                            Capsule().fill(Chrome.overlay(0.055))
                            Capsule().fill(Chrome.accent.opacity(row.id == "remainder" ? 0.35 : 0.8))
                                .frame(width: max(0, geometry.size.width * CGFloat(row.tokens) / CGFloat(max(1, total))))
                                .animation(reduceMotion || performanceMode ? nil : .smooth(duration: 0.4),
                                           value: Double(row.tokens) / Double(max(1, total)))
                        }.frame(height: 4).accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .combine)
                    .help(Text(verbatim: row.tokens.formatted()))
                }
            }
            .usageReveal(trigger: presentationID, active: isActive, style: .sweep, delay: 0.12)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum UsageStyle {
    static let cacheColor = Color.teal
    static func color(_ lane: UsageLane) -> Color {
        switch lane {
        case .input: Chrome.accent
        case .cached: cacheColor
        case .output: Chrome.orange
        case .unknown: Chrome.gray.opacity(0.55)
        }
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(1)))
    }
}
