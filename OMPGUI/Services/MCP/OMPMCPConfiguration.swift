import Darwin
import Foundation

struct OMPMCPSnapshot: Identifiable, Sendable {
    let id = UUID()
    var directory: URL
    var resolvedDirectory: URL
    var original: Data?
    var context: OMPDiscoveryContext

    var url: URL { directory.appendingPathComponent("mcp.json") }
    var text: String { original.map { String(decoding: $0, as: UTF8.self) } ?? OMPMCPDocument.empty.prettyString }
    func document() throws -> JSONValue { try OMPMCPDocument.decode(text) }
}

/// Edits only the active profile's public native MCP file. No project discovery,
/// connection, secret resolution, authentication or package execution occurs here.
enum OMPMCPConfiguration {
    static let byteLimit = OMPMCPDocument.byteLimit

    @MainActor static func context(registry: ProviderRegistry) -> OMPDiscoveryContext? {
        guard let executable = registry.executable(for: .omp) else { return nil }
        return OMPDiscoveryContext(executable: executable,
            environment: OMPCLI.profileConfigurationEnvironment(registry.environment(for: .omp)))
    }

    static func activeDirectory(_ context: OMPDiscoveryContext) async throws -> URL {
        let path = try await OMPCLI.run(["config", "path"], executable: context.executable,
                                       environment: context.environment)
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n") else {
            throw OMPMCPDocument.failure("OMP returned an invalid active profile path.")
        }
        return URL(fileURLWithPath: path)
    }

    static func read(context: OMPDiscoveryContext) async throws -> OMPMCPSnapshot {
        let directory = try await activeDirectory(context)
        return try await read(directory: directory, context: context)
    }

    @concurrent static func read(directory: URL, context: OMPDiscoveryContext) async throws -> OMPMCPSnapshot {
        let resolved = directory.resolvingSymlinksInPath()
        let original = try contents(directory.appendingPathComponent("mcp.json"))
        guard directory.resolvingSymlinksInPath() == resolved else { throw conflict() }
        return OMPMCPSnapshot(directory: directory, resolvedDirectory: resolved, original: original, context: context)
    }

    @MainActor static func save(_ value: JSONValue, snapshot: OMPMCPSnapshot,
                               currentContext: () -> OMPDiscoveryContext?) async throws -> OMPMCPSnapshot {
        guard currentContext() == snapshot.context else { throw conflict() }
        let directory = try await activeDirectory(snapshot.context)
        try Task.checkCancellation()
        guard currentContext() == snapshot.context, directory == snapshot.directory else { throw conflict() }
        return try await commit(value, snapshot: snapshot)
    }

    @MainActor static func prepareForOpening(context: OMPDiscoveryContext,
                                            currentContext: () -> OMPDiscoveryContext?) async throws -> URL {
        guard currentContext() == context else { throw conflict() }
        let directory = try await activeDirectory(context)
        try Task.checkCancellation()
        guard currentContext() == context else { throw conflict() }
        let url = try await prepareFile(directory: directory, context: context)
        guard currentContext() == context else { throw conflict() }
        return url
    }

    @concurrent private static func prepareFile(directory: URL, context: OMPDiscoveryContext) async throws -> URL {
        let resolved = directory.resolvingSymlinksInPath()
        let url = directory.appendingPathComponent("mcp.json")
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor >= 0 {
            defer { close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0 else { throw posixError() }
            guard status.st_mode & S_IFMT == S_IFREG else { throw unsafeFile() }
            guard directory.resolvingSymlinksInPath() == resolved else { throw conflict() }
            // External editors can repair malformed or oversized files without loading them here.
            return url
        }
        if errno == ELOOP { throw unsafeFile() }
        guard errno == ENOENT else { throw posixError() }
        let snapshot = OMPMCPSnapshot(directory: directory, resolvedDirectory: resolved, original: nil, context: context)
        return try await commit(OMPMCPDocument.empty, snapshot: snapshot).url
    }

    @concurrent static func commit(_ value: JSONValue, snapshot: OMPMCPSnapshot) async throws -> OMPMCPSnapshot {
        try Task.checkCancellation()
        try OMPMCPDocument.validate(value)
        let data = value.data(pretty: true)
        guard data.count <= byteLimit else { throw tooLarge() }
        let manager = FileManager.default
        guard snapshot.directory.resolvingSymlinksInPath() == snapshot.resolvedDirectory else { throw conflict() }
        try manager.createDirectory(at: snapshot.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Match OMP's public writer's macOS flock lease. Keep the lock inode
        // in place so another writer cannot accidentally lock a different one.
        let lock = snapshot.url.appendingPathExtension("lock")
        let lease = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lease >= 0 else { throw posixError() }
        defer { close(lease) }
        var leaseStatus = stat()
        guard fstat(lease, &leaseStatus) == 0, leaseStatus.st_mode & S_IFMT == S_IFREG else { throw unsafeFile() }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            throw OMPMCPDocument.failure("MCP configuration is busy. Try again after the other editor finishes.")
        }
        defer { flock(lease, LOCK_UN) }
        guard try contents(snapshot.url) == snapshot.original else { throw conflict() }
        if let original = snapshot.original, JSONValue.parse(original) == value { return snapshot }
        let temporary = snapshot.directory.appendingPathComponent(".mcp-" + UUID().uuidString + ".tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? manager.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try Task.checkCancellation()
        guard snapshot.directory.resolvingSymlinksInPath() == snapshot.resolvedDirectory,
              try contents(snapshot.url) == snapshot.original else { throw conflict() }
        guard rename(temporary.path, snapshot.url.path) == 0 else { throw posixError() }
        var saved = snapshot
        saved.original = data
        return saved
    }

    private static func contents(_ url: URL) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw unsafeFile() }
            throw posixError()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw posixError() }
        guard status.st_mode & S_IFMT == S_IFREG else { throw unsafeFile() }
        guard status.st_size <= byteLimit else { throw tooLarge() }
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        guard data.count <= byteLimit else { throw tooLarge() }
        return data
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private static func conflict() -> OMPMCPError { OMPMCPDocument.failure("The OMP configuration changed. Reopen the editor before saving.") }
    private static func tooLarge() -> OMPMCPError { OMPMCPDocument.failure("MCP configuration exceeds the 2 MiB editing limit.") }
    private static func unsafeFile() -> OMPMCPError { OMPMCPDocument.failure("MCP configuration must be a regular file, not a symbolic link.") }
}
