import Foundation
import SQLite3

/// All database work stays off the main actor. The complete history is on disk;
/// callers only receive five recent pages or one keyset-paginated history page.
actor BrowserHistoryDatabase {
    let url: URL
    init(url: URL) { self.url = url }

    func record(_ visit: BrowserHistoryVisit) throws {
        let db = try Connection(url: url)
        try db.transaction {
            try db.execute("INSERT OR IGNORE INTO visits (token, url, title, visited_at) VALUES (?, ?, '', ?)",
                           [.text(visit.id.uuidString), .text(visit.url), .number(visit.visitedAt.timeIntervalSince1970)])
            guard sqlite3_changes(db.handle) > 0 else { return }
            try db.execute("INSERT INTO recent_pages (url, visit_id, visited_at) VALUES (?, ?, ?) ON CONFLICT(url) DO UPDATE SET visit_id = excluded.visit_id, visited_at = excluded.visited_at",
                           [.text(visit.url), .integer(sqlite3_last_insert_rowid(db.handle)), .number(visit.visitedAt.timeIntervalSince1970)])
        }
    }

    func updateTitle(_ title: String, visitID: UUID) throws {
        let db = try Connection(url: url)
        // UPDATE cannot resurrect visits or recent pages after either clear action.
        try db.execute("UPDATE visits SET title = ? WHERE token = ?", [.text(title), .text(visitID.uuidString)])
    }

    func updateIcon(_ icon: BrowserHistoryIcon, visitID: UUID) throws {
        try updateIcon(icon, matching: "token", value: .text(visitID.uuidString))
    }

    func updateIcon(_ icon: BrowserHistoryIcon, entryID: Int64) throws {
        try updateIcon(icon, matching: "id", value: .integer(entryID), onlyIfMissing: true)
    }

    private func updateIcon(_ icon: BrowserHistoryIcon, matching column: String, value: Value, onlyIfMissing: Bool = false) throws {
        guard icon.png.count <= BrowserHistoryIcon.maximumBytes else { return }
        let db = try Connection(url: url)
        // Bind the icon to an existing visit. A late native/network completion
        // must never bring deleted history (or an orphaned icon) back.
        let conflict = onlyIfMissing ? "DO NOTHING" : "DO UPDATE SET png = excluded.png, is_template = excluded.is_template"
        try db.execute("INSERT INTO page_icons (url, png, is_template) SELECT url, ?, ? FROM visits WHERE \(column) = ? ON CONFLICT(url) \(conflict)",
                       [.blob(icon.png), .integer(icon.isTemplate ? 1 : 0), value])
    }

    func recent() throws -> [BrowserHistoryEntry] {
        let db = try Connection(url: url)
        return try db.entries("SELECT v.id, v.url, v.title, v.visited_at, i.png, i.is_template, v.source, v.source_name FROM recent_pages r JOIN visits v ON v.id = r.visit_id LEFT JOIN page_icons i ON i.url = v.url ORDER BY r.visited_at DESC, r.visit_id DESC LIMIT 5")
    }

    func page(before cursor: BrowserHistoryCursor?, source: BrowserHistorySource = .all) throws -> BrowserHistoryPage {
        let db = try Connection(url: url)
        var bindings: [Value] = []
        var sql = "SELECT v.id, v.url, v.title, v.visited_at, i.png, i.is_template, v.source, v.source_name FROM visits v LEFT JOIN page_icons i ON i.url = v.url WHERE 1=1"
        if source != .all {
            sql += " AND v.source = ?"
            bindings.append(.text(source.rawValue))
        }
        if let cursor {
            sql += " AND (v.visited_at, v.id) < (?, ?)"
            bindings += [.number(cursor.date.timeIntervalSince1970), .integer(cursor.id)]
        }
        sql += " ORDER BY v.visited_at DESC, v.id DESC LIMIT \(BrowserHistoryPage.size + 1)"
        let entries = try db.entries(sql, bindings)
        return .init(entries: Array(entries.prefix(BrowserHistoryPage.size)), hasMore: entries.count > BrowserHistoryPage.size)
    }

    func clearRecent() throws {
        try Connection(url: url).execute("DELETE FROM recent_pages")
    }

    func remove(_ id: Int64) throws {
        let db = try Connection(url: url)
        try db.transaction {
            try db.invalidateImportPreviews()
            try db.execute("DELETE FROM visits WHERE id = ?", [.integer(id)])
            try db.removeOrphanedIcons()
        }
    }

    func clear(since: Date?, through date: Date, source: BrowserHistorySource = .all) throws {
        let db = try Connection(url: url)
        try db.transaction {
            try db.invalidateImportPreviews()
            var sql = "DELETE FROM visits WHERE 1=1"
            var values: [Value] = []
            if source != .all { sql += " AND source = ?"; values.append(.text(source.rawValue)) }
            if let since {
                sql += " AND visited_at >= ? AND visited_at <= ?"
                values += [.number(since.timeIntervalSince1970), .number(date.timeIntervalSince1970)]
            }
            try db.execute(sql, values)
            try db.removeOrphanedIcons()
        }
    }

    func previewImport(_ content: ChromeHistoryImport) throws -> ChromeHistoryImportPreview {
        let db = try Connection(url: url)
        var preview: ChromeHistoryImportPreview!
        try db.transaction {
            preview = .init(content: content, summary: try db.importRows(content, write: false),
                            cleanupRevision: try db.cleanupRevision())
        }
        return preview
    }

    func commitImport(_ preview: ChromeHistoryImportPreview) throws -> ChromeHistoryImportSummary {
        let db = try Connection(url: url)
        var result = ChromeHistoryImportSummary()
        try db.transaction {
            guard try db.cleanupRevision() == preview.cleanupRevision else { throw ChromeHistoryImportError.invalidated }
            result = try db.importRows(preview.content, write: true)
            try Task.checkCancellation()
        }
        return result
    }

    func resetImportExclusions(sourceID: String) throws {
        let db = try Connection(url: url)
        try db.transaction {
            try db.invalidateImportPreviews()
            try db.execute("DELETE FROM chrome_import_receipts WHERE source_id = ? AND visit_id IS NULL", [.text(sourceID)])
        }
    }

    private enum Failure: Error { case storage }
    private enum Value { case text(String), integer(Int64), number(Double), blob(Data) }

    private final class Connection {
        let handle: OpaquePointer

        init(url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let existed = FileManager.default.fileExists(atPath: url.path)
            var connection: OpaquePointer?
            guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
                  let connection else {
                if let connection { sqlite3_close(connection) }
                throw Failure.storage
            }
            handle = connection
            if !existed { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            sqlite3_busy_timeout(handle, 1_000)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA secure_delete = ON")
            // Version 0 is the original native-only history database.
            var version: Int64 = 0
            try statement("PRAGMA user_version", []) {
                guard sqlite3_step($0) == SQLITE_ROW else { throw Failure.storage }
                version = sqlite3_column_int64($0, 0)
            }
            guard (0...1).contains(version) else { throw Failure.storage }
            if version == 0 {
                try transaction {
                    try execute("CREATE TABLE IF NOT EXISTS visits (id INTEGER PRIMARY KEY AUTOINCREMENT, token TEXT NOT NULL UNIQUE, url TEXT NOT NULL, title TEXT NOT NULL, visited_at REAL NOT NULL)")
                    try execute("CREATE INDEX IF NOT EXISTS visits_date ON visits (visited_at DESC, id DESC)")
                    try execute("CREATE INDEX IF NOT EXISTS visits_url ON visits (url)")
                    try execute("CREATE TABLE IF NOT EXISTS page_icons (url TEXT PRIMARY KEY, png BLOB NOT NULL, is_template INTEGER NOT NULL)")
                    try execute("CREATE TABLE IF NOT EXISTS recent_pages (url TEXT PRIMARY KEY, visit_id INTEGER NOT NULL REFERENCES visits(id) ON DELETE CASCADE, visited_at REAL NOT NULL)")
                    try execute("CREATE INDEX IF NOT EXISTS recent_pages_date ON recent_pages (visited_at DESC, visit_id DESC)")
                    try execute("CREATE INDEX IF NOT EXISTS recent_pages_visit ON recent_pages (visit_id)")
                    try execute("ALTER TABLE visits ADD COLUMN source TEXT NOT NULL DEFAULT 'gui'")
                    try execute("ALTER TABLE visits ADD COLUMN source_name TEXT NOT NULL DEFAULT ''")
                    try execute("CREATE INDEX visits_source_date ON visits(source, visited_at DESC, id DESC)")
                    try execute("CREATE TABLE history_metadata (key TEXT PRIMARY KEY, value INTEGER NOT NULL)")
                    try execute("INSERT INTO history_metadata VALUES ('cleanup_revision', 0)")
                    // SET NULL is intentional: deletion keeps only an opaque import
                    // identity, never the removed URL, title, time or icon.
                    try execute("CREATE TABLE chrome_import_receipts (source_id TEXT NOT NULL, fingerprint TEXT NOT NULL, visit_id INTEGER REFERENCES visits(id) ON DELETE SET NULL, PRIMARY KEY(source_id, fingerprint))")
                    try execute("CREATE INDEX chrome_import_receipts_visit ON chrome_import_receipts(visit_id)")
                    try execute("CREATE TABLE chrome_import_batches (id TEXT PRIMARY KEY, source_id TEXT NOT NULL, completed_at REAL NOT NULL, added INTEGER NOT NULL)")
                    try execute("PRAGMA user_version = 1")
                }
            }
        }

        deinit { sqlite3_close(handle) }

        func statement(_ sql: String, _ values: [Value], body: (OpaquePointer) throws -> Void) throws {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw Failure.storage }
            defer { sqlite3_finalize(prepared) }
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                case .text(let text):
                    result = text.withCString { sqlite3_bind_text(prepared, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                case .integer(let number): result = sqlite3_bind_int64(prepared, index, number)
                case .number(let number): result = sqlite3_bind_double(prepared, index, number)
                case .blob(let data):
                    result = data.withUnsafeBytes {
                        sqlite3_bind_blob(prepared, index, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                    }
                }
                guard result == SQLITE_OK else { throw Failure.storage }
            }
            try body(prepared)
        }

        func execute(_ sql: String, _ values: [Value] = []) throws {
            try statement(sql, values) { statement in
                var result = sqlite3_step(statement)
                while result == SQLITE_ROW { result = sqlite3_step(statement) }
                guard result == SQLITE_DONE else { throw Failure.storage }
            }
        }

        func entries(_ sql: String, _ values: [Value] = []) throws -> [BrowserHistoryEntry] {
            var entries: [BrowserHistoryEntry] = []
            try statement(sql, values) { statement in
                var result = sqlite3_step(statement)
                while result == SQLITE_ROW {
                    guard let url = sqlite3_column_text(statement, 1), let title = sqlite3_column_text(statement, 2) else { throw Failure.storage }
                    let count = Int(sqlite3_column_bytes(statement, 4))
                    let icon: BrowserHistoryIcon?
                    if count > 0, count <= BrowserHistoryIcon.maximumBytes, let bytes = sqlite3_column_blob(statement, 4) {
                        icon = .init(png: Data(bytes: bytes, count: count), isTemplate: sqlite3_column_int(statement, 5) != 0)
                    } else { icon = nil }
                    entries.append(.init(id: sqlite3_column_int64(statement, 0), url: String(cString: url), title: String(cString: title),
                                         visitedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)), icon: icon,
                                         source: sqlite3_column_text(statement, 6).flatMap { BrowserHistorySource(rawValue: String(cString: $0)) } ?? .gui,
                                         sourceName: sqlite3_column_text(statement, 7).map { String(cString: $0) } ?? ""))
                    result = sqlite3_step(statement)
                }
                guard result == SQLITE_DONE else { throw Failure.storage }
            }
            return entries
        }

        func transaction(_ body: () throws -> Void) throws {
            try execute("BEGIN IMMEDIATE")
            do { try body(); try execute("COMMIT") }
            catch { try? execute("ROLLBACK"); throw error }
        }

        func removeOrphanedIcons() throws {
            try execute("DELETE FROM page_icons WHERE NOT EXISTS (SELECT 1 FROM visits WHERE visits.url = page_icons.url)")
        }

        func cleanupRevision() throws -> Int64 {
            var value: Int64 = 0
            try statement("SELECT value FROM history_metadata WHERE key = 'cleanup_revision'", []) {
                guard sqlite3_step($0) == SQLITE_ROW else { throw Failure.storage }
                value = sqlite3_column_int64($0, 0)
            }
            return value
        }

        func invalidateImportPreviews() throws {
            try execute("UPDATE history_metadata SET value = value + 1 WHERE key = 'cleanup_revision'")
        }

        func importRows(_ content: ChromeHistoryImport, write: Bool) throws -> ChromeHistoryImportSummary {
            guard content.visits.count <= ChromeHistoryImport.maximumVisits else { throw ChromeHistoryImportError.source(.tooLarge) }
            var summary = ChromeHistoryImportSummary(skipped: content.skipped)
            let sourceID = content.profile.historySourceID
            var seen = Set<String>()
            for visit in content.visits {
                try Task.checkCancellation()
                let fingerprint = visit.fingerprint
                guard seen.insert(fingerprint).inserted else { summary.existing += 1; continue }
                var exists = false, deleted = false
                try statement("SELECT visit_id FROM chrome_import_receipts WHERE source_id = ? AND fingerprint = ?",
                              [.text(sourceID), .text(fingerprint)]) {
                    let result = sqlite3_step($0)
                    guard result == SQLITE_ROW || result == SQLITE_DONE else { throw Failure.storage }
                    exists = result == SQLITE_ROW
                    deleted = exists && sqlite3_column_type($0, 0) == SQLITE_NULL
                }
                if exists {
                    if deleted { summary.deleted += 1 } else { summary.existing += 1 }
                    continue
                }
                summary.added += 1
                guard write else { continue }
                try execute("INSERT INTO visits (token, url, title, visited_at, source, source_name) VALUES (?, ?, ?, ?, 'chrome', ?)",
                            [.text(UUID().uuidString), .text(visit.url), .text(visit.title), .number(visit.visitedAt.timeIntervalSince1970),
                             .text(content.profile.name + " · " + content.profile.directoryName)])
                try execute("INSERT INTO chrome_import_receipts VALUES (?, ?, ?)",
                            [.text(sourceID), .text(fingerprint), .integer(sqlite3_last_insert_rowid(handle))])
                if let icon = content.icons[visit.url], icon.png.count <= BrowserHistoryIcon.maximumBytes {
                    try execute("INSERT INTO page_icons VALUES (?, ?, ?) ON CONFLICT(url) DO NOTHING",
                                [.text(visit.url), .blob(icon.png), .integer(icon.isTemplate ? 1 : 0)])
                }
            }
            if write, summary.added > 0 {
                try execute("INSERT INTO chrome_import_batches VALUES (?, ?, ?, ?)",
                            [.text(UUID().uuidString), .text(sourceID), .number(Date.now.timeIntervalSince1970), .integer(Int64(summary.added))])
            }
            return summary
        }
    }
}
