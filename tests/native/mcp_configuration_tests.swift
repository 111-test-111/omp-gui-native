import Foundation
@testable import OMPGUI

@main
struct NativeMCPConfigurationTests {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let executable = URL(fileURLWithPath: CommandLine.arguments[2])
        guard root.path.contains("/build.noindex/verification/runs/") else { fatalError("Isolated native output required") }
        let manager = FileManager.default
        var environment = OMPCLI.profileConfigurationEnvironment(ProcessInfo.processInfo.environment)
        environment["HOME"] = root.appendingPathComponent("home").path
        environment["PI_CONFIG_DIR"] = ".omp-isolated"
        environment["PI_CODING_AGENT_DIR"] = root.appendingPathComponent("ignored-agent-override").path
        environment["OMP_PROFILE"] = "gui-mcp"
        environment["PI_PROFILE"] = "gui-mcp"
        let context = OMPDiscoveryContext(executable: executable, environment: environment)
        var snapshot = try await OMPMCPConfiguration.read(context: context)
        let expected = root.appendingPathComponent("home/.omp-isolated/profiles/gui-mcp/agent")
        guard snapshot.directory.path == expected.path, snapshot.original == nil else {
            fatalError("Public config path selected \(snapshot.directory.path), expected isolated profile \(expected.path)")
        }
        let server: JSONValue = ["type": "http", "url": "https://example.invalid/mcp",
            "headers": ["Authorization": "MCP_TOKEN"], "oauth": ["clientId": "fixture"],
            "enabled": false, "future": ["preserve": true]]
        let value = try OMPMCPDocument.replacingServer(in: snapshot.document(), oldName: nil,
            name: "native:Profile Server", definition: server, enabled: false)
        snapshot = try await OMPMCPConfiguration.save(value, snapshot: snapshot, currentContext: { context })
        let loaded = try await OMPMCPConfiguration.read(context: context)
        guard try loaded.document() == value else { fatalError("Native profile round trip must preserve literal credentials and advanced fields") }
        environment["OMP_PROFILE"] = "gui-mcp-other"
        environment["PI_PROFILE"] = "gui-mcp-other"
        let other = OMPDiscoveryContext(executable: executable, environment: environment)
        let otherSnapshot = try await OMPMCPConfiguration.read(context: other)
        guard otherSnapshot.directory.path != snapshot.directory.path, otherSnapshot.original == nil else {
            fatalError("Named profiles must remain separate")
        }
        do {
            _ = try await OMPMCPConfiguration.save(value, snapshot: snapshot, currentContext: { other })
            fatalError("An editor cannot cross profiles")
        } catch is OMPMCPError {}
        guard !manager.fileExists(atPath: root.appendingPathComponent("ignored-agent-override/mcp.json").path) else {
            fatalError("Agent override must not redirect a named profile edit")
        }
        let result: JSONValue = ["profile": .string(snapshot.directory.path), "otherProfile": .string(otherSnapshot.directory.path),
            "projectDiscovery": false, "serverExecution": false, "profileSwitchRejected": true]
        try result.data(pretty: true).write(to: root.appendingPathComponent("native-mcp.json"))
        print("Native MCP profile path, isolated writes and profile-switch protection passed")
    }
}
