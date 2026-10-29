import Foundation
import Security

/// The GUI's own GitHub token. OMP owns all model and MCP credentials.
enum AppKeychain {
    /// Stores the value, or removes it for an empty one.
    @discardableResult
    static func set(_ key: String, account: String, service: String = AppInfo.libraryName) -> Bool {
        guard !CaptureRun.isEnabled else { return false }
        let trimmed = key.trimmed
        if trimmed.isEmpty {
            delete(account, service: service)
            return true
        }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        let attributes = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]) { _, new in new }
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func read(_ account: String, service: String = AppInfo.libraryName) -> String? {
        guard !CaptureRun.isEnabled else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.trimmed.isEmpty else { return nil }
        return key.trimmed
    }

    static func delete(_ account: String, service: String = AppInfo.libraryName) {
        guard !CaptureRun.isEnabled else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
