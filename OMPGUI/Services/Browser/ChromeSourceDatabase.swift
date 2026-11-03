import Darwin
import Foundation
import SQLite3

/// Bounded, read-only access shared by Chrome history and cookie import.
enum ChromeSourceDatabase {
    enum Content { case cookies, history, favicons }
    static var defaultRoot: URL {
        if let output = CaptureRun.outputDirectory { return output.appendingPathComponent("chrome", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }
    static let maximumSnapshotBytes = 128 * 1_024 * 1_024

    static func profiles(root: URL = defaultRoot, content: Content) throws -> [ChromeSourceProfile] {
        try Task.checkCancellation()
        _ = try checkedFile(root, directory: true)
        let state = root.appendingPathComponent("Local State")
        var labels: [String: String] = [:]
        if try exists(state) {
            _ = try checkedFile(state, directory: false)
            let file: FileHandle
            do { file = try FileHandle(forReadingFrom: state) }
            catch { throw fileAccessError(error) }
            defer { try? file.close() }
            let data: Data
            do { data = try file.read(upToCount: 4 * 1_024 * 1_024 + 1) ?? Data() }
            catch { throw fileAccessError(error) }
            guard data.count <= 4 * 1_024 * 1_024 else { throw ChromeSourceError.tooLarge }
            if let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let profile = value["profile"] as? [String: Any], let cache = profile["info_cache"] as? [String: [String: Any]] {
                for (directory, info) in cache {
                    if let name = info["name"] as? String, validName(name) { labels[directory] = name }
                }
            }
        }
        let entries: [URL]
        do { entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) }
        catch { throw fileAccessError(error) }
        guard entries.count <= 4_096 else { throw ChromeSourceError.tooLarge }
        var result: [ChromeSourceProfile] = []
        for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            try Task.checkCancellation()
            let directory = entry.lastPathComponent
            guard validDirectory(directory), directory == "Default" || directory.hasPrefix("Profile ") || labels[directory] != nil else { continue }
            guard try database(root: root, directory: directory, content: content) != nil else { continue }
            result.append(ChromeSourceProfile(root: root, directoryName: directory, name: labels[directory] ?? directory))
        }
        guard !result.isEmpty else { throw ChromeSourceError.noProfiles }
        return result
    }

    /// SQLite's backup API includes committed WAL pages. A pinned read transaction
    /// keeps all chunks at one point in time, even if Chrome writes concurrently.
    /// Never use immutable=1 (which would ignore a live WAL), cp or VACUUM here.
    static func snapshot(_ url: URL) throws -> OpaquePointer {
        try Task.checkCancellation()
        let before = try checkedFile(url, directory: false)
        guard before.st_size <= maximumSnapshotBytes else { throw ChromeSourceError.tooLarge }
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if try exists(sidecar) {
                let info = try checkedFile(sidecar, directory: false)
                guard info.st_size <= maximumSnapshotBytes else { throw ChromeSourceError.tooLarge }
            }
        }
        var source: OpaquePointer?, destination: OpaquePointer?
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw accessError() }
        close(descriptor)
        let opened = sqlite3_open_v2(url.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard opened == SQLITE_OK, let source else {
            if let source { sqlite3_close(source) }
            throw opened == SQLITE_PERM || opened == SQLITE_AUTH || errno == EACCES || errno == EPERM
                ? ChromeSourceError.permissionDenied : ChromeSourceError.invalidDatabase
        }
        defer { sqlite3_exec(source, "ROLLBACK", nil, nil, nil); sqlite3_close(source) }
        let budget = ChromeSQLiteBudget()
        budget.install(source)
        defer { withExtendedLifetime(budget) { sqlite3_progress_handler(source, 0, nil, nil) } }
        sqlite3_busy_timeout(source, 250)
        try execute(source, "PRAGMA query_only = ON; PRAGMA trusted_schema = OFF; BEGIN")
        _ = try scalar(source, "SELECT count(*) FROM sqlite_schema") // Pin the read snapshot before backup_init.
        let pages = try scalar(source, "PRAGMA page_count"), size = try scalar(source, "PRAGMA page_size")
        guard size > 0, pages >= 0, pages <= maximumSnapshotBytes / size else { throw ChromeSourceError.tooLarge }
        guard sqlite3_open_v2(":memory:", &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let destination else {
            if let destination { sqlite3_close(destination) }
            throw ChromeSourceError.unavailable
        }
        do {
            try execute(destination, "PRAGMA temp_store = MEMORY; PRAGMA trusted_schema = OFF")
            guard let backup = sqlite3_backup_init(destination, "main", source, "main") else { throw ChromeSourceError.invalidDatabase }
            var finished = false
            defer { if !finished { sqlite3_backup_finish(backup) } }
            let deadline = ContinuousClock.now + .seconds(5)
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw ChromeSourceError.snapshotBusy }
                let status = sqlite3_backup_step(backup, 128)
                if status == SQLITE_DONE { break }
                if status == SQLITE_BUSY || status == SQLITE_LOCKED { Thread.sleep(forTimeInterval: 0.025) }
                else if status != SQLITE_OK { throw ChromeSourceError.invalidDatabase }
            }
            let result = sqlite3_backup_finish(backup); finished = true
            guard result == SQLITE_OK else { throw ChromeSourceError.invalidDatabase }
            let after = try checkedFile(url, directory: false)
            guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else { throw ChromeSourceError.snapshotBusy }
            try execute(destination, "PRAGMA query_only = ON")
            return destination
        } catch { sqlite3_close(destination); throw error }
    }

    static func database(root: URL, directory: String, content: Content) throws -> URL? {
        guard validDirectory(directory) else { throw ChromeSourceError.invalidDatabase }
        _ = try checkedFile(root, directory: true)
        let profile = root.appendingPathComponent(directory, isDirectory: true)
        _ = try checkedFile(profile, directory: true)
        if content != .cookies {
            let file = profile.appendingPathComponent(content == .history ? "History" : "Favicons")
            guard try exists(file) else { return nil }
            _ = try checkedFile(file, directory: false)
            return file
        }
        let network = profile.appendingPathComponent("Network", isDirectory: true)
        if try exists(network) {
            _ = try checkedFile(network, directory: true)
            let modern = network.appendingPathComponent("Cookies")
            if try exists(modern) { _ = try checkedFile(modern, directory: false); return modern }
        }
        let legacy = profile.appendingPathComponent("Cookies")
        if try exists(legacy) { _ = try checkedFile(legacy, directory: false); return legacy }
        return nil
    }

    private static func validDirectory(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.contains(where: { "/\\".contains($0) }) && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    static func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw accessError()
    }
    private static func checkedFile(_ url: URL, directory: Bool) throws -> stat {
        guard url.isFileURL, url == url.standardizedFileURL else { throw ChromeSourceError.invalidDatabase }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw accessError() }
        guard info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw ChromeSourceError.invalidDatabase }
        return info
    }
    private static func accessError() -> ChromeSourceError {
        errno == EPERM || errno == EACCES ? .permissionDenied : .chromeNotFound
    }
    private static func fileAccessError(_ error: Error) -> ChromeSourceError {
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(failure.code) { return .permissionDenied }
        if failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoPermissionError { return .permissionDenied }
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? Error { return fileAccessError(underlying) }
        return .invalidDatabase
    }
    static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            try failSQLite(status)
        }
        return statement
    }
    static func execute(_ db: OpaquePointer, _ sql: String) throws {
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        guard status == SQLITE_OK else {
            try failSQLite(status)
        }
    }
    static func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else { try failSQLite(status) }
        // SQLite's meta table stores decimal versions as TEXT.
        guard let pointer = sqlite3_column_text(statement, 0), let raw = Int64(String(cString: pointer)) else {
            throw ChromeSourceError.invalidDatabase
        }
        guard raw >= 0, raw <= Int32.max else { throw ChromeSourceError.invalidDatabase }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ChromeSourceError.invalidDatabase }
        return Int(raw)
    }
    static func failSQLite(_ status: Int32) throws -> Never {
        try Task.checkCancellation()
        throw [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_INTERRUPT].contains(status)
            ? ChromeSourceError.snapshotBusy : ChromeSourceError.invalidDatabase
    }
}

final class ChromeSQLiteBudget {
    private let deadline = ContinuousClock.now + .seconds(10)

    func install(_ db: OpaquePointer) {
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1_048_576)
        sqlite3_progress_handler(db, 1_000, { pointer in
            guard let pointer else { return 1 }
            let budget = Unmanaged<ChromeSQLiteBudget>.fromOpaque(pointer).takeUnretainedValue()
            return Task.isCancelled || ContinuousClock.now >= budget.deadline ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }
}
