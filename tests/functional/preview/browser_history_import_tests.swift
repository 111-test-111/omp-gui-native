import AppKit
import SQLite3
import SwiftUI
@testable import OMPGUI

@main private enum BrowserHistoryImportChecks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }

    @MainActor static func main() async throws {
        guard let output = CaptureRun.outputDirectory else { fatalError("Isolated capture required") }
        let now = Date.now
        let fixture = try HistoryFixture(root: output.appendingPathComponent("chrome"), now: now)
        try fixture.visit(1, url: "https://example.test/a?q=中文", title: "中文 'history'", offset: -120)
        try fixture.visit(2, url: "https://example.test/a?q=中文", title: "中文 'history'", offset: -60)
        try fixture.visit(3, url: "https://example.test/null-title", title: nil, offset: -30)
        for (index, url) in ["about:blank", "file:///tmp/private", "https://user:secret@example.test"].enumerated() {
            try fixture.visit(Int64(index + 4), url: url, offset: -10)
        }
        try fixture.visit(7, transition: 0x20000003)
        try fixture.visit(8, transition: 0x20000004)
        try fixture.visit(9, transition: 0x10000000)
        try fixture.visit(10, offset: -90_000)
        try fixture.visit(11, offset: 60)
        try fixture.execute("INSERT INTO visits VALUES (12, 999, \(fixture.time), 536870912)")
        try fixture.execute("INSERT INTO urls VALUES (13, 'https://example.test/bad-title', CAST(x'ff' AS TEXT)); INSERT INTO visits VALUES (13, 13, \(fixture.time), 536870912)")
        try fixture.visit(14, offset: -1, microseconds: 1)
        try fixture.visit(15, offset: -1, microseconds: 2)
        let profiles = try ChromeHistorySource.profiles(root: fixture.root)
        expect(profiles.count == 1 && profiles[0].name == "工作 Chrome",
               "History-only Chrome profiles are found without a Cookies database")
        let profile = profiles[0]
        let before = try Data(contentsOf: fixture.file)
        let wal = try Data(contentsOf: URL(fileURLWithPath: fixture.file.path + "-wal"))
        let read = try ChromeHistorySource.read(profile, now: now)
        expect(read.content.visits.count == 6 && read.content.skipped == 8,
               "Each valid main-frame terminal visit is imported; internal, credential, iframe, redirect and malformed rows are skipped")
        expect(read.content.visits.filter { $0.url == "https://example.test/a?q=中文" }.count == 2,
               "Repeated genuine visits to the same URL stay separate")
        expect(read.content.visits.first { $0.sourceID == 3 }?.title == "",
               "A missing Chrome title falls back to the page's host")
        expect(try Data(contentsOf: fixture.file) == before
               && Data(contentsOf: URL(fileURLWithPath: fixture.file.path + "-wal")) == wal,
               "Reading a committed WAL never rewrites Chrome source bytes")
        let precise = read.content.visits.filter { [14, 15].contains($0.sourceID) }
        expect(precise.count == 2 && Set(precise.map(\.fingerprint)).count == 2
               && abs(precise[0].visitedAt.timeIntervalSince(precise[1].visitedAt) - 0.000001) < 0.0000003,
               "Integer Chrome microseconds retain distinct identities and convert from the 1601 epoch")
        let hour = try ChromeHistorySource.read(profile, range: .hour, now: now)
        expect(hour.content.visits.count == 5, "The selected time range excludes older visits without inventing new timestamps")
        let renamed = ChromeSourceProfile(root: profile.root, directoryName: profile.directoryName, name: "Renamed")
        expect(renamed.historySourceID == profile.historySourceID, "Renaming a Chrome profile does not repeat its imports")
        let cancelled = Task { try Task.checkCancellation(); return try ChromeHistorySource.read(profile, now: now) }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled source read succeeded") }
        catch is CancellationError { expect(true, "Cancellation stops source preparation") }

        let icon = imageFixture()
        let png = BrowserHistoryIconCodec.encode(icon)!.png
        try fixture.icons(png, url: "https://example.test/a?q=中文")
        let withIcons = try ChromeHistorySource.read(profile, now: now)
        expect(withIcons.iconData["https://example.test/a?q=中文"] == png,
               "Chrome's own favicon bytes are matched by page URL without a network request")
        try fixture.iconSQL("DROP TABLE favicon_bitmaps")
        expect(try ChromeHistorySource.read(profile, now: now).content.visits.count == 6,
               "An unavailable optional favicon schema does not discard valid history")
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("Favicons"))
        try fixture.icons(png, url: "https://example.test/a?q=中文")

        let unsupported = try HistoryFixture(root: output.appendingPathComponent("unsupported"), now: now)
        try unsupported.execute("DROP TABLE visits; CREATE TABLE visits (id INTEGER)")
        do { _ = try ChromeHistorySource.read(unsupported.profile, now: now); fatalError("Unsupported schema accepted") }
        catch ChromeHistoryImportError.unsupportedDatabase { expect(true, "Unknown source columns fail before any destination writes") }
        let linked = fixture.root.appendingPathComponent("Profile 9")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.directory)
        do { _ = try ChromeHistorySource.profiles(root: fixture.root); fatalError("Symlink accepted") }
        catch ChromeSourceError.invalidDatabase { expect(true, "Profile discovery does not follow directory symlinks") }
        try FileManager.default.removeItem(at: linked)

        try await coexistence(output: output, content: read.content, png: png, now: now)
        try await atomicity(output: output, content: read.content, now: now)
        try await migration(output: output, now: now)
        try await presentation(output: output, fixture: fixture)
        print("PASS browser history import: \(checks) assertions; synthetic SQLite and hidden native views only")
    }

    @MainActor private static func coexistence(output: URL, content: ChromeHistoryImport, png: Data, now: Date) async throws {
        let path = output.appendingPathComponent("destination/history.sqlite")
        let history = BrowserHistoryStore(url: path, iconLoader: { _ in fatalError("Import cannot fetch icons") })
        let native = BrowserHistoryVisit(id: UUID(), url: content.visits[0].url, visitedAt: now)
        history.record(native)
        history.updateTitle("Native title", visitID: native.id)
        history.updateIcon(.init(png: png, isTemplate: false), visitID: native.id)
        await history.flush()
        let recent = history.recent
        let nativeBefore = try await history.page(before: nil, source: .gui).entries
        let preview = try await history.previewImport(content)
        expect(preview.summary.added == 6 && preview.summary.skipped == 8, "Preview counts new and skipped visits without importing them")
        expect(try await history.page(before: nil).entries == nativeBefore, "Preview never changes native history")
        let secondPreview = try await history.previewImport(content)
        let added = try await history.commitImport(preview)
        expect(added.added == 6 && history.recent == recent, "Import keeps the recent-five list unchanged")
        expect(try await history.page(before: nil, source: .gui).entries == nativeBefore,
               "Native timestamps, titles and icons survive import even at the same URL")
        let imported = try await history.page(before: nil, source: .chrome).entries
        expect(imported.count == 6 && imported.allSatisfy { $0.source == .chrome && $0.sourceName == "工作 Chrome · Default" },
               "Imported visits carry their source and profile in the shared timeline")
        expect(imported.map(\.visitedAt) == content.visits.map(\.visitedAt), "Imported visits preserve the original chronological order")
        let repeated = try await history.commitImport(secondPreview)
        expect(repeated.added == 0 && repeated.existing == 6, "A concurrent stale preview rechecks identities inside the write transaction")
        history.remove(imported[0].id)
        await history.flush()
        let afterSingle = try await history.previewImport(content)
        expect(afterSingle.summary.deleted == 1 && afterSingle.summary.added == 0, "Deleting one visit leaves a persistent exclusion")
        history.clear(.hour, now: now, source: .chrome)
        await history.flush()
        let afterRange = try await history.previewImport(content)
        expect(afterRange.summary.deleted == 5 && afterRange.summary.existing == 1,
               "Time-limited Chrome cleanup excludes only matching original visits")
        expect(history.recent == recent, "Chrome-only cleanup leaves native recent pages intact")
        history.clear(.all, source: .chrome)
        await history.flush()
        let reopened = BrowserHistoryStore(url: path, iconLoader: { _ in nil })
        let afterAll = try await reopened.previewImport(content)
        expect(afterAll.summary.deleted == 6 && afterAll.summary.added == 0,
               "Cleared Chrome records remain excluded after reopening the destination")
        _ = try await reopened.commitImport(afterAll)
        expect(try await reopened.page(before: nil).entries == nativeBefore, "Repeat import cannot restore deleted records or delete native visits")

        let fresh = ChromeHistoryImport.Visit(sourceID: content.visits[0].sourceID,
                                              time: content.visits[0].time + 10, url: content.visits[0].url, title: "Later visit")
        let newContent = ChromeHistoryImport(profile: content.profile, visits: content.visits + [fresh], skipped: 0)
        expect(try await reopened.commitImport(reopened.previewImport(newContent)).added == 1,
               "A genuinely later visit remains importable even when Chrome reuses a visit ID")
        let other = ChromeSourceProfile(root: content.profile.root, directoryName: "Profile 1", name: "Other")
        let otherContent = ChromeHistoryImport(profile: other, visits: content.visits, skipped: 0)
        expect(try await reopened.commitImport(reopened.previewImport(otherContent)).added == 6,
               "Independent Chrome profiles have independent visit identities")
        reopened.clear(.all, source: .chrome)
        await reopened.flush()
        try await reopened.resetImportExclusions(sourceID: content.profile.historySourceID)
        let resetPrimary = try await reopened.previewImport(newContent)
        let keptOther = try await reopened.previewImport(otherContent)
        expect(resetPrimary.summary.added == 7 && keptOther.summary.deleted == 6,
               "Explicit exclusion reset applies only to the selected Chrome profile")
        _ = try await reopened.commitImport(reopened.previewImport(newContent))
        expect(try await reopened.commitImport(reopened.previewImport(newContent)).added == 0,
               "Resetting exclusions does not disable duplicate protection")
        reopened.clearRecent()
        await reopened.flush()
        _ = try await reopened.commitImport(reopened.previewImport(newContent))
        expect(reopened.recent.isEmpty, "Import never repopulates an explicitly cleared recent list")
        reopened.record(.init(id: UUID(), url: fresh.url, visitedAt: now.addingTimeInterval(10)))
        await reopened.flush()
        expect(reopened.recent.count == 1, "A later actual GUI visit can populate recent pages normally")
        let list = BrowserHistoryListStore()
        await list.refresh(history: reopened, source: .chrome)
        expect(list.page.entries.allSatisfy { $0.source == .chrome }, "The native history page respects its source filter")
        list.older()
        await list.refresh(history: reopened, source: .gui)
        expect(list.number == 1 && list.page.entries.count == 2 && list.canClear, "Changing source resets paging to that source's newest visits")
        reopened.clear(.all)
        await reopened.flush()
        await list.refresh(history: reopened, source: .chrome)
        expect(!list.canClear && list.page.entries.isEmpty, "Empty filtered history cannot open cleanup")
    }

    @MainActor private static func atomicity(output: URL, content: ChromeHistoryImport, now: Date) async throws {
        let path = output.appendingPathComponent("atomic/history.sqlite")
        let database = BrowserHistoryDatabase(url: path)
        let preview = try await database.previewImport(content)
        try await database.record(.init(id: UUID(), url: "https://native.test", visitedAt: now))
        expect(try await database.commitImport(preview).added == 6, "Native browsing during preview remains compatible with import")
        let beforeClear = try await database.previewImport(content)
        let secondConnection = BrowserHistoryDatabase(url: path)
        try await secondConnection.clear(since: nil, through: now, source: .chrome)
        do { _ = try await database.commitImport(beforeClear); fatalError("Stale cleanup revision accepted") }
        catch ChromeHistoryImportError.invalidated { expect(true, "Cleanup in another store invalidates an outstanding preview before writing") }
        try await database.resetImportExclusions(sourceID: content.profile.historySourceID)
        let cancelledPreview = try await database.previewImport(content)
        let cancelled = Task { try Task.checkCancellation(); return try await database.commitImport(cancelledPreview) }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled import succeeded") }
        catch is CancellationError { expect(true, "Cancellation before commit writes no imported visits") }
        try HistoryFixture.sql(path, """
            CREATE TRIGGER reject_second BEFORE INSERT ON visits WHEN NEW.source = 'chrome'
            AND (SELECT count(*) FROM visits WHERE source = 'chrome') >= 1
            BEGIN SELECT RAISE(ABORT, 'fixture rejection'); END;
            """)
        do { _ = try await database.commitImport(cancelledPreview); fatalError("Partial import accepted") }
        catch { expect(try await database.page(before: nil, source: .chrome).entries.isEmpty, "A failure after the first row rolls back the whole import") }
        expect(try await database.previewImport(content).summary.added == 6, "Failed imports leave no partial duplicate receipts")
        try HistoryFixture.sql(path, "DROP TRIGGER reject_second")
        expect(try await database.commitImport(cancelledPreview).added == 6, "Retry after a transactional failure imports the full batch")
        expect(try await database.page(before: nil, source: .gui).entries.count == 1, "Rollback never disturbs concurrent native browsing")
    }

    @MainActor private static func migration(output: URL, now: Date) async throws {
        let old = output.appendingPathComponent("legacy.sqlite")
        try HistoryFixture.sql(old, """
            CREATE TABLE visits (id INTEGER PRIMARY KEY AUTOINCREMENT, token TEXT NOT NULL UNIQUE, url TEXT NOT NULL, title TEXT NOT NULL, visited_at REAL NOT NULL);
            CREATE TABLE recent_pages (url TEXT PRIMARY KEY, visit_id INTEGER NOT NULL REFERENCES visits(id) ON DELETE CASCADE, visited_at REAL NOT NULL);
            CREATE TABLE page_icons (url TEXT PRIMARY KEY, png BLOB NOT NULL, is_template INTEGER NOT NULL);
            INSERT INTO visits VALUES (1, 'old-token', 'https://old.test', 'Before migration', \(now.timeIntervalSince1970));
            INSERT INTO recent_pages VALUES ('https://old.test', 1, \(now.timeIntervalSince1970));
            INSERT INTO page_icons VALUES ('https://old.test', x'000102', 1);
            """)
        let database = BrowserHistoryDatabase(url: old)
        let entries = try await database.page(before: nil, source: .gui).entries
        expect(entries.count == 1 && entries[0].title == "Before migration" && entries[0].icon?.isTemplate == true,
               "Version-zero migration preserves native records and their icon bytes")
        expect(try await database.recent() == entries, "Migration preserves recent-page identity and ordering")
        let future = output.appendingPathComponent("future.sqlite")
        try HistoryFixture.sql(future, "PRAGMA user_version = 999; CREATE TABLE untouched (id INTEGER)")
        let bytes = try Data(contentsOf: future)
        do { _ = try await BrowserHistoryDatabase(url: future).page(before: nil); fatalError("Future schema accepted") }
        catch { expect(try Data(contentsOf: future) == bytes, "A future destination schema is refused without rewriting it") }
    }

    @MainActor private static func presentation(output: URL, fixture: HistoryFixture) async throws {
        _ = NSApplication.shared
        CaptureRun.defaults?.set(true, forKey: "performanceMode")
        let history = BrowserHistoryStore(url: output.appendingPathComponent("form/history.sqlite"), iconLoader: { _ in nil })
        let importer = ChromeHistoryImportStore(history: history, root: fixture.root)
        importer.discover()
        await importer.waitForOperation()
        expect(importer.selectedProfile != nil && !importer.isBusy, "The native import form discovers the local Chrome profile")
        importer.prepare()
        await importer.waitForOperation()
        expect(importer.preview?.summary.added == 6 && importer.errorKey == nil, "Preview prepares valid visits without creating a browser profile")
        let bundle = BrowserLocalization.localizedBundle(for: "zh-Hans")
        for key in ["Import Chrome history", "Import Chrome history…", "History source", "All sources", "Preview import",
                    "Import history", "Reset import exclusions…", "History import complete",
                    ChromeHistoryImportError.source(.snapshotBusy).messageKey, ChromeHistoryImportError.invalidated.messageKey] {
            expect(Chrome.localized(key, bundle: bundle) != key, "Import controls and failure guidance include packaged Chinese translations")
        }
        for dark in [false, true] {
            ThemeManager.current = dark ? .dark : .light
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await capture(importer, name: dark ? "import-dark" : "import-light", dark: dark, output: output)
        }
        importer.commit()
        await importer.waitForOperation()
        expect(importer.result?.added == 6 && importer.preview == nil && history.recent.isEmpty,
               "Native form completion reports its committed batch without changing recent pages")
        let pages = try await history.page(before: nil)
        expect(pages.entries.first { $0.url == "https://example.test/a?q=中文" }?.icon != nil,
               "Imported favicon bytes are normalized and saved with the visit")
        history.clear(.all, source: .chrome)
        await history.flush()
        importer.prepare()
        await importer.waitForOperation()
        expect(importer.preview?.summary.deleted == 6 && importer.preview?.summary.added == 0,
               "Repeat preview explains previously deleted visits")
        try await capture(importer, name: "import-exclusions", dark: false, output: output)
        importer.resetExclusions()
        await importer.waitForOperation()
        importer.prepare()
        await importer.waitForOperation()
        expect(importer.preview?.summary.added == 6, "Explicit user reset enables a fresh preview of deleted records")
        fixture.close()
        try fixture.reopenExclusive()
        importer.prepare()
        await importer.waitForOperation()
        expect(importer.errorKey == ChromeHistoryImportError.source(.snapshotBusy).messageKey && importer.preview == nil,
               "Chrome's exclusive database lock displays Quit Chrome completely, then retry")
        try await capture(importer, name: "import-chrome-busy", dark: false, output: output)
        let uiSize = TypeScale.shared.ui
        TypeScale.shared.ui = TypeScale.uiRange.upperBound
        try await capture(importer, name: "import-chrome-busy-large-type", dark: false, output: output)
        TypeScale.shared.ui = uiSize
        fixture.close()
        importer.prepare()
        await importer.waitForOperation()
        expect(importer.preview?.summary.added == 6 && importer.errorKey == nil, "Retry works after the source database is released")
        importer.prepare()
        importer.cancel()
        await importer.waitForOperation()
        expect(importer.preview == nil && !importer.isBusy, "Closing an unfinished preview cannot publish stale results")
    }

    @MainActor private static func imageFixture() -> NSImage {
        let image = NSImage(size: NSSize(width: 128, height: 128))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 112, height: 112), xRadius: 20, yRadius: 20).fill()
        image.unlockFocus()
        return BrowserHistoryIconCodec.downloaded(image.tiffRepresentation!)!
    }

    @MainActor private static func capture(_ importer: ChromeHistoryImportStore, name: String, dark: Bool, output: URL) async throws {
        ThemeManager.current = dark ? .dark : .light
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = ChromeHistoryImportForm(importer: importer, onComplete: {}, onClose: {})
            // A real popover supplies its window background. Include it in the
            // offscreen bitmap so transparent black/white text remains visible.
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        let frame = NSRect(x: 0, y: 0, width: 520, height: 620)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = frame
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        expect(host.fittingSize.width <= 521 && host.fittingSize.height <= 620, "Native import form and long errors fit their popover without clipping")
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Missing native snapshot") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        expect(!window.isVisible, "Presentation verification never opens the GUI")
    }
}

private final class HistoryFixture {
    let root: URL
    let directory: URL
    let file: URL
    let time: Int64
    var db: OpaquePointer?
    var profile: ChromeSourceProfile { .init(root: root, directoryName: "Default", name: "工作 Chrome") }
    init(root: URL, now: Date) throws {
        self.root = root
        directory = root.appendingPathComponent("Default")
        file = directory.appendingPathComponent("History")
        time = Int64(now.timeIntervalSince1970 * 1_000_000) + ChromeHistoryImport.windowsEpochMicroseconds
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"工作 Chrome"}}}}"#.utf8).write(to: root.appendingPathComponent("Local State"))
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { fatalError("Cannot create history fixture") }
        try execute("""
            PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;
            CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT);
            CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER, transition INTEGER);
            """)
    }
    func visit(_ id: Int64, url: String? = nil, title: String? = "Visit", offset: Int64 = -5,
               microseconds: Int64 = 0, transition: Int64 = 0x20000000) throws {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
        let page = quote(url ?? "https://example.test/\(id)")
        try execute("INSERT INTO urls VALUES (\(id), \(page), \(title.map(quote) ?? "NULL")); INSERT INTO visits VALUES (\(id), \(id), \(time + offset * 1_000_000 + microseconds), \(transition))")
    }
    func icons(_ data: Data, url: String) throws {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        try iconSQL("""
            CREATE TABLE icon_mapping (page_url TEXT, icon_id INTEGER);
            CREATE TABLE favicon_bitmaps (id INTEGER PRIMARY KEY, icon_id INTEGER, image_data BLOB, width INTEGER, height INTEGER);
            INSERT INTO icon_mapping VALUES ('\(url)', 1);
            INSERT INTO favicon_bitmaps VALUES (1, 1, x'\(hex)', 64, 64);
            """)
    }
    func iconSQL(_ sql: String) throws { try Self.sql(directory.appendingPathComponent("Favicons"), sql) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { fatalError("Fixture SQL: \(String(cString: sqlite3_errmsg(db)))") }
    }
    func reopenExclusive() throws {
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { fatalError("Cannot reopen fixture") }
        try execute("PRAGMA journal_mode = DELETE; PRAGMA locking_mode = EXCLUSIVE; BEGIN EXCLUSIVE")
    }
    func close() { if let db { sqlite3_close(db); self.db = nil } }
    deinit { close() }
    static func sql(_ file: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { fatalError("Cannot open fixture") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { fatalError("Fixture SQL: \(String(cString: sqlite3_errmsg(db)))") }
    }
}
