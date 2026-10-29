import Foundation

/// An in-memory, validated native import. Cookie values are never serialized
/// into preferences, diagnostics, an export file or a temporary database.
struct BrowserCookieImport: Sendable {
    struct PartitionKey: Equatable, Sendable {
        let topLevelSite: String
        let hasCrossSiteAncestor: Bool
    }

    struct Cookie: Sendable {
        let domain: String
        let hostOnly: Bool
        let httpOnly: Bool
        let name: String
        let path: String
        let sameSite: String
        let secure: Bool
        let session: Bool
        let value: String
        let expirationDate: Double?
        let partitionKey: PartitionKey?
        let priority: String
        let sourceScheme: String
        let sourcePort: Int

        var identity: String {
            [domain, path, name, partitionKey?.topLevelSite ?? "", String(partitionKey?.hasCrossSiteAncestor ?? false),
             sourceScheme, String(sourcePort)].joined(separator: "\u{0}")
        }

        var parameters: JSONValue {
            var result: [String: JSONValue] = ["name": .string(name), "value": .string(value), "path": .string(path),
                "secure": .bool(secure), "httpOnly": .bool(httpOnly), "priority": .string(priority),
                "sourceScheme": .string(sourceScheme), "sourcePort": .int(sourcePort)]
            if hostOnly {
                var components = URLComponents()
                components.scheme = secure || sourceScheme == "Secure" ? "https" : "http"
                components.host = domain
                components.port = sourcePort > 0 ? sourcePort : nil
                components.path = path
                result["url"] = .string(components.url!.absoluteString)
            } else { result["domain"] = .string(domain) }
            if !session, let expirationDate { result["expires"] = .double(expirationDate) }
            if let sameSite = ["lax": "Lax", "strict": "Strict", "no_restriction": "None"][sameSite] {
                result["sameSite"] = .string(sameSite)
            }
            if let partitionKey {
                result["partitionKey"] = ["topLevelSite": .string(partitionKey.topLevelSite),
                    "hasCrossSiteAncestor": .bool(partitionKey.hasCrossSiteAncestor)]
            }
            return .object(result)
        }

        func validate() throws {
            let bareDomain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard !bareDomain.isEmpty, domain == domain.lowercased(), domain.utf8.count <= 256,
                  !bareDomain.contains(where: { $0.isWhitespace || "/\\@*%".contains($0) }),
                  hostOnly == !domain.hasPrefix("."), URL(string: "https://" + bareDomain)?.host == bareDomain,
                  name.utf8.count <= 1_024, value.utf8.count <= 16_384,
                  !name.contains(where: { $0.isWhitespace || ";=".contains($0) }),
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  path.hasPrefix("/"), path.utf8.count <= 2_048,
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  ["unspecified", "lax", "strict", "no_restriction"].contains(sameSite),
                  sameSite != "no_restriction" || secure,
                  !name.hasPrefix("__Secure-") || secure,
                  !name.hasPrefix("__Host-") || (secure && hostOnly && path == "/"),
                  !(name.hasPrefix("__Http-") || name.hasPrefix("__Host-Http-")) || (secure && httpOnly),
                  ["Low", "Medium", "High"].contains(priority), ["Unset", "NonSecure", "Secure"].contains(sourceScheme),
                  (-1...65_535).contains(sourcePort), sourcePort != 0 else { throw BrowserCookieImportError.invalidDatabase }
            if let key = partitionKey {
                guard secure, let url = URL(string: key.topLevelSite), ["http", "https"].contains(url.scheme ?? ""),
                      url.host != nil, url.user == nil, url.password == nil, url.port == nil,
                      url.query == nil, url.fragment == nil, url.path.isEmpty,
                      key.topLevelSite == url.absoluteString else { throw BrowserCookieImportError.invalidDatabase }
            }
            if !session {
                guard let expirationDate, expirationDate.isFinite, expirationDate > 0 else { throw BrowserCookieImportError.invalidDatabase }
            }
        }
    }

    static let maximumCookies = 50_000
    static let maximumValueBytes = 32 * 1_024 * 1_024
    let sourceProfileName: String
    let cookies: [Cookie]
    let skippedCount: Int
    var siteCount: Int { Set(cookies.map(\.domain)).count }
}

struct ChromeCookieProfile: Identifiable, Equatable, Sendable {
    let root: URL
    let directoryName: String
    let name: String
    var id: String { directoryName }
}

struct BrowserCookieImportResult: Sendable {
    let profile: BrowserProfileRecord
    let cookieCount: Int
    let skippedCount: Int

    var message: String {
        if skippedCount > 0 {
            return String(format: AppText.localized("Imported %ld cookies into %@. Skipped %ld. Restart OMP GUI to use this profile."),
                cookieCount, profile.name, skippedCount)
        }
        return String(format: AppText.localized("Imported %ld cookies into %@. Restart OMP GUI to use this profile."), cookieCount, profile.name)
    }
}

enum BrowserCookieImportError: LocalizedError, Equatable {
    case chromeNotFound, noProfiles, permissionDenied, keychainDenied, keychainUnavailable
    case invalidDatabase, unsupportedDatabase, unsupportedEncryption, decryptionFailed, snapshotBusy, tooLarge
    case noCookies, busy, unavailable, rejected, profileLimit
    case noImportableCookies(Int)

    var errorDescription: String? {
        let key: String = switch self {
        case .chromeNotFound: "Google Chrome data was not found on this Mac."
        case .noProfiles: "No Chrome profiles with saved cookies were found."
        case .permissionDenied: "macOS blocked access to Chrome data. Allow OMP GUI in System Settings → Privacy & Security → Full Disk Access, then try again."
        case .keychainDenied: "Chrome Keychain access was canceled or denied. Allow access when macOS asks, then try again."
        case .keychainUnavailable: "The Chrome Safe Storage key is unavailable. Open Chrome with this macOS account, then try again."
        case .invalidDatabase: "The Chrome Cookie database could not be read. No profile was added."
        case .unsupportedDatabase: "This Chrome Cookie database version is not supported. No profile was added."
        case .unsupportedEncryption: "This Chrome Cookie encryption format is not supported. No profile was added."
        case .decryptionFailed: "Chrome Cookie decryption or domain verification failed. No profile was added."
        case .snapshotBusy: "Chrome data is busy. Completely quit Chrome and try importing again."
        case .tooLarge: "Chrome Cookie data exceeds the import limit. No profile was added."
        case .noCookies: "This Chrome profile has no unexpired saved cookies to import."
        case .noImportableCookies: "No cookies could be imported. Skipped %ld."
        case .busy: "A Cookie import is already in progress."
        case .unavailable: "The browser could not finish importing cookies. Try importing from Chrome again."
        case .rejected: "The browser could not verify the imported cookies. No profile was added."
        case .profileLimit: "The browser profile list is full."
        }
        if case .noImportableCookies(let count) = self { return String(format: AppText.localized(key), count) }
        return AppText.localized(key)
    }
}
