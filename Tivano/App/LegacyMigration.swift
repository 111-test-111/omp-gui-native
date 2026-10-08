import Foundation

/// The first edition opened carries the real library forward. Both editions share
/// files, while preferences remain in their own bundle domains. Old paths stay valid.
enum LegacyMigration {
    private static let marker = "tivanoSharedLibrary_v1"

    static func run(
        defaults: UserDefaults = .standard,
        support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        formerDomains: [String]? = nil
    ) throws {
        guard !CaptureRun.isEnabled, !defaults.bool(forKey: marker) else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: support, withIntermediateDirectories: true)
        let current = support.appendingPathComponent(AppInfo.libraryName, isDirectory: true)
        if !manager.fileExists(atPath: current.path) {
            for name in ["Droppy Code", "Cody", "Tivano Dev"] {
                let former = support.appendingPathComponent(name, isDirectory: true)
                guard manager.fileExists(atPath: former.path) else { continue }
                // Snapshot before the rename, never overwrite an existing library or
                // merge two sets of thread JSON. Keep absolute attachment paths valid.
                let backup = support.appendingPathComponent("Tivano Backups/migration-\(UUID().uuidString)", isDirectory: true)
                try manager.createDirectory(at: backup, withIntermediateDirectories: true)
                try manager.copyItem(at: former, to: backup.appendingPathComponent(name))
                try manager.moveItem(at: former, to: current)
                do {
                    try manager.createSymbolicLink(at: former, withDestinationURL: current)
                } catch {
                    try manager.moveItem(at: current, to: former)
                    throw error
                }
                break
            }
        }

        // Registered git worktrees contain absolute paths. An alias, rather than a
        // move, carries the old state forward without breaking git's registrations.
        let state = home.appendingPathComponent(AppInfo.stateDirectoryName, isDirectory: true)
        let formerState = home.appendingPathComponent(".droppy-code", isDirectory: true)
        if !manager.fileExists(atPath: state.path), manager.fileExists(atPath: formerState.path) {
            try manager.createSymbolicLink(at: state, withDestinationURL: formerState)
        }

        var domains = formerDomains ?? ["iordv.droppycode", "iordv.cody"]
        if formerDomains == nil, AppInfo.isDevelopment { domains.insert("dev.tivano.Tivano", at: 0) }
        for domain in domains {
            if let former = defaults.persistentDomain(forName: domain) {
                // Never carry an upstream update download into this fork's updater.
                for (key, value) in former where !key.hasPrefix("updateChecker_") && defaults.object(forKey: key) == nil {
                    defaults.set(value, forKey: key)
                }
            }
        }
        defaults.set(true, forKey: marker)
    }
}
