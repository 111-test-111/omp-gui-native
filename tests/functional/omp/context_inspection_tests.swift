import AppKit
import Darwin
import SwiftUI
@testable import OMPGUI

@main @MainActor
private enum ContextInspectionChecks {
    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
    private static func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            precondition(ContinuousClock.now < deadline, "Context state did not settle")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func row(_ id: String, _ parent: String?, _ type: String, _ fields: [String: JSONValue]) -> JSONValue {
        .object(fields.merging(["type": .string(type), "id": .string(id), "parentId": parent.map(JSONValue.string) ?? .null], uniquingKeysWith: { _, next in next }))
    }
    private static func write(_ entries: [JSONValue], to file: URL) throws {
        try Data((entries.map(\.compactString).joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
    }
    private static let usage: JSONValue = ["input": 100, "output": 20, "cacheRead": 300, "cacheWrite": 50,
        "totalTokens": 470, "reasoningTokens": 5, "cost": ["total": .double(0.001)]]
    private static let composition: JSONValue = ["total": 11, "limited": false, "categories": [
        ["kind": "system", "tokens": 5, "items": [["name": "#1", "tokens": 5]], "omittedItems": 0],
        ["kind": "userText", "tokens": 6, "items": [], "omittedItems": 0]]]

    static func main() async throws {
        guard CaptureRun.isEnabled, let output = CaptureRun.storageRoot else { fatalError("Require isolated storage") }
        _ = NSApplication.shared
        let root = StoragePaths.directory("omp/sessions")
        let file = root.appendingPathComponent("inspection.jsonl")
        let header: JSONValue = ["type": "session", "id": "inspection", "version": 3]
        let rows: [JSONValue] = [header,
            row("user", nil, "message", ["message": ["role": "user", "content": "question"]]),
            row("old", "user", "message", ["message": ["role": "assistant", "content": [], "usage": usage]]),
            row("summary", "user", "compaction", ["summary": "new branch"]),
            row("auxiliary", "summary", "model_usage", ["usage": usage]),
            row("answer", "auxiliary", "message", ["message": ["role": "assistant", "provider": "fixture", "model": "context-model", "content": [
                ["type": "text", "text": "answer"], ["type": "toolCall", "name": "task", "arguments": [:]]], "usage": usage]]),
            row("task", "answer", "message", ["message": ["role": "toolResult", "toolName": "task", "details": ["usage": usage], "content": []]])]
        try write(rows, to: file)
        let accounting = OMPContextAccounting(entries: rows)
        expect(accounting.total == 1880 && accounting.input == 400 && accounting.output == 80, "All branches, auxiliary usage and outer task reports count once")
        expect(accounting.reasoning == 20 && accounting.total == 1880, "Reasoning must never inflate total tokens")
        expect(abs((accounting.cacheHitRate ?? 0) - 300.0 / 450) < 0.000001, "Cache denominator excludes generated output")
        expect(accounting.cost == 0.004 && accounting.assistants == 2 && accounting.auxiliaryCalls == 1, "Accounting retains native cost and counters")
        let missing = OMPContextAccounting(entries: [row("missing", nil, "message", ["message": ["role": "assistant", "content": []]])])
        expect(missing.total == nil && missing.cost == nil && missing.reasoning == nil && missing.missingReports == 1, "Missing reports cannot become zero usage or free cost")
        expect(OMPInspectionNumber.count(.double(1.5)) == nil && OMPInspectionNumber.sum([Int.max, 1]) == nil, "Reject fractional counts and overflowing totals")
        expect(OMPContextComposition(composition)?.total == 11, "Decode bounded composition metadata")
        var invalid = composition.object!; invalid["total"] = 12
        expect(OMPContextComposition(.object(invalid)) == nil, "Category totals must reconcile within the estimate, independently of provider usage")
        let journal = try OMPContextJournalInspection(entries: rows)
        expect(!journal.ancestry.contains("old") && journal.compactions == 1, "Context ancestry excludes an abandoned response")
        var cyclic = rows; cyclic.append(row("cycle", "cycle", "custom", [:]))
        do { _ = try OMPContextJournalInspection(entries: cyclic); fatalError("Must reject cyclic ancestry") } catch {}

        let startupFile = root.appendingPathComponent("starting.jsonl")
        let startupReader = OMPContextInspectionReader()
        do { _ = try await startupReader.read(startupFile.path); fatalError("Missing retained journals must remain errors") }
        catch OMPSessionRecordError.unavailable {}
        for prefix in [nil, "", header.compactString] as [String?] {
            if let prefix { try Data(prefix.utf8).write(to: startupFile) }
            do {
                _ = try await startupReader.read(startupFile.path, awaitingFirstSave: true)
                fatalError("A missing, empty or incomplete first journal must wait for its first save")
            } catch OMPContextInspectionReader.ReadError.awaitingFirstSave {}
        }
        try Data("broken journal\n".utf8).write(to: startupFile)
        do { _ = try await startupReader.read(startupFile.path, awaitingFirstSave: true); fatalError("Corruption must not become a startup wait") }
        catch OMPAgentJournal.ReadError.invalidJournal {}
        try Data("{\"type\":\"session\"}\n".utf8).write(to: startupFile)
        do { _ = try await startupReader.read(startupFile.path, awaitingFirstSave: true); fatalError("A malformed complete header must not become a startup wait") }
        catch OMPSessionRecordError.invalidJournal {}
        do { _ = try await startupReader.read(startupFile.appendingPathComponent("child.jsonl").path, awaitingFirstSave: true)
            fatalError("Filesystem failures other than absence must remain errors") }
        catch let failure as NSError { expect(failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOTDIR), "Preserve the actual filesystem failure") }
        do { _ = try await startupReader.read(output.appendingPathComponent("outside.jsonl").path, awaitingFirstSave: true)
            fatalError("Startup waiting cannot bypass the library boundary") }
        catch OMPSessionRecordError.outsideStore {}
        try FileManager.default.removeItem(at: startupFile)

        let captureRoot = StoragePaths.directory("omp/requests")
        let directory = OMPRequestRecordStore.directory(root: captureRoot, file: file.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func capture(leaf: String, time: Int, kind: String = "model_request", composition value: JSONValue = ContextInspectionChecks.composition) throws -> UUID {
            let id = UUID()
            let summary: JSONValue = ["schema": 1, "id": .string(id.uuidString), "sessionID": "inspection", "sessionFile": .string(file.path),
                "leafID": .string(leaf), "kind": .string(kind), "status": "completed", "startedAt": .int(time),
                "model": "fixture/context-model", "composition": value, "payloadObserved": true,
                "reportedUsage": ["input": 100, "cacheRead": 300, "cacheWrite": 50, "output": 20, "reasoningTokens": 5]]
            try summary.data().write(to: directory.appendingPathComponent(id.uuidString + ".summary.json"))
            return id
        }
        let active = try capture(leaf: "answer", time: 1000)
        _ = try capture(leaf: "old", time: 2000)
        _ = try capture(leaf: "task", time: 3000, kind: "side_request")
        let reader = OMPContextInspectionReader()
        var saved = try await reader.read(file.path)
        expect(saved.request?.record.entryID == active.uuidString, "Latest request must match active ancestry and exclude auxiliary calls")
        expect(saved.request?.metadata.reportedInput == 450 && saved.request?.metadata.difference == 439, "Provider input and composition have independent totals")
        expect(saved.request?.metadata.input == 100 && saved.request?.metadata.output == 20
            && saved.request?.metadata.cacheRead == 300 && saved.request?.metadata.cacheWrite == 50
            && saved.request?.metadata.reasoning == 5 && saved.request?.metadata.payloadObserved == true,
            "New summary reports reach every field of the latest-request panel")
        let replacement = try capture(leaf: "task", time: 4000)
        saved = try await reader.read(file.path)
        expect(saved.request?.record.entryID == replacement.uuidString, "A request revision refreshes even when token values and journal are unchanged")
        try write(Array(rows.prefix(2)), to: file)
        saved = try await reader.read(file.path)
        expect(saved.request == nil && saved.journal.accounting.total == nil, "Rewind excludes old branch captures and billing that is no longer retained")
        try write(rows, to: file)

        let app = AppModel()
        var thread = ChatThread(projectID: UUID(), provider: .omp, model: "fixture/context-model", effort: nil, runtimeMode: .auto)
        thread.providerSessionID = file.path; thread.isArchived = true
        app.insertThread(thread)
        let runtime = app.runtime(for: thread.id)
        await runtime.ensureLoaded()
        runtime.draft.text = "keep this unsent"
        let store = ContextWorkspaceStore()
        store.present(runtime)
        expect(store.isRefreshing && !store.isManuallyRefreshing, "Initial snapshot loading leaves the Refresh button enabled")
        store.refresh(.automatic)
        expect(!store.isManuallyRefreshing, "Repeated background refreshes cannot change manual button state")
        store.refresh(.manual)
        expect(store.isManuallyRefreshing, "A manual click during initial loading remains busy until its refresh completes")
        try await eventually { !store.isRefreshing }
        expect(!store.isManuallyRefreshing, "Manual button state clears when the shared read completes")
        store.refresh(.automatic)
        expect(!store.isRefreshing && !store.canAutomaticallyRefresh, "Idle conversations reject periodic and foreground automatic refreshes")
        expect(store.saved?.journal.accounting.total == 1880 && runtime.activeOMPSession == nil, "Archived inspection must read saved data without launching a runtime")
        expect(runtime.draft.text == "keep this unsent", "Inspection preserves drafts")
        store.expandedCategories.insert("request:system")
        store.refresh(.manual)
        expect(store.isManuallyRefreshing, "A manual refresh shows its own busy state")
        store.suspend()
        expect(!store.isManuallyRefreshing, "Hiding the panel clears manual refresh state")
        store.present(runtime)
        try await eventually { !store.isRefreshing }
        expect(store.expandedCategories.contains("request:system"), "Same-session refresh and tab visits preserve disclosures")
        store.suspend(); store.refresh()
        expect(!store.isPresented && !store.isRefreshing, "Hidden panes cannot begin a read")
        let cancelled = ContextWorkspaceStore(); cancelled.present(runtime); cancelled.suspend()
        try await Task.sleep(for: .milliseconds(30))
        expect(cancelled.saved == nil && !cancelled.isRefreshing, "A suspended read cannot publish a late snapshot")
        var startingThread = ChatThread(projectID: UUID(), provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        startingThread.providerSessionID = startupFile.path
        app.insertThread(startingThread)
        let startingRuntime = app.runtime(for: startingThread.id)
        await startingRuntime.ensureLoaded()
        let startingStore = ContextWorkspaceStore()
        startingStore.present(startingRuntime)
        try await eventually { !startingStore.isRefreshing }
        expect(startingStore.error == nil && startingStore.saved == nil && startingStore.updatedAt == nil,
            "An allocated but unwritten first journal produces no red error or invented successful refresh")
        try write([header], to: startupFile)
        startingStore.refresh(.initial)
        try await eventually { !startingStore.isRefreshing }
        expect(startingStore.error == nil && startingStore.saved?.journal.compactions == 0 && startingStore.updatedAt != nil,
            "The next read accepts the first durable journal without restarting the pane")
        try FileManager.default.removeItem(at: startupFile)
        startingStore.refresh(.initial)
        try await eventually { !startingStore.isRefreshing }
        expect(startingStore.error == Chrome.localized(OMPSessionRecordError.unavailable.title)
            && startingStore.saved?.journal.compactions == 0,
            "Losing an accepted journal remains a localized error and preserves the prior snapshot")
        startingStore.suspend(); startingRuntime.cancelPersistence()
        let activeThread = ChatThread(projectID: UUID(), provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        app.insertThread(activeThread)
        let activeRuntime = app.runtime(for: activeThread.id)
        await activeRuntime.ensureLoaded()
        let activeStore = ContextWorkspaceStore()
        activeStore.present(activeRuntime)
        try await eventually { !activeStore.isRefreshing }
        activeRuntime.receiveOMPEvent(.ompActivity(OMPActivity(connected: true, streaming: true)))
        activeStore.updateActivity()
        expect(activeStore.canAutomaticallyRefresh && activeStore.isRefreshing && !activeStore.isManuallyRefreshing,
            "Native active work starts quiet automatic refreshes without changing the Refresh button")
        activeRuntime.receiveOMPEvent(.ompActivity(OMPActivity(stopped: true)))
        activeStore.updateActivity()
        expect(!activeStore.canAutomaticallyRefresh && activeStore.isRefreshing && !activeStore.isManuallyRefreshing,
            "Ending work replaces a pending automatic read with one quiet completion read")
        try await eventually { !activeStore.isRefreshing }
        activeStore.updateActivity()
        activeStore.refresh(.automatic)
        expect(!activeStore.isRefreshing, "Idle conversations cannot restart an automatic read")
        activeStore.refresh(.manual)
        expect(activeStore.isManuallyRefreshing, "Idle conversations still accept explicit manual refreshes")
        activeStore.suspend(); activeRuntime.cancelPersistence()
        expect(WorkspacePanel.context.isImplemented, "Context must be selectable as an implemented sidebar panel")
        let commands: JSONValue = ["commands": [["name": "omp-gui-context", "source": "extension"], ["name": "normal", "source": "extension"]]]
        expect(!OMPSession.commands(commands).contains { $0.name == "omp-gui-context" }, "Private inspection commands must never appear in the composer")

        let kinds = ["system", "toolSchemas", "userText", "assistantText", "thinking", "toolCalls", "toolResults", "images", "summaries", "extensions", "shell", "requestOnly", "other"]
        let richRows: [JSONValue] = kinds.enumerated().map { index, kind in
            ["kind": .string(kind), "tokens": .int((index + 1) * 1234), "items": kind == "toolSchemas"
                ? [["name": "a.long.native.namespace.with.a.tool.name.for.narrow.column.wrapping", "tokens": 1200]] : [], "omittedItems": 0]
        }
        let richComposition: JSONValue = ["total": .int((1...kinds.count).reduce(0, +) * 1234), "limited": false, "categories": .array(richRows)]
        _ = try capture(leaf: "task", time: Int(Date.now.timeIntervalSince1970 * 1000), composition: richComposition)
        let live = OMPContextLiveInspection(["protocolVersion": 1, "sessionID": "inspection", "sessionFile": .string(file.path),
            "timestamp": .double(Date.now.timeIntervalSince1970 * 1000), "model": "fixture/context-model-with-long-native-name",
            "native": ["usedTokens": 24800, "contextWindow": 128000, "anchored": true,
                "systemPromptTokens": 1300, "systemContextTokens": 5200, "skillsTokens": 1000, "systemToolsTokens": 2200, "messagesTokens": 15100],
            "composition": richComposition])!

        // Render the production pane without showing or launching an application window.
        let previews = FilePreviewStore(persistenceURL: output.appendingPathComponent("context-previews.json"))
        previews.setContext(.init(threadID: thread.id, workingDirectory: root.path)); previews.openPanel(.context)
        let session = previews.session!
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 740), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContextWorkspacePane(runtime: runtime, previews: previews, session: session, inspectionOverride: live)
            .environment(app).background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        defer { previews.suspend(); session.contextInspection.suspend(); window.contentView = nil; window.close(); runtime.cancelPersistence() }
        try await eventually { host.layoutSubtreeIfNeeded(); return session.contextInspection.saved != nil && !session.contextInspection.isRefreshing }
        session.contextInspection.expandedCategories.insert("request:toolSchemas")
        try await Task.sleep(for: .milliseconds(750))
        for width in [400, 700, 960] {
            window.setContentSize(NSSize(width: width, height: 740)); host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot render context pane") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("context-\(width).png"))
        }
        let reportTitle = "Analysis | [notes]\n<metadata> #"
        app.updateThread(thread.id) { $0.title = reportTitle }
        let report = ContextWorkspaceReport(runtime: runtime, state: session.contextInspection, live: live,
            capturedAt: Date(timeIntervalSince1970: 1_792_980_000))
        expect(report.json["schemaVersion"]?.int == 1 && report.json["context"]?["usedTokens"]?.int == 24800
            && report.json["context"]?["windowTokens"]?.int == 128000,
            "JSON exports typed current context values with a versioned schema")
        expect(report.json["composition"]?["source"]?.string == "observed_request"
            && report.json["composition"]?["total"]?.int == 112294
            && report.json["latestRequest"]?["reportedInput"]?.int == 450
            && report.json["latestRequest"]?["reportedInputMinusEstimate"]?.int == 450 - 112294,
            "Reports keep composition estimates independent of reported input")
        expect(report.json["accounting"]?["total"]?.int == 1880 && report.json["accounting"]?["reasoning"]?.int == 20,
            "Report accounting does not double-count reasoning")
        expect(report.markdown.contains("Analysis \\| \\[notes\\]<br>&lt;metadata&gt; \\#")
            && report.markdown.contains("a.long.native.namespace.with.a.tool.name.for.narrow.column.wrapping"),
            "Markdown escapes titles and includes category names even when their UI is collapsed")
        let jsonData = report.data(for: .json)
        expect(!String(decoding: jsonData, as: UTF8.self).contains(file.path)
            && report.baseFilename.hasPrefix("omp-context-") && !report.baseFilename.contains(":"),
            "Reports omit native paths and use a filesystem-safe timestamped filename")
        let reportFile = output.appendingPathComponent(report.baseFilename + ".json")
        try jsonData.write(to: reportFile)
        try report.data(for: .markdown).write(to: output.appendingPathComponent(report.baseFilename + ".md"))
        expect(JSONValue.parse(try Data(contentsOf: reportFile)) == report.json, "JSON exports round-trip without turning unknown values into zero")
        app.updateThread(thread.id) { $0.title = "Another title after the save dialog opened" }
        expect(report.json["conversation"]?["title"]?.string == reportTitle,
            "A save dialog retains the exact snapshot captured before navigation or polling")
        let unknown = ContextWorkspaceReport(runtime: runtime, state: ContextWorkspaceStore(), live: live)
        expect(unknown.json["latestRequest"]?.isNull == true && unknown.json["accounting"]?.isNull == true
            && unknown.json["composition"]?["source"]?.string == "session_projection"
            && unknown.markdown.contains("| Total tokens | — |"),
            "Projection-only reports preserve unknown request and accounting fields")
        try await review_regressions(app, root: root)
        print("PASS context inspector: native metadata, independent accounting, branch-safe summaries, request revisions, hidden/cancelled reads, draft preservation and native 400/700/960 pt layout")
        print("PASS context reports: quiet automatic refresh, shared manual reads, frozen Markdown/JSON, typed unknowns, escaped titles and full category names")
        print("PASS first journal: quiet lazy persistence, incomplete header waiting, later recovery, retained-file loss and real filesystem/corruption/boundary errors")
    }

    private static func review_regressions(_ app: AppModel, root: URL) async throws {
        let file = root.appendingPathComponent("review.jsonl")
        let header: JSONValue = ["type": "session", "id": "review", "version": 3]
        func response(_ id: String, _ parent: String, tokens: Int) -> JSONValue {
            row(id, parent, "message", ["message": ["role": "assistant", "provider": "fixture", "model": "review-model",
                "content": [], "usage": ["input": .int(tokens), "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": .int(tokens)]]])
        }
        var entries = [header, row("u", nil, "message", ["message": ["role": "user", "content": "review"]]),
            response("a1", "u", tokens: 10)]
        try write(entries, to: file)
        let captureRoot = StoragePaths.directory("omp/requests")
        let directory = OMPRequestRecordStore.directory(root: captureRoot, file: file.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let owner = UUID().uuidString, pid = ProcessInfo.processInfo.processIdentifier
        try JSONValue.object(["id": .string(owner), "pid": .int(Int(pid)), "updatedAt": .double(Date.now.timeIntervalSince1970 * 1000)])
            .data().write(to: captureRoot.appendingPathComponent(owner + ".owner.json"))
        let requestID = UUID().uuidString
        var summary: [String: JSONValue] = ["schema": 1, "id": .string(requestID), "sessionID": "review", "sessionFile": .string(file.path),
            "leafID": "u", "kind": "model_request", "status": "running", "startedAt": .double(Date.now.timeIntervalSince1970 * 1000),
            "pid": .int(Int(pid)), "ownerID": .string(owner)]
        let summaryFile = directory.appendingPathComponent(requestID + ".summary.json")
        try JSONValue.object(summary).data().write(to: summaryFile)
        var thread = ChatThread(projectID: UUID(), provider: .omp, model: "fixture/review-model", effort: nil, runtimeMode: .auto)
        thread.providerSessionID = file.path
        app.insertThread(thread)
        let runtime = app.runtime(for: thread.id)
        await runtime.ensureLoaded()
        let store = ContextWorkspaceStore()
        store.present(runtime)
        defer { store.suspend(); runtime.cancelPersistence() }
        try await eventually { !store.isRefreshing }
        expect(store.saved?.journal.accounting.total == 10 && store.saved?.request?.record.status == .running,
            "The review fixture starts with an accepted running request and ten recorded tokens")
        let unknown = ContextWorkspaceReport(runtime: runtime, state: store)
        let unknownPayload = unknown.json["latestRequest"]?["payloadObserved"]
        runtime.receiveOMPEvent(.ompActivity(OMPActivity(connected: true, streaming: true)))
        store.updateActivity()
        entries.append(response("a2", "a1", tokens: 20))
        try write(entries, to: file)
        summary["status"] = "completed"
        try JSONValue.object(summary).data().write(to: summaryFile)
        runtime.receiveOMPEvent(.ompActivity(OMPActivity(stopped: true)))
        store.updateActivity()
        try await eventually { !store.isRefreshing }
        let completed = ContextWorkspaceReport(runtime: runtime, state: store)
        let finalTotal = completed.json["accounting"]?["total"]?.int
        let finalStatus = completed.json["latestRequest"]?["status"]?.string
        expect(runtime.activeOMPSession == nil && !store.canAutomaticallyRefresh && !store.isManuallyRefreshing,
            "Completion must not start an OMP connection, idle polling or a manual busy state")
        store.updateActivity(); store.refresh(.automatic)
        expect(!store.isRefreshing, "Repeated idle notifications cannot schedule more completion reads")
        let stoppedInspection = try await runtime.inspectOMPContext(allowResume: false)
        expect(stoppedInspection == nil && runtime.activeOMPSession == nil,
            "A completion inspection cannot resume a connection that has already stopped")

        app.updateThread(thread.id) { $0.isArchived = true }
        var cache = OMPContextSnapshot()
        cache.observeState(["contextUsage": ["tokens": 10, "contextWindow": 1000]])
        runtime.receiveOMPEvent(.ompContext(cache))
        store.refresh(.manual)
        try await eventually { !store.isRefreshing }
        let historical = ContextWorkspaceReport(runtime: runtime, state: store)
        let historicalUsed = historical.json["context"]?["usedTokens"]?.int
        let historicalPanel = ContextWorkspaceOccupancy(runtime: runtime, state: store)
        expect(historicalPanel.used == historicalUsed && historicalPanel.source == "saved_response",
            "Panel and report select the same refreshed historical response")
        entries.append(row("c", "a2", "compaction", ["summary": "smaller context"]))
        try write(entries, to: file)
        store.refresh(.manual)
        try await eventually { !store.isRefreshing }
        let compacted = ContextWorkspaceReport(runtime: runtime, state: store)
        let compactedUsed = compacted.json["context"]?["usedTokens"]
        expect(ContextWorkspaceOccupancy(runtime: runtime, state: store).used == compactedUsed?.int,
            "Compaction invalidation is shared by panel and report")

        entries.append(row("m", "c", "model_change", ["model": "fixture/another-model"]))
        try write(entries, to: file)
        store.refresh(.manual)
        try await eventually { !store.isRefreshing }
        let changedModel = ContextWorkspaceReport(runtime: runtime, state: store)
        expect(changedModel.json["context"]?["usedTokens"]?.isNull == true
            && changedModel.json["context"]?["model"]?.string == "fixture/another-model",
            "A journal model change cannot fall back to usage from the old cached model")

        for observed in [false, true] {
            summary["payloadObserved"] = .bool(observed)
            try JSONValue.object(summary).data().write(to: summaryFile)
            store.refresh(.manual)
            try await eventually { !store.isRefreshing }
            let evidence = ContextWorkspaceReport(runtime: runtime, state: store)
            expect(evidence.json["latestRequest"]?["payloadObserved"]?.bool == observed
                && evidence.markdown.contains("| Provider payload observed | " + Chrome.localized(observed ? "Yes" : "No") + " |"),
                "Explicit false and true payload evidence remain distinct from missing evidence")
        }
        expect(OMPContextRequestMetadata(["payloadObserved": .null]).payloadObserved == nil
            && OMPContextRequestMetadata(["payloadObserved": "false"]).payloadObserved == nil,
            "Null and malformed evidence cannot become a confirmed negative")

        app.updateThread(thread.id) { $0.isArchived = false }
        runtime.receiveOMPEvent(.ompActivity(OMPActivity(connected: true, streaming: true)))
        store.updateActivity(); store.refresh(.manual)
        entries.append(response("a3", "m", tokens: 1))
        try write(entries, to: file)
        runtime.receiveOMPEvent(.ompActivity(OMPActivity(stopped: true)))
        store.updateActivity()
        expect(store.isManuallyRefreshing, "Completion preserves an in-flight explicit refresh")
        try await eventually { !store.isRefreshing }
        expect(store.saved?.journal.accounting.total == 31 && !store.isManuallyRefreshing,
            "A queued completion read accepts final data after an in-flight manual refresh")
        runtime.receiveOMPEvent(.ompActivity(OMPActivity(connected: true, streaming: true)))
        store.updateActivity(); store.suspend()
        runtime.receiveOMPEvent(.ompActivity(OMPActivity(stopped: true)))
        store.updateActivity()
        expect(!store.isPresented && !store.isRefreshing, "A hidden panel cannot start a completion read")

        var failures: [String] = []
        if finalTotal != 30 || finalStatus != "completed" { failures.append("P1: final total=\(String(describing: finalTotal)), status=\(finalStatus ?? "nil")") }
        if historicalUsed != 20 || compactedUsed?.isNull != true { failures.append("P2: refreshed usage=\(String(describing: historicalUsed)), compacted usage=\(compactedUsed?.compactString ?? "nil")") }
        if unknownPayload?.isNull != true || !unknown.markdown.contains("| Provider payload observed | — |") {
            failures.append("P3: missing payload evidence=\(unknownPayload?.compactString ?? "nil")")
        }
        expect(failures.isEmpty, failures.joined(separator: "; "))

        app.updateThread(thread.id) { $0.hydra = HydraHeadInfo(index: 0, task: "Review fixture", kind: .native, origin: .delegated) }
        runtime.receiveOMPEvent(.ompActivity(OMPActivity(connected: true, streaming: true)))
        runtime.receiveOMPEvent(.usage(ContextUsage(usedTokens: 50, windowTokens: 1000)))
        expect(ContextWorkspaceOccupancy(runtime: runtime, state: store).used == 50,
            "Active workers retain newer progress usage instead of an earlier saved response")
        runtime.receiveOMPEvent(.ompActivity(OMPActivity(stopped: true)))
        store.present(runtime)
        try await eventually { !store.isRefreshing }
        expect(ContextWorkspaceOccupancy(runtime: runtime, state: store).used == 1,
            "Idle historical workers select their newly verified journal instead of old progress usage")
        print("PASS review regressions: final request and totals, fresh historical usage and compaction invalidation, unknown payload evidence")
    }
}
