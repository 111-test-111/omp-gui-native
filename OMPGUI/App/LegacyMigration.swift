import Foundation

/// Editions never import one another's data or upstream preferences/credentials.
/// Existing shared installations must be separated offline before either edition opens.
enum LegacyMigration {
    static func run(
        support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard !CaptureRun.isEnabled else { return }
        let manager = FileManager.default
        let current = support.appendingPathComponent(AppInfo.libraryName, isDirectory: true)
        let state = home.appendingPathComponent(AppInfo.stateDirectoryName, isDirectory: true)
        guard (try? manager.destinationOfSymbolicLink(atPath: current.path)) == nil,
              (try? manager.destinationOfSymbolicLink(atPath: state.path)) == nil else {
            throw ProviderError.failed(AppText.localized("OMP GUI data folders must be separate directories."))
        }
        try manager.createDirectory(at: current, withIntermediateDirectories: true)
        try manager.createDirectory(at: state, withIntermediateDirectories: true)
    }

    /// Leftovers of the shared-library builds: lock files beside the stores and per
    /// conversation, and one MCP config folder per launch. Only called with this edition's
    /// lease held, when no other process can be using them.
    static func removeSharedLibraryLeftovers(
        support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) {
        guard !CaptureRun.isEnabled else { return }
        let current = support.appendingPathComponent(AppInfo.libraryName, isDirectory: true)
        for name in ["document-locks", "edit-locks", "mcp-runtime", "library.json.lock", "mcp.json.lock", "custom-mcp.json.lock", "mcp/managed.json.lock"] {
            try? FileManager.default.removeItem(at: current.appendingPathComponent(name))
        }
    }
}
