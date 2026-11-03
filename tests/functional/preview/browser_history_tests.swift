import AppKit
import SwiftUI
@testable import OMPGUI

@main
private enum BrowserHistoryChecks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }

    @MainActor static func main() async throws {
        guard let root = CaptureRun.storageRoot else { fatalError("Requires isolated capture storage") }
        let now = ISO8601DateFormatter().date(from: "2026-10-30T08:30:00Z")!
        var navigation = BrowserHistoryNavigation()
        for address in ["about:blank", "about:blank#omp-gui-fixture", "file:///tmp/private", "data:text/html,hello", "https://user:secret@example.com"] {
            expect(navigation.navigate(to: address, at: now) == nil, "Internal, local and credential-bearing addresses are not history")
        }
        let first = navigation.navigate(to: "https://example.com/first", at: now)!
        expect(navigation.navigate(to: first.url, at: now) == nil, "Duplicate native notifications and reloads do not duplicate a visit")
        let second = navigation.navigate(to: "https://example.com/second", at: now)!
        let back = navigation.navigate(to: first.url, at: now)!
        expect(first.id != second.id && back.id != first.id, "Back/forward visits retain independent history identities")
        _ = navigation.navigate(to: "about:blank")
        expect(navigation.navigate(to: first.url)?.id != back.id, "Returning from a blank tab records the new visit")

        let url = root.appendingPathComponent("history/history.sqlite")
        let history = BrowserHistoryStore(url: url)
        var visits: [BrowserHistoryVisit] = []
        for index in 0..<125 {
            let visit = BrowserHistoryVisit(id: UUID(), url: "https://example.com/page-\(index % 7)?q=C%2B%2B&lang=zh",
                                            visitedAt: now.addingTimeInterval(Double(index - 124) * 3_600))
            visits.append(visit)
            history.record(visit)
            history.updateTitle("页面 \(index) · A title with 'quotes' & spaces", visitID: visit.id)
        }
        await history.flush()
        expect(history.errorKey == nil && history.recent.count == 5, "Recent pages contain exactly five distinct URLs")
        expect(history.recent.map(\.url) == visits.suffix(5).reversed().map(\.url), "Recent pages are sorted by latest visit")
        expect(history.recent.first?.title.contains("124") == true, "Native title updates attach to the right visit")
        let page1 = try await history.page(before: nil)
        let page2 = try await history.page(before: page1.entries.last!.cursor)
        let page3 = try await history.page(before: page2.entries.last!.cursor)
        let all = page1.entries + page2.entries + page3.entries
        expect(page1.entries.count == 50 && page2.entries.count == 50 && page3.entries.count == 25 && !page3.hasMore,
               "The complete history is retained while reads remain bounded to one page")
        expect(Set(all.map(\.id)).count == 125 && all.map(\.visitedAt) == visits.reversed().map(\.visitedAt),
               "Paging includes every repeat visit exactly once in chronological order")
        await checkPagination(history: history, entries: all)

        let resumed = BrowserHistoryStore(url: url)
        await resumed.loadRecent()
        let restored = try await resumed.page(before: nil)
        expect(resumed.recent == history.recent && restored.entries == page1.entries, "Recent pages, exact URLs, titles and visits survive reopening")
        let independent = BrowserHistoryStore(url: root.appendingPathComponent("other-edition/history.sqlite"))
        let independentPage = try await independent.page(before: nil)
        expect(independentPage.entries.isEmpty, "A different edition/library has independent history")

        history.clearRecent()
        history.updateTitle("Late title after clearing recent pages", visitID: visits.last!.id)
        await history.flush()
        let afterRecentClear = try await history.page(before: nil)
        expect(history.recent.isEmpty && afterRecentClear.entries.count == 50,
               "Clearing recent pages preserves full history and late titles cannot repopulate recent pages")
        let clearList = BrowserHistoryListStore()
        await clearList.refresh(history: history)
        expect(clearList.canClear, "An empty recent list does not disable cleanup of existing full history")
        clearList.older()
        await clearList.refresh(history: history)
        let fresh = BrowserHistoryVisit(id: UUID(), url: visits.last!.url, visitedAt: now.addingTimeInterval(1))
        history.record(fresh)
        history.updateTitle("A new visit after clearing", visitID: fresh.id)
        await history.flush()
        expect(history.recent.count == 1 && history.recent.first?.displayTitle == "A new visit after clearing",
               "New visits repopulate a cleared recent list without bringing older pages back")
        history.remove(history.recent[0].id)
        history.updateTitle("Late deleted title", visitID: fresh.id)
        await history.flush()
        expect(history.recent.isEmpty, "Deleting a history visit also removes its recent shortcut without resurrection")

        history.clear(.hour, now: now)
        await history.flush()
        let afterRangeClear = try await history.page(before: nil)
        expect(afterRangeClear.entries.first?.visitedAt == now.addingTimeInterval(-7_200),
               "Time-range cleanup includes the exact boundary and preserves earlier visits")
        history.clear(.all, now: now)
        history.updateTitle("Late title after deleting all history", visitID: first.id)
        history.updateTitle("Late title of a deleted visit", visitID: visits.last!.id)
        await history.flush()
        let afterAllClear = try await history.page(before: nil)
        expect(afterAllClear.entries.isEmpty && history.recent.isEmpty, "Full cleanup survives queued title callbacks")
        await clearList.refresh(history: history)
        expect(clearList.number == 1 && clearList.page.entries.isEmpty && !clearList.canClear,
               "Clearing history from another view resets an empty older page and disables cleanup")
        let emptyRestart = BrowserHistoryStore(url: url)
        await emptyRestart.loadRecent()
        let emptyPage = try await emptyRestart.page(before: nil)
        expect(emptyRestart.recent.isEmpty && emptyPage.entries.isEmpty, "Both clear actions remain effective after reopening")

        // Equal timestamps must not skip or duplicate rows at the page boundary.
        for index in 0..<53 {
            history.record(.init(id: UUID(), url: "https://equal.example/\(index)", visitedAt: now))
        }
        await history.flush()
        let tiedFirst = try await history.page(before: nil)
        history.record(.init(id: UUID(), url: "https://new.example/inserted", visitedAt: now.addingTimeInterval(60)))
        let tiedNext = try await history.page(before: tiedFirst.entries.last!.cursor)
        expect(tiedNext.entries.count == 3 && Set((tiedFirst.entries + tiedNext.entries).map(\.id)).count == 53,
               "Keyset pagination is stable for timestamp ties and concurrent new visits")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Hong_Kong")!
        let midnight = calendar.startOfDay(for: now)
        let grouped = BrowserHistoryDay.groups([
            .init(id: 1, url: first.url, title: "", visitedAt: midnight),
            .init(id: 2, url: first.url, title: "", visitedAt: midnight.addingTimeInterval(-1))
        ], calendar: calendar)
        expect(grouped.count == 2 && grouped[0].id == midnight, "History groups follow local midnight, not UTC")
        expect(BrowserHistoryRange.today.start(now: now, calendar: calendar) == midnight,
               "Today cleanup uses the same local calendar boundary")

        let brokenURL = root.appendingPathComponent("broken-history.sqlite")
        try Data("not a sqlite database".utf8).write(to: brokenURL)
        let broken = BrowserHistoryStore(url: brokenURL)
        await broken.loadRecent()
        let brokenBytes = try Data(contentsOf: brokenURL)
        expect(broken.errorKey != nil && brokenBytes == Data("not a sqlite database".utf8),
               "Storage failures are visible and do not replace an unreadable database")
        let brokenList = BrowserHistoryListStore()
        await brokenList.refresh(history: broken)
        expect(!brokenList.canClear, "Failed history reads cannot enable an empty cleanup action")
        try await checkIcons(output: root)
        try await checkPresentation(output: root)
        expect(EmbeddedBrowserRuntime.shared.endpoint == nil, "History browsing and blank-page rendering never initialize CEF")
        print("Browser history: \(checks) checks passed; isolated storage and offscreen UI only")
    }

    @MainActor private static func checkPagination(history: BrowserHistoryStore, entries: [BrowserHistoryEntry]) async {
        let list = BrowserHistoryListStore()
        let layout = BrowserHistoryPageLayout()
        expect(!list.canClear, "Cleanup is unavailable before any history has loaded")
        var pages: [[BrowserHistoryEntry]] = []
        repeat {
            await list.refresh(history: history)
            expect(!list.page.entries.isEmpty && layout.height(for: list.page.entries) <= BrowserHistoryPageLayout.maximumHeight,
                   "Each visible page fits complete rows and date headings within the height cap")
            pages.append(list.page.entries)
            guard list.page.hasMore else { break }
            let previousNumber = list.number
            list.older()
            list.older()
            expect(list.number == previousNumber + 1 && !list.canClear,
                   "Repeated next-page clicks cannot enqueue duplicate cursors while loading")
            precondition(pages.count < entries.count, "Paging must make forward progress")
        } while true
        expect(pages.flatMap { $0 } == entries, "Height-based pagination visits every database row exactly once without skipping unread rows")
        for expected in pages.dropLast().reversed() {
            list.newer()
            await list.refresh(history: history)
            expect(list.page.entries == expected, "Newer returns to the exact prior page boundary")
        }

        let sparse = entries.prefix(20).enumerated().map { index, entry in
            BrowserHistoryEntry(id: entry.id, url: entry.url, title: entry.title,
                                visitedAt: layout.calendar.date(byAdding: .day, value: -index, to: entries[0].visitedAt)!)
        }
        let savedUI = TypeScale.shared.ui
        defer { TypeScale.shared.ui = savedUI }
        for size in [TypeScale.uiRange.lowerBound, TypeScale.uiRange.upperBound] {
            TypeScale.shared.ui = size
            let resized = BrowserHistoryPageLayout()
            let page = resized.fitting(.init(entries: sparse))
            expect(!page.entries.isEmpty && page.hasMore && resized.height(for: page.entries) <= BrowserHistoryPageLayout.maximumHeight,
                   "Sparse dates and supported font sizes leave no clipped or overflowing last row")
            expect(resized.height(for: [sparse[0]]) < resized.height(for: Array(sparse.prefix(2))),
                   "Small history pages grow with their entries instead of reserving the full height")
        }
        TypeScale.shared.ui = savedUI
        list.older()
        await list.refresh(history: history)
        TypeScale.shared.ui = TypeScale.uiRange.upperBound
        await list.refresh(history: history)
        expect(list.number == 1 && list.page.entries.first?.id == entries.first?.id,
               "Changing layout metrics resets stale page boundaries to the newest visit")
    }

    @MainActor private static func iconFixture(template: Bool = false, size: Int = 32) -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let blue = NSColor(deviceRed: 0.1, green: 0.3, blue: 0.9, alpha: 1)
        let orange = NSColor(deviceRed: 0.95, green: 0.45, blue: 0.1, alpha: 1)
        let black = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
        let clear = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0)
        for y in 0..<size { for x in 0..<size {
            let visible = x > 3 && x < size - 4 && y > 3 && y < size - 4
            bitmap.setColor(visible ? (template ? black : (x < size / 2 ? blue : orange)) : clear, atX: x, y: y)
        } }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(bitmap)
        image.isTemplate = template
        return image
    }

    @MainActor private static func checkIcons(output: URL) async throws {
        let color = iconFixture(), template = iconFixture(template: true)
        let payload = BrowserHistoryIconCodec.encode(color)!
        let templatePayload = BrowserHistoryIconCodec.encode(template)!
        expect(BrowserHistoryIconCodec.decode(payload)?.isTemplate == false
               && BrowserHistoryIconCodec.decode(templatePayload)?.isTemplate == true,
               "Saved icons preserve original colors and appearance-adaptive template identity")
        let pixels = BrowserHistoryIconCodec.decode(payload)!.representations.compactMap { $0 as? NSBitmapImageRep }.first!
        let blue = pixels.colorAt(x: 8, y: 8)!.usingColorSpace(.deviceRGB)!
        let orange = pixels.colorAt(x: 24, y: 8)!.usingColorSpace(.deviceRGB)!
        expect(blue.blueComponent > 0.8 && blue.redComponent < 0.2 && orange.redComponent > 0.9
               && pixels.colorAt(x: 0, y: 0)!.alphaComponent == 0,
               "History icon PNG round trips preserve the artwork's real color pixels and transparent margins")
        expect(BrowserHistoryIconCodec.encode(iconFixture(size: 65)) == nil
               && BrowserHistoryIconCodec.decode(.init(png: Data("invalid".utf8), isTemplate: false)) == nil,
               "Oversized and damaged icons cannot become unbounded decoded history images")
        expect(BrowserHistoryIconLoader.source(for: "http://localhost:5173/path?q=private#section")?.absoluteString
               == "http://localhost:5173/favicon.ico", "Old history uses the site's real origin, without exposing its path or query")
        expect(BrowserHistoryIconLoader.source(for: "file:///tmp/private") == nil
               && BrowserHistoryIconLoader.source(for: "https://user:secret@example.com") == nil,
               "History fallback never fetches privileged or credential-bearing URLs")

        let path = output.appendingPathComponent("icons/history.sqlite")
        var fallback: CheckedContinuation<NSImage?, Never>?
        func waitForFallback() async throws -> CheckedContinuation<NSImage?, Never> {
            let deadline = ContinuousClock.now + .seconds(2)
            while fallback == nil {
                guard ContinuousClock.now < deadline else { fatalError("Missing controlled icon request") }
                try await Task.sleep(for: .milliseconds(5))
            }
            return fallback!
        }
        let history = BrowserHistoryStore(url: path) { _ in await withCheckedContinuation { fallback = $0 } }
        let a = BrowserHistoryVisit(id: UUID(), url: "https://icons.example/a", visitedAt: .now)
        let b = BrowserHistoryVisit(id: UUID(), url: "https://icons.example/b", visitedAt: .now)
        let repeatA = BrowserHistoryVisit(id: UUID(), url: a.url, visitedAt: .now)
        for visit in [a, b, repeatA] { history.record(visit) }
        history.updateIcon(color, visitID: repeatA.id)
        await history.flush()
        let saved = try await history.page(before: nil)
        expect(saved.entries.filter { $0.url == a.url }.allSatisfy { $0.icon == payload }
               && saved.entries.first { $0.url == b.url }?.icon == nil,
               "Repeated visits share their page's icon without replacing another path on the same site")
        let reopened = BrowserHistoryStore(url: path) { _ in fatalError("Saved icons must not fetch again") }
        let reopenedPage = try await reopened.page(before: nil)
        let offlineImage = await reopened.icon(for: reopenedPage.entries.first { $0.url == a.url }!)
        expect(offlineImage != nil, "The real icon remains available offline after reopening the history database")
        history.clearRecent()
        await history.flush()
        let afterRecentClear = try await history.page(before: nil)
        expect(history.recent.isEmpty && afterRecentClear.entries.contains { $0.icon == payload },
               "Clearing only recent pages preserves icons for the complete history")

        let oldB = saved.entries.first { $0.url == b.url }!
        let request = Task { await history.icon(for: oldB) }
        let finish = try await waitForFallback()
        history.updateIcon(template, visitID: b.id)
        await history.flush()
        finish.resume(returning: color)
        _ = await request.value
        await history.flush()
        let afterFallback = try await history.page(before: nil)
        expect(afterFallback.entries.first { $0.url == b.url }?.icon == templatePayload,
               "A late origin fallback cannot overwrite a newer page-declared native icon")

        fallback = nil
        let late = Task { await history.icon(for: oldB) }
        let finishLate = try await waitForFallback()
        history.clear(.all)
        history.updateIcon(color, visitID: a.id)
        await history.flush()
        finishLate.resume(returning: color)
        _ = await late.value
        await history.flush()
        let replacement = BrowserHistoryVisit(id: UUID(), url: b.url, visitedAt: .now)
        history.record(replacement)
        await history.flush()
        let afterClear = try await history.page(before: nil)
        expect(afterClear.entries.count == 1 && afterClear.entries[0].icon == nil,
               "Deleting history removes orphaned icons and rejects late native/network writes")
    }

    @MainActor private static func checkPresentation(output: URL) async throws {
        _ = NSApplication.shared
        CaptureRun.defaults?.set(true, forKey: "performanceMode")
        let history = BrowserHistoryStore(url: output.appendingPathComponent("presentation/history.sqlite"), iconLoader: { _ in nil })
        let samples = [
            ("https://github.com/111-test-111/omp-gui-native", "OMP GUI Native · GitHub"),
            ("https://developer.apple.com/documentation/swiftui", "SwiftUI Documentation — Apple Developer"),
            ("https://www.swift.org/documentation/", "Swift Documentation"),
            ("https://example.com/research", "浏览器设计与原生界面布局参考"),
            ("https://localhost:3000/preview", "Workspace preview"),
            ("https://example.org/notes", "Project notes")
        ]
        for index in 0..<20 {
            let sample = samples[index % samples.count]
            let visit = BrowserHistoryVisit(id: UUID(), url: sample.0, visitedAt: Date.now.addingTimeInterval(Double(index - 19) * 1_200))
            history.record(visit)
            history.updateTitle(sample.1, visitID: visit.id)
            history.updateIcon(iconFixture(template: index.isMultiple(of: 2)), visitID: visit.id)
        }
        await history.flush()
        let workspace = BrowserWorkspaceStore(threadID: UUID(), history: history)
        let page = try workspace.open(materialize: false)
        for language in ["en", "zh-Hans"] {
            let bundle = BrowserLocalization.localizedBundle(for: language)
            for key in ["Recently opened", "Clear recent pages", "Browsing history", "Browsing preferences", "Clear browsing history?", "No browsing history",
                        "Delete browsing history for %@? Matching recent pages will also be removed. Chrome's original history, cookies and open tabs are kept."] {
                expect(language == "en" || Chrome.localized(key, bundle: bundle) != key, "New history controls have packaged Chinese translations")
            }
        }
        // The helper has no main-app resource bundle. Verify translations above;
        // layout snapshots use English and the production solid-material fallback.
        for dark in [false, true] {
            ThemeManager.current = dark ? .dark : .light
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let scheme: ColorScheme = dark ? .dark : .light
            let label = dark ? "dark" : "light"
            let width = dark ? 640.0 : 300.0
            let content = BrowserNewTabPage(page: page, searchEngine: .google)
                .environment(\.colorScheme, scheme)
            try await capture(AnyView(content), name: "new-tab-\(label)-\(Int(width))", width: width, height: 620, output: output)
            let section = BrowserHistorySection(history: history)
                .environment(\.colorScheme, scheme)
                .padding(16).background(Color(nsColor: .textBackgroundColor))
            try await capture(AnyView(section), name: "history-\(label)", width: 560, height: 500, output: output,
                              checkHistoryLayout: true)
        }
        ThemeManager.current = .light
        NSApp.appearance = NSAppearance(named: .aqua)
        let small = BrowserHistoryStore(url: output.appendingPathComponent("small-history/history.sqlite"), iconLoader: { _ in nil })
        func smallView() -> AnyView {
            AnyView(BrowserHistorySection(history: small).environment(\.colorScheme, .light)
                .padding(16).background(Color(nsColor: .textBackgroundColor)))
        }
        let emptySize = try await capture(smallView(), name: "history-empty", width: 560, height: 500, output: output,
                                         checkHistoryLayout: true)
        small.record(.init(id: UUID(), url: "https://example.com/first", visitedAt: .now))
        await small.flush()
        let oneSize = try await capture(smallView(), name: "history-one", width: 560, height: 500, output: output,
                                       checkHistoryLayout: true)
        for index in 1...2 { small.record(.init(id: UUID(), url: "https://example.com/\(index)", visitedAt: .now)) }
        await small.flush()
        let threeSize = try await capture(smallView(), name: "history-three", width: 560, height: 500, output: output,
                                         checkHistoryLayout: true)
        expect(oneSize.height < emptySize.height && oneSize.height < threeSize.height && threeSize.height < 360,
               "The native history card shrinks for one entry and grows for three, retaining the empty-state height")
        expect(page.host == nil && workspace.pages.count == 1, "Recent/history presentation does not create browser targets or extra tabs")
    }

    @discardableResult
    @MainActor private static func capture(_ view: AnyView, name: String, width: Double, height: Double, output: URL,
                                          checkHistoryLayout: Bool = false) async throws -> NSSize {
        let frame = NSRect(x: 0, y: 0, width: width, height: height)
        // Settings supplies a column width. A non-scrolling stack's unconstrained
        // ideal width includes full page titles, so measure at that same width.
        let host = NSHostingView(rootView: view.frame(width: width))
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = frame
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        expect(host.fittingSize.width <= width + 1, "History content fits the requested narrow/wide native viewport")
        if checkHistoryLayout {
            func hasScrollView(_ view: NSView) -> Bool {
                view is NSScrollView || view.subviews.contains(where: hasScrollView)
            }
            expect(!hasScrollView(host),
                   "History pagination has no internal scrolling region")
            expect(host.fittingSize.height <= height, "History, its page controls and header fit without clipping")
            // Invisible NSHostingView windows expose no accessibility children.
            // Real pointer/AX activation remains part of visible GUI acceptance;
            // the empty/loading/failure cleanup gate is checked on the store.
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No offscreen bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        expect(!window.isVisible, "History layout verification never shows a window")
        return host.fittingSize
    }
}
