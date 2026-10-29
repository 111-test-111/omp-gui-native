import AppKit
import Charts
import Foundation
import SwiftUI
@testable import OMPGUI

@main
struct UsageStatisticsChecks {
    @MainActor static var checks = 0
    @MainActor static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        checks += 1
    }

    static func turn(_ date: Date, _ tokens: Int, input: Int? = nil, output: Int? = nil,
                     cached: Int? = nil, model: String? = "openai/gpt-5") -> TurnRecord {
        var turn = TurnRecord(index: 0)
        turn.startedAt = date
        turn.tokenSpends = [TokenSpend(provider: .omp, totalTokens: tokens, inputTokens: input,
                                      outputTokens: output, cachedInputTokens: cached, model: model)]
        return turn
    }

    @MainActor static func aggregation() -> UsageStatistics {
        let calendar = UsageCalendar.calendar
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12))!
        func ago(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: now)! }
        let project = Project(name: "OMP GUI", path: "/isolated/omp-gui")
        var parent = ChatThread(projectID: project.id, provider: .omp, model: nil, effort: nil, runtimeMode: .supervised)
        parent.createdAt = ago(400)
        parent.isArchived = true
        var first = turn(now, 180, input: 130, output: 50, cached: 80)
        first.nativeSessionFile = "/isolated/session.jsonl"
        first.nativeUserEntryID = "native-user"
        let missing = TurnRecord(index: 1)
        let unknown = turn(ago(1), 20, model: nil)
        let previous = turn(ago(7), 300)
        let outsideTrend = turn(ago(100), 100)
        let lastYear = turn(calendar.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 23))!, 500)
        let future = turn(ago(-1), 999)
        var child = ChatThread(projectID: nil, provider: .omp, model: nil, effort: nil, runtimeMode: .supervised)
        child.createdAt = ago(2)
        child.hydra = HydraHeadInfo(index: 0, task: "Inspect", kind: .native, origin: .delegated)
        let childTurn = turn(now, 80, input: 50, output: 30, cached: 20, model: "anthropic/claude-sonnet")
        var fork = parent
        fork.id = UUID(); fork.createdAt = ago(1)
        var duplicate = first; duplicate.id = UUID()
        var unsupported = parent
        unsupported.id = UUID(); unsupported.provider = .codex
        var embeddedAgent = turn(now, 9999)
        embeddedAgent.tokenSpends?[0].agentID = "child"
        let snapshots = [
            UsageThreadSnapshot(thread: parent, turns: [first, unknown, previous, outsideTrend, lastYear, future, missing, embeddedAgent].map(UsageTurn.init)),
            UsageThreadSnapshot(thread: child, turns: [UsageTurn(childTurn)]),
            UsageThreadSnapshot(thread: fork, turns: [UsageTurn(first), UsageTurn(duplicate)]),
            UsageThreadSnapshot(thread: unsupported, turns: [UsageTurn(turn(now, 50000))])
        ]
        let stats = UsageStatistics.build(snapshots, projects: [project], range: .week, now: now)
        expect(stats.amounts.total == 280, "Archived OMP and child spend count once; forks, embedded child copies, other runtimes and future dates do not")
        expect(stats.amounts.input == 80 && stats.amounts.cached == 100 && stats.amounts.output == 80 && stats.amounts.unknown == 20,
               "Stacked buckets preserve the authoritative total without adding cached input twice")
        expect(abs(stats.amounts.cacheHitRate! - 100.0 / 180.0) < 0.00001, "Cache rate is weighted by known input, never by output or missing reports")
        expect(stats.turnCount == 3 && stats.sessionCount == 2 && stats.activeDays == 2, "Only turns with spend contribute activity counts")
        expect(stats.subagentTokens == 80 && stats.modelCount == 2, "Subagents retain independent ownership and unknown models do not inflate the model count")
        expect(stats.previousTotal == 300 && stats.dailyAverage == 40, "Range comparison uses the previous nonoverlapping calendar period; daily average includes quiet days")
        expect(stats.days.count == 7 && stats.days.reduce(0, { $0 + $1.amounts.total }) == 280, "Daily series fills quiet days inside the selected range")
        expect(stats.yearTotal == 680 && stats.yearDaily.values.reduce(0, +) == 680, "The annual heatmap excludes last year's spend and ignores the selected shorter range")
        expect(stats.models.reduce(0, { $0 + $1.tokens }) == 280 && stats.providers.reduce(0, { $0 + $1.tokens }) == 280
               && stats.projects.reduce(0, { $0 + $1.tokens }) == 280, "Every ranking reconciles with the total, including unknown attribution")
        let all = UsageStatistics.build(snapshots, projects: [project], range: .all, now: now)
        expect(all.amounts.total == 1180 && all.days.count == 90 && all.days.reduce(0, { $0 + $1.amounts.total }) == 580,
               "All-time KPIs retain old history while chart marks stay bounded to 90 days")
        expect(all.previousTotal == nil, "An unbounded period has no invented comparison")
        let incomplete = UsageAmounts(TokenSpend(provider: .omp, totalTokens: 100))
        expect(incomplete.unknown == 100 && incomplete.cacheHitRate == nil && incomplete.outputReports == 0,
               "Missing counters remain unknown rather than becoming a zero-percent cache rate")
        let malformed = UsageAmounts(TokenSpend(provider: .omp, totalTokens: 100, inputTokens: -1, outputTokens: 1000, cachedInputTokens: 200))
        expect(malformed.unknown == 100 && malformed.cacheHitRate == nil, "Malformed counters cannot overfill a stack or produce a cache rate")
        let zeroCache = UsageAmounts(TokenSpend(provider: .omp, totalTokens: 100, inputTokens: 90, outputTokens: 10, cachedInputTokens: 0))
        expect(zeroCache.cacheHitRate == 0, "An explicitly reported zero cache hit remains distinguishable from unknown")
        let rankedTurns = (0..<20).map { UsageTurn(turn(now, $0 + 1, model: "provider/model-\($0)")) }
        let ranked = UsageStatistics.build([UsageThreadSnapshot(thread: parent, turns: rankedTurns)], projects: [], range: .month, now: now)
        expect(ranked.models.count == 9 && ranked.models.last?.id == "remainder" && ranked.models.reduce(0, { $0 + $1.tokens }) == ranked.amounts.total,
               "Large rankings collapse the remainder without dropping spend")
        var alias = child
        alias.id = UUID(); alias.hydra?.nativeCanonicalID = child.id
        let aliasStats = UsageStatistics.build([
            UsageThreadSnapshot(thread: child, turns: [UsageTurn(childTurn)]),
            UsageThreadSnapshot(thread: alias, turns: [UsageTurn(turn(now, 120))])
        ], projects: [], range: .week, now: now)
        expect(aliasStats.amounts.total == 120 && aliasStats.sessionCount == 1 && aliasStats.subagentTokens == 120,
               "Old native-worker aliases contribute only their most complete cumulative snapshot")
        let overflow = UsageStatistics.build([UsageThreadSnapshot(thread: parent, turns: [
            UsageTurn(turn(now, Int.max)), UsageTurn(turn(now, 10))
        ])], projects: [], range: .week, now: now)
        expect(overflow.amounts.total == Int.max && overflow.invalidReports == 1,
               "Corrupted counts that overflow the aggregate are excluded and reported without crashing settings")
        let zone = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: "America/Los_Angeles")!
        defer { NSTimeZone.default = zone }
        let dstNow = UsageCalendar.calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
        let dst = UsageStatistics.build([], projects: [], range: .week, now: dstNow)
        expect(dst.days.count == 7 && Set(dst.days.map { UsageCalendar.dayKey($0.date) }).count == 7,
               "The fall DST transition produces seven distinct local days")
        return all
    }

    @MainActor static func storage() throws {
        let now = Date.now
        var thread = ChatThread(projectID: nil, provider: .omp, model: nil, effort: nil, runtimeMode: .supervised)
        thread.hasStartedTurn = true
        var first = turn(now, 100, input: 80, output: 20, cached: 40)
        first.status = .completed
        let reference = ThreadTurnReference(id: first.id, revision: 2)
        var head = ThreadDocument(threadID: thread.id)
        head.turnIndex = [reference]
        let stored = StoredTurn(turn: first, items: [], itemPositions: [:])
        expect(DiskWriter.shared.writeThreadSynchronously(ThreadSave(head: head, dirtyTurns: [first.id: stored])), "The revisioned usage fixture saves")
        // Retain a stale revision beside the selected one. Only the head's revision owns spend.
        var old = first; old.tokenSpends?[0].totalTokens = 999
        struct Revisions: Encodable { let revisions: [String: StoredTurn] }
        let file = Revisions(revisions: ["1": StoredTurn(turn: old, items: [], itemPositions: [:]), "2": stored])
        try JSONEncoder.storage.encode(file).write(to: Storage.turnURL(thread.id, first.id))
        let loaded = try UsageHistoryReader.read(threads: [thread], live: [:])
        expect(loaded.snapshots.first?.turns.first?.tokenSpends?.first?.totalTokens == 100 && loaded.unreadableFiles == 0,
               "The reader selects the committed turn revision without decoding transcript items")
        let cached = try UsageHistoryReader.read(threads: [thread], live: [:], cached: loaded.cache)
        expect(cached.snapshots.first?.turns.count == 1 && cached.cache.count == 1, "An unchanged committed head reuses compact accounting data")
        var updated = first; updated.tokenSpends?[0].totalTokens = 150
        let live = try UsageHistoryReader.read(threads: [thread], live: [thread.id: [updated]], cached: loaded.cache)
        expect(live.snapshots.first?.turns.first?.tokenSpends?.first?.totalTokens == 150, "Unsaved live usage replaces disk usage instead of adding it")
        let removed = try UsageHistoryReader.read(threads: [thread], live: [thread.id: []], cached: loaded.cache)
        expect(removed.snapshots.first?.turns.isEmpty == true, "An empty current transcript removes stale disk turns")
        try Data("unreadable".utf8).write(to: Storage.turnURL(thread.id, first.id))
        let broken = try UsageHistoryReader.read(threads: [thread], live: [:])
        expect(broken.unreadableFiles == 1 && broken.snapshots.first?.turns.isEmpty == true && broken.cache.isEmpty,
               "A damaged revision yields explicit partial coverage and is never cached as a complete result")
        var legacy = ThreadDocument(threadID: thread.id)
        legacy.turns = [updated]
        try JSONEncoder.storage.encode(legacy).write(to: Storage.threadURL(thread.id), options: .atomic)
        let restored = try UsageHistoryReader.read(threads: [thread], live: [:], cached: loaded.cache)
        expect(restored.snapshots.first?.turns.first?.tokenSpends?.first?.totalTokens == 150,
               "Head replacement invalidates the cache and old self-contained GUI documents remain readable")
        var other = thread; other.provider = .codex
        expect(try UsageHistoryReader.read(threads: [other], live: [:]).snapshots.isEmpty, "Legacy provider identifiers never become a usage source")
        let oversized = try FileHandle(forWritingTo: Storage.threadURL(thread.id))
        try oversized.truncate(atOffset: UInt64(UsageHistoryReader.maxFileBytes + 1)); try oversized.close()
        let bounded = try UsageHistoryReader.read(threads: [thread], live: [:])
        expect(bounded.limited && bounded.cache.isEmpty, "An oversized accounting file is bounded and explicitly marks partial coverage")
    }

    @MainActor static func render(_ statistics: UsageStatistics, output: URL) async throws {
        guard let defaults = CaptureRun.defaults else { fatalError("Isolated preferences required") }
        let previousPerformanceMode = defaults.object(forKey: "performanceMode")
        defer {
            if let previousPerformanceMode { defaults.set(previousPerformanceMode, forKey: "performanceMode") }
            else { defaults.removeObject(forKey: "performanceMode") }
        }
        for (width, scheme) in [(760.0, ColorScheme.light), (400.0, .dark)] {
            // Native Liquid Glass needs the window compositor, which an undisplayed
            // window cannot capture. Keep both layout images on the isolated fallback.
            defaults.set(true, forKey: "performanceMode")
            let content = VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Spacer(minLength: 0)
                    UsageRefreshButton(loadedAt: Date(timeIntervalSince1970: 1_792_973_200), isLoading: false) {}
                }
                UsagePeriodHeader(range: .constant(.all))
                UsageDashboard(statistics: statistics, range: .all)
            }
                .font(.ui(.body)).foregroundStyle(Chrome.primaryText)
                .frame(width: width, alignment: .topLeading).padding(24)
                .background(scheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
                .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 48, height: 1800),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            // Mount only in an undisplayed native window so system controls are
            // actually drawn. ImageRenderer cannot render NSSegmentedControl.
            for _ in 0..<3 {
                window.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            expect(abs(size.width - (width + 48)) < 1 && size.height > 500 && size.height < 4000,
                   "The dashboard keeps a bounded layout at \(width) pt without horizontal overflow")
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                fatalError("The native usage dashboard must render offscreen")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding") }
            try data.write(to: output.appendingPathComponent("usage-\(Int(width))-\(scheme == .dark ? "dark" : "light").png"))
            if let day = statistics.days.last(where: { $0.amounts.output > 0 }) {
                let detail = UsageDayDetail(day: day).padding(16)
                    .background(scheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: detail)
                renderer.scale = 2
                guard let cgImage = renderer.cgImage,
                      let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                    fatalError("The popover content must render offscreen")
                }
                try data.write(to: output.appendingPathComponent("usage-detail-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    @MainActor static func hoverBounds() {
        let bar = UsageBarGeometry.bounds(bucket: 10...30, top: 60, baseline: 180)
        expect(bar.contains(CGPoint(x: 20, y: 100)), "The visible stack is a hover target")
        expect(!bar.contains(CGPoint(x: 10.5, y: 100)), "The gap between daily columns never activates a detail")
        expect(!bar.contains(CGPoint(x: 20, y: 20)), "Hovering chart space above a shorter bar does not select it")
        expect(!UsageBarGeometry.bounds(bucket: 10...30, top: 180, baseline: 180).contains(CGPoint(x: 20, y: 180)),
               "A zero-height day has no hover target")
    }

    @MainActor static func hoverMeasurements(proxy: ChartProxy, frame: CGRect, days: [UsageDay]) -> [String: CGFloat] {
        var values: [String: CGFloat] = ["plotWidth": frame.width, "hits": 0, "gaps": 0, "above": 0, "zero": 0]
        for day in days {
            guard let bar = UsageBarGeometry.bounds(for: day, proxy: proxy),
                  let start = proxy.position(forX: day.date) else { continue }
            let center = CGPoint(x: frame.minX + bar.midX, y: frame.minY + bar.midY)
            let hit = UsageBarGeometry.hoveredDay(at: center, in: frame, proxy: proxy, days: days)
            if day.amounts.total == 0 {
                if hit == nil { values["zero", default: 0] += 1 }
            } else if hit == day.date && bar.width > 0 {
                values["hits", default: 0] += 1
            }
            let gap = CGPoint(x: frame.minX + start, y: center.y)
            if UsageBarGeometry.hoveredDay(at: gap, in: frame, proxy: proxy, days: days) == nil {
                values["gaps", default: 0] += 1
            }
            let above = CGPoint(x: center.x, y: frame.minY + bar.minY - 2)
            if UsageBarGeometry.hoveredDay(at: above, in: frame, proxy: proxy, days: days) == nil {
                values["above", default: 0] += 1
            }
        }
        return values
    }

    @MainActor static func nativeHoverCoordinates() async throws {
        let originalZone = NSTimeZone.default
        defer { NSTimeZone.default = originalZone }
        for (count, width, zone) in [(7, 400.0, "Asia/Hong_Kong"), (90, 760.0, "Asia/Hong_Kong"), (7, 400.0, "America/Los_Angeles")] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            let calendar = UsageCalendar.calendar
            let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30))!
            let days = (0..<count).map { index in
                let date = calendar.date(byAdding: .day, value: index, to: start)!
                let amount = UsageAmounts(TokenSpend(provider: .omp, totalTokens: index == 1 ? 0 : (index + 1) * 100))
                return UsageDay(date: date, amounts: amount)
            }
            final class Reading { var values: [String: CGFloat] = [:] }
            let reading = Reading()
            // A native continuous date axis is essential: hand-written pixel ranges
            // missed the zero-width positionRange(forX:) regression.
            let chart = Chart(days) { day in
                BarMark(x: .value("Date", day.date, unit: .day), y: .value("Tokens", day.amounts.total),
                        width: .ratio(UsageBarGeometry.widthRatio))
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let anchor = proxy.plotFrame {
                        let values = hoverMeasurements(proxy: proxy, frame: geometry[anchor], days: days)
                        Color.clear.task(id: values) { reading.values = values }
                    }
                }
            }
            .frame(width: width, height: 200)
            .environment(\.calendar, calendar)
            let host = NSHostingView(rootView: chart)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let values = reading.values
            expect((values["plotWidth"] ?? 0) > 0, "Native chart layout completes at \(width) pt")
            expect(values["hits"] == CGFloat(count - 1), "Every populated bar, including both range edges, is hittable in \(zone): \(values)")
            expect(values["gaps"] == CGFloat(count), "Native date-axis gaps stay inert in \(zone)")
            expect(values["above"] == CGFloat(count), "Native chart space above the stack stays inert in \(zone)")
            expect(values["zero"] == 1, "The zero-use day stays inert in \(zone)")
        }
    }

    @MainActor static func renderPlot(output: URL) throws {
        guard let defaults = CaptureRun.defaults else { fatalError("Isolated preferences required") }
        let previous = defaults.object(forKey: "performanceMode")
        defaults.set(true, forKey: "performanceMode")
        defer {
            if let previous { defaults.set(previous, forKey: "performanceMode") }
            else { defaults.removeObject(forKey: "performanceMode") }
        }
        let calendar = UsageCalendar.calendar
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))!
        let days = (0..<7).map { index in
            let total = (index + 1) * 100
            return UsageDay(date: calendar.date(byAdding: .day, value: index, to: start)!,
                            amounts: UsageAmounts(TokenSpend(provider: .omp, totalTokens: total, inputTokens: total * 4 / 5,
                                                             outputTokens: total / 5, cachedInputTokens: total / 2)))
        }
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let view = UsageTrendPlot(days: days, isActive: false, selected: .constant(nil))
                .frame(width: 400, height: 200).padding(16)
                .background(scheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let cgImage = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                fatalError("The daily plot must render offscreen without opening native presentations")
            }
            expect(cgImage.width == 864 && cgImage.height == 464, "The \(name) plot keeps its bounds with native click targets")
            try data.write(to: output.appendingPathComponent("usage-plot-\(name).png"))
        }
    }

    @MainActor static func main() async throws {
        guard let root = CaptureRun.storageRoot else { fatalError("Isolated capture storage required") }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let statistics = aggregation()
        try storage()
        hoverBounds()
        try await nativeHoverCoordinates()
        try await render(statistics, output: root.deletingLastPathComponent())
        try renderPlot(output: root.deletingLastPathComponent())
        expect(SettingsPage.usage.title == "Usage" && SettingsPage.usage.keywords.contains("统计"), "Usage is a searchable native settings destination")
        print("Usage statistics checks passed: \(checks)")
    }
}
