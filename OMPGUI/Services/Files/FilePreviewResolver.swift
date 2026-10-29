import Foundation

enum FilePreviewResolver {
    /// Plain relative names may contain a colon. URI-looking references are only
    /// accepted for the file scheme; never reinterpret an HTTP URL as a local path.
    static func isLocalReference(_ path: String) -> Bool {
        guard !path.isEmpty, !path.utf8.contains(0) else { return false }
        let lower = path.lowercased()
        if lower.hasPrefix("file:") { return true }
        if path.hasPrefix("/") || path.hasPrefix("~") || path.hasPrefix("./") || path.hasPrefix("../") { return true }
        if lower.contains("://") { return false }
        let remoteSchemes = ["http:", "https:", "mailto:", "tel:", "data:", "javascript:", "about:", "codex:", "chatgpt-conversation:", "app:", "xd:"]
        return !remoteSchemes.contains { lower.hasPrefix($0) }
    }

    static func resolve(_ reference: FilePreviewReference, relativeTo directory: String) throws -> FilePreviewTarget {
        guard !reference.path.isEmpty, !reference.path.utf8.contains(0) else { throw FilePreviewError.invalidReference }
        guard isLocalReference(reference.path) else { throw FilePreviewError.nonLocalReference }
        if let line = reference.line, line <= 0 { throw FilePreviewError.invalidLocation }
        if let column = reference.column, column <= 0 { throw FilePreviewError.invalidLocation }

        var encodedPath = reference.path
        var fragmentLocation: FilePreviewLocation?
        let isFileURL = encodedPath.lowercased().hasPrefix("file:")
        if isFileURL {
            guard let components = URLComponents(string: encodedPath), components.scheme?.lowercased() == "file",
                  components.host == nil || components.host == "" || components.host?.lowercased() == "localhost",
                  components.query == nil, !components.path.isEmpty else { throw FilePreviewError.invalidReference }
            // Keep escaped ':' and '#' distinguishable from navigation suffixes.
            // Each resulting path is decoded once, equivalent to components.path;
            // it is never decoded again after that URL-level conversion.
            encodedPath = components.percentEncodedPath
            if let fragment = components.fragment { fragmentLocation = lineFragment(fragment) }
        }

        let basePath = (directory as NSString).expandingTildeInPath
        // An actual filename wins over the display convention. This matters for
        // files such as "report:2026", "file.swift:12", or "report%20.txt".
        // Percent escapes in a plain Markdown path are decoded only if its
        // literal spelling does not exist. File URLs always follow URL escaping.
        var path = decodedPath(encodedPath, relativeTo: basePath, preserveLiteral: !isFileURL)
        let completeURL = url(for: path, relativeTo: basePath)
        var suffixLocation: FilePreviewLocation?
        if !FileManager.default.fileExists(atPath: completeURL.path) {
            if !isFileURL, let hash = encodedPath.lastIndex(of: "#"), let location = lineFragment(String(encodedPath[encodedPath.index(after: hash)...])) {
                fragmentLocation = location
                encodedPath = String(encodedPath[..<hash])
            }
            let parsed = colonLocation(encodedPath, relativeTo: basePath, preserveLiteral: !isFileURL)
            path = decodedPath(parsed.path, relativeTo: basePath, preserveLiteral: !isFileURL)
            suffixLocation = parsed.location
        }
        guard !path.isEmpty, !path.utf8.contains(0) else { throw FilePreviewError.invalidReference }
        if path.hasPrefix("~"), (path as NSString).expandingTildeInPath.hasPrefix("~") { throw FilePreviewError.invalidReference }
        if !path.hasPrefix("/") && !path.hasPrefix("~") {
            guard basePath.hasPrefix("/"), !basePath.utf8.contains(0) else { throw FilePreviewError.invalidReference }
        }

        var location = fragmentLocation ?? suffixLocation
        if let line = reference.line { location = FilePreviewLocation(line: line, column: reference.column ?? location?.column) }
        else if let column = reference.column {
            guard location != nil else { throw FilePreviewError.invalidLocation }
            location?.column = column
        }
        return FilePreviewTarget(url: url(for: path, relativeTo: basePath).resolvingSymlinksInPath().standardizedFileURL, location: location)
    }

    private static func url(for path: String, relativeTo directory: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(expanded).standardizedFileURL
    }

    private static func decodedPath(_ path: String, relativeTo directory: String, preserveLiteral: Bool) -> String {
        if preserveLiteral, !path.contains("%") || FileManager.default.fileExists(atPath: url(for: path, relativeTo: directory).path) { return path }
        return path.removingPercentEncoding ?? path
    }

    private static func colonLocation(_ path: String, relativeTo directory: String, preserveLiteral: Bool) -> (path: String, location: FilePreviewLocation?) {
        guard let lastColon = path.lastIndex(of: ":") else { return (path, nil) }
        let suffix = path[path.index(after: lastColon)...]
        let beforeLast = String(path[..<lastColon])
        guard !beforeLast.isEmpty else { return (path, nil) }
        if let start = rangeStart(suffix) { return (beforeLast, FilePreviewLocation(line: start)) }
        guard let last = positiveInteger(suffix) else { return (path, nil) }
        // The one-colon path may itself end in a numeric component. Prefer it if
        // it exists, so "report:2026:7" can target line 7 of "report:2026".
        let candidate = decodedPath(beforeLast, relativeTo: directory, preserveLiteral: preserveLiteral)
        if FileManager.default.fileExists(atPath: url(for: candidate, relativeTo: directory).path) {
            return (beforeLast, FilePreviewLocation(line: last))
        }
        if let previousColon = beforeLast.lastIndex(of: ":"),
           let line = positiveInteger(beforeLast[beforeLast.index(after: previousColon)...]) {
            let base = String(beforeLast[..<previousColon])
            if !base.isEmpty { return (base, FilePreviewLocation(line: line, column: last)) }
        }
        return (beforeLast, FilePreviewLocation(line: last))
    }

    private static func rangeStart<S: StringProtocol>(_ value: S) -> Int? {
        guard let dash = value.firstIndex(of: "-"), let start = positiveInteger(value[..<dash]),
              let end = positiveInteger(value[value.index(after: dash)...]), end >= start else { return nil }
        return start
    }

    private static func positiveInteger<S: StringProtocol>(_ value: S) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let number = Int(value), number > 0 else { return nil }
        return number
    }

    /// GitHub-style line fragments, including a line range or column. A range
    /// opens its first line; the read-only preview does not manufacture a selection.
    private static func lineFragment(_ fragment: String) -> FilePreviewLocation? {
        guard fragment.hasPrefix("L") else { return nil }
        let rest = fragment.dropFirst()
        if let range = rest.firstIndex(of: "-") {
            guard positiveInteger(rest[..<range]) != nil, rest[rest.index(after: range)...].hasPrefix("L"),
                  positiveInteger(rest[rest.index(range, offsetBy: 2)...]) != nil else { return nil }
            return positiveInteger(rest[..<range]).map { FilePreviewLocation(line: $0) }
        }
        if let column = rest.firstIndex(of: "C"), let line = positiveInteger(rest[..<column]),
           let number = positiveInteger(rest[rest.index(after: column)...]) {
            return FilePreviewLocation(line: line, column: number)
        }
        return positiveInteger(rest).map { FilePreviewLocation(line: $0) }
    }
}
