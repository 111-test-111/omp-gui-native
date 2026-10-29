import CryptoKit
import Darwin
import Foundation

/// Read exact, bounded bytes without following a substituted index symlink.
/// Git's own index.lock is the cross-process admission boundary for writes.
enum GitWorkspaceIndex {
    static let maximumBytes = 32 * 1_024 * 1_024

    static func read(_ url: URL, limit: Int = maximumBytes, missing: Bool = true) throws -> Data? {
        let fd = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        if fd < 0 {
            if errno == ENOENT, missing { return nil }
            throw GitWriteError.unsupportedIndex
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw GitWriteError.unsupportedIndex }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit, bytes.count == info.st_size else { throw GitWriteError.unsupportedIndex }
        return bytes
    }

    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    static func revision(_ location: GitRepositoryLocation, head: String?) throws -> GitWorkspaceRevision {
        guard let headFile = try read(location.gitDirectory.appendingPathComponent("HEAD"), limit: 65_536, missing: false) else {
            throw GitWriteError.unsupportedIndex
        }
        let text = String(data: headFile, encoding: .utf8) ?? ""
        let reference = text.hasPrefix("ref: ") && text.hasSuffix("\n") ? String(text.dropFirst(5).dropLast()) : nil
        return .init(head: head, headFile: digest(headFile), index: try read(location.indexFile).map(digest), reference: reference)
    }
}
