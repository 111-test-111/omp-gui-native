import Darwin
import Foundation

struct PreviewDirectoryEntry: Identifiable, Hashable, Sendable {
    var url: URL
    var isDirectory: Bool
    var isSymbolicLink: Bool
    var id: String { url.standardizedFileURL.path }
    var name: String { url.lastPathComponent }
}

struct PreviewDirectoryListing: Sendable {
    var entries: [PreviewDirectoryEntry]
    var isTruncated: Bool
}

enum PreviewDirectoryBrowser {
    /// A directory is read only when expanded. The cap bounds both retained rows
    /// and stat calls even in a generated folder with hundreds of thousands of
    /// entries. The UI discloses isTruncated and offers system browsing.
    static let maxEntries = 2_000
    static let maxListingScanEntries = 20_000
    static let excludedNames: Set<String> = [
        ".git", "build.noindex", "node_modules", ".build", "DerivedData", "__pycache__", ".cache", ".next", ".nuxt", ".venv", "venv",
        ".mypy_cache", ".pytest_cache", ".ruff_cache", ".turbo", ".parcel-cache", ".gradle", ".swiftpm",
    ]

    static func list(_ directory: URL, showHidden: Bool = false) async throws -> PreviewDirectoryListing {
        try Task.checkCancellation()
        let listing = Task.detached(priority: .userInitiated) { try listSynchronously(directory, showHidden: showHidden) }
        return try await withTaskCancellationHandler {
            let result = try await listing.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            listing.cancel()
        }
    }

    private static func listSynchronously(_ directory: URL, showHidden: Bool) throws -> PreviewDirectoryListing {
        try Task.checkCancellation()
        guard directory.isFileURL else { throw FilePreviewError.nonLocalReference }
        guard let stream = directory.path.withCString({ opendir($0) }) else {
            throw errno == ENOENT || errno == ENOTDIR ? FilePreviewError.missing : FilePreviewError.unreadable
        }
        defer { closedir(stream) }
        var entries: [PreviewDirectoryEntry] = []
        var scanned = 0
        var isTruncated = false
        entries.reserveCapacity(min(256, maxEntries))
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let record = readdir(stream) else {
                if errno != 0 { throw FilePreviewError.unreadable }
                break
            }
            let name = entryName(record)
            if name == "." || name == ".." { continue }
            scanned += 1
            if scanned > maxListingScanEntries {
                isTruncated = true
                break
            }
            if !showHidden, name.hasPrefix(".") || excludedNames.contains(name) { continue }
            if entries.count == maxEntries {
                isTruncated = true
                break
            }
            entries.append(directoryEntry(record, name: name, parent: directory))
        }
        try Task.checkCancellation()
        return PreviewDirectoryListing(entries: sorted(entries), isTruncated: isTruncated)
    }

    private static func entryName(_ record: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &record.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(record.pointee.d_namlen) + 1) { String(cString: $0) }
        }
    }

    private static func directoryEntry(_ record: UnsafeMutablePointer<dirent>, name: String, parent: URL) -> PreviewDirectoryEntry {
        let url = parent.appendingPathComponent(name)
        let isLink = record.pointee.d_type == DT_LNK
        var isDirectory = record.pointee.d_type == DT_DIR
        if isLink || record.pointee.d_type == DT_UNKNOWN {
            if let info = PreviewFileMetadata.read(url) { isDirectory = (info.mode & S_IFMT) == S_IFDIR }
        }
        // iWork bundles and other document packages are previewable items,
        // rather than folders whose internal implementation should be shown.
        if isDirectory, (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { isDirectory = false }
        return PreviewDirectoryEntry(url: url, isDirectory: isDirectory, isSymbolicLink: isLink)
    }

    private static func sorted(_ entries: [PreviewDirectoryEntry]) -> [PreviewDirectoryEntry] {
        // URL.lastPathComponent is not free. Extract at most the bounded row
        // count once, rather than reconstructing each name at every comparison.
        entries.map { (entry: $0, name: $0.name) }.sorted { first, second in
            if first.entry.isDirectory != second.entry.isDirectory { return first.entry.isDirectory }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }.map(\.entry)
    }
}
