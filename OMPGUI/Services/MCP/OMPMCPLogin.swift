import AppKit
import Foundation

/// A single user-requested native OAuth operation, with no model or MCP connection hub.
@MainActor @Observable
final class OMPMCPLogin {
    private final class ResourceBundle: NSObject {}
    private(set) var isRunning = false
    private(set) var completed = false
    private(set) var link: URL?
    private(set) var prompt: String?
    private(set) var error: String?
    private(set) var browserOpenFailed = false
    @ObservationIgnored private var child: StdioProcess?
    @ObservationIgnored private var generation = UUID()

    static func command(context: OMPDiscoveryContext) -> OMPSDKLaunch.Command? {
        let executable = context.executable.resolvingSymlinksInPath()
        let root = executable.deletingLastPathComponent().deletingLastPathComponent()
        guard executable.lastPathComponent == "cli.js", executable.deletingLastPathComponent().lastPathComponent == "dist",
              let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
              JSONValue.parse(data)?["name"]?.string == "@oh-my-pi/pi-coding-agent",
              ["sdk.ts", "mcp/oauth-flow.ts", "mcp/oauth-discovery.ts", "mcp/oauth-credentials.ts"].allSatisfy({
                  FileManager.default.isReadableFile(atPath: root.appendingPathComponent("src/" + $0).path)
              }), let bun = LoginEnvironment.which("bun", in: context.environment),
              let host = Bundle(for: ResourceBundle.self).url(forResource: "OMPMCPLogin", withExtension: "js") else { return nil }
        var environment = context.environment
        environment["OMP_GUI_NATIVE_EXECUTABLE"] = executable.path
        return OMPSDKLaunch.Command(executable: bun, arguments: [host.path], environment: environment)
    }

    func start(server: OMPMCPServer, snapshot: OMPMCPSnapshot,
               currentContext: () -> OMPDiscoveryContext?,
               save: (JSONValue) async -> String?) async {
        guard !isRunning else { return }
        let expected = UUID()
        generation = expected
        completed = false; error = nil; link = nil; prompt = nil
        guard let command = Self.command(context: snapshot.context) else {
            error = Chrome.localized("Native MCP sign-in requires an OMP npm SDK installation and Bun. You can also sign in with /mcp reauth in OMP.")
            return
        }
        isRunning = true
        defer { if generation == expected { isRunning = false; prompt = nil; child = nil } }
        do {
            guard currentContext() == snapshot.context else { throw OMPMCPDocument.failure("The OMP configuration changed. Reopen the editor before saving.") }
            let current = try await OMPMCPConfiguration.read(context: snapshot.context)
            try Task.checkCancellation()
            guard generation == expected, currentContext() == snapshot.context,
                  current.directory == snapshot.directory, current.original == snapshot.original else { throw OMPMCPDocument.failure("The OMP configuration changed. Reopen the editor before saving.") }
            let process = StdioProcess(executable: command.executable, arguments: command.arguments,
                directory: FileManager.default.temporaryDirectory, environment: command.environment)
            try process.start()
            child = process
            process.send(["definition": server.definition, "directory": .string(snapshot.directory.path),
                          "resolvedDirectory": .string(snapshot.resolvedDirectory.path), "original": .string(snapshot.text)])
            for await frame in process.messages {
                guard generation == expected, !Task.isCancelled else { break }
                switch frame["type"]?.string {
                case "open_url":
                    if let raw = frame["url"]?.string, let url = URL(string: raw),
                       ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                       url.user == nil, url.password == nil {
                        link = url
                        openBrowser()
                    }
                case "input": prompt = frame["message"]?.string ?? Chrome.localized("Paste the callback URL or authorization code.")
                case "error": error = frame["message"]?.string
                case "complete":
                    guard let auth = frame["auth"], currentContext() == snapshot.context else { throw OMPMCPDocument.failure("The OMP configuration changed. Reopen the editor before saving.") }
                    var definition = server.definition.object ?? [:]
                    var fields = definition["auth"]?.object ?? [:]
                    for key in ["type", "credentialId", "tokenUrl", "clientId", "resource"] {
                        if let value = auth[key] { fields[key] = value }
                    }
                    definition["auth"] = .object(fields)
                    let document = try OMPMCPDocument.replacingServer(in: snapshot.document(), oldName: server.id,
                        name: server.id, definition: .object(definition), enabled: server.enabled)
                    error = await save(document)
                    completed = error == nil
                default: break
                }
            }
            let status = await process.waitForExit()
            if generation == expected, !completed, error == nil {
                error = process.failureReason ?? Chrome.localized(status == 0 ? "OMP did not confirm MCP sign-in." : "MCP sign-in failed. Try again in OMP.")
            }
        } catch {
            if generation == expected, !Task.isCancelled { self.error = error.localizedDescription }
            await child?.terminateAndWait(timeout: 3)
        }
    }

    func answer(_ value: String) {
        guard isRunning, prompt != nil else { return }
        child?.send(["type": "input", "value": .string(value)])
        prompt = nil
    }

    func openBrowser() {
        guard let link else { return }
        browserOpenFailed = !NSWorkspace.shared.open(link)
    }

    func stop() {
        generation = UUID()
        isRunning = false
        prompt = nil
        let process = child
        child = nil
        process?.terminate()
        Task { await process?.terminateAndWait(timeout: 3) }
    }
}
