import Foundation
@testable import OMPGUI

@MainActor private final class LoginFixtureSettings: ProviderSettings {
    let executable: URL
    init(_ executable: URL) { self.executable = executable }
    func isEnabled(_ provider: ProviderKind) -> Bool { provider == .omp }
    func binaryPath(for provider: ProviderKind) -> String { executable.path }
    func lastModel(for provider: ProviderKind) -> String? { nil }
    func apiKey(for provider: ProviderKind) -> String { "" }
    func adoptModelFamilies(_ families: [ModelOption], for provider: ProviderKind) {}
}

@main
struct OMPP3Checks {
    @MainActor private static var count = 0
    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        count += 1
    }

    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard root.path.contains("/build.noindex/verification/runs/") else { fatalError("Require isolated output directory") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await checkToolCatalogue(root)
        try await checkToolControls(root)
        try await checkBrowserLogin(root)
        try await checkProviderLogout(root)
        let catalog: JSONValue = ["commands": [
            ["name": "compact", "source": "builtin", "aliases": ["summarize"], "description": "Compact context",
             "input": ["hint": "[instructions]"], "subcommands": [["name": "status", "description": "Show state", "usage": "status [verbose]"]]],
            ["name": "skill:review", "source": "skill", "description": "Review"],
            ["name": "extension-task", "source": "extension"], ["name": "custom-task", "source": "custom"],
            ["name": "mcp:server:prompt", "source": "mcp_prompt"], ["name": "file-task", "source": "file"]
        ]]
        let commands = SlashCommand.ompCommands(catalog)
        expect(commands.count == 6 && commands[0].isBuiltIn, "Native command sources remain distinct")
        expect(commands.map(\.source) == ["builtin", "skill", "extension", "custom", "mcp_prompt", "file"], "No source is collapsed into an extension")
        expect(commands[0].aliases == ["summarize"] && commands[0].inputHint == "[instructions]", "Aliases and argument hints survive discovery")
        expect(commands[0].subcommands.first?.usage == "status [verbose]", "Subcommand usage survives discovery")
        expect(SlashCommand.suggestions(commands, matching: "summ", recent: []).first?.name == "compact", "Alias lookup retains the canonical native command")
        expect(SlashCommand.suggestions(commands, matching: "compact st", recent: []).first?.name == "compact status", "Native subcommands are selectable")
        expect(SlashCommand.suggestions(commands, matching: "", recent: []).count == 6, "Empty menus list each top-level command once")

        let now = Date(timeIntervalSince1970: 100)
        let select: JSONValue = ["type": "extension_ui_request", "id": "select", "method": "select", "title": "Choose",
            "options": ["One", "Two"], "optionDetails": [["description": "First detail"], [:]], "timeout": 1_500]
        let choice = OMPExtensionDialog.request(select, now: now)!
        expect(choice.questions[0].choices[0].detail == "First detail", "Select details remain aligned with their labels")
        expect(choice.questions[0].choices[1].detail == nil, "Absent option descriptions remain unknown")
        expect(choice.deadline == now.addingTimeInterval(1.5), "Native dialog timeout uses milliseconds")
        let editor: JSONValue = ["type": "extension_ui_request", "id": "editor", "method": "editor", "title": "Edit", "prefill": "  first\nsecond\n"]
        let edit = OMPExtensionDialog.request(editor)!.questions[0]
        expect(edit.isMultiline && edit.preservesWhitespace && edit.prefill == "  first\nsecond\n", "Editors retain multiline prefill and exact whitespace semantics")
        expect(OMPExtensionDialog.request(["id": "unsupported", "method": "custom"]) == nil, "TUI component factories are not emulated")

        var state = OMPExtensionState()
        for index in 0..<30 {
            _ = state.observe(["method": "setStatus", "statusKey": .string(String(index)), "statusText": "\u{1b}[31mready\u{1b}[0m"])
        }
        expect(state.statuses.count == 16 && state.statuses["0"] == "ready", "Status state is bounded and ANSI formatting is removed")
        _ = state.observe(["method": "setStatus", "statusKey": "0"])
        expect(state.statuses["0"] == nil, "Undefined native status removes the previous text")
        _ = state.observe(["method": "setWidget", "widgetKey": "task", "widgetLines": ["line one", "line two"], "widgetPlacement": "belowEditor"])
        expect(state.widgets[0].placement == .belowEditor && state.widgets[0].lines.count == 2, "Text widgets preserve placement and lines")
        _ = state.observe(["method": "setWidget", "widgetKey": "task", "widgetLines": ["replacement"]])
        expect(state.widgets.count == 1 && state.widgets[0].lines == ["replacement"], "Widget updates replace their own key")
        _ = state.observe(["method": "setWidget", "widgetKey": "task"])
        expect(state.widgets.isEmpty, "Undefined native widgets are removed")
        expect(OMPLoginLink(["url": "file:///tmp/secret"]) == nil, "Login links cannot open local files")
        expect(OMPLoginLink(["url": "javascript:alert(1)"]) == nil, "Login links reject executable URL schemes")
        let link = OMPLoginLink(["url": "https://provider.example/oauth?code=long", "launchUrl": "http://127.0.0.1:1234/login"])!
        expect(link.destination.host == "127.0.0.1", "Native loopback launch URL is the lossless copy target")
        expect(OMPLoginLink(["url": "https://provider.example/oauth", "launchUrl": "https://other.example/login"])!.destination.host == "provider.example", "Remote substitutions do not replace the visible provider URL")

        let original: JSONValue = ["default": "old/model", "future": ["nested": true], "custom": "keep/model"]
        let keyContext = OMPDiscoveryContext(executable: URL(fileURLWithPath: "/fixture/omp"), environment: [:])
        let keyValue: JSONValue = ["directory": "/fixture/agent", "file": "/fixture/agent/models.yml", "revision": "fixture-revision",
            "providers": [["id": "anthropic", "name": "Anthropic", "value": "ENV_REFERENCE", "hasOAuth": true, "environmentKeys": ["ANTHROPIC_API_KEY"]],
                          ["id": "google", "name": "Google", "value": "", "hasOAuth": .null]]]
        let keySnapshot = try OMPModelConfigurationSnapshot.decode(keyValue, context: keyContext)
        expect(keySnapshot.providers[0].hasOAuth == true && keySnapshot.providers[1].hasOAuth == nil, "Missing native OAuth status remains unknown")
        expect(keySnapshot.changes(from: ["anthropic": "ENV_REFERENCE", "google": ""]).isEmpty, "Unchanged key fields are not sent as edits")
        expect(keySnapshot.changes(from: ["anthropic": "", "google": "new-key"]) == ["anthropic": .string(""), "google": .string("new-key")], "Clear and replacement remain distinct credential edits")
        var duplicateKeys = keyValue.object!
        duplicateKeys["providers"] = [keyValue["providers"]!.array![0], keyValue["providers"]!.array![0]]
        do { _ = try OMPModelConfigurationSnapshot.decode(.object(duplicateKeys), context: keyContext); fatalError("Duplicate provider identities must fail") }
        catch { expect(true, "Duplicate provider identities cannot create ambiguous key bindings") }
        let imageValue: JSONValue = ["directory": "/fixture/agent", "selector": "pictures/draw", "selected": "pictures/draw",
            "models": [["id": "pictures/draw", "provider": "pictures", "name": "Draw", "hasCredentials": false, "requiresCredentials": true]],
            "backends": [["id": "pictures", "name": "Pictures", "preferredModel": "pictures/draw", "keyProvider": "pictures"]]]
        let images = try OMPImageConfiguration.decode(imageValue, context: keyContext)
        expect(images.selected?.hasCredentials == false && images.backend?.keyProvider == "pictures", "An image preference without credentials remains selectable with its configuration method")
        var unresolvedImage = imageValue.object!
        unresolvedImage["selector"] = "owner/missing"
        unresolvedImage["selected"] = .null
        let unresolved = try OMPImageConfiguration.decode(.object(unresolvedImage), context: keyContext)
        expect(unresolved.selector == "owner/missing" && unresolved.selected == nil, "Unknown saved image selectors survive discovery without being reset")
        var duplicateImage = imageValue.object!
        duplicateImage["models"] = [imageValue["models"]!.array![0], imageValue["models"]!.array![0]]
        do { _ = try OMPImageConfiguration.decode(.object(duplicateImage), context: keyContext); fatalError("Duplicate image models must fail") }
        catch { expect(true, "Duplicate image identities cannot create ambiguous selections") }
        let imageRoles = OMPSelectorRecord.merging(["image": "pictures/draw"], into: original)
        expect(imageRoles["image"]?.string == "pictures/draw" && imageRoles["default"] == original["default"] && imageRoles["future"] == original["future"], "Choosing an image backend preserves all other model roles")
        let automaticImages = OMPSelectorRecord.merging(["image": ""], into: imageRoles)
        expect(automaticImages["image"] == nil && automaticImages["default"] == original["default"], "Automatic removes only the image role override")
        let merged = OMPSelectorRecord.merging(["default": " new/model ", "smol": ""], into: original)
        expect(merged["default"]?.string == "new/model", "Role forms save native selectors")
        expect(merged["future"] == original["future"] && merged["custom"] == original["custom"], "Role forms preserve unknown native fields")
        let file = root.appendingPathComponent("config.yml")
        try? FileManager.default.removeItem(at: file)
        let missing = try OMPConfigurationRevision.read(directory: root)
        try Data("modelRoles: {}\n".utf8).write(to: file)
        let created = try OMPConfigurationRevision.read(directory: root)
        expect(missing != created, "External creation invalidates the profile revision")
        try Data("modelRoles: {default: example/model}\n".utf8).write(to: file)
        expect(try OMPConfigurationRevision.read(directory: root) != created, "External edits invalidate the profile revision")

        let plugins = OMPNativePlugins.inventory(["npm": [["name": "@example/plugin", "version": "1.0", "enabled": true]],
            "marketplace": [["id": "tool@market", "scope": "project", "entries": [["version": "2.0"]]]]])
        expect(plugins.count == 2 && plugins[1].scope == "project", "Native package and marketplace inventory preserve scope")
        expect(plugins[1].enabled == nil, "Missing native enablement is not invented")

        let skills = try OMPNativeSkills.inventory(["skills": [
            ["name": "z-user", "description": "原样 <description>", "filePath": "/global/z/SKILL.md", "source": "native:user", "hide": true],
            ["name": "a-plugin", "filePath": "/plugins/a/SKILL.md", "source": "omp-plugins:user"],
            ["name": "project", "filePath": "/project/SKILL.md", "source": "native:project"],
            ["name": "plugin-project", "filePath": "/plugins/project/SKILL.md", "source": "claude-plugins:project"],
            ["name": "unknown", "filePath": "/unknown/SKILL.md", "source": "future"],
            ["name": "ambiguous", "filePath": "/ambiguous/SKILL.md", "source": "native:project:user"],
            ["name": "relative", "filePath": "relative/SKILL.md", "source": "custom:user"],
            ["name": "remote", "filePath": "https://example.com/SKILL.md", "source": "custom:user"],
            ["name": "directory", "filePath": "/global/skills", "source": "native:user"],
            ["name": "duplicate", "filePath": "/global/z/../z/SKILL.md", "source": "agents:user"]
        ]])
        expect(skills.map(\.name) == ["a-plugin", "z-user"], "Only explicit user sources with local skill documents appear, sorted and deduplicated")
        expect(skills[1].description == "原样 <description>", "Native metadata and manually invoked skills remain visible verbatim")
        expect(try OMPNativeSkills.inventory(["skills": []]).isEmpty, "An empty native inventory is valid")
        do {
            _ = try OMPNativeSkills.inventory(["unexpected": []])
            fatalError("Malformed skill catalogs must not masquerade as an empty list")
        } catch { count += 1 }

        let skillFile = root.appendingPathComponent("global-skill/SKILL.md")
        try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let skillSource = "---\nname: example\ndescription: 示例\n---\n# Skill\n\n```swift\nlet value = 1\n```\n"
        try Data(skillSource.utf8).write(to: skillFile)
        let skillOpening = try await PreviewFileLoader.open(.init(path: skillFile.path), relativeTo: root.path)
        let skillDocument = try skillOpening.content!.get()
        expect(skillDocument.kind == .markdown && skillDocument.text == skillSource, "Skill preview loads the complete original Markdown including frontmatter")
        let skillReader = PreviewReaderState(snapshot: .init(wrapsLines: true))
        skillReader.document = .init(x: 0, y: 120)
        skillReader.showsSource = true
        skillReader.source = .init(x: 0, y: 60, selectionLocation: 4, selectionLength: 2)
        skillReader.showsSource = false
        expect(skillReader.document.y == 120 && skillReader.source.y == 60 && skillReader.source.selectionLength == 2,
               "Preview and source keep separate reading positions and source selection")

        let config = SessionConfiguration(provider: .omp, executable: nil, workingDirectory: root, environment: [:],
            resumeID: nil, resumeAt: nil, model: nil, effort: nil, runtimeMode: .auto, interactionMode: .build,
            apiKey: nil, hydra: nil, antiSlopEnabled: false)
        let session = OMPSession(configuration: config)
        var questions: [String] = [], resolved: [String] = [], snapshots: [OMPExtensionState] = [], editorText = ""
        session.onEvent = { event in
            switch event {
            case .question(let value): questions.append(value.id)
            case .requestResolved(let id): resolved.append(id)
            case .ompExtensionState(let value): snapshots.append(value)
            case .ompEditorText(let text): editorText = text
            default: break
            }
        }
        session.rpc.onFrame?(select)
        session.rpc.onFrame?(editor)
        session.rpc.onFrame?(["type": "extension_ui_request", "id": "cancel-frame", "method": "cancel", "targetId": "select"])
        expect(questions == ["select", "editor"] && resolved == ["select"], "Native cancellation removes only its target dialog")
        session.rpc.onFrame?(["type": "extension_ui_request", "id": "timeout", "method": "input", "title": "Timed", "timeout": 1])
        for index in 0..<20 { session.rpc.onFrame?(["type": "extension_ui_request", "id": "status", "method": "setStatus", "statusKey": "progress", "statusText": .string(String(index))]) }
        session.rpc.onFrame?(["type": "extension_ui_request", "id": "prepared", "method": "set_editor_text", "text": "prepared text"])
        try await Task.sleep(for: .milliseconds(200))
        expect(resolved.contains("timeout"), "Expired dialogs leave the native UI without user action")
        expect(snapshots.count == 1 && snapshots[0].statuses["progress"] == "19", "Bursty text updates publish once with the latest native state")
        expect(editorText == "prepared text", "Native editor updates reach the composer integration event")
        session.stop()
        expect(resolved.contains("editor") && snapshots.last == OMPExtensionState(), "Process shutdown clears presentation state and outstanding dialogs")
        print("OMP P3 native entry checks passed: \(count)")
    }

    @MainActor private static func checkToolCatalogue(_ root: URL) async throws {
        func entry(_ name: String) -> OMPToolCatalogue.Entry { OMPToolCatalogue.entries.first { $0.name == name }! }
        let unknown = OMPToolCatalogue.Configuration()
        expect(entry("bash").gate.status(unknown) == .unknown, "Missing config never implies enabled or disabled")
        expect(entry("lsp").call.title(xdev: nil) == "Direct / xd://", "Unknown transport retains both possible call methods")
        expect(entry("read").call == .direct && entry("xd://resolve").call == .device,
               "Transport tools and contextual actions keep distinct calling methods")
        expect(entry("git_overview").call == .workflow && entry("git_overview").gate.status(unknown) == .conditional,
               "Command-owned helpers do not claim ordinary-session availability")
        expect(entry("yield").statusTitle(unknown) == "Subagent only", "Hidden subagent tools retain their activation condition")

        var config = OMPToolCatalogue.Configuration(values: ["eval.js": false, "eval.py": false, "browser.enabled": true])
        expect(entry("browser").gate.status(config) == .disabled, "An enabled prelude cannot bypass disabled eval backends")
        config.values["eval.js"] = true
        expect(entry("browser").gate.status(config) == .enabled, "One configured backend enables the prelude config gate")
        config.values.removeValue(forKey: "browser.enabled")
        expect(entry("browser").gate.status(config) == .unknown, "A missing prelude switch remains unknown even with eval enabled")
        config.values["browser.enabled"] = false
        expect(entry("browser").gate.status(config) == .disabled, "An explicit disabled switch wins over unknown dependencies")
        config.values["find.enabled"] = "auto"
        expect(entry("find").gate.status(config) == .automatic, "Automatic judge selection stays distinct from enabled")
        config.values["task.maxRecursionDepth"] = -1
        expect(entry("task").gate.status(config) == .enabled, "Unlimited native delegation opens the global recursion gate")
        config.values["task.maxRecursionDepth"] = 0
        expect(entry("task").gate.status(config) == .disabled, "Zero recursion depth disables global delegation")
        config.values["memory.backend"] = "hindsight"
        expect(entry("recall").gate.status(config) == .disabled, "The GUI memory switch overrides an external backend")
        config.memoryEnabled = true
        expect(entry("recall").gate.status(config) == .enabled, "Global GUI memory enables its tool gates without a session")
        config.values["autolearn.enabled"] = false
        expect(entry("learn").gate.status(config) == .disabled, "Memory alone does not enable automatic learning")
        expect(entry("gui_open_file_location").gate.status(unknown) == .host,
               "GUI ownership does not claim successful native registration")

        let executable = root.appendingPathComponent("tool-config-fixture")
        let script = #"""
        #!/usr/bin/python3
        import json, sys
        assert sys.argv[1:] == ["config", "list", "--json"]
        print(json.dumps({"tools.xdev": {"value": False}, "bash.enabled": {"value": True},
                          "browser.enabled": {"value": False}, "modelRoles": {"value": {"default": "fixture/model"}},
                          "credential.secret": {"value": "never-retain"}, "tools.unknown": {"value": "never-retain"}}))
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let values = try await OMPCLI.configuration(executable: executable, environment: [:])
        config.values = values
        expect(values["bash.enabled"]?.bool == true && values["browser.enabled"]?.bool == false,
               "Public global CLI switches reach the catalogue unchanged")
        expect(entry("lsp").call.title(xdev: config.xdev) == "Direct call", "Disabling xdev exposes discoverable tools directly")
        config.values["tools.xdev"] = true
        expect(entry("lsp").call.title(xdev: config.xdev) == "xd://", "Enabling xdev identifies mounted tool calls")
        expect(values["modelRoles"]?["default"]?.string == "fixture/model", "Existing config consumers retain their values")
        expect(values["credential.secret"] == nil && values["tools.unknown"] == nil,
               "The catalogue allowlist never retains credentials or arbitrary tool settings")
    }

    @MainActor private static func checkToolControls(_ root: URL) async throws {
        func entry(_ name: String) -> OMPToolCatalogue.Entry { OMPToolCatalogue.entries.first { $0.name == name }! }
        expect(entry("read").controls.isEmpty && entry("git_overview").controls.isEmpty,
               "Core and command-owned tools never invent independent availability switches")
        expect(entry("checkpoint").controls == entry("rewind").controls,
               "Checkpoint and rewind expose their single shared native setting")
        expect(entry("learn").controls == entry("manage_skill").controls,
               "Automatic learning shares its native switch without also mutating memory")
        expect(entry("browser").controls == [.flag("browser.enabled")], "A prelude switch does not silently enable eval dependencies")
        expect(Set(entry("eval").controls) == [.flag("eval.js"), .flag("eval.py")], "Eval exposes independent native backend switches")
        expect(Set(OMPToolCatalogue.members(of: .memory)) == ["memory_edit", "retain", "recall", "reflect"],
               "The existing GUI memory setting controls the four memory tools as one class")
        expect(OMPToolCatalogue.Control.memory.key == nil, "Memory never writes the external backend preference")
        expect(entry("memory_edit").editableControls.isEmpty && entry("recall").editableControls.isEmpty
               && entry("generate_image").editableControls.isEmpty,
               "Capabilities managed by other settings pages have no duplicate tool switches")
        expect(entry("bash").editableControls == entry("bash").controls && entry("task").editableControls == [.depth],
               "Settings unique to the tool catalogue remain editable")
        let managed = OMPToolCatalogue.Configuration(values: ["generate_image.enabled": true], memoryEnabled: true)
        expect(entry("generate_image").gate.status(managed) == .enabled && entry("recall").gate.status(managed) == .enabled,
               "Read-only capabilities still report changes made in their owning settings pages")
        expect(OMPToolCatalogue.Control.find.accepts("auto") && !OMPToolCatalogue.Control.find.accepts("invalid"),
               "Search controls preserve automatic mode and reject unsupported values")
        expect(OMPToolCatalogue.Control.depth.accepts(-1) && OMPToolCatalogue.Control.depth.accepts(25)
               && !OMPToolCatalogue.Control.depth.accepts(-2), "Delegation controls preserve unlimited and custom depths")
        expect(!OMPToolCatalogue.Control.flag("bash.enabled").accepts("true"), "A malformed config value never becomes an editable boolean")
        let dependencies = OMPToolCatalogue.Configuration(values: ["browser.enabled": true, "eval.js": false,
            "eval.py": false, "autolearn.enabled": true])
        expect(entry("browser").statusTitle(dependencies) == "eval disabled" && entry("learn").statusTitle(dependencies) == "Memory disabled",
               "An enabled local switch explains its disabled parent dependency")

        let fixture = root.appendingPathComponent("tool-settings")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let file = fixture.appendingPathComponent("config.yml")
        let initial: JSONValue = ["bash.enabled": true, "eval.py": true, "eval.js": false, "find.enabled": "auto",
                                  "generate_image.enabled": false, "ownerField": "preserve"]
        try initial.data().write(to: file)
        let executable = fixture.appendingPathComponent("omp-fixture")
        let script = #"""
        #!/usr/bin/python3
        import json, os, pathlib, sys
        root = pathlib.Path(os.environ["OMP_TOOL_FIXTURE_ROOT"])
        args = sys.argv[1:]
        with (root / "calls.jsonl").open("a") as log: log.write(json.dumps(args) + "\n")
        assert "PI_CONFIG_FILES" not in os.environ
        file = root / "config.yml"
        if args[:2] == ["config", "path"]: print(root)
        elif args[:2] == ["config", "list"]:
            values = json.loads(file.read_text())
            values["eval.js"] = False
            print(json.dumps({key: {"value": value} for key, value in values.items()}))
        elif args[:2] == ["config", "set"]:
            if args[2] == "eval.py": sys.exit("fixture write failure")
            values = json.loads(file.read_text())
            try: value = json.loads(args[3])
            except ValueError: value = args[3]
            values[args[2]] = value
            file.write_text(json.dumps(values))
        elif args[:2] == ["--mode", "rpc"]:
            for line in sys.stdin:
                command = json.loads(line)
                print(json.dumps(dict(type="response", id=command["id"], command=command["type"], success=True,
                    data={"providers": [{"id": "fixture", "name": "Fixture", "authenticated": True}]})), flush=True)
        else: sys.exit("Unexpected discovery command")
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        LoginEnvironment.setOverlay(["OMP_TOOL_FIXTURE_ROOT": fixture.path, "PI_CONFIG_FILES": fixture.appendingPathComponent("chat-overlay.yml").path])
        defer { LoginEnvironment.setOverlay([:]) }
        let native = OMPNativeSettings(registry: ProviderRegistry(settings: LoginFixtureSettings(executable)))
        await native.refresh(force: true, configurationOnly: true)
        expect(native.error == nil && native.configurationContext != nil && native.values["bash.enabled"]?.bool == true,
               "Tools read an editable global snapshot without provider discovery")
        await native.setTool(.flag("bash.enabled"), false, expected: true)
        expect(native.error == nil && native.values["bash.enabled"]?.bool == false, "A tool switch persists and reads back through the public CLI")
        let saved = try Data(contentsOf: file)
        expect(JSONValue.parse(saved)?["ownerField"]?.string == "preserve", "A tool switch preserves unrelated native settings")
        let calls = try String(contentsOf: fixture.appendingPathComponent("calls.jsonl"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).compactMap { JSONValue.parse(String($0)) }
        expect(calls.allSatisfy { $0.array?.first?.string == "config" }, "Tool reads and writes never open RPC or discover models")
        try Data((String(decoding: saved, as: UTF8.self) + "\n ").utf8).write(to: file)
        let external = try Data(contentsOf: file)
        await native.setTool(.flag("bash.enabled"), true, expected: false)
        let afterConflict = try Data(contentsOf: file)
        expect(native.error != nil && afterConflict == external, "A stale switch cannot overwrite an external profile edit")
        await native.refresh(force: true, configurationOnly: true)
        await native.setTool(.find, "on", expected: "auto")
        expect(native.error == nil && native.values["find.enabled"]?.string == "on", "Search mode writes its exact native enum")
        await native.setTool(.flag("eval.js"), true, expected: false)
        let overridden = JSONValue.parse(try Data(contentsOf: file))
        expect(native.error != nil && native.values["eval.js"]?.bool == false && overridden?["eval.js"]?.bool == true,
               "A saved value shadowed by another source reports the override and retains effective state")
        let beforeFailure = try Data(contentsOf: file)
        await native.setTool(.flag("eval.py"), false, expected: true)
        let afterFailure = try Data(contentsOf: file)
        expect(native.error != nil && native.values["eval.py"]?.bool == true && afterFailure == beforeFailure,
               "A failed write keeps the last confirmed state and profile bytes")
        await native.setTool(.flag("credential.secret"), false, expected: true)
        let afterUnsupported = try Data(contentsOf: file)
        expect(native.error != nil && afterUnsupported == beforeFailure, "Tool controls cannot mutate an undeclared native setting")
        await native.setTool(.flag("generate_image.enabled"), true, expected: false)
        let afterManaged = try Data(contentsOf: file)
        expect(native.error != nil && afterManaged == beforeFailure,
               "The catalogue writer refuses to bypass the owning image settings page")
        await native.set("generate_image.enabled", true, expected: false, refreshCatalog: false)
        expect(native.error == nil && native.values["generate_image.enabled"]?.bool == true,
               "The original settings writer can still update capabilities it owns")
        await native.refresh(force: true)
        expect(native.error == nil && native.loginProviders.first?.authenticated == true,
               "Configuration-only discovery never poisons the provider discovery cache")
        await native.refresh(force: true, configurationOnly: true)
        expect(native.loginProviders.first?.authenticated == true, "Tool refreshes preserve already discovered sign-in state")
    }

    @MainActor private static func checkBrowserLogin(_ root: URL) async throws {
        let known = Dictionary(uniqueKeysWithValues: ["automatic", "manual", "terminal"].map {
            ($0, OMPAuthenticationProvider(id: $0, supportsBrowserLogin: true, credentialProviderID: $0))
        })
        func provider(_ id: String) -> OMPLoginProvider {
            OMPLoginProvider.decode(["id": .string(id), "authenticated": false], policies: known)!
        }
        expect(provider("manual").supportsBrowserLogin && !provider("typesafe").supportsBrowserLogin,
               "Only providers confirmed by native browser-login policies expose sign-in")
        expect(OMPLoginProvider.decode(["id": "manual", "available": false], policies: known) == nil,
               "An unavailable native provider cannot become a browser-login option")
        expect(OMPLoginProvider.decode(["id": "manual"], policies: [:])?.supportsBrowserLogin == false,
               "Unavailable policy discovery never guesses that a provider supports browser login")
        let directory = URL(fileURLWithPath: "/fixture/profile")
        let catalog: JSONValue = ["directory": .string(directory.path), "providers": [
            ["id": "subscription", "supportsBrowserLogin": true, "credentialProviderID": "subscription"],
            ["id": "device", "supportsBrowserLogin": true, "credentialProviderID": "subscription"]]]
        let decoded = try OMPAuthenticationProvider.decode(catalog, directory: directory)
        expect(OMPLoginProvider.decode(["id": "device", "authenticated": true], policies: decoded)?.accountProviderID == "subscription",
               "The native credential namespace survives capability decoding without reading credentials")
        expect(OMPLoginProvider.decode(["id": "unknown", "authenticated": true], policies: decoded)?.accountProviderID == "unknown",
               "Unknown policy identities stay distinct instead of guessing a credential alias")
        do { _ = try OMPAuthenticationProvider.decode(catalog, directory: directory.appendingPathComponent("other")); fatalError("Stale profile policy accepted") }
        catch { expect(true, "Authentication alias metadata is fenced to its native profile") }
        let executable = root.appendingPathComponent("login-fixture")
        let script = #"""
        #!/usr/bin/python3
        import json, sys
        login = None
        def emit(frame):
            print(json.dumps(frame), flush=True)
        def finish(success=True):
            emit({"type": "response", "id": login["id"], "command": "login", "success": success,
                  "error": "Use the terminal UI to log in." if not success else None})
        for line in sys.stdin:
            frame = json.loads(line)
            if frame["type"] == "login":
                login = frame
                if frame["providerId"] == "terminal":
                    finish(False)
                    continue
                if frame["providerId"] == "typesafe":
                    finish(False)
                    continue
                emit({"type": "extension_ui_request", "method": "open_url", "url": "file:///tmp/rejected"})
                link = {"type": "extension_ui_request", "method": "open_url", "id": "link",
                        "url": "https://provider.example/auth", "launchUrl": "http://127.0.0.1:1234/launch"}
                emit(link)
                emit(dict(link, id="duplicate"))
                emit({"type": "extension_ui_request", "method": "input", "id": "code", "title": "Paste code"})
                if frame["providerId"] == "automatic":
                    emit({"type": "extension_ui_request", "method": "cancel", "targetId": "code"})
                    finish()
            elif frame["type"] == "extension_ui_response" and frame.get("value") == "native-code":
                finish()
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let registry = ProviderRegistry(settings: LoginFixtureSettings(executable))
        let keyOnly = OMPNativeLogin(openURL: { _ in fatalError("API-key providers must not open a login page") })
        await keyOnly.start(provider: provider("typesafe"), registry: registry)
        expect(!keyOnly.isRunning && !keyOnly.completed && keyOnly.input == nil && keyOnly.links.isEmpty
               && keyOnly.error == AppText.localized("This provider does not support browser sign-in. Configure its API key or use OMP's terminal."),
               "API-key and unverified flows are rejected before opening RPC or leaving authentication busy")
        var opened: [URL] = []
        let automatic = OMPNativeLogin(openURL: { opened.append($0); return true })
        await automatic.start(provider: provider("automatic"), registry: registry)
        expect(opened.map(\.absoluteString) == ["http://127.0.0.1:1234/launch"],
               "Login automatically opens the validated loopback destination once, ignoring unsafe and duplicate links")
        expect(automatic.completed && !automatic.isRunning && automatic.input == nil && automatic.error == nil,
               "Browser callback completion needs no answer and clears the optional native challenge")

        var attempts = 0
        let manual = OMPNativeLogin(openURL: { _ in attempts += 1; return attempts > 1 })
        let manualTask = Task { await manual.start(provider: provider("manual"), registry: registry) }
        try await waitForLoginInput(manual)
        expect(manual.browserOpenFailed && !manual.completed, "An unsuccessful browser launch retains the pending native login")
        manual.openLoginPage()
        expect(!manual.browserOpenFailed && attempts == 2, "Retrying the browser reuses the live native login URL")
        manual.answer("native-code")
        await manualTask.value
        expect(manual.completed && manual.input == nil && manual.error == nil,
               "Manual code entry still responds to the original OMP login request")

        let cancelled = OMPNativeLogin(openURL: { _ in true })
        let cancelledTask = Task { await cancelled.start(provider: provider("manual"), registry: registry) }
        try await waitForLoginInput(cancelled)
        cancelled.stop()
        await cancelledTask.value
        expect(!cancelled.completed && !cancelled.isRunning && cancelled.input == nil && cancelled.links.isEmpty && cancelled.error == nil,
               "Leaving or cancelling inline login stops its native process and clears its challenge without reporting success")

        let terminal = OMPNativeLogin(openURL: { _ in fatalError("Pre-browser rejection must not open a URL") })
        await terminal.start(provider: provider("terminal"), registry: registry)
        expect(!terminal.completed && !terminal.isRunning && terminal.error == "Use the terminal UI to log in.",
               "Providers rejected by native RPC retain an actionable error for terminal login")
    }

    @MainActor private static func checkProviderLogout(_ root: URL) async throws {
        let fixture = root.appendingPathComponent("provider-logout")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: fixture.appendingPathComponent("config.yml"))
        let stateFile = fixture.appendingPathComponent("accounts.json")
        let executable = fixture.appendingPathComponent("omp-fixture")
        let script = #"""
        #!/usr/bin/python3
        import json, os, pathlib, sys, time
        root = pathlib.Path(os.environ["OMP_LOGOUT_FIXTURE_ROOT"])
        file = root / "accounts.json"
        def state(): return json.loads(file.read_text())
        def provider(name): return "fixture" if name == "fixture-alias" else name
        def authenticated(value, name):
            return any(row.get("provider") == provider(name) for row in value["accounts"]) or (name != "other" and value["mode"] in ("fallback", "empty"))
        def models(value):
            return [{"id": "model", "provider": name, "name": name} for name in ("fixture", "other") if authenticated(value, name)]
        args = sys.argv[1:]
        if args[:2] == ["config", "path"]: print(root)
        elif args[:2] == ["config", "list"]: print("{}")
        elif args[0] == "models": print(json.dumps({"models": models(state())}))
        elif args[:2] == ["--mode", "rpc"]:
            for line in sys.stdin:
                frame = json.loads(line)
                command, value, data, error = frame["type"], state(), {}, None
                if command in ("get_login_providers", "get_logout_accounts", "logout"): assert "PI_CONFIG_FILES" not in os.environ
                if command == "get_login_providers":
                    data = {"providers": [{"id": name, "name": name, "authenticated": authenticated(value, name)}
                                          for name in ("fixture", "fixture-alias", "other")]}
                elif command == "get_available_models": data = {"models": models(value)}
                elif command == "get_logout_accounts":
                    if value["mode"] == "slow":
                        (root / "started").touch()
                        while not (root / "release").exists(): time.sleep(0.01)
                    rows = [row for row in value["accounts"] if row.get("provider") == provider(frame["providerId"])]
                    data = {"accounts": rows}
                    if value["mode"] == "malformed": data["accounts"] = rows + [{}]
                elif command == "logout":
                    key, name = frame["credentialId"], provider(frame["providerId"])
                    if value["mode"] == "failure" and key == 2: error = "fixture credential removal failed"
                    else:
                        value["accounts"] = [row for row in value["accounts"] if not (row["provider"] == name and row["credentialId"] == key)]
                        file.write_text(json.dumps(value))
                        if authenticated(value, name): data["remainingSource"] = "environment or stored credentials"
                else: error = "unexpected command"
                print(json.dumps({"id": frame["id"], "type": "response", "command": command,
                                  "success": error is None, "data": data, "error": error}), flush=True)
        else: sys.exit("Unexpected command")
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        LoginEnvironment.setOverlay(["OMP_LOGOUT_FIXTURE_ROOT": fixture.path,
                                     "PI_CONFIG_FILES": fixture.appendingPathComponent("chat-overlay.yml").path])
        defer { LoginEnvironment.setOverlay([:]) }
        let accounts: [JSONValue] = [
            ["credentialId": 1, "provider": "fixture", "type": "oauth"],
            ["credentialId": 2, "provider": "fixture", "type": "api_key"],
            ["credentialId": 3, "provider": "other", "type": "api_key"],
        ]
        func prepare(_ mode: String, rows: [JSONValue]? = nil) async throws -> OMPNativeSettings {
            try JSONValue.object(["mode": .string(mode), "accounts": .array(rows ?? accounts)]).data().write(to: stateFile)
            let native = OMPNativeSettings(registry: ProviderRegistry(settings: LoginFixtureSettings(executable)))
            await native.refresh(force: true)
            expect(native.error == nil, "Logout fixtures must discover their isolated provider inventory")
            return native
        }
        func remainingIDs() throws -> [Int] {
            JSONValue.parse(try Data(contentsOf: stateFile))!["accounts"]!.array!.compactMap { $0["credentialId"]?.int }
        }
        func signedIn(_ native: OMPNativeSettings, _ id: String) -> Bool {
            native.loginProviders.first { $0.id == id }?.authenticated == true
        }

        let success = try await prepare("normal")
        await success.registry.loadCatalog(.omp, force: true)
        expect(success.registry.models(for: .omp).contains { $0.id == "fixture/model" },
               "The configured provider initially contributes selectable models")
        await success.signOut(providerID: "fixture-alias")
        expect(try remainingIDs() == [3], "Provider logout removes every selected stored account, preserving other providers")
        expect(success.signOutError == nil && success.signingOutProviderID == nil
               && !signedIn(success, "fixture") && !signedIn(success, "fixture-alias") && signedIn(success, "other"),
               "Both aliases leave Configured providers only after native credential removal succeeds")
        expect(success.registry.models(for: .omp).allSatisfy { $0.id != "fixture/model" },
               "Logout must not leave the removed provider's model catalog cached")

        let fallback = try await prepare("fallback")
        await fallback.signOut(providerID: "fixture")
        expect(try remainingIDs() == [3], "An external auth fallback does not prevent stored credential removal")
        expect(fallback.signOutError == nil && fallback.remainingAuthenticationSource != nil && signedIn(fallback, "fixture"),
               "Remaining native authentication is reported rather than falsely hiding an authenticated provider")

        let empty = try await prepare("empty", rows: [accounts[2]])
        await empty.signOut(providerID: "fixture")
        expect(try remainingIDs() == [3] && empty.signOutError != nil && signedIn(empty, "fixture"),
               "Environment-only authentication cannot be reported as successfully removed")

        let failure = try await prepare("failure")
        await failure.signOut(providerID: "fixture")
        expect(try remainingIDs() == [2, 3] && failure.signOutError != nil && failure.remainingAuthenticationSource == nil,
               "A failed later removal reports partial failure without undoing the native result or deleting other accounts")
        expect(signedIn(failure, "fixture") && signedIn(failure, "other") && failure.signingOutProviderID == nil,
               "Partial failure refreshes confirmed auth state and releases the busy state")

        let malformed = try await prepare("malformed")
        await malformed.signOut(providerID: "fixture")
        expect(try remainingIDs() == [1, 2, 3] && malformed.signOutError != nil,
               "A malformed account inventory is rejected before deleting any credentials")

        let slow = try await prepare("slow")
        let pending = Task { await slow.signOut(providerID: "fixture") }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: fixture.appendingPathComponent("started").path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        expect(slow.signingOutProviderID == "fixture", "An in-flight logout is exposed before credentials are removed")
        await slow.signOut(providerID: "other")
        await slow.set("modelRoles", [:])
        expect(try remainingIDs() == [1, 2, 3] && slow.signingOutProviderID == "fixture" && slow.error != nil,
               "Concurrent logout and configuration writes cannot interrupt the active credential mutation")
        try Data().write(to: fixture.appendingPathComponent("release"))
        await pending.value
        expect(try remainingIDs() == [3], "Single-flight logout never deletes credentials from a second requested provider")
    }

    @MainActor private static func waitForLoginInput(_ flow: OMPNativeLogin) async throws {
        let deadline = Date().addingTimeInterval(5)
        while flow.input == nil && flow.error == nil && !flow.completed && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard flow.input != nil else { fatalError("Native login fixture did not request input: \(flow.error ?? "timeout")") }
    }
}
