import Foundation

enum OMPSystemPrompt {
    private final class ResourceBundle: NSObject {}

    struct File {
        let url: URL
        let resolvedURL: URL
        let original: Data?
        let text: String
    }

    static func fileURL(in agentDirectory: URL) -> URL {
        agentDirectory.appendingPathComponent("APPEND_SYSTEM.md")
    }

    static func read(_ url: URL) throws -> File {
        let resolvedURL = url.resolvingSymlinksInPath()
        let original = try contents(of: resolvedURL)
        let text: String
        if let original {
            guard let decoded = String(data: original, encoding: .utf8) else {
                throw ProviderError.failed(AppText.localized("The OMP prompt file must contain UTF-8 text."))
            }
            text = decoded
        } else {
            text = ""
        }
        return File(url: url, resolvedURL: resolvedURL, original: original, text: text)
    }

    static func save(_ text: String, file: File) throws -> File {
        guard file.url.resolvingSymlinksInPath() == file.resolvedURL,
              try contents(of: file.resolvedURL) == file.original else {
            throw ProviderError.failed(AppText.localized("The OMP prompt file changed on disk. Reload it before saving."))
        }
        try FileManager.default.createDirectory(at: file.resolvedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file.resolvedURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.resolvedURL.path)
        return try read(file.url)
    }

    private static func contents(of url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    /// Let OMP discover APPEND_SYSTEM.md itself. Its public extension hook adds
    /// GUI guidance and file-change observations, without overriding native tools.
    static func guidanceExtension(enabled: Bool, bundle: Bundle? = nil) throws -> Data {
        let guidance = AntiSlopPolicy.instructions(enabled: enabled)
        let literal = String(decoding: try JSONEncoder().encode(guidance), as: UTF8.self)
        let resources = bundle ?? Bundle(for: ResourceBundle.self)
        guard let source = resources.url(forResource: "OMPFileSnapshots", withExtension: "js") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let snapshots = try String(contentsOf: source, encoding: .utf8)
        guard let queueSource = resources.url(forResource: "OMPQueueControl", withExtension: "js") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let queueControls = try String(contentsOf: queueSource, encoding: .utf8)
        guard let memorySource = resources.url(forResource: "OMPMemoryControl", withExtension: "js") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let memoryControls = try String(contentsOf: memorySource, encoding: .utf8)
        guard let debugSource = resources.url(forResource: "OMPDebugControl", withExtension: "js") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let debugControls = try String(contentsOf: debugSource, encoding: .utf8)
        guard let captureSource = resources.url(forResource: "OMPRequestCapture", withExtension: "js") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let captureURL = String(decoding: try JSONEncoder().encode(captureSource.absoluteString), as: UTF8.self)
        guard let contextSource = resources.url(forResource: "OMPContextControl", withExtension: "js") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let contextURL = String(decoding: try JSONEncoder().encode(contextSource.absoluteString), as: UTF8.self)
        return Data("""
        import { installRequestCaptureExtension } from \(captureURL);
        import { installContextCommands } from \(contextURL);

        \(snapshots)

        \(queueControls)

        \(memoryControls)

        \(debugControls)

        export default function (omp) {
            installFileSnapshots(omp);
            installQueueCommands(omp);
            installMemoryCommands(omp);
            installDebugCommands(omp);
            installRequestCaptureExtension(omp);
            installContextCommands(omp);
            omp.on("before_agent_start", (event) => ({
                systemPrompt: [...event.systemPrompt, \(literal)]
            }));
        }
        """.utf8)
    }
}
