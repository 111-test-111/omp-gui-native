import Darwin
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    var description: String
}

@main
@MainActor
private enum FilePreviewChecks {
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(description: message) }
    }

    private static func expectError(_ expected: FilePreviewError, _ body: () async throws -> Void) async throws {
        do {
            try await body()
            throw CheckFailure(description: "Expected preview error \(expected)")
        } catch let error as FilePreviewError {
            try expect(error == expected, "Wrong preview error: \(error), expected \(expected)")
        }
    }

    private static func target(_ url: URL) -> FilePreviewTarget { FilePreviewTarget(url: url) }

    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omp-preview-checks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try checkResolver(root)
        print("PASS resolver: relative/absolute/file URL/tilde, coordinates, literal colon names, symlinks, missing paths, remote rejection")
        try await checkLoader(root)
        print("PASS loader: strict UTF-8/16/32, BOMs, binary/invalid/missing/directory/FIFO states, 2 MiB bound, kinds, revisions, cancellation")
        try await checkOpening(root)
        print("PASS opening: combined resolution/read, file errors retained, directories/packages, visible snapshot revision reuse, bounded pinning, cancellation")
        try await checkBrowser(root)
        print("PASS browser: shallow bounded listing, folders first, cache filtering, opaque packages, symlink metadata, hidden toggle, cancellation")
        try await checkWatcher(root)
        print("PASS watcher: debounced edits, sibling filtering, atomic replacement, deletion/recreation, missing parent, stop/deinit and descriptor teardown")
    }

    private static func checkResolver(_ root: URL) throws {
        let nested = root.appendingPathComponent("folder with space", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("你好 name.swift")
        try Data("line one\nline two\n".utf8).write(to: file)
        let expected = file.resolvingSymlinksInPath().standardizedFileURL
        let relative = try FilePreviewResolver.resolve(FilePreviewReference(path: "../你好 name.swift:2:4"), relativeTo: nested.path)
        try expect(relative.url == expected && relative.location == FilePreviewLocation(line: 2, column: 4), "Relative coordinate parsing failed")
        let absolute = try FilePreviewResolver.resolve(FilePreviewReference(path: file.path, line: 3, column: 2), relativeTo: "")
        try expect(absolute.url == expected && absolute.location == FilePreviewLocation(line: 3, column: 2), "Absolute explicit coordinate parsing failed")
        let escapedName = "../%E4%BD%A0%E5%A5%BD%20name.swift:2:4"
        let escapedRelative = try FilePreviewResolver.resolve(FilePreviewReference(path: escapedName), relativeTo: nested.path)
        try expect(escapedRelative == relative, "Escaped relative Unicode/spaces lost coordinates")
        let escapedAbsolute = try FilePreviewResolver.resolve(FilePreviewReference(path: file.path.replacingOccurrences(of: "你好 name", with: "%E4%BD%A0%E5%A5%BD%20name")), relativeTo: "")
        try expect(escapedAbsolute.url == expected, "Escaped absolute Unicode/spaces failed")
        let fileURL = try FilePreviewResolver.resolve(FilePreviewReference(path: file.absoluteString + "#L7C3"), relativeTo: root.path)
        try expect(fileURL.url == expected && fileURL.location == FilePreviewLocation(line: 7, column: 3), "File URL decoding or fragment failed")
        let fragment = try FilePreviewResolver.resolve(FilePreviewReference(path: file.path + "#L7-L9"), relativeTo: root.path)
        try expect(fragment.url == expected && fragment.location?.line == 7, "Raw line range fragment failed")
        let missing = try FilePreviewResolver.resolve(FilePreviewReference(path: "missing.swift:42"), relativeTo: root.path)
        try expect(missing.url.lastPathComponent == "missing.swift" && missing.location?.line == 42, "Missing target could not be resolved")
        let colon = root.appendingPathComponent("report:2026")
        try Data("report".utf8).write(to: colon)
        let literal = try FilePreviewResolver.resolve(FilePreviewReference(path: colon.path), relativeTo: root.path)
        try expect(literal.url.lastPathComponent == "report:2026" && literal.location == nil, "Existing colon filename was split")
        let colonLine = try FilePreviewResolver.resolve(FilePreviewReference(path: colon.path + ":7"), relativeTo: root.path)
        try expect(colonLine.url.lastPathComponent == "report:2026" && colonLine.location == FilePreviewLocation(line: 7), "Colon filename plus line was split incorrectly")
        let fullColon = root.appendingPathComponent("file.swift:12:4")
        try Data().write(to: fullColon)
        let literalCoordinates = try FilePreviewResolver.resolve(FilePreviewReference(path: fullColon.path), relativeTo: root.path)
        try expect(literalCoordinates.url.lastPathComponent == "file.swift:12:4" && literalCoordinates.location == nil, "Literal coordinate filename was split")
        let literalPercent = root.appendingPathComponent("report%20.txt")
        let decodedPercent = root.appendingPathComponent("report .txt")
        try Data().write(to: literalPercent)
        try Data().write(to: decodedPercent)
        let preservedPercent = try FilePreviewResolver.resolve(FilePreviewReference(path: "report%20.txt"), relativeTo: root.path)
        try expect(preservedPercent.url.lastPathComponent == "report%20.txt", "Existing literal percent filename was decoded")
        let preservedPercentLocation = try FilePreviewResolver.resolve(FilePreviewReference(path: "report%20.txt:8"), relativeTo: root.path)
        try expect(preservedPercentLocation.url.lastPathComponent == "report%20.txt" && preservedPercentLocation.location?.line == 8, "Literal percent filename plus line was decoded")
        let onceDecoded = try FilePreviewResolver.resolve(FilePreviewReference(path: "report%2520.txt"), relativeTo: root.path)
        try expect(onceDecoded.url.lastPathComponent == "report%20.txt", "Plain path percent escapes were decoded more than once")
        let percentURL = try FilePreviewResolver.resolve(FilePreviewReference(path: literalPercent.absoluteString), relativeTo: root.path)
        try expect(percentURL.url.lastPathComponent == "report%20.txt", "File URL was decoded more than once")
        for (name, encoded) in [("hash#L12.txt", "hash%23L12.txt"), ("colon:12", "colon%3A12")] {
            try Data().write(to: root.appendingPathComponent(name))
            let resolved = try FilePreviewResolver.resolve(FilePreviewReference(path: encoded), relativeTo: root.path)
            try expect(resolved.url.lastPathComponent == name && resolved.location == nil, "Escaped delimiter became a coordinate")
            let located = try FilePreviewResolver.resolve(FilePreviewReference(path: encoded + ":9"), relativeTo: root.path)
            try expect(located.url.lastPathComponent == name && located.location?.line == 9, "Escaped delimiter plus explicit coordinate failed")
        }
        let missingEscaped = try FilePreviewResolver.resolve(FilePreviewReference(path: "missing%23L12%3A9"), relativeTo: root.path)
        try expect(missingEscaped.url.lastPathComponent == "missing#L12:9" && missingEscaped.location == nil, "Missing escaped delimiters became navigation suffixes")
        let missingEscapedURL = try FilePreviewResolver.resolve(FilePreviewReference(path: root.appendingPathComponent("missing:12").absoluteString.replacingOccurrences(of: ":12", with: "%3A12")), relativeTo: root.path)
        try expect(missingEscapedURL.url.lastPathComponent == "missing:12" && missingEscapedURL.location == nil, "Missing file URL escaped colon became a coordinate")
        let readRange = try FilePreviewResolver.resolve(FilePreviewReference(path: file.path + ":2-4"), relativeTo: root.path)
        try expect(readRange.url == expected && readRange.location == FilePreviewLocation(line: 2), "Legacy read range did not open its first line")
        let literalRange = root.appendingPathComponent("report:2-4")
        try Data().write(to: literalRange)
        let preservedRange = try FilePreviewResolver.resolve(FilePreviewReference(path: literalRange.path), relativeTo: root.path)
        try expect(preservedRange.url.lastPathComponent == "report:2-4" && preservedRange.location == nil, "Existing literal range filename was split")
        for suffix in [":4-2", ":0-3", ":3-", ":3-a", ":3-5-7", ":9999999999999999999999-99999999999999999999999"] {
            let malformed = try FilePreviewResolver.resolve(FilePreviewReference(path: "missing.swift" + suffix), relativeTo: root.path)
            try expect(malformed.url.lastPathComponent == "missing.swift" + suffix && malformed.location == nil, "Malformed range became coordinates")
        }
        let alias = root.appendingPathComponent("alias.swift")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        let symlink = try FilePreviewResolver.resolve(FilePreviewReference(path: alias.path), relativeTo: root.path)
        try expect(symlink.identity == relative.identity, "Symbolic link aliases have different identities")
        let tilde = try FilePreviewResolver.resolve(FilePreviewReference(path: "~"), relativeTo: root.path)
        try expect(tilde.url == FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL, "Tilde was not expanded")
        try expect(!FilePreviewResolver.isLocalReference("https://example.com/file.swift") && !FilePreviewResolver.isLocalReference("mailto:a@example.com"), "Remote reference was classified local")
        try expect(FilePreviewResolver.isLocalReference("./http:literal") && FilePreviewResolver.isLocalReference(file.absoluteString), "Local reference was rejected")
        do {
            _ = try FilePreviewResolver.resolve(FilePreviewReference(path: "https://example.com/file"), relativeTo: root.path)
            throw CheckFailure(description: "Remote URL resolved")
        } catch FilePreviewError.nonLocalReference { }
        do {
            _ = try FilePreviewResolver.resolve(FilePreviewReference(path: file.path, line: 0), relativeTo: root.path)
            throw CheckFailure(description: "Nonpositive location resolved")
        } catch FilePreviewError.invalidLocation { }
        do {
            _ = try FilePreviewResolver.resolve(FilePreviewReference(path: "file%00.txt"), relativeTo: root.path)
            throw CheckFailure(description: "Encoded NUL path resolved")
        } catch FilePreviewError.invalidReference { }
    }

    private static func checkLoader(_ root: URL) async throws {
        let text = "Hello 你好🙂\nSecond line\n"
        let encodings: [(String, String.Encoding, [UInt8])] = [
            ("utf8", .utf8, []), ("utf8-bom", .utf8, [0xEF, 0xBB, 0xBF]),
            ("utf16-le", .utf16LittleEndian, [0xFF, 0xFE]), ("utf16-be", .utf16BigEndian, [0xFE, 0xFF]),
            ("utf32-le", .utf32LittleEndian, [0xFF, 0xFE, 0, 0]), ("utf32-be", .utf32BigEndian, [0, 0, 0xFE, 0xFF]),
        ]
        for (name, encoding, prefix) in encodings {
            let file = root.appendingPathComponent(name + ".txt")
            var data = Data(prefix)
            data.append(text.data(using: encoding)!)
            try data.write(to: file)
            let loaded = try await PreviewFileLoader.load(target(file))
            try expect(loaded.text == text && loaded.kind == .text && !loaded.isTruncated && loaded.byteCount == data.count, "\(name) round trip failed")
        }
        let invalidCases: [(String, [UInt8], FilePreviewError)] = [
            ("invalid-utf8", [0xFF, 0xFF, 0xFF], .invalidEncoding),
            ("utf8-continuation", [0x80], .invalidEncoding),
            ("utf8-overlong", [0xC0, 0xAF], .invalidEncoding),
            ("utf8-truncated", [0xE2, 0x82], .invalidEncoding),
            ("utf8-surrogate", [0xED, 0xA0, 0x80], .invalidEncoding),
            ("utf8-out-of-range", [0xF4, 0x90, 0x80, 0x80], .invalidEncoding),
            ("invalid-utf16", [0xFF, 0xFE, 0, 0xD8], .invalidEncoding),
            ("invalid-utf32", [0xFF, 0xFE, 0, 0, 0, 0, 0x11, 0], .invalidEncoding),
            ("binary", [0x41, 0, 0x42], .binary),
        ]
        for (name, bytes, error) in invalidCases {
            let file = root.appendingPathComponent(name + ".txt")
            try Data(bytes).write(to: file)
            try await expectError(error) { _ = try await PreviewFileLoader.load(target(file)) }
        }
        // C0 detection is exact across every accepted encoding, including its
        // historical tab/LF/FF/CR/ESC allowances. DEL/C1 are not C0 controls.
        let controls = root.appendingPathComponent("controls.txt")
        for unit in 0..<32 {
            let controlText = "A" + String(Unicode.Scalar(unit)!) + "B"
            for (_, encoding, prefix) in encodings {
                var bytes = Data(prefix)
                bytes.append(controlText.data(using: encoding)!)
                try bytes.write(to: controls)
                if [9, 10, 12, 13, 27].contains(unit) {
                    let loaded = try await PreviewFileLoader.load(target(controls))
                    try expect(loaded.text == controlText, "Permitted C0 scalar \(unit) was rejected")
                } else {
                    try await expectError(.binary) { _ = try await PreviewFileLoader.load(target(controls)) }
                }
            }
        }
        let c1Text = "A\u{7F}\u{80}\u{9F}你好🙂B"
        try Data(c1Text.utf8).write(to: controls)
        let c1Loaded = try await PreviewFileLoader.load(target(controls))
        try expect(c1Loaded.text == c1Text, "C1 or multibyte Unicode bytes were misclassified as C0 controls")
        let unknown = root.appendingPathComponent("unknown-format.opaque")
        try Data([0, 1, 2, 255, 254]).write(to: unknown)
        let binary = try await PreviewFileLoader.load(target(unknown))
        try expect(binary.kind == .quickLook && binary.text == nil, "Unknown binary did not reach Quick Look")
        let extensionless = root.appendingPathComponent("extensionless")
        let boundaryText = String(repeating: "a", count: 8_191) + "🙂some source"
        try Data(boundaryText.utf8).write(to: extensionless)
        let sniffed = try await PreviewFileLoader.load(target(extensionless))
        try expect(sniffed.kind == .text && sniffed.text == boundaryText, "UTF-8 sample boundary broke extensionless source")

        let kinds: [(String, FilePreviewKind)] = [("Makefile", .text), ("Dockerfile.dev", .text), ("CMakeLists.txt", .text), ("paper.tex", .text), ("class.cls", .text), ("main.zig", .text), ("app.fsx", .text), (".env.production", .text), ("file.html", .text), ("file.svg", .text), ("file.md", .markdown), ("image.png", .image), ("document.pdf", .pdf), ("movie.mp4", .media), ("document.docx", .quickLook)]
        for (name, kind) in kinds {
            let file = root.appendingPathComponent(name)
            try Data("source".utf8).write(to: file)
            let loaded = try await PreviewFileLoader.load(target(file))
            try expect(loaded.kind == kind, "Wrong preview kind for \(name): \(loaded.kind)")
        }
        let large = root.appendingPathComponent("large.txt")
        let limit = Int(PreviewFileLoader.maxTextBytes)
        try Data(repeating: 0x61, count: limit).write(to: large)
        let full = try await PreviewFileLoader.load(target(large))
        try expect(full.text?.utf8.count == limit && !full.isTruncated, "Source at exact limit was truncated")
        try Data(repeating: 0x61, count: limit + 1).write(to: large)
        try await expectError(.tooLarge(limit: PreviewFileLoader.maxTextBytes)) { _ = try await PreviewFileLoader.load(target(large)) }
        try await expectError(.missing) { _ = try await PreviewFileLoader.load(target(root.appendingPathComponent("absent.txt"))) }
        try await expectError(.directory) { _ = try await PreviewFileLoader.load(target(root)) }

        let fifo = root.appendingPathComponent("pipe.txt")
        guard fifo.path.withCString({ mkfifo($0, 0o600) }) == 0 else { throw CheckFailure(description: "Could not create FIFO fixture") }
        try await expectError(.unsupportedFile) { _ = try await PreviewFileLoader.load(target(fifo)) }
        let permissions = root.appendingPathComponent("permissions.txt")
        try Data(text.utf8).write(to: permissions)
        permissions.path.withCString { _ = chmod($0, 0) }
        if geteuid() != 0 {
            try await expectError(.unreadable) { _ = try await PreviewFileLoader.load(target(permissions)) }
        }
        permissions.path.withCString { _ = chmod($0, 0o600) }
        let before = try await PreviewFileLoader.load(target(permissions))
        try Data(String(repeating: "x", count: text.utf8.count).utf8).write(to: permissions)
        let after = try await PreviewFileLoader.load(target(permissions))
        try expect(before.byteCount == after.byteCount && before.revision != after.revision, "Same-length edit did not change revision")
        let cancelled = Task { try Task.checkCancellation(); return try await PreviewFileLoader.load(target(permissions)) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw CheckFailure(description: "Cancelled source load completed") } catch is CancellationError { }
    }

    private static func checkOpening(_ root: URL) async throws {
        let source = root.appendingPathComponent("opening.swift")
        try Data("let first = 1\nlet second = 2\n".utf8).write(to: source)
        let reference = FilePreviewReference(path: "opening.swift:2:4")
        let opened = try await PreviewFileLoader.open(reference, relativeTo: root.path)
        guard case .success(let snapshot)? = opened.content else {
            throw CheckFailure(description: "Combined opening did not load its selected file")
        }
        try expect(!opened.isDirectory && opened.target.url == source.resolvingSymlinksInPath().standardizedFileURL
                   && opened.target.location == FilePreviewLocation(line: 2, column: 4), "Combined opening lost resolved navigation")
        try expect(snapshot.text == "let first = 1\nlet second = 2\n", "Combined opening changed complete source")

        // A tagged snapshot proves the equal-revision path reuses its value
        // instead of re-reading the file. Production passes only the one
        // already-visible snapshot; the service retains no cache of its own.
        var tagged = snapshot
        tagged.text = "already visible source"
        let reused = try await PreviewFileLoader.open(reference, relativeTo: root.path, reusing: tagged)
        guard case .success(let reusedSnapshot)? = reused.content else { throw CheckFailure(description: "Snapshot reuse failed") }
        try expect(reusedSnapshot.text == tagged.text && reused.target.location == opened.target.location,
                   "An unchanged current snapshot was re-read or lost its navigation")
        let classified = try await PreviewFileLoader.open(reference, relativeTo: root.path, readsContent: false, reusing: tagged)
        try expect(!classified.isDirectory && classified.content == nil, "Pinning eagerly retained a document")

        try Data("let changed = 3\n".utf8).write(to: source, options: .atomic)
        let changed = try await PreviewFileLoader.open(reference, relativeTo: root.path, reusing: tagged)
        guard case .success(let changedSnapshot)? = changed.content else { throw CheckFailure(description: "Changed source opening failed") }
        try expect(changedSnapshot.text == "let changed = 3\n" && changedSnapshot.revision != snapshot.revision,
                   "Atomic replacement reused stale visible content")
        let other = root.appendingPathComponent("other-opening.swift")
        try Data("let other = true\n".utf8).write(to: other)
        let different = try await PreviewFileLoader.open(FilePreviewReference(path: other.path), relativeTo: root.path, reusing: tagged)
        guard case .success(let otherSnapshot)? = different.content else { throw CheckFailure(description: "Different file opening failed") }
        try expect(otherSnapshot.text == "let other = true\n", "Snapshot reuse crossed file identities")

        let directory = try await PreviewFileLoader.open(FilePreviewReference(path: root.path), relativeTo: root.path)
        let directoryOnly = try await PreviewFileLoader.open(FilePreviewReference(path: root.path), relativeTo: root.path, readsContent: false)
        try expect(directory.isDirectory && directory.content == nil && directoryOnly.isDirectory && directoryOnly.content == nil,
                   "Opening treated a directory as a file")
        let package = root.appendingPathComponent("Opening.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let packageOnly = try await PreviewFileLoader.open(FilePreviewReference(path: package.path), relativeTo: root.path, readsContent: false)
        let packageOpened = try await PreviewFileLoader.open(FilePreviewReference(path: package.path), relativeTo: root.path)
        guard case .success(let packageSnapshot)? = packageOpened.content else { throw CheckFailure(description: "Document package was not previewable") }
        try expect(!packageOnly.isDirectory && packageOnly.content == nil && !packageOpened.isDirectory && packageSnapshot.kind == .quickLook,
                   "Opening traversed a document package instead of previewing it")
        for (name, expected) in [("absent-opening.swift", FilePreviewError.missing), ("large.txt", .tooLarge(limit: PreviewFileLoader.maxTextBytes)), ("binary.txt", .binary), ("pipe.txt", .unsupportedFile)] {
            let file = FilePreviewReference(path: name)
            let error = try await PreviewFileLoader.open(file, relativeTo: root.path)
            guard case .failure(let failure)? = error.content else { throw CheckFailure(description: "Opening discarded file error \(expected)") }
            try expect(!error.isDirectory && failure == expected && error.target.url.lastPathComponent == name,
                       "Opening did not retain the failed file's target and error")
            let pin = try await PreviewFileLoader.open(file, relativeTo: root.path, readsContent: false)
            try expect(!pin.isDirectory && pin.content == nil, "Classifying a pinned file tried to load its contents")
        }
        try await expectError(.nonLocalReference) {
            _ = try await PreviewFileLoader.open(FilePreviewReference(path: "https://example.com/source.swift"), relativeTo: root.path)
        }
        let cancelled = Task { try await PreviewFileLoader.open(reference, relativeTo: root.path) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw CheckFailure(description: "Cancelled opening completed") } catch is CancellationError { }
    }

    private static func checkBrowser(_ root: URL) async throws {
        let browser = root.appendingPathComponent("browser", isDirectory: true)
        try FileManager.default.createDirectory(at: browser, withIntermediateDirectories: true)
        for name in ["z-folder", "a-folder", ".git", "node_modules", "build.noindex", ".hidden"] {
            try FileManager.default.createDirectory(at: browser.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: browser.appendingPathComponent("b.txt"))
        try FileManager.default.createSymbolicLink(at: browser.appendingPathComponent("alias-folder"), withDestinationURL: browser.appendingPathComponent("a-folder"))
        let listing = try await PreviewDirectoryBrowser.list(browser)
        try expect(listing.entries.map(\.name) == ["a-folder", "alias-folder", "z-folder", "b.txt"], "Directory order or default cache filtering failed")
        try expect(listing.entries[1].isSymbolicLink && listing.entries[1].isDirectory, "Directory symlink was not classified")
        let hidden = try await PreviewDirectoryBrowser.list(browser, showHidden: true)
        try expect(hidden.entries.contains { $0.name == ".git" } && hidden.entries.contains { $0.name == "node_modules" }, "Explicit hidden/cache view omitted files")
        let large = root.appendingPathComponent("many-files", isDirectory: true)
        try FileManager.default.createDirectory(at: large, withIntermediateDirectories: true)
        for index in 0...PreviewDirectoryBrowser.maxEntries { try Data().write(to: large.appendingPathComponent("file-\(index)")) }
        let bounded = try await PreviewDirectoryBrowser.list(large)
        try expect(bounded.entries.count == PreviewDirectoryBrowser.maxEntries && bounded.isTruncated, "Directory row limit was not disclosed")
        let nestedFolder = browser.appendingPathComponent("a-folder/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)
        try Data().write(to: nestedFolder.appendingPathComponent("match-你好.swift"))
        try Data().write(to: browser.appendingPathComponent("node_modules/match-secret.swift"))
        try Data().write(to: browser.appendingPathComponent(".hidden/match-secret.swift"))
        let package = browser.appendingPathComponent("Document.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data().write(to: package.appendingPathComponent("match-secret.swift"))
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data().write(to: outside.appendingPathComponent("match-outside.swift"))
        try FileManager.default.createSymbolicLink(at: browser.appendingPathComponent("external-link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: browser.appendingPathComponent("match-outside-link.swift"), withDestinationURL: outside.appendingPathComponent("match-outside.swift"))
        let shallow = try await PreviewDirectoryBrowser.list(browser)
        try expect(!shallow.isTruncated && !shallow.entries.contains { $0.name.hasPrefix("match-") && !$0.isSymbolicLink },
                   "Listing recursively exposed nested, hidden, package or symlink-target contents")
        let expanded = try await PreviewDirectoryBrowser.list(nestedFolder)
        try expect(expanded.entries.map(\.name) == ["match-你好.swift"] && !expanded.isTruncated,
                   "Explicit directory expansion omitted a Unicode filename")
        let bundle = shallow.entries.first { $0.name == "Document.app" }
        try expect(bundle?.isDirectory == false && bundle?.isSymbolicLink == false,
                   "Document package was exposed as an expandable directory")
        let directoryLink = shallow.entries.first { $0.name == "external-link" }
        let fileLink = shallow.entries.first { $0.name == "match-outside-link.swift" }
        try expect(directoryLink?.isSymbolicLink == true && directoryLink?.isDirectory == true
                    && directoryLink?.url.path == browser.appendingPathComponent("external-link").path
                    && fileLink?.isSymbolicLink == true && fileLink?.isDirectory == false,
                   "Shallow listing lost symlink identity or target-kind metadata")
        let hiddenOnly = root.appendingPathComponent("many-hidden-files", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenOnly, withIntermediateDirectories: true)
        for index in 0...PreviewDirectoryBrowser.maxListingScanEntries { try Data().write(to: hiddenOnly.appendingPathComponent(".hidden-\(index)")) }
        let hiddenOnlyListing = try await PreviewDirectoryBrowser.list(hiddenOnly)
        try expect(hiddenOnlyListing.entries.isEmpty && hiddenOnlyListing.isTruncated, "All-hidden folder scan escaped its hard limit")
        try await expectError(.nonLocalReference) { _ = try await PreviewDirectoryBrowser.list(URL(string: "https://example.com/files")!) }
        try await expectError(.missing) { _ = try await PreviewDirectoryBrowser.list(browser.appendingPathComponent("missing-folder")) }
        try await expectError(.missing) { _ = try await PreviewDirectoryBrowser.list(browser.appendingPathComponent("b.txt")) }
        let cancelled = Task { try Task.checkCancellation(); return try await PreviewDirectoryBrowser.list(browser) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw CheckFailure(description: "Cancelled listing completed") } catch is CancellationError { }
    }

    @MainActor
    private static func awaitCondition(_ message: String, _ condition: @MainActor () -> Bool) async throws {
        let timeout = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now >= timeout { throw CheckFailure(description: message) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func descriptorCount() -> Int {
        (0..<1_024).reduce(into: 0) { count, descriptor in
            if fcntl(Int32(descriptor), F_GETFD) >= 0 { count += 1 }
        }
    }

    @MainActor
    private static func checkWatcher(_ root: URL) async throws {
        let folder = root.appendingPathComponent("watched", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("source.txt")
        try Data("before".utf8).write(to: file)
        var changes = 0
        var watch: PreviewFileWatch? = PreviewFileWatch(url: file) { changes += 1 }
        weak let released = watch
        try Data("first".utf8).write(to: file)
        try await Task.sleep(for: .milliseconds(50))
        try Data("second".utf8).write(to: file)
        try await awaitCondition("In-place file write was not observed") { changes >= 1 }
        try await Task.sleep(for: .milliseconds(300))
        try expect(changes == 1, "Burst writes were not debounced")
        try Data("sibling".utf8).write(to: folder.appendingPathComponent("other.txt"))
        try await Task.sleep(for: .milliseconds(400))
        try expect(changes == 1, "Unrelated sibling write reloaded the preview")
        let before = try await PreviewFileLoader.load(target(file))
        try Data("atomic".utf8).write(to: file, options: .atomic)
        try await awaitCondition("Atomic replacement was not observed") { changes >= 2 }
        let replaced = try await PreviewFileLoader.load(target(file))
        try expect(replaced.text == "atomic" && before.revision != replaced.revision, "Atomic replacement served a stale snapshot")
        try FileManager.default.removeItem(at: file)
        try await awaitCondition("Deletion was not observed") { changes >= 3 }
        try await expectError(.missing) { _ = try await PreviewFileLoader.load(target(file)) }
        try Data("recreated".utf8).write(to: file)
        try await awaitCondition("Recreation was not observed") { changes >= 4 }
        try FileManager.default.removeItem(at: folder)
        try await awaitCondition("Parent deletion was not observed") { changes >= 5 }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("new parent".utf8).write(to: file)
        try await awaitCondition("Parent recreation was not observed") { changes >= 6 }
        let continuousStart = changes
        var writing = true
        let writer = Task {
            for index in 0..<30 {
                try Data("continuous \(index)".utf8).write(to: file)
                try await Task.sleep(for: .milliseconds(40))
            }
            writing = false
        }
        try await awaitCondition("Continuous writes starved the debounced refresh") { changes > continuousStart && writing }
        try await writer.value
        try await Task.sleep(for: .milliseconds(300))
        watch?.stop()
        let stoppedAt = changes
        try Data("after stop".utf8).write(to: file)
        try await Task.sleep(for: .milliseconds(400))
        try expect(changes == stoppedAt, "Stopped watcher still called back")
        watch = nil
        try expect(released == nil, "Watcher has a retain cycle")
        try await Task.sleep(for: .milliseconds(100))

        let absent = root.appendingPathComponent("not-created/yet/file.txt")
        var absentChanges = 0
        var absentWatch: PreviewFileWatch? = PreviewFileWatch(url: absent) { absentChanges += 1 }
        try FileManager.default.createDirectory(at: absent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("appeared".utf8).write(to: absent)
        try await awaitCondition("Initially missing parent was not observed") { absentChanges == 1 }
        absentWatch?.stop()
        absentWatch = nil
        try await Task.sleep(for: .milliseconds(200))

        // A preloaded frame can become stale before its watcher is installed.
        // No write occurs after initialization, so vnode events alone cannot
        // repair this gap: the expected revision must trigger the refresh.
        let prepared = try await PreviewFileLoader.load(target(file))
        try Data("replaced before installing watch".utf8).write(to: file, options: .atomic)
        var initialChanges = 0
        let preparedWatch = PreviewFileWatch(url: file, expectedRevision: prepared.revision) { initialChanges += 1 }
        try await awaitCondition("Preloaded file replacement became a silent watcher baseline") { initialChanges == 1 }
        preparedWatch.stop()
        try await Task.sleep(for: .milliseconds(200))

        // Dispatch infrastructure is warmed above. Repeated creation/destruction
        // should close both vnode descriptors, not accumulate one per tab switch.
        let baseline = descriptorCount()
        for _ in 0..<48 {
            var temporary: PreviewFileWatch? = PreviewFileWatch(url: file) { }
            weak let weakTemporary = temporary
            temporary = nil
            try expect(weakTemporary == nil, "Destroying an active watcher leaked it")
        }
        try await Task.sleep(for: .milliseconds(400))
        try expect(descriptorCount() <= baseline + 1, "Watcher vnode descriptors leaked after teardown")
    }
}
