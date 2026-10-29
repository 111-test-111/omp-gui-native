import Foundation

extension URL {
    /// Only complete HTTP(S) URLs enter the app's web-browser preference.
    /// Scheme-like filenames and local references retain their file route.
    var isHTTPWebLink: Bool {
        ["http", "https"].contains(scheme?.lowercased() ?? "") && host?.isEmpty == false
    }
}

/// A file named by the native runtime, a message link, or an explicit user action.
/// Coordinates are one based and remain separate from the filename when available.
struct FilePreviewReference: Codable, Hashable, Sendable {
    var path: String
    var line: Int?
    var column: Int?

    init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }
}

/// The directory belongs to the source conversation, rather than whichever tab is
/// selected by the time a background file load completes.
struct FilePreviewContext: Codable, Hashable, Sendable {
    var threadID: UUID
    var workingDirectory: String
}

struct FilePreviewLocation: Codable, Hashable, Sendable {
    var line: Int
    var column: Int?

    init(line: Int, column: Int? = nil) {
        self.line = line
        self.column = column
    }
}

/// Only an explicit preview action creates model-readable context. A tab change
/// alone grants no context and the originating worktree travels with the quote.
struct FileQuestionContext: Codable, Hashable, Sendable {
    var path: String
    var source: FilePreviewContext
    var startLine: Int?
    var endLine: Int?
    var selectedText: String?

    var reference: String {
        guard let startLine else { return path }
        return path + "#L\(startLine)" + (endLine.map { $0 > startLine ? "-L\($0)" : "" } ?? "")
    }

    var promptText: String {
        let location = reference + "\nworktree: " + source.workingDirectory
        guard let selectedText, !selectedText.isEmpty else { return location }
        return location + "\n\n" + selectedText
    }

    static func selection(path: String, source: FilePreviewContext, text: String, range: NSRange) -> Self? {
        let native = text as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= native.length, range.length <= native.length - range.location else { return nil }
        // Preserve a selection's exact UTF-16 extent, including Unicode and CRLF.
        func line(at offset: Int) -> Int {
            var count = 1
            var index = 0
            while index < offset {
                let scalar = native.character(at: index)
                if scalar == 13 {
                    if index + 1 < native.length, native.character(at: index + 1) == 10 {
                        if index + 2 <= offset { count += 1 }
                        index += 2
                        continue
                    }
                    count += 1
                } else if scalar == 10 { count += 1 }
                index += 1
            }
            return count
        }
        return Self(path: path, source: source, startLine: line(at: range.location),
                    endLine: line(at: NSMaxRange(range) - 1), selectedText: native.substring(with: range))
    }
}

enum FilePreviewKind: String, Codable, Hashable, Sendable {
    case text, markdown, image, pdf, media, quickLook
}

/// The resolved URL is standardized and has its symbolic links resolved, making
/// aliases to the same file share a preview tab. The location never forms part of
/// that identity.
struct FilePreviewTarget: Hashable, Sendable {
    var url: URL
    var location: FilePreviewLocation?

    init(url: URL, location: FilePreviewLocation? = nil) {
        self.url = url
        self.location = location
    }

    var identity: String { url.path }
}

/// Text snapshots contain the entire accepted source. Large sources are refused
/// by the loader with a disclosed limit, never presented as if they were complete.
struct PreviewFileSnapshot: Sendable {
    var url: URL
    var kind: FilePreviewKind
    var text: String?
    var revision: String
    var byteCount: Int64
    var isTruncated: Bool
}
