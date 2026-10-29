import Foundation

/// An npm installation exposes OMP's public SDK and its native CLI entry. A
/// standalone binary keeps its ordinary RPC path and does not advertise the
/// optional per-message queue controls.
enum OMPSDKLaunch {
    private final class ResourceBundle: NSObject {}

    struct Command {
        var executable: URL
        var arguments: [String]
        var environment: [String: String]
    }

    static func command(executable: URL, arguments: [String], environment: [String: String]) -> Command {
        let original = Command(executable: executable, arguments: arguments, environment: environment)
        let native = executable.resolvingSymlinksInPath()
        guard native.lastPathComponent == "cli.js", native.deletingLastPathComponent().lastPathComponent == "dist" else { return original }
        let root = native.deletingLastPathComponent().deletingLastPathComponent()
        guard let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
              JSONValue.parse(data)?["name"]?.string == "@oh-my-pi/pi-coding-agent",
              ["sdk.ts", "main.ts", "cli.ts", "cli/args.ts", "cli/profile-bootstrap.ts", "session/queued-messages.ts"].allSatisfy({
                  FileManager.default.isReadableFile(atPath: root.appendingPathComponent("src/" + $0).path)
              }),
              let bun = LoginEnvironment.which("bun", in: environment),
              let host = Bundle(for: ResourceBundle.self).url(forResource: "OMPSDKHost", withExtension: "js") else { return original }
        var nativeEnvironment = environment
        nativeEnvironment["OMP_GUI_NATIVE_EXECUTABLE"] = native.path
        return Command(executable: bun, arguments: [host.path] + arguments, environment: nativeEnvironment)
    }
}
