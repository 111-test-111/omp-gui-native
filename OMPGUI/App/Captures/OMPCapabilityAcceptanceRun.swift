#if DEBUG
import AppKit
import SwiftUI

/// Owner-requested native P3/P4 acceptance. Never enabled by a normal launch.
@MainActor
enum OMPCapabilityAcceptanceRun {
    static var enabled: Bool { CaptureRun.isEnabled && CommandLine.arguments.contains("--omp-capability-acceptance") }
    private static var output: URL { CaptureRun.outputDirectory! }
    private static var checks: [String] = []
    private static var window: NSWindow?
    private static var loginWindow: NSWindow?
    private static var runtimes: [ThreadRuntime] = []
    private static var loginCompleted = false
    private static var phase = "preparing"
    private static var facts: [String: JSONValue] = [:]
    private static var p4Only: Bool { CommandLine.arguments.contains("--p4-only") }
    private static func arg(_ key: String) -> String {
        let index = CommandLine.arguments.firstIndex(of: key)!
        return CommandLine.arguments[index + 1]
    }
    static func prepare() {
        guard output.path.contains("/build.noindex/omp-capability-live/"), let root = CaptureRun.storageRoot,
              !FileManager.default.fileExists(atPath: root.path), let defaults = CaptureRun.defaults else { fatalError("Require fresh isolated capability acceptance") }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defaults.removePersistentDomain(forName: CaptureRun.suiteName)
            defaults.set("omp", forKey: "defaultProvider")
            defaults.set(["omp": arg(p4Only ? "--omp-p4" : "--omp-p3")], forKey: "providerBinaryPaths")
            defaults.set("dark", forKey: "appTheme")
            for key in ["notifyWhenFinished", "chimeWhenFinished", "antiSlopEnabled", "sidebarActivityView"] { defaults.set(false, forKey: key) }
            defaults.set(true, forKey: "hasSeenHydraIntro")
            var library = Library()
            let project = Project(name: "P3/P4 native acceptance", path: output.appendingPathComponent("workspace").path)
            library.projects = [project]
            var thread = ChatThread(projectID: project.id, provider: .omp, model: "omp-gui-bootstrap/acceptance", effort: "off", runtimeMode: .auto)
            thread.title = "P3 · Native extension acceptance"
            thread.hasCustomTitle = true
            thread.hydraEnabled = false
            library.threads = [thread]
            try JSONEncoder.storage.encode(library).write(to: root.appendingPathComponent("library.json"), options: .atomic)
            defaults.synchronize()
        } catch { fatalError(error.localizedDescription) }
    }
    static func run(model: AppModel) async {
        do {
            await model.bootstrap()
            let chat = model.threads.first!
            model.selectedThreadID = chat.id
            let runtime = model.runtime(for: chat.id)
            runtimes.append(runtime)
            await runtime.ensureLoaded()
            window = WindowManager.shared.makeCaptureWindow(size: NSSize(width: 1320, height: 860), threadControls: true)
            window?.title = "OMP P3/P4 Acceptance"
            if !p4Only {
                await model.omp.refresh(force: true)
                try require(model.omp.loginProviders.isEmpty, "Fresh native profile has no RPC login directory before its first authenticated model")
                WindowManager.shared.showSettings(page: .providers)
                try writePhase("inspection-empty-login")
                try await marker("login-fallback-continue")
                for win in NSApp.windows where win !== window { win.close() }
                try writePhase("native-plugin-install")
                let plugins = OMPNativePlugins()
                let installed = await plugins.change("install", target: output.appendingPathComponent("local-plugin").path,
                    scope: "user", registry: model.providers, directory: output.appendingPathComponent("workspace"))
                try require(installed, "Production plugin service installs the self-authored local plugin through real OMP")
                await plugins.refresh(registry: model.providers, directory: output.appendingPathComponent("workspace"))
                try require(plugins.error == nil && plugins.plugins.contains { $0.name == "omp-gui-local-acceptance" && $0.scope == "user" }, "Real native inventory reports the installed plugin and scope")
                await plugins.diagnose(registry: model.providers, directory: output.appendingPathComponent("workspace"))
                try require(plugins.error == nil && !plugins.diagnostics.isEmpty, "Real native plugin diagnostics return structured checks")
                await model.omp.refresh(force: true)
                var provider = model.omp.loginProviders.first { $0.id == "omp-gui-acceptance" }
                try require(provider != nil && provider?.authenticated == false, "Installed extension registers an unauthenticated synthetic native provider")
                // This isolated, explicitly requested fixture supplies its own
                // browser flow rather than an installed built-in auth policy.
                provider?.supportsBrowserLogin = true
                let login = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                login.isReleasedWhenClosed = false
                login.title = "OMP Synthetic Login Acceptance"
                let flow = OMPNativeLogin(openURL: { NSWorkspace.shared.open($0) })
                login.contentView = NSHostingView(rootView: OMPLoginControls(provider: provider!, flow: flow,
                    useTerminal: {}, cancel: { flow.stop() }).font(.ui(.body)).environment(model)
                    .task {
                        await flow.start(provider: provider!, registry: model.providers)
                        loginCompleted = flow.completed
                    }
                    .onDisappear { flow.stop() })
                loginWindow = login
                login.center(); login.makeKeyAndOrderFront(nil)
                try writePhase("inspection-native-login")
                try await wait("synthetic native login", seconds: 600) { loginCompleted }
                login.close()
                await model.omp.refresh(force: true)
                try require(model.omp.loginProviders.contains { $0.id == "omp-gui-acceptance" && $0.authenticated }, "Native login RPC persists synthetic credentials only in the isolated profile")
                try require(model.omp.agentDirectory.path == output.appendingPathComponent("native-config/agent").path, "Native profile discovery stays inside the isolated acceptance directory")
                let roles = model.omp.values["modelRoles"] ?? [:]
                let roleError = await model.omp.setSelectors("modelRoles", changes: ["smol": "omp-gui-acceptance/acceptance"], expected: roles)
                try require(roleError == nil && model.omp.values["modelRoles"]?["future-role"]?.string == "preserve/me", "Real native role writes preserve unknown role assignments")
                await model.omp.set("task.maxRecursionDepth", .int(-1))
                try require(model.omp.error == nil && model.omp.values["task.maxRecursionDepth"]?.int == -1, "Native agent form serialization preserves negative sentinel values")
                let profile = model.omp.agentDirectory.appendingPathComponent("config.yml")
                let original = try String(contentsOf: profile, encoding: .utf8)
                try require(original.contains("futureAcceptance: preserved"), "Unknown native profile fields survive writes")
                try Data((original + "\nexternalAcceptanceOwner: retained\n").utf8).write(to: profile)
                let conflict = await model.omp.setSelectors("modelRoles", changes: ["smol": "must/not/write"], expected: model.omp.values["modelRoles"] ?? [:])
                try require(conflict != nil && (try String(contentsOf: profile, encoding: .utf8)).contains("externalAcceptanceOwner: retained"), "External CLI-style changes reject stale form saves")
                await model.omp.refresh(force: true)
                try require(model.omp.error == nil, "Native settings reload after the external modification")
                let mcpFile = model.omp.agentDirectory.appendingPathComponent("mcp.json")
                try Data("{\"mcpServers\":{\"acceptance-disabled\":{\"command\":\"/usr/bin/false\",\"enabled\":false,\"future\":42}},\"future\":\"preserved\"}".utf8).write(to: mcpFile)
                let mcpContext = OMPMCPConfiguration.context(registry: model.providers)!
                var mcpSnapshot = try await OMPMCPConfiguration.read(context: mcpContext)
                for enabled in [true, false] {
                    let value = try OMPMCPDocument.settingEnabled(enabled, server: "acceptance-disabled", in: mcpSnapshot.document())
                    mcpSnapshot = try await OMPMCPConfiguration.save(value, snapshot: mcpSnapshot,
                        currentContext: { OMPMCPConfiguration.context(registry: model.providers) })
                }
                try require(try mcpSnapshot.document()["mcpServers"]?["acceptance-disabled"]?["future"]?.int == 42, "Native MCP file edits retain unknown server fields")
                await model.providers.loadCatalog(.omp, force: true)
                try writePhase("inspection-native-select")
                runtime.draft = ComposerDraft(text: "/omp-gui-acceptance dialogs")
                runtime.send()
                try await wait("native rich selection", seconds: 120) { !runtime.questions.isEmpty }
                try require(runtime.questions.first?.questions.first?.choices.first?.detail?.contains("保留选项说明") == true, "Real native rich option descriptions reach the GUI")
                runtime.draft = ComposerDraft(text: "UNSENT_P3_OWNER_DRAFT")
                try await wait("native editor", seconds: 600) { runtime.questions.first?.questions.first?.isMultiline == true }
                try writePhase("inspection-native-editor")
                try require(runtime.questions.first?.questions.first?.prefill == "  first line\n第二行🙂\n", "Real native editor preserves multiline Unicode prefill")
                try await wait("native prepared editor text", seconds: 600) { runtime.pendingOMPEditorText == "NATIVE_PREPARED_TEXT" }
                try require(runtime.draft.text == "UNSENT_P3_OWNER_DRAFT", "Native prepared text does not overwrite active user typing")
                let edit = try JSONValue.parse(Data(contentsOf: output.appendingPathComponent("results/editor.json")))
                try require(edit?["edited"]?.string == "  第一行🙂\nsecond line\n", "Native receives the exact edited whitespace and Unicode")
                try require(runtime.ompExtensionState.statuses["acceptance"] == "NATIVE_STATUS_OK" && runtime.ompExtensionState.widgets.count == 2, "Real native status and above/below widgets reach the composer")
                try require(model.providers.commands.values.flatMap { $0 }.contains { $0.name == "omp-gui-acceptance" && $0.source == "extension" }, "Native command discovery preserves extension source")
                try writePhase("inspection-native-prepared")
                try await wait("apply prepared text from actual UI", seconds: 600) { runtime.pendingOMPEditorText == nil && runtime.draft.text == "NATIVE_PREPARED_TEXT" }
                try require(runtime.followUps.contains { $0.ompState == .draft && $0.text.contains("UNSENT_P3_OWNER_DRAFT") }, "Applying prepared text retains the displaced draft without submitting it")
                for draft in runtime.followUps where draft.ompState == .draft { runtime.removeFollowUp(draft.id) }
                for mode in ["timeout", "cancel"] {
                    try await wait("previous native extension command", seconds: 120) { runtime.phase == .idle }
                    runtime.draft = ComposerDraft(text: "/omp-gui-acceptance " + mode)
                    runtime.send()
                    try await wait("native \(mode)", seconds: 120) { FileManager.default.fileExists(atPath: output.appendingPathComponent("results/\(mode).json").path) && runtime.questions.isEmpty && runtime.phase == .idle }
                    let result = try JSONValue.parse(Data(contentsOf: output.appendingPathComponent("results/\(mode).json")))
                    try require(result?["cancelled"]?.bool == true, "Real native \(mode) clears its GUI request and returns cancellation")
                }
                WindowManager.shared.showSettings(page: .providers)
                try writePhase("inspection-p3-settings")
                try await marker("p3-continue")
                for win in NSApp.windows where win !== window && win !== loginWindow { win.close() }
                runtime.stopSession()
                let removed = await plugins.change("uninstall", target: "omp-gui-local-acceptance", scope: "user", registry: model.providers, directory: output.appendingPathComponent("workspace"))
                await plugins.refresh(registry: model.providers, directory: output.appendingPathComponent("workspace"))
                try require(removed && !plugins.plugins.contains { $0.name == "omp-gui-local-acceptance" }, "Production service uninstalls the local plugin from the isolated native registry")
                facts["p3_status"] = "completed"
                try writeReport(status: "p3-completed")
            }

            model.settings.setBinaryPath(arg("--omp-p4"), for: .omp)
            await model.providers.refreshEverything()
            var parent = ChatThread(projectID: chat.projectID, provider: .omp, model: arg("--omp-model"), effort: "off", runtimeMode: .auto)
            parent.title = "P4 · Native Hydra acceptance"
            parent.hasCustomTitle = true
            parent.hydraEnabled = true
            model.insertThread(parent)
            model.selectedThreadID = parent.id
            let lead = model.runtime(for: parent.id)
            runtimes.append(lead)
            await lead.ensureLoaded()
            guard let preview = (window as? ThreadWindow)?.filePreviews else { throw Failure("Missing isolated file preview") }
            let linked = output.appendingPathComponent("linked-source")
            let source = linked.appendingPathComponent("Source.txt")
            let sourceContext = FilePreviewContext(threadID: parent.id, workingDirectory: linked.path)
            let text = try String(contentsOf: source, encoding: .utf8)
            let selected = FileQuestionContext.selection(path: source.path, source: sourceContext, text: text, range: (text as NSString).range(of: "原生上下文🙂 P4_SELECTED_FACT"))!
            lead.setExplicitFileContext(selected)
            _ = preview.open(FilePreviewReference(path: source.path, line: 2), context: FilePreviewContext(threadID: parent.id, workingDirectory: output.appendingPathComponent("workspace").path))
            try writePhase("native-host-tools")
            lead.draft = ComposerDraft(text: "Synthetic GUI acceptance. Do not delegate or modify files. Call gui_read_selected_context once with {} and then gui_open_file_location with path \(source.path) and line 2. After both succeed reply P4_HOST_OK. Do not use another tool.")
            lead.send()
            try await wait("real native host tool calls", seconds: 240) { lead.phase == .idle && lead.ompActivity?.canRecycle == true }
            let tools = lead.entries.compactMap { entry -> ToolCall? in if case .tool(let call) = entry.item.content { return call }; return nil }
            try require(tools.contains { ($0.toolDevice ?? $0.toolName) == "gui_read_selected_context" && $0.status == .completed && $0.output.contains("P4_SELECTED_FACT") }, "Actual model calls the registered native selected-context host tool")
            try require(tools.contains { ($0.toolDevice ?? $0.toolName) == "gui_open_file_location" && $0.status == .completed }, "Actual model opens a linked-worktree file through the native host tool")
            try require(preview.session?.selectedTab?.url.path == source.path && preview.session?.selectedTab?.location?.line == 2, "Native host open preserves the selected source worktree and line")
            lead.setExplicitFileContext(nil)
            do {
                _ = try await model.handleOMPHostTool(OMPHostToolRequest(id: "clear-check", toolCallID: "clear-check", name: "gui_read_selected_context", arguments: [:]), threadID: parent.id)
                throw Failure("Cleared file context remained readable")
            } catch is OMPHostToolError { checks.append("Clearing explicit context revokes the production host callback") }

            try writePhase("native-hydra-worker")
            lead.isHydraPanelHidden = true
            lead.draft = ComposerDraft(text: "Synthetic read-only native Hydra acceptance. Call task exactly once with agent acceptance, name GUIAcceptance, isolated true, and task: Read Source.txt; run bash command sleep 12; printf 'P4_CHILD_TOOL_DONE\\n'; after it finishes reply exactly P4_CHILD_FINAL and include any steering marker. Do not change any file and do not delegate again. When the native task finishes reply P4_PARENT_FINAL.")
            lead.send()
            try await wait("real native worker", seconds: 240) { model.children(of: parent.id).contains { $0.hydra?.kind == .native } }
            let child = model.children(of: parent.id).first { $0.hydra?.kind == .native }!
            let childRuntime = model.runtime(for: child.id)
            try require(child.hydra?.nativeResult?.sessionFile != nil && child.hydra?.nativeObservationID != nil, "Real OMP worker exposes durable session and observation identity")
            try require(!lead.canRecycleSession, "Parent cannot recycle while native child work remains")
            await model.setOMPAgentDetailsVisible(headID: child.id, visible: true, consumer: "acceptance")
            try await wait("worker durable details", seconds: 120) { childRuntime.entries.contains { if case .tool = $0.item.content { return true }; return false } }
            let steeringSupported = childRuntime.canSteerNativeOMPAgent
            facts["worker_steering_supported"] = .bool(steeringSupported)
            if steeringSupported {
                childRuntime.draft = ComposerDraft(text: "Include P4_STEER_OK in the final reply. Keep the requested read-only task and do not delegate.")
                childRuntime.send()
                try await wait("native child steering acceptance", seconds: 60) { childRuntime.draft.isEmpty && !childRuntime.isOMPAgentSteeringPending }
                checks.append("Actual native worker confirms steering acceptance")
            } else {
                try require(lead.ompCapabilities["steer_subagent"] == .unsupported && !childRuntime.canSteerNativeOMPAgent,
                    "Actual native unknown-command response keeps worker steering unavailable")
                try require(lead.ompCapabilities["cancel_subagent"] == .unsupported && !childRuntime.canStopNativeOMPAgent,
                    "Actual native unknown-command response keeps worker stop unavailable")
            }
            await model.setOMPAgentDetailsVisible(headID: child.id, visible: false, consumer: "acceptance")
            try await Task.sleep(for: .milliseconds(400))
            await model.setOMPAgentDetailsVisible(headID: child.id, visible: true, consumer: "acceptance")
            try await wait("native child completion", seconds: 300) { model.thread(child.id)?.hydra?.isFinished == true && lead.phase == .idle && lead.ompActivity?.canRecycle == true }
            try await wait("completed native worker detail replay", seconds: 120) { childRuntime.entries.contains { if case .assistant(let message) = $0.item.content { return message.text.contains("P4_CHILD_FINAL") }; return false } }
            let result = model.thread(child.id)?.hydra?.nativeResult
            try require(result?.model == arg("--omp-model"), "Hydra reports the actual native worker model")
            try require(result?.workingDirectory?.isEmpty == false && result?.parentSessionFile != nil && result?.agentSource != nil, "Real native worker preserves worktree, parent and source metadata")
            if steeringSupported {
                try require(childRuntime.entries.contains { if case .user(let user) = $0.item.content { return user.text.contains("P4_STEER_OK") }; return false }, "Native worker steering remains readable after hide and reopen")
                try require(childRuntime.entries.contains { if case .assistant(let message) = $0.item.content { return message.text.contains("P4_STEER_OK") }; return false }, "Actual native worker consumes the accepted steering instruction")
            }
            facts["worker_model"] = result?.model.map(JSONValue.string) ?? .null
            facts["worker_isolated"] = result?.isolated.map(JSONValue.bool) ?? .null
            facts["worker_changes_applied"] = result?.changesApplied.map(JSONValue.bool) ?? .null
            facts["worker_has_output_artifact"] = .bool(result?.outputPath != nil)
            lead.isHydraPanelHidden = false
            lead.hydraSelectedHeadID = child.id
            try writePhase("inspection-p4-transcript")
            try await marker("finish")
            for current in runtimes { current.stopSession(); current.saveNow(); current.cancelPersistence() }
            try writeReport(status: "completed")
            try writePhase("completed")
            NSApp.terminate(nil)
        } catch {
            for runtime in runtimes { runtime.stopSession() }
            try? writeReport(status: "failed", error: error.localizedDescription)
            try? writePhase("failed", error: error.localizedDescription)
        }
    }
    private static func require(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure(label) }
        checks.append(label)
    }
    private static func wait(_ label: String, seconds: Int, until predicate: () -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !predicate() {
            try Task.checkCancellation()
            guard ContinuousClock.now < limit else { throw Failure("Timeout: " + label) }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
    private static func marker(_ name: String) async throws {
        try await wait("inspection " + name, seconds: 600) { FileManager.default.fileExists(atPath: output.appendingPathComponent(name).path) }
    }
    private static func writePhase(_ value: String, error: String? = nil) throws {
        phase = value
        try JSONValue.object(["phase": .string(value), "error": error.map(JSONValue.string) ?? .null,
            "gui_pid": .int(Int(ProcessInfo.processInfo.processIdentifier))]).data().write(to: output.appendingPathComponent("phase.json"), options: .atomic)
    }
    private static func writeReport(status: String, error: String? = nil) throws {
        facts["status"] = .string(status)
        facts["phase"] = .string(phase)
        facts["checks"] = .array(checks.map(JSONValue.string))
        facts["error"] = error.map(JSONValue.string) ?? .null
        facts["synthetic_login"] = .bool(!p4Only)
        try JSONValue.object(facts).data().write(to: output.appendingPathComponent("report.json"), options: .atomic)
    }
    private struct Failure: LocalizedError { var errorDescription: String?; init(_ message: String) { errorDescription = message } }
}
#endif
