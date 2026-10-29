import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import Security
import SQLite3

/// Reads only the explicitly selected Chrome profile. All SQLite/keychain work
/// runs off the main actor; no source database, key or plaintext is written out.
enum ChromeCookieSource {
    static var defaultRoot: URL {
        if let output = CaptureRun.outputDirectory { return output.appendingPathComponent("chrome", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }
    static let maximumSnapshotBytes = 128 * 1_024 * 1_024

    static func profiles(root: URL = defaultRoot) throws -> [ChromeCookieProfile] {
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
            guard data.count <= 4 * 1_024 * 1_024 else { throw BrowserCookieImportError.tooLarge }
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
        guard entries.count <= 4_096 else { throw BrowserCookieImportError.tooLarge }
        var result: [ChromeCookieProfile] = []
        for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            try Task.checkCancellation()
            let directory = entry.lastPathComponent
            guard validDirectory(directory), directory == "Default" || directory.hasPrefix("Profile ") || labels[directory] != nil else { continue }
            guard try database(root: root, directory: directory) != nil else { continue }
            result.append(ChromeCookieProfile(root: root, directoryName: directory, name: labels[directory] ?? directory))
        }
        guard !result.isEmpty else { throw BrowserCookieImportError.noProfiles }
        return result
    }

    static func read(_ profile: ChromeCookieProfile, now: Date = Date(),
                     keyProvider: () throws -> Data = readKeychainPassword) throws -> BrowserCookieImport {
        try Task.checkCancellation()
        guard validName(profile.name), let source = try database(root: profile.root, directory: profile.directoryName) else {
            throw BrowserCookieImportError.noProfiles
        }
        let db = try snapshot(source)
        let budget = SQLiteBudget()
        budget.install(db)
        defer { withExtendedLifetime(budget) { sqlite3_close(db) } }
        guard try scalar(db, "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name IN ('meta', 'cookies')") == 2 else {
            throw BrowserCookieImportError.invalidDatabase
        }
        let version = try scalar(db, "SELECT value FROM meta WHERE key = 'version'")
        let compatible = try scalar(db, "SELECT value FROM meta WHERE key = 'last_compatible_version'")
        guard (23...24).contains(version), (23...version).contains(compatible) else { throw BrowserCookieImportError.unsupportedDatabase }
        let statement = try prepare(db, """
            SELECT host_key, name, value, encrypted_value, path, is_secure, is_httponly,
                   expires_utc, is_persistent, has_expires, samesite, priority,
                   source_scheme, source_port, top_frame_site_key, has_cross_site_ancestor
            FROM cookies
            """)
        defer { sqlite3_finalize(statement) }
        var key: Data?
        defer { if let count = key?.count { key?.resetBytes(in: 0..<count) } }
        var cookies: [BrowserCookieImport.Cookie] = [], identities = Set<String>()
        var skipped = 0, total = 0, valueBytes = 0
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { try failSQLite(status) }
            total += 1
            guard total <= BrowserCookieImport.maximumCookies else { throw BrowserCookieImportError.tooLarge }
            let decoded: BrowserCookieImport.Cookie?
            do {
                decoded = try readCookie(statement, version: version, now: now, key: &key, keyProvider: keyProvider)
            } catch let error as BrowserCookieImportError {
                switch error {
                case .invalidDatabase, .unsupportedEncryption, .decryptionFailed, .tooLarge:
                    skipped += 1
                    continue
                default: throw error
                }
            }
            guard let cookie = decoded, identities.insert(cookie.identity).inserted else { skipped += 1; continue }
            valueBytes += cookie.value.utf8.count + cookie.name.utf8.count + cookie.path.utf8.count + cookie.domain.utf8.count
                + (cookie.partitionKey?.topLevelSite.utf8.count ?? 0)
            guard valueBytes <= BrowserCookieImport.maximumValueBytes else { throw BrowserCookieImportError.tooLarge }
            cookies.append(cookie)
        }
        guard !cookies.isEmpty else {
            if skipped > 0 { throw BrowserCookieImportError.noImportableCookies(skipped) }
            throw BrowserCookieImportError.noCookies
        }
        return BrowserCookieImport(sourceProfileName: profile.name, cookies: cookies, skippedCount: skipped)
    }

    /// Only row-local decoding errors may be skipped. Schema/SQLite failures,
    /// aggregate limits, cancellation and Keychain errors escape the outer loop.
    private static func readCookie(_ statement: OpaquePointer, version: Int, now: Date,
                                   key: inout Data?, keyProvider: () throws -> Data) throws -> BrowserCookieImport.Cookie? {
        let persistent = try boolean(statement, 8)
        guard persistent == (try boolean(statement, 9)) else { throw BrowserCookieImportError.invalidDatabase }
        guard sqlite3_column_type(statement, 7) == SQLITE_INTEGER else { throw BrowserCookieImportError.invalidDatabase }
        let microseconds = sqlite3_column_int64(statement, 7)
        let expiry = Double(microseconds) / 1_000_000 - 11_644_473_600
        if persistent {
            guard microseconds > 0 else { throw BrowserCookieImportError.invalidDatabase }
            if expiry <= now.timeIntervalSince1970 { return nil }
        }
        let domain = try string(statement, 0, maximum: 256)
        let encrypted = try bytes(statement, 3, maximum: 16_448)
        var value = try string(statement, 2, maximum: 16_384)
        if !encrypted.isEmpty {
            guard value.isEmpty else { throw BrowserCookieImportError.invalidDatabase }
            guard encrypted.starts(with: Data("v10".utf8)) else { throw BrowserCookieImportError.unsupportedEncryption }
            if key == nil {
                var password = try keyProvider()
                defer { password.resetBytes(in: 0..<password.count) }
                try Task.checkCancellation()
                key = try deriveKey(password)
            }
            value = try decrypt(encrypted, key: key!, host: domain, version: version)
        }
        let sameSite = try enumeration(statement, 10, values: [-1: "unspecified", 0: "no_restriction", 1: "lax", 2: "strict"])
        let topLevelSite = try string(statement, 14, maximum: 2_048)
        let ancestor = try boolean(statement, 15)
        let cookie = BrowserCookieImport.Cookie(domain: domain, hostOnly: !domain.hasPrefix("."),
            httpOnly: try boolean(statement, 6), name: try string(statement, 1, maximum: 1_024),
            path: try string(statement, 4, maximum: 2_048), sameSite: sameSite, secure: try boolean(statement, 5),
            session: !persistent, value: value, expirationDate: persistent ? expiry : nil,
            partitionKey: topLevelSite.isEmpty ? nil : .init(topLevelSite: topLevelSite, hasCrossSiteAncestor: ancestor),
            priority: try enumeration(statement, 11, values: [0: "Low", 1: "Medium", 2: "High"]),
            sourceScheme: try enumeration(statement, 12, values: [0: "Unset", 1: "NonSecure", 2: "Secure"]),
            sourcePort: try integer(statement, 13))
        try cookie.validate()
        return cookie
    }

    /// SQLite's backup API includes committed WAL pages. A pinned read transaction
    /// keeps all chunks at one point in time, even if Chrome writes concurrently.
    /// Never use immutable=1 (which would ignore a live WAL), cp or VACUUM here.
    static func snapshot(_ url: URL) throws -> OpaquePointer {
        try Task.checkCancellation()
        let before = try checkedFile(url, directory: false)
        guard before.st_size <= maximumSnapshotBytes else { throw BrowserCookieImportError.tooLarge }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if try exists(sidecar) {
                let info = try checkedFile(sidecar, directory: false)
                guard info.st_size <= maximumSnapshotBytes else { throw BrowserCookieImportError.tooLarge }
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
                ? BrowserCookieImportError.permissionDenied : BrowserCookieImportError.invalidDatabase
        }
        defer { sqlite3_exec(source, "ROLLBACK", nil, nil, nil); sqlite3_close(source) }
        let budget = SQLiteBudget()
        budget.install(source)
        defer { withExtendedLifetime(budget) { sqlite3_progress_handler(source, 0, nil, nil) } }
        sqlite3_busy_timeout(source, 250)
        try execute(source, "PRAGMA query_only = ON; PRAGMA trusted_schema = OFF; BEGIN")
        _ = try scalar(source, "SELECT count(*) FROM sqlite_schema") // Pin the read snapshot before backup_init.
        let pages = try scalar(source, "PRAGMA page_count"), size = try scalar(source, "PRAGMA page_size")
        guard size > 0, pages >= 0, pages <= maximumSnapshotBytes / size else { throw BrowserCookieImportError.tooLarge }
        guard sqlite3_open_v2(":memory:", &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let destination else {
            if let destination { sqlite3_close(destination) }
            throw BrowserCookieImportError.unavailable
        }
        do {
            try execute(destination, "PRAGMA temp_store = MEMORY; PRAGMA trusted_schema = OFF")
            guard let backup = sqlite3_backup_init(destination, "main", source, "main") else { throw BrowserCookieImportError.invalidDatabase }
            var finished = false
            defer { if !finished { sqlite3_backup_finish(backup) } }
            let deadline = ContinuousClock.now + .seconds(5)
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw BrowserCookieImportError.snapshotBusy }
                let status = sqlite3_backup_step(backup, 128)
                if status == SQLITE_DONE { break }
                if status == SQLITE_BUSY || status == SQLITE_LOCKED { Thread.sleep(forTimeInterval: 0.025) }
                else if status != SQLITE_OK { throw BrowserCookieImportError.invalidDatabase }
            }
            let result = sqlite3_backup_finish(backup); finished = true
            guard result == SQLITE_OK else { throw BrowserCookieImportError.invalidDatabase }
            let after = try checkedFile(url, directory: false)
            guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else { throw BrowserCookieImportError.snapshotBusy }
            try execute(destination, "PRAGMA query_only = ON")
            return destination
        } catch { sqlite3_close(destination); throw error }
    }

    static func readKeychainPassword() throws -> Data {
        guard !CaptureRun.isEnabled else { throw BrowserCookieImportError.keychainUnavailable }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage", kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed].contains(status) { throw BrowserCookieImportError.keychainDenied }
        guard status == errSecSuccess, let password = value as? Data, !password.isEmpty, password.count <= 1_024 else {
            throw BrowserCookieImportError.keychainUnavailable
        }
        return password
    }

    static func deriveKey(_ password: Data) throws -> Data {
        guard !password.isEmpty, password.count <= 1_024 else { throw BrowserCookieImportError.keychainUnavailable }
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let result = key.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { input in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1_003, output.baseAddress!.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128)
                }
            }
        }
        guard result == kCCSuccess else { throw BrowserCookieImportError.decryptionFailed }
        return key
    }

    static func decrypt(_ encrypted: Data, key: Data, host: String, version: Int) throws -> String {
        guard encrypted.starts(with: Data("v10".utf8)) else { throw BrowserCookieImportError.unsupportedEncryption }
        let cipher = Data(encrypted.dropFirst(3)), iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        guard key.count == kCCKeySizeAES128, !cipher.isEmpty, cipher.count % kCCBlockSizeAES128 == 0 else {
            throw BrowserCookieImportError.decryptionFailed
        }
        var plain = Data(count: cipher.count + kCCBlockSizeAES128), written = 0
        let capacity = plain.count
        let result = plain.withUnsafeMutableBytes { output in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    cipher.withUnsafeBytes { input in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress, input.baseAddress, cipher.count,
                            output.baseAddress, capacity, &written)
                    }
                }
            }
        }
        defer { plain.resetBytes(in: 0..<plain.count) }
        guard result == kCCSuccess else { throw BrowserCookieImportError.decryptionFailed }
        plain.count = written
        let offset: Int
        if version >= 24 {
            let digest = Data(SHA256.hash(data: Data(host.utf8)))
            guard plain.count >= digest.count, plain.prefix(digest.count) == digest else { throw BrowserCookieImportError.decryptionFailed }
            offset = digest.count
        } else { offset = 0 }
        guard let value = String(data: plain.dropFirst(offset), encoding: .utf8) else { throw BrowserCookieImportError.decryptionFailed }
        return value
    }

    private static func database(root: URL, directory: String) throws -> URL? {
        guard validDirectory(directory) else { throw BrowserCookieImportError.invalidDatabase }
        _ = try checkedFile(root, directory: true)
        let profile = root.appendingPathComponent(directory, isDirectory: true)
        _ = try checkedFile(profile, directory: true)
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
    private static func validName(_ name: String) -> Bool {
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
        guard url.isFileURL, url == url.standardizedFileURL else { throw BrowserCookieImportError.invalidDatabase }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw accessError() }
        guard info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw BrowserCookieImportError.invalidDatabase }
        return info
    }
    private static func accessError() -> BrowserCookieImportError {
        errno == EPERM || errno == EACCES ? .permissionDenied : .chromeNotFound
    }
    private static func fileAccessError(_ error: Error) -> BrowserCookieImportError {
        let failure = error as NSError
        if failure.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(failure.code) { return .permissionDenied }
        if failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoPermissionError { return .permissionDenied }
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? Error { return fileAccessError(underlying) }
        return .invalidDatabase
    }
    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            try failSQLite(status)
        }
        return statement
    }
    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        guard status == SQLITE_OK else {
            try failSQLite(status)
        }
    }
    private static func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW else { try failSQLite(status) }
        // SQLite's meta table stores decimal versions as TEXT.
        guard let pointer = sqlite3_column_text(statement, 0), let raw = Int64(String(cString: pointer)) else {
            throw BrowserCookieImportError.invalidDatabase
        }
        guard raw >= 0, raw <= Int32.max else { throw BrowserCookieImportError.invalidDatabase }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw BrowserCookieImportError.invalidDatabase }
        return Int(raw)
    }
    private static func failSQLite(_ status: Int32) throws -> Never {
        try Task.checkCancellation()
        throw [SQLITE_BUSY, SQLITE_LOCKED, SQLITE_INTERRUPT].contains(status)
            ? BrowserCookieImportError.snapshotBusy : BrowserCookieImportError.invalidDatabase
    }
    private static func integer(_ statement: OpaquePointer, _ column: Int32) throws -> Int {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else { throw BrowserCookieImportError.invalidDatabase }
        let value = sqlite3_column_int64(statement, column)
        guard value >= Int32.min, value <= Int32.max else { throw BrowserCookieImportError.invalidDatabase }
        return Int(value)
    }
    private static func boolean(_ statement: OpaquePointer, _ column: Int32) throws -> Bool {
        let value = try integer(statement, column)
        guard value == 0 || value == 1 else { throw BrowserCookieImportError.invalidDatabase }
        return value == 1
    }
    private static func enumeration(_ statement: OpaquePointer, _ column: Int32, values: [Int: String]) throws -> String {
        guard let value = values[try integer(statement, column)] else { throw BrowserCookieImportError.invalidDatabase }
        return value
    }
    private static func bytes(_ statement: OpaquePointer, _ column: Int32, maximum: Int) throws -> Data {
        let type = sqlite3_column_type(statement, column)
        guard type == SQLITE_BLOB || type == SQLITE_TEXT else { throw BrowserCookieImportError.invalidDatabase }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= maximum else { throw BrowserCookieImportError.tooLarge }
        guard count > 0 else { return Data() }
        guard let pointer = sqlite3_column_blob(statement, column) else { throw BrowserCookieImportError.invalidDatabase }
        return Data(bytes: pointer, count: count)
    }
    private static func string(_ statement: OpaquePointer, _ column: Int32, maximum: Int) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let value = String(data: try bytes(statement, column, maximum: maximum), encoding: .utf8) else {
            throw BrowserCookieImportError.invalidDatabase
        }
        return value
    }
}

private final class SQLiteBudget {
    private let deadline = ContinuousClock.now + .seconds(10)

    func install(_ db: OpaquePointer) {
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1_048_576)
        sqlite3_progress_handler(db, 1_000, { pointer in
            guard let pointer else { return 1 }
            let budget = Unmanaged<SQLiteBudget>.fromOpaque(pointer).takeUnretainedValue()
            return Task.isCancelled || ContinuousClock.now >= budget.deadline ? 1 : 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }
}
