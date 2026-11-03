import Foundation

/// OMP owns the lease and the final claim. The GUI only probes before resume,
/// then checks the returned identity so a racing owner cannot silently fork it.
struct OMPResumeTarget: Sendable {
    let file: URL
    let sessionID: String

    static func read(_ path: String) throws -> Self {
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // A native title reservation can precede the header. Never read the full journal.
        guard let data = try handle.read(upToCount: 32_768),
              let header = data.split(separator: 0x0A).prefix(8)
                .compactMap({ JSONValue.parse(Data($0)) }).first(where: { $0["type"]?.string == "session" }),
              let id = header["id"]?.string, !id.isEmpty, id.utf8.count <= 1024, !id.contains("\0") else {
            throw ProviderError.failed(AppText.localized("OMP could not read this conversation's native session identity."))
        }
        return Self(file: file, sessionID: id)
    }

    func validate(_ state: JSONValue) throws {
        guard state["sessionId"]?.string == sessionID,
              let path = state["sessionFile"]?.string, path.hasPrefix("/"),
              URL(fileURLWithPath: path).resolvingSymlinksInPath() == file else {
            throw ProviderError.failed(AppText.localized("OMP resumed a different session. The original conversation is preserved. Close its other owner and try again."))
        }
    }

    static func prepare(_ path: String, executable: URL, environment: [String: String], directory: URL) async throws -> Self {
        let target = try await Task.detached(priority: .userInitiated) { try read(path) }.value
        try Task.checkCancellation()
        let result: ShellResult
        do {
            result = try await Shell.run(executable, ["session", "lease", "--json", "--", target.sessionID],
                                         in: directory, environment: environment, timeout: 10, outputLimit: 32_768)
        } catch {
            try Task.checkCancellation()
            // An older CLI or unavailable probe is not evidence of a free lease.
            // OMP still claims it; validate its final identity before publishing it.
            return target
        }
        try Task.checkCancellation()
        guard result.succeeded, let report = JSONValue.parse(result.output),
              let held = report["held"]?.array, let unknown = report["unknown"]?.array,
              (held + unknown).allSatisfy({ $0.string == target.sessionID }) else { return target }
        if held.contains(.string(target.sessionID)) {
            throw ProviderError.failed(AppText.localized("This conversation is open in another OMP process. Close it there before continuing here."))
        }
        return target
    }
}
