import Foundation
@testable import OMPGUI

@main
struct NativeMemoryConfigurationExport {
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        precondition(output.path.contains("/build.noindex/verification/runs/") && CaptureRun.isEnabled)
        let disabled = OMPMemoryConfiguration()
        precondition(!disabled.enabled)
        var enabled = disabled
        enabled.enabled = true
        // Disable optional network-backed work in the isolated native test.
        enabled.autoRetain = false
        try JSONValue.object(["off": disabled.json, "on": enabled.json]).data().write(to: output.appendingPathComponent("memory-options.json"))
        let profile = output.appendingPathComponent("rpc-profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("memory:\n  backend: off\nmnemopi:\n  noEmbeddings: true\n  llmMode: none\n".utf8)
            .write(to: profile.appendingPathComponent("config.yml"))
        var environment = ProcessInfo.processInfo.environment
        environment["PI_CODING_AGENT_DIR"] = profile.path
        environment["PI_CONFIG_DIR"] = output.appendingPathComponent("rpc-root").path
        let configuration = SessionConfiguration(provider: .omp, executable: URL(fileURLWithPath: CommandLine.arguments[2]),
            workingDirectory: output, environment: environment, resumeID: nil, resumeAt: nil,
            model: "openai/gpt-4o-mini", effort: nil, runtimeMode: .fullAccess, interactionMode: .build,
            apiKey: nil, hydra: nil, memory: enabled, antiSlopEnabled: false)
        let session = OMPSession(configuration: configuration)
        defer { session.stop() }
        _ = try await session.start()
        let inspection = try await session.inspectMemory()
        precondition(inspection.files.count == 2 && inspection.files.contains { $0.isGlobal })
        for file in inspection.files {
            precondition(FileManager.default.fileExists(atPath: file.path))
            let preview = try await session.previewMemory(file)
            precondition(preview.isEmpty, "An isolated empty database must have an empty preview")
        }
        try await session.rpc.drainAndWait()
        print("PASS native memory RPC: built SDK host, generated extension, private command and EOF shutdown")
    }
}
