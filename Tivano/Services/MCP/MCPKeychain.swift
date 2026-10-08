import Foundation

/// Stores MCP secret field values in the macOS Keychain so they never sit
/// in plaintext. `mcp.json` keeps only the non-secret values.
enum MCPKeychain {
    private static func account(server: String, field: String) -> String {
        "MCP " + server + " " + field
    }

    static func value(server: String, field: String) -> String? {
        guard !CaptureRun.isEnabled else { return nil }
        return APIKeychain.read(account(server: server, field: field))
    }

    /// Stores the value, or removes it for an empty one.
    @discardableResult
    static func set(_ value: String, server: String, field: String) -> Bool {
        APIKeychain.set(value, account: account(server: server, field: field))
    }

    static func delete(server: String, field: String) {
        APIKeychain.delete(account(server: server, field: field))
    }

    /// Forgets every secret the entry declares. The entry, not its id: a custom server
    /// is not in the catalog, so looking it up there would silently delete nothing.
    static func deleteAll(server entry: MCPCatalogEntry) {
        for field in entry.fields {
            delete(server: entry.id, field: field.key)
        }
    }
}
