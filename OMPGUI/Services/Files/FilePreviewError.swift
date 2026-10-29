import Foundation

enum FilePreviewError: Error, LocalizedError, Equatable, Sendable {
    case invalidReference
    case nonLocalReference
    case invalidLocation
    case missing
    case unreadable
    case directory
    case unsupportedFile
    case binary
    case invalidEncoding
    case tooLarge(limit: Int64)
    case changedWhileReading

    var errorDescription: String? {
        let key: String
        switch self {
        case .invalidReference:
            key = "This file path is invalid."
        case .nonLocalReference:
            key = "Only local files can be previewed here."
        case .invalidLocation:
            key = "File line and column numbers must be positive."
        case .missing:
            key = "This file no longer exists."
        case .unreadable:
            key = "This file could not be read. Check its permissions or open it externally."
        case .directory:
            key = "Select a file inside this folder to preview it."
        case .unsupportedFile:
            key = "This item is not a regular file and cannot be previewed."
        case .binary:
            key = "This file contains binary data and cannot be shown as source text."
        case .invalidEncoding:
            key = "This file is not valid UTF-8, UTF-16, or UTF-32 text. UTF-16 and UTF-32 files need a byte order mark."
        case .tooLarge(let limit):
            let template = Self.localized("Source preview is limited to %@. Open this file externally to view its full contents.")
            return String(format: template, ByteCountFormatter.string(fromByteCount: limit, countStyle: .binary))
        case .changedWhileReading:
            key = "This file changed while it was being read. Refresh the preview to try again."
        }
        return Self.localized(key)
    }

    private static func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }
}
