import Foundation
@testable import OMPGUI

@MainActor
private final class IsolatedProviderSettings: ProviderSettings {
    var executable: String
    init(_ executable: String) { self.executable = executable }
    func isEnabled(_ provider: ProviderKind) -> Bool { provider == .omp }
    func binaryPath(for provider: ProviderKind) -> String { executable }
    func lastModel(for provider: ProviderKind) -> String? { nil }
    func apiKey(for provider: ProviderKind) -> String { "" }
    func adoptModelFamilies(_ families: [ModelOption], for provider: ProviderKind) {}
}

@main
struct OMPP3NativeCLIChecks {
    @MainActor private static var count = 0
    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        count += 1
    }

    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 4 else { fatalError("Require output root, actual OMP CLI and wrapper") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let actualCLI = URL(fileURLWithPath: CommandLine.arguments[2])
        let wrapper = URL(fileURLWithPath: CommandLine.arguments[3])
        guard root.path.contains("/build.noindex/verification/runs/"), FileManager.default.isExecutableFile(atPath: actualCLI.path) else { fatalError("Require isolated native CLI fixture") }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("agent"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("agent/config.yml")
        let overlay = root.appendingPathComponent("chat-overlay.yml")
        try Data("modelRoles:\n  default: example/original\n  custom-global: example/keep\nfutureSetting:\n  nested: retain\n".utf8).write(to: file)
        try Data("modelRoles:\n  default: overlay/should-not-save\n  overlay-only: overlay/should-not-copy\ngenerate_image:\n  enabled: true\n".utf8).write(to: overlay)
        try Data().write(to: root.appendingPathComponent("calls.jsonl"))
        LoginEnvironment.setOverlay([
            // Preserve the runner's selected Bun when production reloads the login shell.
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "PI_CONFIG_DIR": root.path, "PI_CODING_AGENT_DIR": root.appendingPathComponent("agent").path,
            "OMP_PROFILE": "default", "PI_PROFILE": "default", "PI_CONFIG_FILES": overlay.path,
            "OMP_P3_REAL_CLI": actualCLI.path, "OMP_P3_CONFIG_ROOT": root.path,
        ])
        defer { LoginEnvironment.setOverlay([:]) }
        let registry = ProviderRegistry(settings: IsolatedProviderSettings(wrapper.path))
        let native = OMPNativeSettings(registry: registry)
        await native.refresh(force: true, configurationOnly: true)
        expect(native.error == nil && native.agentDirectory == root.appendingPathComponent("agent"), "Settings discover only the isolated active profile")
        expect(native.values["modelRoles"]?["default"]?.string == "example/original", "Settings forms do not display process overlay values as profile values")
        expect(native.values["modelRoles"]?["overlay-only"] == nil, "Chat-only role keys do not enter the editable profile record")
        expect(native.values["generate_image.enabled"]?.bool == false, "Image tool activation reflects the profile's native default rather than a chat overlay")
        expect(registry.environment(for: .omp)["PI_CONFIG_FILES"] == overlay.path, "Settings filtering leaves the chat environment unchanged")
        let expected = native.values["modelRoles"]!
        let error = await native.setSelectors("modelRoles", changes: ["default": "example/updated"], expected: expected)
        expect(error == nil, "Real native CLI accepts a declared role edit")
        expect(native.values["modelRoles"]?["default"]?.string == "example/updated", "Native CLI refresh reports the saved role")
        expect(native.values["modelRoles"]?["custom-global"]?.string == "example/keep", "Unknown global role fields survive the real native writer")
        let saved = try String(contentsOf: file, encoding: .utf8)
        expect(saved.contains("futureSetting:") && saved.contains("nested: retain"), "Unknown top-level native fields survive config set")
        expect(!saved.contains("overlay-only") && !saved.contains("overlay/should-not-save"), "Process overlays never leak into the saved profile")
        await native.set("task.maxRecursionDepth", .int(-1))
        expect(native.error == nil && native.values["task.maxRecursionDepth"]?.int == -1, "Production CLI serialization preserves the native -1 depth value")
        await native.set("generate_image.enabled", true, expected: false)
        expect(native.error == nil && native.values["generate_image.enabled"]?.bool == true, "The image tool switch persists through the public native config CLI")
        expect(native.values["modelRoles"]?["default"]?.string == "example/updated" && native.values["modelRoles"]?["custom-global"]?.string == "example/keep", "Enabling image tools preserves existing model roles")
        let beforeExternal = native.values["modelRoles"]!
        var externallyEdited = try String(contentsOf: file, encoding: .utf8)
        externallyEdited += "\nexternalOwnerField: owner-change\n"
        try Data(externallyEdited.utf8).write(to: file)
        let rejected = await native.setSelectors("modelRoles", changes: ["default": "example/must-not-write"], expected: beforeExternal)
        expect(rejected != nil, "Production settings reject external modifications before a native write")
        expect(try String(contentsOf: file, encoding: .utf8) == externallyEdited, "Conflict rejection leaves all external file bytes unchanged")
        await native.refresh(force: true)
        expect(native.error == nil && native.values["task.maxRecursionDepth"]?.int == -1, "External CLI edits can be reloaded after conflict")
        await native.setTool(.flag("astGrep.enabled"), true, expected: native.values["astGrep.enabled"]!)
        expect(native.error == nil && native.values["astGrep.enabled"]?.bool == true,
               "Tool catalogue switches persist with the real native boolean parser")
        await native.setTool(.find, "on", expected: native.values["find.enabled"]!)
        expect(native.error == nil && native.values["find.enabled"]?.string == "on",
               "Tool search mode persists with the real native enum parser")
        expect(try String(contentsOf: file, encoding: .utf8).contains("externalOwnerField: owner-change"),
               "Tool edits preserve the external owner's unrelated configuration")
        let calls = try String(contentsOf: root.appendingPathComponent("calls.jsonl"), encoding: .utf8).split(whereSeparator: \.isNewline).compactMap { JSONValue.parse(String($0)) }
        let writes = calls.filter { $0["command"]?[1]?.string == "set" }
        expect(writes.count == 5 && writes.allSatisfy { $0["overlayPresent"]?.bool == false }, "Profile mutations strip process overlays and conflicts never start another write")

        let skillFile = root.appendingPathComponent("agent/skills/gui-global-skill/SKILL.md")
        let projectSkill = root.appendingPathComponent("project/.omp/skills/gui-project-skill/SKILL.md")
        for (url, name) in [(skillFile, "gui-global-skill"), (projectSkill, "gui-project-skill")] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("---\nname: \(name)\ndescription: Isolated skill inventory fixture.\n---\n# \(name)\n".utf8).write(to: url)
        }
        let beforeSkills = try Data(contentsOf: file)
        var skillEnvironment = registry.environment(for: .omp)
        skillEnvironment["HOME"] = root.path
        // A chat-only overlay must not hide a profile's skills from Settings.
        try Data("skills:\n  enabled: false\n".utf8).write(to: overlay)
        let globalSkills = try await OMPNativeSkills.list(executable: actualCLI, environment: skillEnvironment)
        expect(globalSkills.contains { $0.name == "gui-global-skill" && $0.filePath == skillFile.path }, "Public skill CLI discovers the isolated profile without chat overlays")
        expect(!globalSkills.contains { $0.name == "gui-project-skill" || $0.source.hasSuffix(":project") }, "Global settings do not discover project skills")
        expect(try Data(contentsOf: file) == beforeSkills, "Skill discovery preserves the native profile bytes")
        expect(registry.environment(for: .omp)["PI_CONFIG_FILES"] == overlay.path, "Global inventory leaves the chat environment intact")
        print("OMP P3 isolated actual CLI checks passed: \(count)")
    }
}
