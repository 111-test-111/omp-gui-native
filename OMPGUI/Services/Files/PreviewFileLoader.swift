import Darwin
import Foundation
import UniformTypeIdentifiers

/// Resolving, classification and the selected file's complete read share one
/// worker. Failed file reads keep their resolved target so the UI can offer a
/// retry in that file's tab; invalid/nonlocal references still throw.
struct PreviewFileOpening: Sendable {
    var target: FilePreviewTarget
    var isDirectory: Bool
    var content: Result<PreviewFileSnapshot, FilePreviewError>?
}

enum PreviewFileLoader {
    /// One complete source document at a time; the pane releases inactive text
    /// snapshots. The same bound applies even if a file grows during the read.
    static let maxTextBytes: Int64 = 2 * 1_024 * 1_024
    private static let chunkBytes = 64 * 1_024
    private static let sniffBytes = 8 * 1_024

    static func open(_ reference: FilePreviewReference, relativeTo directory: String,
                     readsContent: Bool = true, reusing snapshot: PreviewFileSnapshot? = nil) async throws -> PreviewFileOpening {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let target = try FilePreviewResolver.resolve(reference, relativeTo: directory)
            try Task.checkCancellation()
            // Multi-file pinning resolves/classifies each tab but reads only
            // the one that becomes visible. There is no document cache here.
            if !readsContent {
                let metadata = PreviewFileMetadata.read(target.url)
                let isFolder = metadata.map { ($0.mode & S_IFMT) == S_IFDIR } == true
                let isPackage = isFolder && (try? target.url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
                try Task.checkCancellation()
                return PreviewFileOpening(target: target, isDirectory: isFolder && !isPackage, content: nil)
            }
            if let snapshot, snapshot.url == target.url,
               PreviewFileMetadata.read(target.url)?.revision == snapshot.revision {
                try Task.checkCancellation()
                return PreviewFileOpening(target: target, isDirectory: false, content: .success(snapshot))
            }
            do {
                let loaded = try loadSynchronously(target)
                return PreviewFileOpening(target: target, isDirectory: false, content: .success(loaded))
            } catch FilePreviewError.directory {
                return PreviewFileOpening(target: target, isDirectory: true, content: nil)
            } catch let error as FilePreviewError {
                try Task.checkCancellation()
                return PreviewFileOpening(target: target, isDirectory: false, content: .failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            let opening = try await work.value
            try Task.checkCancellation()
            return opening
        } onCancel: {
            work.cancel()
        }
    }

    static func load(_ target: FilePreviewTarget) async throws -> PreviewFileSnapshot {
        try Task.checkCancellation()
        let read = Task.detached(priority: .userInitiated) { try loadSynchronously(target) }
        return try await withTaskCancellationHandler {
            let result = try await read.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            read.cancel()
        }
    }

    /// HTML and SVG must be source before the general image/text conformance
    /// checks; neither is ever handed to an active document renderer.
    static func kind(for url: URL) -> FilePreviewKind {
        let ext = url.pathExtension.lowercased()
        if ["html", "htm", "xhtml", "svg", "svgz"].contains(ext) { return .text }
        if ["md", "markdown", "mdown", "mkd", "mdx"].contains(ext) { return .markdown }
        if ext == "pdf" { return .pdf }
        if PreviewSyntaxHighlighter.languageExtension(forFilePath: url.path) != nil
            || sourceExtensions.contains(ext) || sourceFilenames.contains(url.lastPathComponent.lowercased()) { return .text }
        guard let type = UTType(filenameExtension: ext) else { return .quickLook }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .audiovisualContent) || type.conforms(to: .audio) { return .media }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return .text }
        return .quickLook
    }

    private static let sourceExtensions: Set<String> = [
        "txt", "text", "log", "swift", "c", "h", "m", "mm", "cc", "cpp", "cxx", "hpp", "hxx", "rs", "go", "py", "pyi", "rb",
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "java", "kt", "kts", "scala", "cs", "fs", "fsx", "vb", "php", "lua", "pl", "pm",
        "r", "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "sql", "css", "scss", "sass", "less", "json", "jsonl", "ndjson",
        "yaml", "yml", "toml", "ini", "conf", "config", "env", "xml", "xsd", "xsl", "plist", "strings", "xcstrings", "csv", "tsv",
        "tex", "bib", "rst", "adoc", "diff", "patch", "gitignore", "gitattributes", "editorconfig", "dockerignore", "graphql", "gql",
        "proto", "cmake", "gradle", "nix", "lock", "svelte", "vue", "astro", "make", "mk", "tf", "tfvars", "v", "sv", "zig",
    ]
    private static let sourceFilenames: Set<String> = [
        "makefile", "gnumakefile", "dockerfile", "containerfile", "gemfile", "rakefile", "podfile", "brewfile", "license", "copying",
        "readme", ".gitignore", ".gitattributes", ".editorconfig", ".dockerignore", ".env", ".npmrc", ".nvmrc", ".python-version",
    ]

    private static func loadSynchronously(_ target: FilePreviewTarget) throws -> PreviewFileSnapshot {
        try Task.checkCancellation()
        guard target.url.isFileURL else { throw FilePreviewError.nonLocalReference }
        // O_NONBLOCK prevents a tool-supplied FIFO/device path from waiting on a
        // writer. Nothing except a regular file or a Quick Look package is read.
        let descriptor = target.url.path.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw error(for: errno) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw FilePreviewError.unreadable }
        let initial = PreviewFileMetadata(info)
        var kind = kind(for: target.url)
        if (info.st_mode & S_IFMT) == S_IFDIR {
            guard (try? target.url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true else { throw FilePreviewError.directory }
            kind = .quickLook
        } else if (info.st_mode & S_IFMT) != S_IFREG {
            throw FilePreviewError.unsupportedFile
        }

        // Unknown files use a bounded sample. This makes extensionless source
        // readable while leaving Office archives and binary formats to Quick Look.
        if kind == .quickLook, (info.st_mode & S_IFMT) == S_IFREG, isUnclassified(target.url) {
            let sample = try read(descriptor, maximum: sniffBytes, offset: 0)
            if looksLikeText(sample) { kind = .text }
        }

        var text: String?
        if kind == .text || kind == .markdown {
            guard initial.byteCount <= maxTextBytes else { throw FilePreviewError.tooLarge(limit: maxTextBytes) }
            var bytes = Data()
            bytes.reserveCapacity(Int(min(initial.byteCount, maxTextBytes)))
            while true {
                try Task.checkCancellation()
                let remaining = Int(maxTextBytes) + 1 - bytes.count
                let chunk = try read(descriptor, maximum: min(chunkBytes, remaining), offset: off_t(bytes.count))
                if chunk.isEmpty { break }
                bytes.append(chunk)
                guard bytes.count <= maxTextBytes else { throw FilePreviewError.tooLarge(limit: maxTextBytes) }
            }
            text = try decode(bytes)
            try Task.checkCancellation()
            if let text, containsBinaryControls(text) { throw FilePreviewError.binary }
            var finished = stat()
            guard fstat(descriptor, &finished) == 0, PreviewFileMetadata(finished) == initial else { throw FilePreviewError.changedWhileReading }
        }
        try Task.checkCancellation()
        guard PreviewFileMetadata.read(target.url) == initial else { throw FilePreviewError.changedWhileReading }
        return PreviewFileSnapshot(url: target.url, kind: kind, text: text, revision: initial.revision,
                                   byteCount: initial.byteCount, isTruncated: false)
    }

    private static func isUnclassified(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return true }
        return type == .data || type.isDynamic
    }

    private static func read(_ descriptor: Int32, maximum: Int, offset: off_t) throws -> Data {
        try Task.checkCancellation()
        var data = Data(count: maximum)
        let count = data.withUnsafeMutableBytes { buffer in
            Darwin.pread(descriptor, buffer.baseAddress, maximum, offset)
        }
        guard count >= 0 else {
            if errno == EINTR { return try read(descriptor, maximum: maximum, offset: offset) }
            throw error(for: errno)
        }
        data.count = count
        return data
    }

    private static func error(for code: Int32) -> FilePreviewError {
        code == ENOENT || code == ENOTDIR ? .missing : .unreadable
    }

    private static func looksLikeText(_ bytes: Data) -> Bool {
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return true
        }
        // A bounded sample can end in the middle of a UTF-8 scalar. Only the
        // final three bytes may be discarded for classification; the full load
        // below always validates every byte.
        for tail in 0...(bytes.count == sniffBytes ? 3 : 0) {
            if let text = String(bytes: bytes.dropLast(tail), encoding: .utf8), !containsBinaryControls(text) { return true }
        }
        return false
    }

    private static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return try decode32([UInt8](data), offset: 4, littleEndian: true) }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return try decode32([UInt8](data), offset: 4, littleEndian: false) }
        if data.starts(with: [0xFF, 0xFE]) { return try decode16([UInt8](data), littleEndian: true) }
        if data.starts(with: [0xFE, 0xFF]) { return try decode16([UInt8](data), littleEndian: false) }
        let payload = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
        let containsNUL = payload.withUnsafeBytes { bytes in
            bytes.count > 0 && memchr(bytes.baseAddress!, 0, bytes.count) != nil
        }
        if containsNUL { throw FilePreviewError.binary }
        // Foundation performs strict UTF-8 validation in its native decoder.
        // Avoid copying the complete file into an Array and validating through
        // a generic Swift collection, which is costly in local Debug builds.
        guard let result = String(data: payload, encoding: .utf8) else { throw FilePreviewError.invalidEncoding }
        return result
    }

    private static func decode16(_ bytes: [UInt8], littleEndian: Bool) throws -> String {
        guard (bytes.count - 2).isMultiple(of: 2) else { throw FilePreviewError.invalidEncoding }
        var units: [UInt16] = []
        units.reserveCapacity((bytes.count - 2) / 2)
        for index in stride(from: 2, to: bytes.count, by: 2) {
            if (index - 2).isMultiple(of: chunkBytes) { try Task.checkCancellation() }
            let first = UInt16(bytes[index]), second = UInt16(bytes[index + 1])
            units.append(littleEndian ? first | second << 8 : first << 8 | second)
        }
        guard let result = String(validating: units, as: Unicode.UTF16.self) else { throw FilePreviewError.invalidEncoding }
        return result
    }

    private static func decode32(_ bytes: [UInt8], offset: Int, littleEndian: Bool) throws -> String {
        guard (bytes.count - offset).isMultiple(of: 4) else { throw FilePreviewError.invalidEncoding }
        var units: [UInt32] = []
        units.reserveCapacity((bytes.count - offset) / 4)
        for index in stride(from: offset, to: bytes.count, by: 4) {
            if (index - offset).isMultiple(of: chunkBytes) { try Task.checkCancellation() }
            var value: UInt32 = 0
            for part in 0..<4 { value |= UInt32(bytes[index + part]) << (littleEndian ? part * 8 : (3 - part) * 8) }
            units.append(value)
        }
        guard let result = String(validating: units, as: Unicode.UTF32.self) else { throw FilePreviewError.invalidEncoding }
        return result
    }

    private static let binaryControlBytes: [Int32] = (0..<32).filter { ![9, 10, 12, 13, 27].contains($0) }.map(Int32.init)

    private static func containsBinaryControls(_ text: String) -> Bool {
        // A C0 scalar is represented by the same single byte in valid UTF-8;
        // it cannot occur inside a multibyte scalar. This is also exact for
        // strings decoded from BOM UTF-16/32. Keep tab/LF/FF/CR/ESC accepted.
        var text = text
        return text.withUTF8 { bytes in
            guard let base = bytes.baseAddress, !bytes.isEmpty else { return false }
            for value in binaryControlBytes {
                if memchr(base, value, bytes.count) != nil { return true }
            }
            return false
        }
    }
}

/// File identity plus nanosecond modification/change stamps. Size alone misses
/// a same-length edit, and the inode changes when an editor saves atomically.
struct PreviewFileMetadata: Hashable, Sendable {
    var device: Int32
    var inode: UInt64
    var byteCount: Int64
    var mode: UInt16
    var modificationSeconds: Int64
    var modificationNanoseconds: Int64
    var changeSeconds: Int64
    var changeNanoseconds: Int64

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        byteCount = info.st_size
        mode = info.st_mode
        modificationSeconds = Int64(info.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changeSeconds = Int64(info.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(info.st_ctimespec.tv_nsec)
    }

    var revision: String {
        "\(device):\(inode):\(byteCount):\(mode):\(modificationSeconds):\(modificationNanoseconds):\(changeSeconds):\(changeNanoseconds)"
    }

    static func read(_ url: URL) -> Self? {
        var info = stat()
        guard url.path.withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0 else { return nil }
        return Self(info)
    }
}
