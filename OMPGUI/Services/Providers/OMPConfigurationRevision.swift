import CryptoKit
import Foundation

/// File fingerprints detect external CLI edits without retaining credential data.
struct OMPConfigurationRevision: Equatable, Sendable {
    private var fingerprints: [String: String]

    static func read(directory: URL) throws -> Self {
        var values: [String: String] = [:]
        for name in ["config.yml", "config.yaml"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                values[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            } else { values[name] = "missing" }
        }
        return Self(fingerprints: values)
    }
}

/// A form edits only its declared string fields. Future native fields survive.
enum OMPSelectorRecord {
    static func merging(_ changes: [String: String], into original: JSONValue) -> JSONValue {
        var result = original.object ?? [:]
        for (key, value) in changes {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { result[key] = nil }
            else { result[key] = .string(trimmed) }
        }
        return .object(result)
    }
}
