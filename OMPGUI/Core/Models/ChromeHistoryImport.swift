import CryptoKit
import Foundation

struct ChromeSourceProfile: Identifiable, Equatable, Sendable {
    let root: URL
    let directoryName: String
    let name: String
    var id: String { directoryName }
    // Display-name changes do not change the source's identity.
    var historySourceID: String {
        SHA256.hash(data: Data(root.appendingPathComponent(directoryName).standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

enum ChromeSourceError: Error, Equatable {
    case chromeNotFound, noProfiles, permissionDenied, invalidDatabase, tooLarge, snapshotBusy, unavailable
}

enum BrowserHistorySource: String, CaseIterable, Identifiable, Sendable {
    case all, gui, chrome
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All sources"
        case .gui: "OMP GUI"
        case .chrome: "Chrome"
        }
    }
}

struct ChromeHistoryImport: Sendable {
    static let maximumVisits = 200_000
    static let maximumTextBytes = 64 * 1_024 * 1_024
    static let maximumIconBytes = 16 * 1_024 * 1_024
    static let windowsEpochMicroseconds: Int64 = 11_644_473_600_000_000

    struct Visit: Sendable {
        let sourceID: Int64
        let time: Int64
        let url: String
        let title: String
        var visitedAt: Date {
            Date(timeIntervalSince1970: Double(time - ChromeHistoryImport.windowsEpochMicroseconds) / 1_000_000)
        }
        // Exact source time and URL guard against visit-ID reuse after a Chrome
        // database reset. This identity never depends on a floating-point Date.
        var fingerprint: String {
            SHA256.hash(data: Data("\(sourceID)\u{0}\(time)\u{0}\(url)".utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    let profile: ChromeSourceProfile
    let visits: [Visit]
    let skipped: Int
    var icons: [String: BrowserHistoryIcon] = [:]
}

struct ChromeHistoryImportSummary: Equatable, Sendable {
    var added = 0
    var existing = 0
    var deleted = 0
    var skipped = 0
}

struct ChromeHistoryImportPreview: Sendable {
    let content: ChromeHistoryImport
    let summary: ChromeHistoryImportSummary
    let cleanupRevision: Int64
}

enum ChromeHistoryImportError: Error {
    case source(ChromeSourceError), unsupportedDatabase, invalidated, storage

    var messageKey: String {
        switch self {
        case .source(.chromeNotFound), .source(.noProfiles):
            "No Chrome profiles with browsing history were found."
        case .source(.snapshotBusy):
            "Chrome is using its history database. Quit Chrome completely, then retry."
        case .source(.permissionDenied):
            "macOS blocked access to Chrome history. Allow OMP GUI in Privacy & Security, then retry."
        case .source(.tooLarge):
            "Chrome history exceeds the import limit. Choose a smaller time range or reduce the source database size."
        case .unsupportedDatabase:
            "This Chrome history database format is not supported."
        case .invalidated:
            "History changed while preparing the import. Preview it again before importing."
        case .source(.invalidDatabase), .source(.unavailable), .storage:
            "Chrome history could not be read or imported. No records were added."
        }
    }
}
