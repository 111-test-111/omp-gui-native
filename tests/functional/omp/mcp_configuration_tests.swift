import Darwin
import AppKit
import Foundation
import SwiftUI
@testable import OMPGUI

@main
struct MCPConfigurationTests {
    @MainActor private static var count = 0
    @MainActor private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        guard try condition() else { fatalError(message) }
        count += 1
    }

    @MainActor private static func rejected(_ message: String, _ operation: () async throws -> Void) async {
        do { try await operation(); fatalError(message) }
        catch { count += 1 }
    }

    @MainActor static func main() async throws {
        try checkQuickConnect()
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard root.path.contains("/build.noindex/verification/runs/") else { fatalError("Isolated output required") }
        let manager = FileManager.default
        let profile = root.appendingPathComponent("profile")
        try manager.createDirectory(at: profile, withIntermediateDirectories: true)
        let selected = root.appendingPathComponent("selected-profile")
        try Data(profile.path.utf8).write(to: selected)
        let cli = root.appendingPathComponent("omp-fixture")
        let script = """
        #!/bin/sh
        [ "$1" = config ] && [ "$2" = path ] || exit 91
        [ -z "${PI_CONFIG_FILES+x}" ] || exit 92
        if [ -n "$OMP_GUI_MCP_GATE" ] && [ -f "$OMP_GUI_MCP_GATE" ]; then
            /usr/bin/touch "$OMP_GUI_MCP_GATE.started"
            while [ -f "$OMP_GUI_MCP_GATE" ]; do /bin/sleep 0.02; done
        fi
        /bin/cat "$OMP_GUI_MCP_PATH"
        """
        try Data(script.utf8).write(to: cli)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        var environment = ProcessInfo.processInfo.environment
        environment["OMP_GUI_MCP_PATH"] = selected.path
        environment.removeValue(forKey: "PI_CONFIG_FILES")
        let context = OMPDiscoveryContext(executable: cli, environment: environment)
        let project = root.appendingPathComponent("project/.omp/mcp.json")
        try manager.createDirectory(at: project.deletingLastPathComponent(), withIntermediateDirectories: true)
        let projectBytes = Data("deliberately malformed project MCP: never read or written".utf8)
        try projectBytes.write(to: project)

        var snapshot = try await OMPMCPConfiguration.read(context: context)
        try expect(snapshot.original == nil && snapshot.document() == OMPMCPDocument.empty, "Missing native file is editable without creating it")
        expect(!manager.fileExists(atPath: snapshot.url.path), "Discovery is read only")
        let secretMarker = root.appendingPathComponent("must-not-execute").path
        let local: JSONValue = ["type": "stdio", "command": "npx", "args": ["-y", "@example/server", "a b", "", "第二行\nline", "'quoted'"],
            "env": ["TOKEN": .string("!touch " + secretMarker), "LITERAL": "${TOKEN:-fallback}"], "cwd": "", "timeout": 4200,
            "enabled": false, "instructions": false, "future": ["nested": [1, true]]]
        let remote: JSONValue = ["type": "sse", "url": "https://user:password@example.com/mcp?token=secret",
            "headers": ["Authorization": "Bearer ${TOKEN}", "X-Empty": ""], "oauth": ["clientId": "owner", "scope": "offline_access", "future": true],
            "auth": ["type": "oauth", "credentialId": "native-secret"], "requestIdFormat": "string", "future": 42]
        var value: JSONValue = ["mcpServers": ["local": local, "remote": remote], "disabledServers": ["remote"],
            "enabledServers": ["local", "remote"], "futureTopLevel": ["keep": true]]
        let rows = OMPMCPDocument.servers(in: value)
        expect(rows.map(\.enabled) == [true, false], "Denylist wins and allowlist overrides a disabled definition")
        expect(rows[1].detail == "example.com", "List details never contain URL credentials or query tokens")
        try expect(OMPMCPServerDraft(local).definition() == local, "Unchanged visual draft preserves all optional and unknown fields")
        try expect(OMPMCPServerDraft(remote).definition() == remote, "Remote draft retains OAuth, headers, instructions and future fields")
        var draft = OMPMCPServerDraft(local)
        draft.command = "uvx"
        draft.arguments = [OMPMCPArgument(value: "server"), OMPMCPArgument(value: "argument with spaces")]
        let edited = try draft.definition()
        expect(edited["future"] == local["future"] && edited["env"] == local["env"], "Visual edits preserve advanced fields and literal references")
        expect(edited["args"]?.array == ["server", "argument with spaces"], "Arguments remain an argv array without shell parsing")
        try expect(OMPMCPServerDraft(JSONValue.parse(edited.prettyString)!).definition() == edited, "JSON and visual round trips keep definitions intact")
        draft.environment.append(OMPMCPKeyValue(key: "TOKEN", value: "duplicate"))
        await rejected("Duplicate form keys cannot overwrite a secret") { _ = try draft.definition() }
        for command in ["npx", "uvx", "custom-server"] {
            let definition: JSONValue = ["type": "stdio", "command": .string(command)]
            var empty = OMPMCPServerDraft(definition)
            expect(empty.arguments.count == 1 && empty.arguments[0].value.isEmpty,
                   "Local forms begin with one empty argument")
            expect(empty.environment.count == 1 && empty.environment[0].key.isEmpty && empty.environment[0].value.isEmpty,
                   "Every local installation method begins with one empty environment entry")
            try expect(empty.definition() == definition, "Untouched blank form rows do not alter the native definition")
            empty.arguments[0].value = "@example/server"
            empty.environment[0].value = "TOKEN_REFERENCE"
            await rejected("A value-only environment row cannot be silently discarded") { _ = try empty.definition() }
            empty.environment[0].key = "TOKEN"
            let filled = try empty.definition()
            expect(filled["args"] == ["@example/server"] && filled["env"] == ["TOKEN": "TOKEN_REFERENCE"],
                   "Filling the default rows writes one argument and the native environment entry")
        }
        let explicitEmptyLocal: JSONValue = ["command": "server", "args": [], "env": [:]]
        try expect(OMPMCPServerDraft(explicitEmptyLocal).definition() == explicitEmptyLocal,
                   "Explicit empty argument and environment collections survive unchanged")
        let emptyArgument: JSONValue = ["command": "server", "args": [""]]
        try expect(OMPMCPServerDraft(emptyArgument).definition() == emptyArgument,
                   "A saved empty argv value remains a real argument")
        var emptyEnvironment = OMPMCPServerDraft(["command": "server"])
        emptyEnvironment.environment = [OMPMCPKeyValue(key: "EMPTY", value: ""), OMPMCPKeyValue()]
        try expect(emptyEnvironment.definition()["env"] == ["EMPTY": ""],
                   "Named empty environment values are retained while pristine rows are omitted")
        var headerDraft = OMPMCPServerDraft(remote)
        headerDraft.headers.append(OMPMCPKeyValue(key: "authorization", value: "duplicate"))
        await rejected("Header names are unique ignoring case") { _ = try headerDraft.definition() }
        let unauthenticated: JSONValue = ["type": "http", "url": "https://example.invalid/mcp", "oauth": ["clientId": "keep"]]
        var emptyHeaders = OMPMCPServerDraft(unauthenticated)
        expect(emptyHeaders.headers.count == 1 && emptyHeaders.headers[0].key.isEmpty && emptyHeaders.headers[0].value.isEmpty,
               "A remote form starts with one empty header row")
        try expect(emptyHeaders.definition() == unauthenticated, "The untouched default header row never enters native JSON")
        emptyHeaders.headers[0].value = "TOKEN_REFERENCE"
        await rejected("A partially filled header cannot be silently discarded") { _ = try emptyHeaders.definition() }
        emptyHeaders.headers[0].key = "Authorization"
        try expect(emptyHeaders.definition()["headers"] == ["Authorization": "TOKEN_REFERENCE"], "Filling the default header creates the native entry")
        emptyHeaders.headers = [OMPMCPKeyValue(key: "X-Empty", value: ""), OMPMCPKeyValue()]
        try expect(emptyHeaders.definition()["headers"] == ["X-Empty": ""], "Named empty values are kept while pristine rows are omitted")
        let explicitEmpty: JSONValue = ["type": "sse", "url": "https://example.invalid/mcp", "headers": [:]]
        try expect(OMPMCPServerDraft(explicitEmpty).definition() == explicitEmpty, "An existing empty headers object remains unchanged")
        var switched = OMPMCPServerDraft(local)
        switched.transport = .http
        switched.url = "https://example.invalid/mcp"
        expect(switched.headers.count == 1, "Switching from a local form also has a header row ready")
        try expect(switched.definition()["headers"] == nil, "Switching transports does not persist the empty header row")
        var large = local.object!
        large["args"] = .array(Array(repeating: "x", count: 129))
        expect(!OMPMCPServerDraft.supportsVisualEditing(.object(large)), "Large definitions use JSON rather than unbounded form rows")

        await rejected("Existing names cannot be replaced by Install") {
            _ = try OMPMCPDocument.replacingServer(in: value, oldName: nil, name: "local", definition: remote, enabled: true)
        }
        let renamed = try OMPMCPDocument.replacingServer(in: value, oldName: "local", name: "namespace:Local Server", definition: edited, enabled: true)
        expect(renamed["mcpServers"]?["local"] == nil && renamed["enabledServers"]?.array == ["namespace:Local Server", "remote"], "Renaming migrates profile overrides")
        expect(renamed["futureTopLevel"] == value["futureTopLevel"] && renamed["mcpServers"]?["remote"] == remote, "Editing one server preserves all other native data")
        let disabled = try OMPMCPDocument.settingEnabled(false, server: "local", in: value)
        expect(OMPMCPDocument.servers(in: disabled).first?.enabled == false && disabled["mcpServers"]?["local"]?["future"] == local["future"], "Disable updates native overrides while retaining definition fields")
        let enabled = try OMPMCPDocument.settingEnabled(true, server: "remote", in: disabled)
        expect(OMPMCPDocument.servers(in: enabled).last?.enabled == true && enabled["disabledServers"]?.array == ["local"], "Enable removes only this server's denylist entry")
        let removed = OMPMCPDocument.removingServer("remote", from: value)
        expect(removed["mcpServers"]?["remote"] == nil && removed["disabledServers"]?.array == [] && removed["enabledServers"]?.array == ["local"], "Removal clears only that definition and its overrides")

        for invalid in ["", "bad  name", "bad/name", "bad\n", String(repeating: "a", count: 101)] {
            await rejected("Invalid native name must be rejected") { try OMPMCPDocument.validateName(invalid) }
        }
        let invalidDefinitions: [JSONValue] = [.null, ["command": ""], ["type": "future", "url": "https://example.com"],
            ["command": "npx", "url": "https://example.com"], ["command": "npx", "args": [1]],
            ["command": "npx", "env": ["TOKEN": 2]], ["command": "npx", "timeout": -1],
            ["command": "npx", "enabled": "false"], ["type": "http", "url": "file:///secret"]]
        for definition in invalidDefinitions {
            await rejected("Invalid definition cannot be saved") { try OMPMCPDocument.validateServer(definition) }
        }

        snapshot = try await OMPMCPConfiguration.save(value, snapshot: snapshot, currentContext: { context })
        try expect(snapshot.document() == value, "Native file can be installed and read back")
        let permissions = try manager.attributesOfItem(atPath: snapshot.url.path)[.posixPermissions] as! NSNumber
        expect(permissions.intValue & 0o777 == 0o600, "Credential-bearing native file is private")
        expect(!manager.fileExists(atPath: secretMarker), "No command or secret reference executes while editing")
        let raw = try Data(contentsOf: snapshot.url)
        _ = try await OMPMCPConfiguration.save(value, snapshot: snapshot, currentContext: { context })
        try expect(Data(contentsOf: snapshot.url) == raw, "No-change saves preserve exact file bytes")
        try expect(Data(contentsOf: project) == projectBytes, "Project MCP configuration is untouched")

        let external = Data("{\"mcpServers\":{},\"external\":\"owner edit\"}".utf8)
        try external.write(to: snapshot.url)
        await rejected("External writes reject stale snapshots") { _ = try await OMPMCPConfiguration.save(value, snapshot: snapshot, currentContext: { context }) }
        try expect(Data(contentsOf: snapshot.url) == external, "Conflict does not clobber owner data")
        snapshot = try await OMPMCPConfiguration.read(context: context)
        let other = root.appendingPathComponent("other-profile")
        try manager.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(other.path.utf8).write(to: selected)
        await rejected("Native active-profile changes reject old editors") { _ = try await OMPMCPConfiguration.save(value, snapshot: snapshot, currentContext: { context }) }
        expect(!manager.fileExists(atPath: other.appendingPathComponent("mcp.json").path), "Profile switch never creates a file in the new profile")
        try Data(profile.path.utf8).write(to: selected)
        var contextCalls = 0
        await rejected("Executable/environment changes during native path lookup reject the save") {
            _ = try await OMPMCPConfiguration.save(value, snapshot: snapshot, currentContext: {
                contextCalls += 1
                return contextCalls == 1 ? context : nil
            })
        }
        expect(contextCalls == 2, "Context is checked before and after the asynchronous CLI reply")

        let lock = snapshot.url.appendingPathExtension("lock")
        let descriptor = open(lock.path, O_RDWR)
        guard descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { fatalError("Acquire fixture lease") }
        await rejected("A concurrent native config writer owns the lock") { _ = try await OMPMCPConfiguration.save(value, snapshot: snapshot, currentContext: { context }) }
        flock(descriptor, LOCK_UN); close(descriptor)
        try expect(Data(contentsOf: snapshot.url) == external, "Lock failure leaves the original file untouched")

        try manager.removeItem(at: snapshot.url)
        let target = root.appendingPathComponent("symlink-target.json")
        try external.write(to: target)
        try manager.createSymbolicLink(at: snapshot.url, withDestinationURL: target)
        await rejected("Symbolic links cannot redirect profile reads") { _ = try await OMPMCPConfiguration.read(context: context) }
        await rejected("A symlink swap cannot redirect profile writes") { _ = try await OMPMCPConfiguration.save(value, snapshot: snapshot, currentContext: { context }) }
        await rejected("Opening JSON cannot follow a configuration symlink") {
            _ = try await OMPMCPConfiguration.prepareForOpening(context: context, currentContext: { context })
        }
        try expect(Data(contentsOf: target) == external, "Symlink target is never modified")
        try manager.removeItem(at: snapshot.url)
        try Data(repeating: 0x20, count: OMPMCPConfiguration.byteLimit + 1).write(to: snapshot.url)
        await rejected("Large native files fail before loading an editor") { _ = try await OMPMCPConfiguration.read(context: context) }
        try Data("{broken json".utf8).write(to: snapshot.url)
        snapshot = try await OMPMCPConfiguration.read(context: context)
        await rejected("Malformed JSON is retained for a repair editor") { _ = try snapshot.document() }
        snapshot = try await OMPMCPConfiguration.save(value, snapshot: snapshot, currentContext: { context })
        try expect(snapshot.document() == value, "Raw JSON can repair a malformed native file")
        value = ["mcpServers": [:], "future": .string(String(repeating: "x", count: OMPMCPConfiguration.byteLimit))]
        await rejected("Oversized updates leave existing native bytes intact") { _ = try await OMPMCPConfiguration.save(value, snapshot: snapshot, currentContext: { context }) }
        try expect(Data(contentsOf: snapshot.url) == snapshot.original, "Rejected update preserves saved configuration")
        let leftovers = try manager.contentsOfDirectory(atPath: profile.path).filter { $0.hasSuffix(".tmp") }
        expect(leftovers.isEmpty, "Atomic writes leave no secret temporary files")
        try await checkSettingsRefresh(context: context, root: root)
        try await checkEditorLayout(snapshot: snapshot, root: root)
        try await checkQuickConnectPresentation()
        print("MCP profile configuration checks passed: \(count)")
    }

    @MainActor private static func checkQuickConnect() throws {
        for entry in MCPCatalog.entries {
            let values = Dictionary(uniqueKeysWithValues: entry.fields.map { field in
                (field.key, field.defaultValue ?? (field.kind == .secret ? "${MCP_FIXTURE_SECRET}" : "/fixture/path"))
            })
            let definition = try OMPMCPQuickConnect.definition(for: entry, values: values)
            try OMPMCPDocument.validateServer(definition)
            try expect(definition["auth"] == nil, "Catalog templates cannot fabricate sign-in or credentials")
            try expect(OMPMCPQuickConnect.matches(entry, query: entry.name), "Every catalog server is searchable")
            try expect(Bundle(for: WindowManager.self).image(forResource: NSImage.Name(entry.asset)) != nil, "Approved catalog icons are bundled")
        }
        let github = MCPCatalog.entry(id: "github")!
        do { _ = try OMPMCPQuickConnect.definition(for: github, values: [:]); fatalError("Required credentials must be entered") }
        catch is OMPMCPError { count += 1 }
        let value = try OMPMCPQuickConnect.definition(for: github, values: ["token": "${MCP_FIXTURE_SECRET}"])
        try expect(value["headers"]?["Authorization"]?.string == "Bearer ${MCP_FIXTURE_SECRET}", "Quick connect preserves environment references literally")
        let publicHub = try OMPMCPQuickConnect.definition(for: MCPCatalog.entry(id: "huggingface")!, values: [:])
        try expect(publicHub["headers"]?.object?.isEmpty == true, "An omitted optional token does not create an empty authorization header")
        let gitlab = try OMPMCPQuickConnect.definition(for: MCPCatalog.entry(id: "gitlab")!, values: ["instance": "https://gitlab.example.invalid/"])
        try expect(gitlab["url"]?.string == "https://gitlab.example.invalid/api/v4/mcp", "Native OAuth templates normalize pasted instance hosts")
    }

    @MainActor private static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { fatalError(message) }
            try await Task.sleep(for: .milliseconds(20))
        }
        count += 1
    }

    @MainActor private static func checkSettingsRefresh(context: OMPDiscoveryContext, root: URL) async throws {
        let manager = FileManager.default
        let directory = root.appendingPathComponent("automatic-profile")
        let selected = root.appendingPathComponent("automatic-selected-profile")
        let gate = root.appendingPathComponent("automatic-profile-gate")
        try Data(directory.path.utf8).write(to: selected)
        var context = context
        context.environment["OMP_GUI_MCP_PATH"] = selected.path
        context.environment["OMP_GUI_MCP_GATE"] = gate.path
        let state = MCPSettingsState()
        defer { state.stop(); try? manager.removeItem(at: gate) }
        state.start(context: context)
        expect(!state.hasEditableConfiguration, "Editing is unavailable before the first native configuration read")
        try await eventually("The settings page must load automatically") { !state.busy && state.document == OMPMCPDocument.empty }
        expect(state.hasEditableConfiguration, "An empty but valid profile offers visual installation")
        let url = directory.appendingPathComponent("mcp.json")
        expect(!manager.fileExists(atPath: url.path), "Entering Settings never creates native configuration")
        var opened: URL?
        let openError = await state.openFile(currentContext: { context }, open: { opened = $0; return true })
        expect(openError == nil && opened == url, "Open JSON delegates the active native file to the system opener")
        try await eventually("Creating a file for external editing updates Settings") { !state.busy && state.snapshot?.original != nil }
        try expect(OMPMCPDocument.decode(String(contentsOf: url, encoding: .utf8)) == OMPMCPDocument.empty,
                   "Opening a missing JSON file creates a native empty configuration")

        let first: JSONValue = ["mcpServers": ["first": ["command": "server"]]]
        try first.data(pretty: true).write(to: url)
        try await eventually("In-place external writes must refresh the list") { !state.busy && state.document == first }
        let stale = state.snapshot!
        let second: JSONValue = ["mcpServers": ["second": ["command": "server"]], "future": true]
        try second.data(pretty: true).write(to: url, options: .atomic)
        try await eventually("Atomic editor saves must refresh the list") { !state.busy && state.document == second }
        let staleError = await state.save(first, snapshot: stale, currentContext: { context })
        try expect(staleError != nil && Data(contentsOf: url) == second.data(pretty: true),
                   "Automatic list refresh never grants an old editor permission to overwrite an external change")
        try await eventually("Any refresh queued by an external save must finish before another mutation") { !state.busy && state.document == second }
        let saved = await state.save(first, snapshot: state.snapshot!, currentContext: {
            expect(state.busy && state.hasEditableConfiguration,
                   "Saving keeps loaded control availability stable while serializing mutations")
            state.refresh()
            return context
        })
        expect(saved == nil && state.document == first, "Visual saves update the list immediately")
        try await eventually("Refresh requests during a save must drain after it finishes") { !state.busy && state.document == first && state.error == nil }

        // Block only the profile CLI: file events should read the already resolved JSON directly.
        try Data().write(to: gate)
        try second.data(pretty: true).write(to: url, options: .atomic)
        try await eventually("The shared cache stays accurate between page visits without another profile CLI call") {
            !state.busy && state.document == second
        }
        let cached = state.snapshot!
        state.start(context: context)
        expect(state.busy && state.document == second && state.snapshot?.id == cached.id && state.fileURL == url,
               "Reentering MCP immediately retains the installed list and its original snapshot while checking the profile")
        try await eventually("The returning page must revalidate its active profile in the background") {
            manager.fileExists(atPath: gate.path + ".started")
        }
        state.start(context: context)
        expect(state.document == second && state.hasEditableConfiguration,
               "Repeated starts coalesce without clearing or dimming a warm page")
        try manager.removeItem(at: gate)
        try await eventually("A slow profile check settles without a loading placeholder") { !state.busy && state.document == second }

        let malformed = Data("{invalid external JSON".utf8)
        try malformed.write(to: url, options: .atomic)
        try await eventually("Malformed external JSON must stop mutations without losing the file action") {
            !state.busy && state.document == nil && state.error != nil
        }
        expect(!state.hasEditableConfiguration, "Invalid external JSON disables visual mutations")
        let repairError = await state.openFile(currentContext: { context }, open: { $0 == url })
        try expect(repairError == nil && Data(contentsOf: url) == malformed,
                   "The external editor can repair invalid JSON without the GUI rewriting its contents")
        try await eventually("External-open refresh must finish") { !state.busy }
        let oversized = Data(repeating: 0x20, count: OMPMCPConfiguration.byteLimit + 1)
        try oversized.write(to: url, options: .atomic)
        try await eventually("Oversized files must retain an external repair path") {
            !state.busy && state.snapshot == nil && state.error == OMPMCPDocument.failure("MCP configuration exceeds the 2 MiB editing limit.").localizedDescription
        }
        let largeError = await state.openFile(currentContext: { context }, open: { $0 == url })
        try expect(largeError == nil && Data(contentsOf: url) == oversized, "Opening an oversized file does not load or replace it")
        try first.data(pretty: true).write(to: url, options: .atomic)
        try await eventually("Repairing external JSON must recover the page automatically") { !state.busy && state.document == first && state.error == nil }
        try manager.removeItem(at: url)
        try await eventually("Deleting JSON must restore the empty state automatically") { !state.busy && state.document == OMPMCPDocument.empty && state.snapshot?.original == nil }
        state.refresh()
        expect(state.busy && state.hasEditableConfiguration,
               "A background refresh retains the loaded control availability instead of dimming the page")
        try await eventually("Background refresh must settle without losing editability") { !state.busy && state.hasEditableConfiguration }

        let other = root.appendingPathComponent("automatic-other-profile")
        try Data(other.path.utf8).write(to: selected)
        state.refresh()
        try await eventually("Returning to Settings must re-resolve the active native profile") {
            !state.busy && state.fileURL == other.appendingPathComponent("mcp.json") && state.document == OMPMCPDocument.empty
        }
        opened = nil
        let changedError = await state.openFile(currentContext: { nil }, open: { opened = $0; return true })
        expect(changedError != nil && opened == nil, "A changed executable/environment prevents opening the wrong profile")
        let launchError = await state.openFile(currentContext: { context }, open: { _ in false })
        expect(launchError != nil, "A failed system opener is visible to the user")
        var changedContext = context
        changedContext.environment["OMP_GUI_MCP_CONTEXT"] = "changed"
        state.start(context: changedContext)
        expect(state.snapshot == nil && state.document == nil && state.fileURL == nil,
               "A different executable/environment never receives another profile's cached list")
        state.stop()
        try await Task.sleep(for: .milliseconds(250))
        expect(!state.busy && state.snapshot == nil && state.document == nil && state.fileURL == nil,
               "Stopping the application cache cancels pending reads, releases its watch and rejects late results")
    }

    @MainActor private static func checkEditorLayout(snapshot: OMPMCPSnapshot, root: URL) async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = OMPMCPServer(id: "remote-form", definition: ["type": "http", "url": "https://example.invalid/mcp"], enabled: true)
        let host = NSHostingView(rootView: MCPServerEditor(snapshot: snapshot, server: server, openFile: { nil }, save: { _ in nil })
            .presentedChrome().environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(host)
        let fields = views.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        expect(fields.count >= 5, "The actual remote editor mounts the default header key/value alongside its other inputs")
        expect(fields.allSatisfy { ($0.placeholderString ?? "").isEmpty }, "Every visible native editor input has no placeholder")
        guard let scroll = views.compactMap({ $0 as? NSScrollView }).first, let document = scroll.documentView else {
            fatalError("The real editor must retain its bounded native scroll viewport")
        }
        let scrollFields = fields.filter { $0.isDescendant(of: document) }
        expect(scrollFields.count >= 4, "The remote form retains its native inputs inside the scroll viewport")
        for field in scrollFields {
            let rect = scroll.contentView.convert(field.bounds, from: field)
            expect(rect.minX >= 8 && rect.maxX <= scroll.contentView.bounds.width - 8,
                   "Native inputs must leave room at both scroll edges for their glass surface: \(rect)")
        }
        let viewport = host.convert(scroll.bounds, from: scroll)
        expect(viewport.minX >= 0 && viewport.maxX <= host.bounds.width,
               "The expanded scroll viewport remains inside the popover")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("remote-editor.png"))
        }
    }

    @MainActor private static func checkQuickConnectPresentation() async throws {
        var entry = MCPCatalog.entry(id: "github")!
        entry.sampleTools = ["first", "second", "third"]
        let previewHeight = NSHostingView(rootView: MCPQuickConnectTools(entry: entry, width: 200).frame(width: 200)).fittingSize.height
        entry.sampleTools += (1...30).map { "additional_tool_\($0)" }
        let fullHeight = NSHostingView(rootView: MCPQuickConnectTools(entry: entry, width: 200).frame(width: 200)).fittingSize.height
        expect(fullHeight > previewHeight && fullHeight <= 120,
               "The popover displays tools beyond the card preview in a bounded, scrollable viewport")

        let fixture = MCPQuickConnectPresentationFixture()
        fixture.selection = "gitlab"
        let host = NSHostingView(rootView: ScrollView {
            VStack {
                Color.clear.frame(height: 180)
                MCPQuickConnectCatalog(query: "", configured: [], canEdit: true,
                    select: { fixture.selection = $0.id }, presented: { id in
                        Binding(get: { fixture.selection == id }, set: { if !$0 { fixture.selection = nil } })
                    }, editor: { entry in AnyView(MCPQuickConnectFixtureEditor(entry: entry, fixture: fixture)) })
            }.padding(20)
        })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 780, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = host
        window.orderBack(nil)
        defer { fixture.close?(); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        try await eventually("A newly mounted row opens its requested login without depending on the global key window") { fixture.popup != nil && fixture.close != nil }
        fixture.close?()
        try await eventually("The initial presentation closes before testing later page visits") { fixture.selection == nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first else {
            fatalError("The real catalog requires its enclosing settings-style scroll view")
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let origin = scroll.contentView.bounds.origin
        expect(origin.y > 0, "Exercise popovers after the settings page has scrolled")
        for id in ["github", "gitlab"] {
            fixture.popup = nil
            fixture.close = nil
            fixture.selection = id
            try await eventually("The catalog's native connection/sign-in form must open") { fixture.popup != nil && fixture.close != nil }
            expect(window.alphaValue == 0 && fixture.popup?.alphaValue == 0,
                   "Catalog presentation checks never display a visible application or popup")
            expect(abs(scroll.contentView.bounds.origin.y - origin.y) < 0.5,
                   "Opening a catalog form does not scroll its settings page")
            // Cancel and click-away both close through this native presenter's close path.
            fixture.close?()
            try await eventually("Closing the native form clears its presentation binding") { fixture.selection == nil }
            try await Task.sleep(for: .milliseconds(80))
            expect(abs(scroll.contentView.bounds.origin.y - origin.y) < 0.5,
                   "Dismissing a catalog form keeps the settings page at its original position")
        }
    }
}

@MainActor @Observable
private final class MCPQuickConnectPresentationFixture {
    var selection: String?
    @ObservationIgnored weak var popup: NSWindow?
    @ObservationIgnored var close: (@MainActor () -> Void)?
}

private struct MCPQuickConnectFixtureEditor: View {
    let entry: MCPCatalogEntry
    let fixture: MCPQuickConnectPresentationFixture
    @Environment(\.closePopover) private var close

    var body: some View {
        MCPQuickConnectEditor(entry: entry, submit: { _ in nil })
            .background { MCPQuickConnectHiddenWindowProbe(resolve: { fixture.popup = $0 }) }
            .onAppear { fixture.close = close }
    }
}

private struct MCPQuickConnectHiddenWindowProbe: NSViewRepresentable {
    let resolve: (NSWindow) -> Void
    func makeNSView(context: Context) -> Probe { Probe(resolve: resolve) }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        let resolve: (NSWindow) -> Void
        init(resolve: @escaping (NSWindow) -> Void) { self.resolve = resolve; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { window.alphaValue = 0; resolve(window) }
        }
    }
}
