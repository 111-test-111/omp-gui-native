import AppKit
import SwiftUI
import Foundation
@testable import OMPGUI

@main
struct OMPWorkerChecks {
    @MainActor static var count = 0
    @MainActor static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        count += 1
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Worker fixture timed out")
    }

    @MainActor static func checkContextUsage(app: AppModel, parent: ChatThread, root: URL) async throws {
        let file = StoragePaths.directory("omp/sessions").appendingPathComponent("context-worker.jsonl")
        func response(_ id: String, parent: JSONValue = .null, total: JSONValue = 32000) -> JSONValue {
            ["type": "message", "id": .string(id), "parentId": parent,
             "message": ["role": "assistant", "provider": "native", "model": "context-worker",
                         "usage": ["totalTokens": total], "content": [], "stopReason": "stop"]]
        }
        let rows: [JSONValue] = [
            response("first", total: 12000),
            response("current", parent: "first"),
            response("abandoned", parent: "first", total: 999000),
            ["type": "model_usage", "id": "late-usage", "parentId": "abandoned", "activeLeafId": "current",
             "usage": ["totalTokens": 999000]]
        ]
        let journal = rows.map(\.compactString).joined(separator: "\n") + "\n"
        try Data((journal + "{\"type\":").utf8).write(to: file)
        let projection = try OMPAgentJournal.contextReport(rows)
        expect(projection.usage?.usedTokens == 32000 && projection.model == "native/context-worker",
               "Worker context follows the active native branch and latest response, never cumulative or auxiliary usage")
        var compacted = projection
        compacted.observe(["type": "compaction"])
        expect(compacted.usage == nil, "Compaction cannot keep the pre-compaction response occupancy")
        compacted.observe(response("next", total: 4000))
        expect(compacted.usage?.usedTokens == 4000, "The first response after compaction restores occupancy")
        compacted.observe(["type": "model_change", "model": "native/other-worker"])
        expect(compacted.usage == nil && compacted.model == "native/other-worker",
               "A model change cannot pair an earlier response with the new model's capacity")
        expect(OMPAgentJournal.ContextReport.progressUsage(["tokens": 900000, "contextWindow": 128000]) == nil,
               "A legacy cumulative progress counter never manufactures a context reading")
        let invalidCounts: [JSONValue] = [-1, 1.5, "32000", .null]
        for invalid in invalidCounts {
            expect(OMPAgentJournal.ContextReport.progressUsage(["contextTokens": invalid]) == nil,
                   "Malformed native context counts remain unknown")
        }
        let spawn = AgentSpawn(id: "context-worker", taskID: nil, toolUseID: nil, description: "task", prompt: nil,
            model: "native/context-worker", sessionFile: file.path, observationID: "context-observation")
        app.mirrorOMPAgent(spawn, parentID: parent.id)
        let head = app.children(of: parent.id).first { $0.hydra?.nativeID == spawn.id }!
        app.finishOMPAgent(nativeID: spawn.id, parentID: parent.id, status: .completed, summary: nil)
        let runtime = app.runtime(for: head.id)
        await runtime.ensureLoaded()
        runtime.draft = ComposerDraft(text: "Keep this worker draft")
        let before = runtime.entries.map(\.id)
        async let firstRead: Void = runtime.refreshOMPContext()
        async let secondRead: Void = runtime.refreshOMPContext()
        _ = try await (firstRead, secondRead)
        expect(runtime.canInspectOMPContext && runtime.displayedContextUsage?.usedTokens == 32000
               && runtime.displayedContextUsage?.windowTokens == nil,
               "A completed worker can recover its known count while an unknown capacity stays unknown")
        app.providers.updateCatalog([ModelOption(id: "native/context-worker", name: "Worker", metadata:
            ModelMetadata(contextWindow: 128000, pricing: ModelPricing(status: .unknown)))], for: .omp)
        expect(runtime.displayedContextUsage?.fraction == 0.25,
               "The worker's own catalogue can fill its capacity after the read without restarting it")
        let savedBytes = try Data(contentsOf: file)
        expect(runtime.activeOMPSession == nil && !runtime.canManageContext && runtime.entries.map(\.id) == before
               && runtime.draft.text == "Keep this worker draft"
               && savedBytes == Data((journal + "{\"type\":").utf8),
               "Worker context inspection leaves execution, controls, timeline, draft and journal unchanged")
        // The linked helper has no application localization bundle. Inspect the
        // compiled Chinese resource separately and render the real English view.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let resources = repo.appendingPathComponent("build.noindex/development/Build/Products/Debug/OMP GUI Dev.app/Contents/Resources/zh-Hans.lproj")
        guard let chinese = Bundle(url: resources) else { fatalError("Missing built Chinese localization") }
        for key in ["Refresh saved subagent context", "%@ / Unknown", "Unknown / %@",
                    "Context usage comes from OMP's latest reported response. Pending messages and tool results may not be included.",
                    "OMP manages this subagent's compaction and handoff."] {
            expect(chinese.localizedString(forKey: key, value: key, table: "Localizable") != key,
                   "The built app supplies the worker context's Chinese localization")
        }
        do {
            let host = NSHostingView(rootView: UsagePanel(runtime: runtime, provider: .omp)
                .environment(app).environment(\.locale, Locale(identifier: "en")))
            let size = host.fittingSize
            expect(size.width == 360 && size.height > 100 && size.height < 340,
                   "Worker Usage fits its read-only context instead of a disabled management form")
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("worker-context-en.png"))
            }
            window.close()
        }
        let compactedJournal = Array(rows.prefix(2)) + [JSONValue.object(["type": "compaction", "id": "compacted", "parentId": "current"])]
        try Data((compactedJournal.map(\.compactString).joined(separator: "\n") + "\n").utf8).write(to: file)
        try await runtime.refreshOMPContext()
        expect(runtime.displayedContextUsage == nil, "Refreshing a compacted journal clears a previously saved response size")
        runtime.cancelPersistence()
    }

    @MainActor static func checkDurableHistory(app: AppModel, project: Project, parent: ChatThread, root: URL) async throws {
        let file = StoragePaths.directory("omp/sessions").appendingPathComponent("durable-worker.jsonl")
        let fullReport = "The complete implementation report remains visible as the first turn's final answer."
        let error = "Codex error event: native lane rejected in-flight input (code=unsupported_native_inflight_message)"
        func row(_ id: String, _ role: String, _ text: String, _ timestamp: String, stop: String? = nil, error: String? = nil) -> JSONValue {
            var message: [String: JSONValue] = ["role": .string(role), "content": [["type": "text", "text": .string(text)]]]
            if let stop { message["stopReason"] = .string(stop) }
            if let error { message["errorMessage"] = .string(error) }
            return ["type": "message", "id": .string(id), "parentId": .null, "timestamp": .string(timestamp), "message": .object(message)]
        }
        func incoming(_ id: String, _ text: String, _ timestamp: String, nested: Bool = false, display: Bool = true) -> JSONValue {
            var custom: [String: JSONValue] = ["customType": "irc:incoming", "display": .bool(display),
                "content": .string("<irc>Incoming IRC message from agent `Main`:\n" + text + "</irc>"),
                "details": ["from": "Main", "fromParent": true, "message": .string(text)]]
            var entry: [String: JSONValue] = ["id": .string(id), "parentId": .null, "timestamp": .string(timestamp)]
            if nested {
                custom["role"] = "custom"
                entry["type"] = "message"
                entry["message"] = .object(custom)
            } else {
                entry.merge(custom) { _, value in value }
                entry["type"] = "custom_message"
            }
            return .object(entry)
        }
        let rows: [JSONValue] = [
            row("u1", "user", "Original assignment", "2026-01-01T00:00:00.000Z"),
            row("a1", "assistant", fullReport, "2026-01-01T00:02:02.250Z", stop: "stop"),
            incoming("hidden", "Hidden delivery", "2026-01-01T00:04:00Z", display: false),
            incoming("u2", "Follow-up", "2026-01-01T00:05:00Z"),
            row("a2", "assistant", "", "2026-01-01T00:05:01Z", stop: "error", error: error),
            incoming("u3", "OMP delivered the pending message", "2026-01-01T00:05:02Z", nested: true),
            row("progress", "assistant", "Working on the correction", "2026-01-01T00:05:03Z", stop: "toolUse"),
            incoming("mid-turn", "Also preserve the original notation", "2026-01-01T00:05:04Z"),
            row("a3", "assistant", "No further changes.", "2026-01-01T00:05:12Z", stop: "stop")
        ]
        let journal = rows.map(\.compactString).joined(separator: "\n") + "\n"
        try Data((journal + "{\"type\":").utf8).write(to: file)
        let batchID = UUID().uuidString + "-batch-call"
        var spawn = AgentSpawn(id: "durable-worker", taskID: nil, toolUseID: batchID, description: "task", prompt: nil,
            model: "native/model", sessionFile: file.path, observationID: "first-observation")
        app.mirrorOMPAgent(spawn, parentID: parent.id)
        let head = app.children(of: parent.id).first { $0.hydra?.nativeID == spawn.id }!
        let runtime = app.runtime(for: head.id)
        await runtime.ensureLoaded()
        app.finishOMPAgent(nativeID: spawn.id, parentID: parent.id, status: .completed, summary: nil)
        let beforeOpen = runtime.entries.count
        try await Task.sleep(for: .milliseconds(30))
        expect(runtime.entries.count == beforeOpen, "Finished hidden workers do not eagerly parse journals")
        await app.setOMPAgentDetailsVisible(headID: head.id, visible: true, consumer: "offline-regression")
        expect(runtime.nativeAgentHistoryIssue == nil && !runtime.nativeAgentHistoryLoading, "A worker opens from its journal without a live parent process")
        expect(runtime.turns.map(\.status) == [.completed, .failed, .completed], "Native stop/error boundaries survive history replay")
        let summaries = runtime.entries.compactMap { entry -> TurnSummary? in
            if case .turnEnd(let summary) = entry.item.content { return summary }
            return nil
        }
        expect(summaries.count == 3 && abs(summaries[0].duration - 122.25) < 0.001 && summaries[0].durationIsKnown == true,
               "Elapsed time uses the native 122.25 seconds rather than history-read time")
        let meta = TimelineMeta.build(runtime.entries)
        let users = runtime.entries.filter { $0.kind == .user }
        expect(users.compactMap { if case .user(let message) = $0.item.content { return message.text }; return nil }
            == ["Original assignment", "Follow-up", "OMP delivered the pending message", "Also preserve the original notation"],
               "Visible parent instructions use their complete structured body across both native custom-message shapes")
        expect(users[1].turnID == runtime.turns[1].id && users[2].turnID == runtime.turns[2].id
            && users[3].turnID == runtime.turns[2].id && users[1].item.date == OMPAgentJournal.date(rows[3]),
               "New instructions lead later turns while in-flight steering remains in its current turn with native dates")
        let lastRows = runtime.entries.filter { $0.turnID == runtime.turns[2].id && $0.kind != .turnEnd }
        let lastContent = FinishedTurnContent(entries: lastRows, finalAssistantID: meta.finalAssistantIDByTurn[runtime.turns[2].id])
        expect(lastContent.prompt === users[2] && lastContent.process.contains { $0 === users[3] }
            && lastContent.final?.kind == .assistant,
               "A later round keeps its new instruction outside the fold and its mid-turn instruction at the original process position")
        let answers = runtime.entries.filter { meta.finalAssistantIDByTurn[$0.turnID ?? UUID()] == $0.id }
        expect(answers.count == 2 && answers.contains { if case .assistant(let message) = $0.item.content { return message.text == fullReport }; return false },
               "The implementation report and later acknowledgement remain separate visible final replies")
        let errorRow = runtime.entries.first { if case .notice(let notice) = $0.item.content { return notice.message == error }; return false }
        expect(errorRow?.turnID == runtime.turns[1].id && errorRow?.item.date == OMPAgentJournal.date(rows[4]),
               "The original native channel error retains its actual time and failed turn")
        expect(runtime.entries.contains { if case .notice(let notice) = $0.item.content { return notice.level == .warning && notice.message.contains("OMP") }; return false },
               "The channel diagnostic identifies OMP-owned delivery without hiding or retrying the error")
        let firstIDs = runtime.entries.filter { $0.kind != .notice }.map(\.id)
        let firstObjects = runtime.entries.map(ObjectIdentifier.init)
        await app.setOMPAgentDetailsVisible(headID: head.id, visible: false, consumer: "offline-regression")
        await app.setOMPAgentDetailsVisible(headID: head.id, visible: true, consumer: "offline-regression")
        expect(runtime.entries.filter { $0.kind != .notice }.map(\.id) == firstIDs, "Reopening saved history preserves native item and turn identities")
        expect(runtime.entries.map(ObjectIdentifier.init) == firstObjects,
               "Unchanged worker history must retain its displayed entries, not clear and replay them")
        let snapshot = try OMPAgentJournal.readIfChanged(file.path, since: nil)!
        expect(try OMPAgentJournal.readIfChanged(file.path, since: snapshot.fingerprint) == nil,
               "The incomplete trailing line does not invalidate a prepared worker history")
        let changed = journal.replacingOccurrences(of: fullReport, with: fullReport + " Updated.")
        try Data(changed.utf8).write(to: file)
        await runtime.loadNativeAgentHistory()
        expect(runtime.entries.contains { if case .assistant(let message) = $0.item.content { return message.text == fullReport + " Updated." }; return false },
               "Changed content with the same native IDs must invalidate the prepared history")
        try Data(journal.utf8).write(to: file)
        await runtime.loadNativeAgentHistory()

        // Same conversation, a new control generation; no new avatar or roster slot.
        spawn.observationID = "second-observation"
        app.mirrorOMPAgent(spawn, parentID: parent.id)
        expect(app.children(of: parent.id).filter { $0.providerSessionID == file.path }.map(\.id) == [head.id], "A cold retained worker also resumes in its stable page")
        for index in 1...2 {
            var sibling = spawn
            sibling.id = "batch-worker-\(index)"
            sibling.sessionFile = StoragePaths.directory("omp/sessions").appendingPathComponent("batch-\(index).jsonl").path
            app.mirrorOMPAgent(sibling, parentID: parent.id)
        }
        let coldParent = ThreadRuntime(threadID: parent.id, app: app)
        await coldParent.ensureLoaded()
        let batchHeads = coldParent.hydraHeads(forTool: UUID().uuidString + "-batch-call")
        expect(batchHeads.count == 3 && Set(batchHeads.compactMap { app.thread($0)?.hydra?.index }).count == 3,
               "A restored batch maps all three distinct avatars from persisted native tool metadata")
        expect(batchHeads == app.runtime(for: parent.id).hydraHeads(forTool: batchID), "Hot and cold parent timelines resolve the same batch members")

        var aliases = [head]
        for index in 1...2 {
            var alias = head
            alias.id = UUID()
            alias.hydra?.index += index
            alias.hydra?.startedAt = head.hydra!.startedAt.addingTimeInterval(Double(index))
            alias.hydra?.nativeObservationID = "legacy-\(index)"
            aliases.append(alias)
        }
        let repaired = AppModel.coalescingOMPAgentHeads(aliases)
        expect(repaired.count == aliases.count && repaired[0].id == head.id
            && repaired.dropFirst().allSatisfy { $0.hydra?.nativeCanonicalID == head.id },
               "Legacy duplicate metadata coalesces to the original avatar without deleting stored records")
        expect(AppModel.coalescingOMPAgentHeads(repaired) == repaired, "Legacy metadata repair is idempotent")
        let decoded = try JSONDecoder.storage.decode([ChatThread].self, from: JSONEncoder.storage.encode(repaired))
        expect(decoded.map(\.id) == repaired.map(\.id)
            && decoded.map { $0.hydra?.nativeCanonicalID } == repaired.map { $0.hydra?.nativeCanonicalID }
            && decoded.map { $0.hydra?.nativeObservationSequence } == repaired.map { $0.hydra?.nativeObservationSequence }
            && decoded.map(\.providerSessionID) == repaired.map(\.providerSessionID),
               "Stable-page identity, control order and native journal bindings survive library persistence")

        // Missing timestamps are unknown, never a fabricated zero-second result.
        var untimed = row("untimed", "assistant", "Untimed completion", "", stop: "stop").object!
        untimed.removeValue(forKey: "timestamp")
        runtime.receiveOMPEvent(.ompAgentJournalEntry(.object(untimed)))
        let unknown = runtime.entries.compactMap { if case .turnEnd(let value) = $0.item.content { return value }; return nil }.last!
        expect(unknown.durationIsKnown == false && !TurnEndRow.label(for: unknown).contains("0"), "Missing native time is displayed as an outcome without invented duration")

        let beforeFailure = runtime.entries.map(\.id)
        try Data((journal + "not-json\n").utf8).write(to: file)
        await runtime.loadNativeAgentHistory()
        expect(runtime.nativeAgentHistoryIssue != nil && runtime.entries.map(\.id) == beforeFailure,
               "A malformed journal reports failure and preserves the readable display history")
        let outside = root.appendingPathComponent("outside-session.jsonl")
        do { _ = try OMPAgentJournal.read(outside.path); fatalError("Read outside the edition's native store") }
        catch OMPAgentJournal.ReadError.outsideStore { expect(true, "Offline history cannot read outside this edition's native store") }
        let link = file.deletingLastPathComponent().appendingPathComponent("outside-link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do { _ = try OMPAgentJournal.read(link.path); fatalError("Followed escaped worker symlink") }
        catch OMPAgentJournal.ReadError.outsideStore { expect(true, "A symlink cannot escape the native journal boundary") }
        let large = file.deletingLastPathComponent().appendingPathComponent("large-worker.jsonl")
        FileManager.default.createFile(atPath: large.path, contents: Data())
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(OMPAgentJournal.maximumBytes + 1)); try handle.close()
        do { _ = try OMPAgentJournal.read(large.path); fatalError("Unbounded worker history read") }
        catch OMPAgentJournal.ReadError.tooLarge { expect(true, "Offline history enforces its byte budget before parsing") }
        await app.setOMPAgentDetailsVisible(headID: head.id, visible: false, consumer: "offline-regression")
    }

    @MainActor static func main() async throws {
        guard CaptureRun.isEnabled, let root = CaptureRun.storageRoot,
              root.path.contains("/build.noindex/verification/runs/"),
              let index = CommandLine.arguments.firstIndex(of: "--fixture") else { fatalError("Require isolated worker storage") }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessions = StoragePaths.directory("omp/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let journal = sessions.appendingPathComponent("header-check.jsonl")
        let header = "{\"type\":\"session\",\"cwd\":\"/worktrees/中文 root\"}\n"
        try Data(header.utf8).write(to: journal)
        expect(OMPCLI.sessionWorkingDirectory(journal.path) == "/worktrees/中文 root", "Legacy first-line session header preserves its native worktree")
        try Data(("{\"type\":\"title\",\"title\":\"Native title\"}\n" + header).utf8).write(to: journal)
        expect(OMPCLI.sessionWorkingDirectory(journal.path) == "/worktrees/中文 root", "Native title preamble cannot hide the worker session directory")
        try Data((String(repeating: "{\"type\":\"title\"}\n", count: 8) + header).utf8).write(to: journal)
        expect(OMPCLI.sessionWorkingDirectory(journal.path) == nil, "Session discovery does not scan beyond the bounded preamble")
        let outside = root.appendingPathComponent("outside-session.jsonl")
        try Data(header.utf8).write(to: outside)
        expect(OMPCLI.sessionWorkingDirectory(outside.path) == nil, "Worktree discovery cannot read journals outside this GUI's native store")
        let source = FilePreviewContext(threadID: UUID(), workingDirectory: "/worktrees/中文 root")
        let text = "first\r\n😀中文\nlast\n"
        let native = text as NSString
        let selected = FileQuestionContext.selection(path: source.workingDirectory + "/file.swift", source: source,
            text: text, range: native.range(of: "😀中文\nlast"))!
        expect(selected.startLine == 2 && selected.endLine == 3 && selected.selectedText == "😀中文\nlast", "Unicode/CRLF selection preserves exact text and lines")
        expect(selected.source == source && selected.reference == source.workingDirectory + "/file.swift#L2-L3", "Selection retains absolute location and source worktree")
        expect(FileQuestionContext.selection(path: "/a", source: source, text: text, range: NSRange(location: 0, length: 7))?.endLine == 1, "A selected CRLF remains on its preceding line")
        expect(FileQuestionContext.selection(path: "/a", source: source, text: text, range: NSRange(location: native.length, length: 1)) == nil, "Stale selections cannot read past snapshot")

        let log = root.appendingPathComponent("requests.jsonl")
        try Data().write(to: log)
        let config = SessionConfiguration(provider: .omp, executable: URL(fileURLWithPath: CommandLine.arguments[index + 1]),
            workingDirectory: root, environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                "OMP_FIXTURE_LOG": log.path, "OMP_FIXTURE_SESSION_FILE": root.appendingPathComponent("native.jsonl").path],
            resumeID: nil, resumeAt: nil, model: nil, effort: nil, runtimeMode: .auto, interactionMode: .build, apiKey: nil, hydra: nil, antiSlopEnabled: false)
        let session = OMPSession(configuration: config)
        let app = AppModel()
        let projectDirectory = root.appendingPathComponent("gui-projection", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let project = app.addProject(at: projectDirectory)
        let parent = ChatThread(projectID: project.id, provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        app.insertThread(parent)
        var spawns: [AgentSpawn] = [], messages: [String] = [], notices: [String] = [], resets = 0, loads = 0, finishes = 0, hostCalls = 0
        session.onEvent = { event in
            switch event {
            case .agentStarted(let spawn):
                spawns.append(spawn)
                app.mirrorOMPAgent(spawn, parentID: parent.id)
            case .agentEvent(let id, let nested):
                if case .messageCompleted(_, let text) = nested { messages.append(text) }
                if case .notice(let notice) = nested { notices.append(notice.message) }
                if case .ompAgentJournalEntry(let entry) = nested, let message = entry["message"] {
                    let text = ToolText.blocks(message["content"])
                    if message["role"]?.string == "assistant", !text.isEmpty { messages.append(text) }
                    if message["role"]?.string == "custom", message["customType"]?.string == "async-result" { notices.append(text) }
                }
                app.receiveOMPAgentEvent(nested, nativeID: id, parentID: parent.id)
            case .agentTranscriptReset(let id, let observationID):
                resets += 1
                app.resetOMPAgentTranscript(nativeID: id, parentID: parent.id, observationID: observationID)
            case .agentTranscriptLoaded(let id, let observationID):
                loads += 1
                app.completeOMPAgentTranscript(nativeID: id, parentID: parent.id, observationID: observationID)
            case .agentFinished(let id, let status, let summary):
                finishes += 1
                app.finishOMPAgent(nativeID: id, parentID: parent.id, status: status, summary: summary)
            case .agentResult(let id, let observationID, let result, let summary):
                app.updateOMPAgentResult(nativeID: id, parentID: parent.id, observationID: observationID, result: result, summary: summary)
            default: break
            }
        }
        session.onHostTool = { request in
            hostCalls += 1
            if request.id == "cancelled" { try await Task.sleep(for: .seconds(1)) }
            return .object(["content": .array([.object(["type": "text", "text": "selected context"])])])
        }
        func requests() -> [JSONValue] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { JSONValue.parse(String($0)) }
        }
        func reads() -> Int { requests().filter { $0["type"]?.string == "get_subagent_messages" }.count }
        _ = try await session.start()
        expect(session.previewHostToolsEnabled, "Host tools require acknowledged native registration")
        var pair = HydraPair(provider: .omp)
        pair.orchestratorModel = "native/lead"
        pair.workerModel = "native/worker"
        pair.workerEffort = "high"
        pair.maxHeads = 3
        app.settings.addHydraPair(pair)
        let retired = HydraPair(provider: .codex)
        app.settings.addHydraPair(retired)
        var retiredHeads = HydraPair(provider: .omp)
        retiredHeads.workerProvider = .claude
        app.settings.addHydraPair(retiredHeads)
        expect(app.supportedHydraPairs.map(\.id) == [pair.id], "Hydra pairs never expose retired runtimes")
        app.enterHydraPair(retired, for: parent.id)
        expect(app.thread(parent.id)?.provider == .omp && app.thread(parent.id)?.hydraPairID == nil,
               "Imported legacy pairs cannot select or launch another runtime")
        app.enterHydraPair(pair, for: parent.id)
        let paired = app.thread(parent.id)!
        let launch = app.hydraLaunch(for: paired)!
        expect(paired.model == "native/lead" && launch.workerModel == "native/worker"
                && launch.workerEffort == "high" && launch.maxHeads == 3 && app.children(of: parent.id).isEmpty,
               "Upstream pair choices project native OMP configuration without allocating a GUI worker")
        try session.updateDelegationPreference(launch)
        let overlay = OMPSession.delegationConfiguration(launch)
        expect(overlay["task"]?["agentModelOverrides"]?["task"]?.string == "native/worker:high"
                && overlay["task"]?["maxConcurrency"]?.int == 3 && overlay["task"]?["eager"]?.string == "preferred"
                && overlay["providers"]?["openaiLiveSteering"]?.bool == false,
               "The pair's model, thinking level and cap use OMP's native task selector and settings")
        app.setHydra(false, for: parent.id)
        expect(app.hydraLaunch(for: app.thread(parent.id)!) == nil, "Hydra off leaves native delegation policy in control")
        app.setHydra(true, for: parent.id)
        expect(app.hydraPair(for: app.thread(parent.id)!)?.id == pair.id, "Switching Hydra preserves the selected pair")
        app.leaveHydraPair(for: parent.id)
        let inherited = app.hydraLaunch(for: app.thread(parent.id)!)!
        expect(inherited.workerModel == nil && inherited.workerEffort == nil && inherited.maxHeads == nil,
               "Leaving a pair restores OMP's configured worker models and concurrency")
        try session.updateDelegationPreference(nil)
        expect(OMPSession.delegationConfiguration(nil) == ["providers": ["openaiLiveSteering": false]],
               "Clearing delegation preserves native boundary delivery without changing the active profile")
        app.removeHydraPair(pair.id)
        app.removeHydraPair(retired.id)
        app.removeHydraPair(retiredHeads.id)
        app.updateThread(parent.id) { $0.model = nil }
        expect(requests().contains { $0["type"]?.string == "set_subagent_subscription" && $0["level"]?.string == "progress" }, "Subscription follows actual process-wide progress granularity")
        _ = try await session.rpc.request("fixture_spawn")
        try await wait { spawns.last?.model == "native/model" }
        let first = spawns.last!
        expect(first.agentSource == "project" && first.parentSessionFile?.hasSuffix("parent.jsonl") == true, "Native source and parent identity remain factual")
        try await Task.sleep(for: .milliseconds(250))
        expect(reads() == 0 && messages.isEmpty, "Invisible workers never read/parse transcripts")
        let hiddenHead = app.children(of: parent.id).first { $0.hydra?.nativeObservationID == first.observationID }!
        expect(app.runtime(for: hiddenHead.id).displayedContextUsage == ContextUsage(usedTokens: 32000, windowTokens: 128000),
               "Hidden worker rings use per-response contextTokens and native capacity rather than 170000 cumulative tokens")
        await session.setAgentDetailsVisible(first.id, observationID: first.observationID, visible: true)
        try await wait { messages == ["Final output from run 1"] }
        expect(resets == 1, "First visible read starts one authoritative transcript")
        let firstHead = app.children(of: parent.id).first { $0.hydra?.nativeObservationID == first.observationID }!
        let firstRuntime = app.runtime(for: firstHead.id)
        func workerUsers() -> [(id: String, text: String)] {
            firstRuntime.entries.compactMap { entry in
                if case .user(let user) = entry.item.content { return (entry.id, user.text) }
                return nil
            }
        }
        expect(workerUsers().map(\.text) == ["Native assignment"], "Initial native user is replayed once without a duplicate GUI brief")
        _ = try await session.rpc.request("fixture_append", fields: ["text": "Visible continuation"])
        try await wait { messages.last == "Visible continuation" }
        expect(requests().last { $0["type"]?.string == "get_subagent_messages" }?["fromByte"]?.int ?? 0 > 0, "Visible reads continue native byte cursor")
        await session.setAgentDetailsVisible(first.id, observationID: first.observationID, visible: false)
        let hiddenReads = reads()
        _ = try await session.rpc.request("fixture_append", fields: ["text": "Hidden continuation"])
        try await Task.sleep(for: .milliseconds(250))
        expect(reads() == hiddenReads, "Hiding stops transcript work")
        await session.setAgentDetailsVisible(first.id, observationID: first.observationID, visible: true)
        try await wait { messages.last == "Hidden continuation" }
        expect(messages.count == 3 && resets == 1, "Reopening fills gaps without replaying prior messages")
        _ = try await session.rpc.request("fixture_steer")
        try await wait { messages.last == "Steering response" }
        expect(workerUsers().map(\.text) == ["Native assignment", "Steering input"], "Native steering user entry remains visible in the worker transcript")
        let originalUserIDs = workerUsers().map(\.id)
        let asyncBody = "<system-notice>Native background completed.\nFull result remains readable.</system-notice>"
        _ = try await session.rpc.request("fixture_async_notice", fields: ["text": .string(asyncBody)])
        try await wait { notices.contains(asyncBody) }
        expect(messages.last == "Steering response", "Replayed custom completion cannot become the worker's final assistant reply")
        expect(firstRuntime.entries.contains { entry in
            if case .notice(let notice) = entry.item.content { return notice.level == .info && notice.message == asyncBody }
            return false
        }, "Durable worker replay preserves the complete background notice as readable information")
        let acknowledgedSteer = "Acknowledged but not yet consumed"
        let steeringAttachmentURL = root.appendingPathComponent("steering-context.txt")
        try Data("Synthetic steering attachment metadata fixture".utf8).write(to: steeringAttachmentURL)
        let steeringAttachment = Attachment(name: "steering-context.txt", path: steeringAttachmentURL.path, mimeType: "text/plain")
        let nativeSteeringText = acknowledgedSteer + "\n\nAttached files (use the native read tool to inspect them):\n- " + steeringAttachment.path
        func acknowledgedAttachments() -> [Attachment]? {
            firstRuntime.entries.compactMap { entry in
                if case .user(let user) = entry.item.content, user.text == acknowledgedSteer { return user.attachments }
                return nil
            }.last
        }
        let usersBeforeACK = Set(firstRuntime.entries.filter { $0.id.hasPrefix("omp-native-user-") }.map(\.id))
        try await session.steerAgent(first.id, message: nativeSteeringText)
        firstRuntime.recordNativeAgentSteeringAcceptance(outgoing: ComposerDraft(text: acknowledgedSteer, attachments: [steeringAttachment]), text: nativeSteeringText,
                                                         visibleNativeUsers: usersBeforeACK)
        expect(workerUsers().last?.text == acknowledgedSteer && workerUsers().filter { $0.text == acknowledgedSteer }.count == 1
                && acknowledgedAttachments() == [steeringAttachment],
               "Native ACK retains one local row and its attachment metadata before steering consumption")
        let beforeResetLoads = loads
        _ = try await session.rpc.request("fixture_truncate")
        try await wait { messages.last == "Replacement snapshot" && loads > beforeResetLoads }
        expect(resets == 2, "Native cursor reset replaces rather than splices history")
        expect(workerUsers().prefix(2).map(\.text) == ["Native assignment", "Steering input"] && workerUsers().prefix(2).map(\.id) == originalUserIDs,
               "Native reset restores all user entries with durable identities")
        expect(workerUsers().last?.text == acknowledgedSteer && workerUsers().filter { $0.text == acknowledgedSteer }.count == 1
                && firstRuntime.entries.last?.id.hasPrefix("omp-steer-local-") == true
                && acknowledgedAttachments() == [steeringAttachment],
               "Transcript reset preserves acknowledged unconsumed steering and attachments after imported native rows")
        let beforeConsumedLoads = loads
        _ = try await session.rpc.request("fixture_consume_steer")
        try await wait { messages.last == "Acknowledged steering response" && loads > beforeConsumedLoads }
        expect(workerUsers().filter { $0.text == acknowledgedSteer }.count == 1
                && workerUsers().last?.id.hasPrefix("omp-native-user-") == true
                && !firstRuntime.entries.contains { $0.id.hasPrefix("omp-steer-local-") }
                && acknowledgedAttachments() == [steeringAttachment],
               "Later durable consumption replaces the local ACK row once while preserving attachment metadata")
        let beforeWake = spawns.last!.observationID
        let beforeWakeItems = Set(firstRuntime.entries.map(\.id))
        _ = try await session.rpc.request("fixture_wake")
        try await wait { spawns.last?.observationID != beforeWake && messages.last == "The same worker completed its follow-up" }
        let wake = spawns.last!
        expect(app.children(of: parent.id).count == 1 && app.children(of: parent.id).first?.id == firstHead.id,
               "A native wake reuses its durable page, name and roster count")
        expect(firstRuntime.entries.filter { beforeWakeItems.contains($0.id) }.count == beforeWakeItems.count,
               "A wake preserves already loaded native rows rather than replaying them")
        expect(!(await session.setAgentDetailsVisible(first.id, observationID: beforeWake, visible: true)),
               "The old wake observation cannot acquire current worker controls or a log lease")
        var staleWakeResult = OMPAgentResult(); staleWakeResult.nativeReport = "stale wake"
        app.updateOMPAgentResult(nativeID: first.id, parentID: parent.id, observationID: beforeWake, result: staleWakeResult, summary: nil)
        expect(app.thread(firstHead.id)?.hydra?.nativeResult?.nativeReport != "stale wake", "A delayed wake result cannot rewrite the current observation")
        _ = try await session.rpc.request("fixture_spawn")
        try await wait { spawns.last?.observationID != wake.observationID }
        let second = spawns.last!
        let mirrored = app.children(of: parent.id)
        expect(mirrored.count == 2 && Set(mirrored.compactMap { $0.hydra?.nativeObservationID }).count == 2,
               "Reused native slot preserves two independent GUI histories")
        let oldHead = mirrored.first { $0.id == firstHead.id }!
        expect(oldHead.hydra?.canStop == false && oldHead.hydra?.canSteer == false
                && oldHead.hydra?.providerHistoryIssue != nil && oldHead.hydra?.status == .running,
               "ID reuse revokes old controls without inventing a native terminal status")
        var oldResult = OMPAgentResult()
        oldResult.nativeReport = "Late original result"
        app.updateOMPAgentResult(nativeID: first.id, parentID: parent.id, observationID: wake.observationID,
                                 result: oldResult, summary: "Original summary")
        expect(app.thread(oldHead.id)?.hydra?.nativeResult?.nativeReport == "Late original result"
                && app.children(of: parent.id).first { $0.hydra?.nativeObservationID == second.observationID }?.hydra?.nativeResult?.nativeReport == nil,
               "A delayed identity-fenced result updates only its original head")
        let parentRuntime = app.runtime(for: parent.id)
        parentRuntime.draft = ComposerDraft(text: "User draft")
        parentRuntime.receiveOMPEvent(.ompEditorText("prepared"))
        expect(parentRuntime.pendingOMPEditorText == "prepared" && parentRuntime.draft.text == "User draft",
               "Native editor text stays pending while a user draft exists")
        let quoteOnly = ReplyQuote(text: "Quote-only text must remain editable")
        parentRuntime.draft = ComposerDraft(quotes: [quoteOnly])
        let quoteOutgoing = parentRuntime.draft.outgoingText
        let beforeEditorFollowUps = parentRuntime.followUps.count
        parentRuntime.applyOMPEditorText()
        expect(parentRuntime.draft.text == "prepared" && parentRuntime.pendingOMPEditorText == nil
                && parentRuntime.followUps.count == beforeEditorFollowUps + 1
                && parentRuntime.followUps.last?.ompState == .draft
                && parentRuntime.followUps.last?.text == quoteOutgoing,
               "Applying prepared editor text preserves a displaced quote-only draft as an unsubmitted follow-up")
        parentRuntime.draft = ComposerDraft(text: "Keep this draft")
        parentRuntime.receiveOMPEvent(.ompEditorText("prepared"))
        parentRuntime.receiveOMPEvent(.ompExtensionState(OMPExtensionState(statuses: ["phase": "Busy"],
            widgets: [OMPExtensionWidget(id: "widget", lines: ["Live"], placement: .aboveEditor)])))
        parentRuntime.receiveOMPEvent(.ompLoginURL(OMPLoginLink(.object(["id": "login", "url": "https://example.com/login"]))!))
        parentRuntime.receiveOMPEvent(.ompExtensionReset)
        expect(parentRuntime.pendingOMPEditorText == nil && parentRuntime.ompExtensionState == OMPExtensionState()
                && parentRuntime.ompLoginLinks.isEmpty && parentRuntime.draft.text == "Keep this draft",
               "Native extension reset clears pending editor/state/login presentation while preserving the user draft")
        parentRuntime.draft = ComposerDraft(quotes: [quoteOnly])
        let beforeAutomaticFollowUps = parentRuntime.followUps.count
        parentRuntime.receiveOMPEvent(.ompEditorText("automatic prepared text"))
        expect(parentRuntime.draft.text == "automatic prepared text" && parentRuntime.draft.quotes == [quoteOnly]
                && parentRuntime.pendingOMPEditorText == nil && parentRuntime.followUps.count == beforeAutomaticFollowUps,
               "Automatic editor prefill into an empty text draft retains its existing quote")
        await parentRuntime.ensureLoaded()
        parentRuntime.draft = ComposerDraft()

        let childDirectory = root.appendingPathComponent("child-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
        let childFile = childDirectory.appendingPathComponent("selected.swift")
        try Data("Explicit content".utf8).write(to: childFile)
        let childContext = FileQuestionContext(path: childFile.path,
            source: FilePreviewContext(threadID: oldHead.id, workingDirectory: childDirectory.path),
            startLine: 4, endLine: 5, selectedText: "Explicit content")
        parentRuntime.addFileContextToDraft(childContext)
        expect(parentRuntime.explicitFileContext == childContext && parentRuntime.draft.outgoingText.contains(childDirectory.path),
               "Explicit selection from a child worktree reaches parent composer without losing provenance")
        let selectedResult = try await app.handleOMPHostTool(OMPHostToolRequest(id: "selected", toolCallID: "selected", name: "gui_read_selected_context", arguments: .object([:])), threadID: parent.id)
        expect(ToolText.blocks(selectedResult["content"]).contains(childFile.path + "#L4-L5"), "Host context read exposes only the explicitly shared source and coordinates")
        parentRuntime.setExplicitFileContext(nil)
        do {
            _ = try await app.handleOMPHostTool(OMPHostToolRequest(id: "cleared", toolCallID: "cleared", name: "gui_read_selected_context", arguments: .object([:])), threadID: parent.id)
            fatalError("Cleared context remained readable")
        } catch OMPHostToolError.noSelection { expect(true, "Clear revokes host-readable context") }
        do {
            _ = try await app.handleOMPHostTool(OMPHostToolRequest(id: "outside", toolCallID: "outside", name: "gui_open_file_location", arguments: .object(["path": .string(childFile.path)])), threadID: parent.id)
            fatalError("Unshared outside worktree was accepted")
        } catch OMPHostToolError.invalidLocation { expect(true, "Host file open cannot escape the active or explicit worktree") }
        expect(parentRuntime.updateNativeDetailConsumer("panel", visible: true)
                && parentRuntime.updateNativeDetailConsumer("chat", visible: true)
                && parentRuntime.updateNativeDetailConsumer("chat", visible: false)
                && !parentRuntime.updateNativeDetailConsumer("panel", visible: false),
               "Closing main chat cannot revoke another visible detail consumer")
        let oldPanel = "hydra-panel-" + UUID().uuidString
        let poppedPanel = "hydra-panel-" + UUID().uuidString
        expect(parentRuntime.updateNativeDetailConsumer(oldPanel, visible: true)
                && parentRuntime.updateNativeDetailConsumer(poppedPanel, visible: true)
                && parentRuntime.updateNativeDetailConsumer(oldPanel, visible: false)
                && !parentRuntime.updateNativeDetailConsumer(poppedPanel, visible: false),
               "Overlapping Hydra panel transition keeps the new view subscribed after the old view disappears")
        await session.setAgentDetailsVisible(first.id, observationID: first.observationID, visible: true)
        expect(session.agentDetails[first.id]?.visible == false, "Old visibility lease cannot address reused worker id")
        _ = try await session.rpc.request("fixture_stale_finish")
        expect(finishes == 0 && session.knownAgents.contains(second.id), "Stale completion cannot terminate reused id")
        _ = try await session.rpc.request("fixture_ownerless_finish")
        expect(finishes == 0 && session.knownAgents.contains(second.id), "Ownerless late completion cannot terminate a reused id")
        _ = try await session.rpc.request("fixture_ownerless_progress")
        expect(spawns.last?.model == "native/model", "Ownerless late progress cannot rewrite a reused id's actual model")
        await session.setAgentDetailsVisible(second.id, observationID: second.observationID, visible: true)
        try await wait { messages.last == "Final output from run 2" }
        let completedHead = app.children(of: parent.id).first { $0.hydra?.nativeObservationID == second.observationID }!
        let completedRuntime = app.runtime(for: completedHead.id)
        let priorTurns = completedRuntime.turns.count
        let instruction = "Correct the three reported issues"
        let beforeInstructionLoads = loads
        _ = try await session.rpc.request("fixture_parent_instruction", fields: ["text": .string(instruction)])
        try await wait { loads > beforeInstructionLoads }
        let correctionTurn = completedRuntime.turns.last!.id
        expect(completedRuntime.turns.count == priorTurns + 1 && completedRuntime.turns.last?.status == .running
            && !completedRuntime.entries.contains { $0.turnID == correctionTurn && $0.kind == .turnEnd },
               "A parent instruction starts exactly one later worker round")
        let instructionEntry = completedRuntime.entries.first { entry in
            if case .user(let user) = entry.item.content { return user.text == instruction }
            return false
        }
        expect(instructionEntry?.turnID == correctionTurn && completedRuntime.turns.last?.userItemID == instructionEntry?.id,
               "A live parent IRC instruction is a readable input at the start of its round")
        let readsBeforeHold = reads()
        _ = try await session.rpc.request("fixture_hold_read")
        try await wait { reads() > readsBeforeHold }
        app.settings.hydraAutoClearFinished = true
        let finalCorrection = "All three corrections are complete"
        _ = try await session.rpc.request("fixture_finish", fields: ["text": .string(finalCorrection)])
        try await wait { finishes == 1 }
        expect(!session.knownAgents.contains(second.id), "Native lifecycle owns terminal status")
        try await wait { messages.last == finalCorrection && completedRuntime.turns.last?.status == .completed }
        expect(completedRuntime.turns.count == priorTurns + 1 && completedRuntime.turns.last?.id == correctionTurn,
               "Completion overtaking a captured journal batch cannot split the correction into extra turns")
        let correctionRows = completedRuntime.entries.filter { $0.turnID == correctionTurn }
        let correctionEnds = correctionRows.compactMap { if case .turnEnd(let summary) = $0.item.content { return summary }; return nil }
        let correctionMeta = TimelineMeta.build(completedRuntime.entries)
        let correctionContent = FinishedTurnContent(entries: correctionRows.filter { $0.kind != .turnEnd },
            finalAssistantID: correctionMeta.finalAssistantIDByTurn[correctionTurn])
        expect(correctionEnds.count == 1 && correctionEnds[0].duration == 40 && !completedRuntime.isRunning
            && correctionContent.prompt === instructionEntry && correctionContent.final?.turnID == correctionTurn,
               "The drained round has one complete duration, its leading instruction and the actual final reply")
        expect(app.thread(completedHead.id)?.isInPanel == false && app.thread(completedHead.id) != nil,
               "Clear finished heads removes a natively finished head from its panel while keeping its conversation")
        _ = try await session.rpc.request("fixture_wake")
        try await wait { spawns.last?.observationID != second.observationID && messages.last == "The same worker completed its follow-up" }
        let beforeInterruptedLoads = loads
        _ = try await session.rpc.request("fixture_parent_instruction", fields: ["text": "Review the remaining correction"])
        try await wait { loads > beforeInterruptedLoads }
        let interruptedTurn = completedRuntime.turns.last!.id
        let beforeInterruptedTurns = completedRuntime.turns.count
        _ = try await session.rpc.request("fixture_finish", fields: ["status": "aborted", "text": "Work stopped before a final reply", "stopReason": "toolUse"])
        try await wait { finishes == 2 && completedRuntime.turns.last?.status == .interrupted }
        let interruptedEnds = completedRuntime.entries.compactMap { entry -> TurnSummary? in
            guard entry.turnID == interruptedTurn, case .turnEnd(let summary) = entry.item.content else { return nil }
            return summary
        }
        expect(completedRuntime.turns.count == beforeInterruptedTurns && interruptedEnds.count == 1
            && interruptedEnds[0].status == .interrupted && interruptedEnds[0].duration == 30,
               "A later wake drops old completion state and drains an aborted round's tail before its single fallback end")
        _ = try await session.rpc.request("fixture_host", fields: ["callId": "success"])
        try await wait { requests().contains { $0["type"]?.string == "host_tool_result" && $0["id"]?.string == "success" } }
        expect(hostCalls == 1, "Native host call executes once and returns native result")
        _ = try await session.rpc.request("fixture_host", fields: ["callId": "success"])
        expect(hostCalls == 1, "Repeated native host id cannot execute twice")
        _ = try await session.rpc.request("fixture_host", fields: ["callId": "cancelled"])
        try await wait { hostCalls == 2 }
        _ = try await session.rpc.request("fixture_host_cancel", fields: ["callId": "cancelled"])
        try await Task.sleep(for: .milliseconds(50))
        expect(!requests().contains { $0["type"]?.string == "host_tool_result" && $0["id"]?.string == "cancelled" }, "Native cancellation suppresses late host result")
        await session.stopAndWait(timeout: 2)
        expect(session.hostToolCalls.isEmpty && session.agentDetails.isEmpty, "Process stop releases host calls and detail readers")
        try await checkDurableHistory(app: app, project: project, parent: parent, root: root)
        try await checkContextUsage(app: app, parent: parent, root: root)
        app.settings.hydraShowsHeadDetails = true
        // Cached columns change an environment flag without removing their
        // hosting views. Exercise the real transcript's lease in two windows.
        let windowA = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 280), styleMask: .borderless, backing: .buffered, defer: false)
        let windowB = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 280), styleMask: .borderless, backing: .buffered, defer: false)
        windowA.isReleasedWhenClosed = false; windowB.isReleasedWhenClosed = false
        let resize = WindowLiveResize(window: windowA)
        func transcript(_ shown: Bool) -> some View {
            HydraHeadTranscript(head: app.thread(firstHead.id)!, height: 280, workingDirectory: root.path, projectName: nil)
                .environment(app).environment(resize).environment(\.chatColumnIsShown, shown)
                .frame(width: 560, height: 280)
        }
        let hostA = NSHostingView(rootView: transcript(true)), hostB = NSHostingView(rootView: transcript(true))
        windowA.contentView = hostA; windowB.contentView = hostB
        defer { windowA.contentView = nil; windowB.contentView = nil; windowA.close(); windowB.close() }
        hostA.layoutSubtreeIfNeeded(); hostB.layoutSubtreeIfNeeded()
        try await wait { firstRuntime.updateNativeDetailConsumer("probe", visible: false) }
        hostA.isHidden = true; hostA.rootView = transcript(false); hostA.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        expect(firstRuntime.updateNativeDetailConsumer("probe", visible: false), "A hidden cached transcript cannot revoke another visible window's lease")
        hostB.isHidden = true; hostB.rootView = transcript(false); hostB.layoutSubtreeIfNeeded()
        try await wait { !firstRuntime.updateNativeDetailConsumer("probe", visible: false) }
        expect(true, "Hiding cached hosting views releases the final detail lease without onDisappear")
        hostA.rootView = transcript(true); hostA.isHidden = false; hostA.layoutSubtreeIfNeeded()
        try await wait { firstRuntime.updateNativeDetailConsumer("probe", visible: false) }
        expect(true, "Revealing a cached hosting view reacquires its native detail lease")
        hostA.isHidden = true; hostA.rootView = transcript(false); hostA.layoutSubtreeIfNeeded()
        try await wait { !firstRuntime.updateNativeDetailConsumer("probe", visible: false) }

        app.settings.hydraShowsHeadDetails = false
        hostA.rootView = transcript(true); hostA.isHidden = false; hostA.layoutSubtreeIfNeeded()
        try await wait { firstRuntime.updateNativeDetailConsumer("probe", visible: false) }
        expect(true, "A visible compact worker card reads the journal needed to fill its step bar")
        hostA.isHidden = true; hostA.rootView = transcript(false); hostA.layoutSubtreeIfNeeded()
        try await wait { !firstRuntime.updateNativeDetailConsumer("probe", visible: false) }
        expect(true, "Hiding the compact card releases its journal lease without unmounting")
        app.settings.hydraShowsHeadDetails = true

        let stepsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520), styleMask: .borderless, backing: .buffered, defer: false)
        stepsWindow.isReleasedWhenClosed = false
        func stepsPopover(_ shown: Bool) -> some View {
            HydraHeadStepsPopover(headID: firstHead.id)
                .environment(app).environment(resize).environment(\.chatColumnIsShown, shown)
        }
        let stepsHost = NSHostingView(rootView: stepsPopover(true))
        stepsWindow.contentView = stepsHost
        stepsHost.layoutSubtreeIfNeeded()
        try await wait { firstRuntime.updateNativeDetailConsumer("probe", visible: false) }
        stepsHost.rootView = stepsPopover(false)
        stepsHost.layoutSubtreeIfNeeded()
        try await wait { !firstRuntime.updateNativeDetailConsumer("probe", visible: false) }
        stepsWindow.contentView = nil
        stepsWindow.close()
        expect(true, "The original head steps popover acquires and releases its own native log lease")

        // Cover the main chat column itself, not only its floating transcript.
        // Seed the unrelated command catalogue so this functional view cannot
        // launch discovery against an installed OMP.
        let chatDirectory = app.thread(firstHead.id)!.executionDirectory(projectPath: project.path)
        app.providers.updateCommands([], for: .omp, directory: chatDirectory)
        var chatDisappearances = 0
        func chat(_ shown: Bool) -> some View {
            ChatView(runtime: firstRuntime)
                .modifier(HostedEnvironment(model: app, liveResize: resize))
                .environment(\.chatColumnIsShown, shown)
                .onDisappear { chatDisappearances += 1 }
                .frame(width: 560, height: 280)
        }
        let chatHost = NSHostingView(rootView: chat(true))
        windowA.contentView = chatHost; chatHost.layoutSubtreeIfNeeded()
        try await wait { firstRuntime.updateNativeDetailConsumer("probe", visible: false) }
        chatHost.isHidden = true; chatHost.rootView = chat(false); chatHost.layoutSubtreeIfNeeded()
        try await wait { !firstRuntime.updateNativeDetailConsumer("probe", visible: false) }
        expect(chatDisappearances == 0, "A cached main chat releases its lease while remaining mounted")
        chatHost.rootView = chat(true); chatHost.isHidden = false; chatHost.layoutSubtreeIfNeeded()
        try await wait { firstRuntime.updateNativeDetailConsumer("probe", visible: false) }
        expect(true, "Revealing a cached main chat reacquires its detail lease")
        chatHost.isHidden = true; chatHost.rootView = chat(false); chatHost.layoutSubtreeIfNeeded()
        try await wait { !firstRuntime.updateNativeDetailConsumer("probe", visible: false) }
        print("PASS workers: \(count) selection, native metadata, visibility/cursor, reused-id and host-tool checks")
    }
}
