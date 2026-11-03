import Foundation
import SQLite3

enum ChromeHistorySource {
    struct ReadResult: Sendable {
        var content: ChromeHistoryImport
        var iconData: [String: Data]
    }

    static func profiles(root: URL = ChromeSourceDatabase.defaultRoot) throws -> [ChromeSourceProfile] {
        try ChromeSourceDatabase.profiles(root: root, content: .history)
    }

    static func read(_ profile: ChromeSourceProfile, range: BrowserHistoryRange = .all,
                     now: Date = .now) throws -> ReadResult {
        guard ChromeSourceDatabase.validName(profile.name),
              let path = try ChromeSourceDatabase.database(root: profile.root, directory: profile.directoryName, content: .history)
        else { throw ChromeSourceError.noProfiles }
        let visits = try readVisits(path, since: range.start(now: now), now: now)
        try Task.checkCancellation()
        var icons: [String: Data] = [:]
        if let path = try ChromeSourceDatabase.database(root: profile.root, directory: profile.directoryName, content: .favicons) {
            do { icons = try readIcons(path, urls: Set(visits.rows.map(\.url))) }
            catch ChromeSourceError.invalidDatabase { /* Optional favicon cache may be damaged. */ }
            catch ChromeHistoryImportError.unsupportedDatabase { }
        }
        return .init(content: .init(profile: profile, visits: visits.rows, skipped: visits.skipped), iconData: icons)
    }

    private static func readVisits(_ path: URL, since: Date?, now: Date) throws -> (rows: [ChromeHistoryImport.Visit], skipped: Int) {
        let db = try ChromeSourceDatabase.snapshot(path)
        let budget = ChromeSQLiteBudget()
        budget.install(db)
        defer { withExtendedLifetime(budget) { sqlite3_close(db) } }
        try requireColumns(db, table: "urls", names: ["id", "url", "title"])
        try requireColumns(db, table: "visits", names: ["id", "url", "visit_time", "transition"])
        let statement = try ChromeSourceDatabase.prepare(db, """
            SELECT v.id, v.visit_time, u.url, u.title, v.transition
            FROM visits v LEFT JOIN urls u ON u.id = v.url
            WHERE v.visit_time >= ? AND v.visit_time <= ?
            ORDER BY v.visit_time DESC, v.id DESC
            """)
        defer { sqlite3_finalize(statement) }
        let epoch = ChromeHistoryImport.windowsEpochMicroseconds
        sqlite3_bind_int64(statement, 1, since.map { Int64($0.timeIntervalSince1970 * 1_000_000) + epoch } ?? epoch)
        sqlite3_bind_int64(statement, 2, Int64(now.timeIntervalSince1970 * 1_000_000) + epoch)
        var rows: [ChromeHistoryImport.Visit] = [], skipped = 0, total = 0, bytes = 0
        while try next(statement) {
            total += 1
            guard total <= ChromeHistoryImport.maximumVisits else { throw ChromeSourceError.tooLarge }
            let transition = sqlite3_column_int64(statement, 4)
            let core = transition & 0xff
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 4) == SQLITE_INTEGER,
                  sqlite3_column_int64(statement, 0) > 0,
                  core != 3, core != 4, transition & 0x20000000 != 0,
                  let url = text(statement, 2, maximum: 16_384),
                  let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                  BrowserAddress.resolve(url) != nil,
                  let title = sqlite3_column_type(statement, 3) == SQLITE_NULL ? "" : text(statement, 3, maximum: 16_384)
            else { skipped += 1; continue }
            bytes += url.utf8.count + title.utf8.count
            guard bytes <= ChromeHistoryImport.maximumTextBytes else { throw ChromeSourceError.tooLarge }
            rows.append(.init(sourceID: sqlite3_column_int64(statement, 0), time: sqlite3_column_int64(statement, 1),
                              url: url, title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))))
        }
        return (rows, skipped)
    }

    private static func readIcons(_ path: URL, urls: Set<String>) throws -> [String: Data] {
        guard !urls.isEmpty else { return [:] }
        let db = try ChromeSourceDatabase.snapshot(path)
        let budget = ChromeSQLiteBudget()
        budget.install(db)
        defer { withExtendedLifetime(budget) { sqlite3_close(db) } }
        try requireColumns(db, table: "icon_mapping", names: ["page_url", "icon_id"])
        try requireColumns(db, table: "favicon_bitmaps", names: ["id", "icon_id", "image_data", "width", "height"])
        let statement = try ChromeSourceDatabase.prepare(db, """
            SELECT m.page_url, b.image_data FROM icon_mapping m
            JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
            WHERE b.width > 0 AND b.height > 0 AND length(b.image_data) <= 1048576
            ORDER BY abs(b.width - 32) + abs(b.height - 32), b.id DESC
            """)
        defer { sqlite3_finalize(statement) }
        var icons: [String: Data] = [:], bytes = 0, count = 0
        while try next(statement) {
            count += 1
            guard count <= ChromeHistoryImport.maximumVisits else { break }
            guard let url = text(statement, 0, maximum: 16_384), urls.contains(url), icons[url] == nil,
                  sqlite3_column_type(statement, 1) == SQLITE_BLOB,
                  let blob = sqlite3_column_blob(statement, 1) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 1))
            guard length > 0, bytes + length <= ChromeHistoryImport.maximumIconBytes else { continue }
            icons[url] = Data(bytes: blob, count: length)
            bytes += length
        }
        return icons
    }

    private static func requireColumns(_ db: OpaquePointer, table: String, names: Set<String>) throws {
        let statement = try ChromeSourceDatabase.prepare(db, "PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while try next(statement) { if let name = text(statement, 1, maximum: 256) { columns.insert(name) } }
        guard names.isSubset(of: columns) else { throw ChromeHistoryImportError.unsupportedDatabase }
    }

    private static func next(_ statement: OpaquePointer) throws -> Bool {
        try Task.checkCancellation()
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return false }
        guard result == SQLITE_ROW else { try ChromeSourceDatabase.failSQLite(result) }
        return true
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32, maximum: Int) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= maximum else { return nil }
        if count == 0 { return "" }
        guard let pointer = sqlite3_column_text(statement, column),
              let value = String(data: Data(bytes: pointer, count: count), encoding: .utf8),
              !value.contains("\u{0}") else { return nil }
        return value
    }
}
