import Foundation
import CryptoKit

/// Stable across processes, unlike Swift's randomized Hasher. SHA256.hash(data:)
/// is verified in the installed macOS SDK's CryptoKit.swiftinterface.
enum SharedResourceLock {
    static func url(in root: URL, resource: String) -> URL {
        let hash = SHA256.hash(data: Data(resource.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("resource-locks/\(hash).lock")
    }
}
