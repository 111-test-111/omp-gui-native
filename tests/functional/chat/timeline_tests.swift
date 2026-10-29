import AppKit
import Foundation
import SwiftUI
@testable import OMPGUI

@MainActor @Observable
private final class AnswerStage {
    var nextPrompt = false
}

private struct AnswerHarness: View {
    let runtime: ThreadRuntime
    let turnID: UUID
    let summary: TurnSummary
    let answer: TimelineEntry
    let stage: AnswerStage
    var process: [TimelineEntry] = []
    var waiting = TurnWaiting()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TurnFinishedBlock(runtime: runtime, turnID: turnID, summary: summary,
                entries: process + [answer], finalAssistantID: answer.id,
                workingDirectory: nil, canUndo: !stage.nextPrompt, waiting: waiting)
            if stage.nextPrompt { Text("Next user input") }
        }
        .frame(width: 520, alignment: .leading)
    }
}

private struct SavedAnswerTurn: Codable {
    var revisions: [String: StoredTurn]
}

@main
struct TimelineAnswerChecks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        checks += 1
    }

    @MainActor private static func textViews(in root: NSView) -> [LinkTextView] {
        (root as? LinkTextView).map { [$0] } ?? root.subviews.flatMap { textViews(in: $0) }
    }

    @MainActor private static func checkRepeatedDiagnostics(_ output: URL) async throws {
        let app = AppModel()
        app.settings.performanceMode = true
        app.settings.chimeWhenFinished = false
        app.settings.notifyWhenFinished = false
        let thread = ChatThread(projectID: UUID(), provider: .omp, model: nil, effort: nil, runtimeMode: .supervised)
        app.insertThread(thread)
        let runtime = app.runtime(for: thread.id)
        await runtime.ensureLoaded()
        runtime.rehearseTurn("Exercise native failures without starting a provider")
        let decoder = OMPEventDecoder(prefix: "diagnostics", directory: "/", capturesSnapshots: false)
        decoder.onEvent = { runtime.receiveOMPEvent($0) }
        let capacity = "Codex error event: Codex is at capacity, please try again later (code=turn_rate_limit_exceeded)"
        let socket = "The socket connection was closed unexpectedly."
        func failure(_ message: String, _ id: String) {
            decoder.handle(["type": "message_end", "messageId": .string(id),
                "message": ["role": "assistant", "stopReason": "error", "errorMessage": .string(message)]])
        }
        func retry(_ message: String) {
            decoder.handle(["type": "auto_retry_start", "errorMessage": .string(message)])
        }
        func notice(_ entry: TimelineEntry) -> Notice {
            guard case .notice(let value) = entry.item.content else { fatalError("Expected a diagnostic") }
            return value
        }
        failure(capacity, "capacity-1")
        let first = runtime.entries.last!
        retry(capacity)
        expect(runtime.entries.last === first && notice(first).level == .error && notice(first).occurrenceCount == 1,
            "A native retry warning is the same failure as its error, preserving one red row and its identity")
        failure(capacity, "capacity-2")
        retry(capacity)
        expect(runtime.entries.count == 2 && notice(first).occurrenceCount == 2,
            "Repeated error/retry pairs increase the error count once per failed attempt")
        retry(socket)
        let second = runtime.entries.last!
        expect(notice(second).level == .warning, "An independent warning remains visible")
        failure(socket, "socket-1")
        failure(socket, "socket-2")
        retry(socket)
        expect(runtime.entries.count == 3 && runtime.entries.last === second,
            "Socket failures use the same single-row behavior even when the warning arrives first")
        expect(notice(second).level == .error && notice(second).occurrenceCount == 2,
            "A mirrored warning never downgrades an error or doubles its count")

        runtime.receiveOMPEvent(.notice(Notice(level: .error, message: "Extension failed")))
        runtime.receiveOMPEvent(.notice(Notice(level: .error, message: "Extension failed")))
        expect(notice(runtime.entries.last!).occurrenceCount == 2, "Errors without retry warnings also accumulate")
        failure(socket, "socket-3")
        expect(runtime.entries.count == 5 && notice(runtime.entries.last!).occurrenceCount == 1,
            "A different diagnostic separates repeated error groups")
        runtime.receiveOMPEvent(.messageDelta(id: "intervening-text", text: "A new response separates errors"))
        failure(socket, "socket-4")
        expect(runtime.entries.suffix(2).first?.kind == .assistant && notice(runtime.entries.last!).occurrenceCount == 1,
            "Pending streamed content is flushed before a notice so it separates error groups")
        let beforeTerminal = runtime.entries.count
        runtime.receiveOMPEvent(.turnCompleted(status: .failed, error: socket))
        expect(runtime.entries.count == beforeTerminal && notice(runtime.entries.last!).occurrenceCount == 1,
            "The terminal outcome repeats an existing failure without adding an occurrence or another row")

        let firstItem = first.item
        let oldNotice = try JSONDecoder().decode(Notice.self, from: Data("{\"level\":\"error\",\"message\":\"Old failure\"}".utf8))
        expect(oldNotice.occurrenceCount == 1, "Histories predating diagnostic counts decode with one occurrence")
        let savedNotice = try JSONDecoder().decode(Notice.self, from: JSONEncoder().encode(notice(first)))
        expect(savedNotice == notice(first), "Saving and reopening preserves accumulated error counts")
        let turnID = UUID()
        func item(_ id: String, _ level: Notice.Level, _ turn: UUID? = nil, limit: LimitNotice? = nil) -> TimelineItem {
            TimelineItem(id: id, turnID: turn ?? turnID, date: Date(timeIntervalSince1970: 100),
                content: .notice(Notice(level: level, message: capacity, limit: limit)))
        }
        let legacy = [item("error-1", .error), item("warning-1", .warning), item("error-2", .error), item("warning-2", .warning)]
        let compacted = TimelineItem.coalescingConsecutiveNotices(legacy)
        expect(compacted.count == 1 && compacted[0].id == legacy[0].id && compacted[0].date == legacy[0].date,
            "Old error/warning pairs retain the first row's original identity and position")
        expect(TimelineItem.coalescingConsecutiveNotices(compacted) == compacted,
            "Repeated history preparation does not change a diagnostic's count")
        expect(TimelineItem.coalescingConsecutiveNotices([legacy[0], item("other-turn", .error, UUID())]).count == 2,
            "Identical errors in different turns stay separate")
        expect(TimelineItem.coalescingConsecutiveNotices([legacy[0], item("limit", .warning, limit: LimitNotice(threadID: UUID()))]).count == 2,
            "Usage-limit notices retain their independent controls and identity")
        expect(TimelineItem.coalescingConsecutiveNotices([legacy[0], item("info", .info), legacy[2]]).count == 3,
            "Informational content is not swallowed into repeated errors")

        let savedID = UUID()
        var document = ThreadDocument(threadID: savedID)
        document.items = legacy
        try JSONEncoder.storage.encode(document).write(to: Storage.threadURL(savedID))
        expect(Storage.readDocument(savedID)?.document.items == compacted,
            "Existing head-file conversations use the same error/warning consolidation")
        var turn = TurnRecord(index: 0)
        turn.id = turnID; turn.status = .failed; turn.completedAt = .now
        let reference = ThreadTurnReference(id: turnID, revision: 1)
        document.items = []; document.turnIndex = [reference]
        try JSONEncoder.storage.encode(document).write(to: Storage.threadURL(savedID))
        try FileManager.default.createDirectory(at: Storage.turnsURL(savedID), withIntermediateDirectories: true)
        let positions = Dictionary(uniqueKeysWithValues: legacy.enumerated().map { ($0.element.id, Double($0.offset)) })
        try JSONEncoder.storage.encode(SavedAnswerTurn(revisions: ["1": StoredTurn(turn: turn, items: legacy, itemPositions: positions)]))
            .write(to: Storage.turnURL(savedID, turnID))
        expect(Storage.readRecentDocument(savedID)?.document.items == compacted,
            "Recent archived history consolidates identical diagnostics")
        expect(Storage.readTurns(savedID, references: [reference])?.document.items == compacted,
            "Older history pages consolidate identical diagnostics")
        var restoredThread = ChatThread(projectID: UUID(), provider: .omp, model: nil, effort: nil, runtimeMode: .supervised)
        restoredThread.id = savedID
        app.insertThread(restoredThread)
        let restored = app.runtime(for: savedID)
        await restored.ensureLoaded()
        let restoredEntry = restored.entries.first { $0.kind == .notice }!
        expect(notice(restoredEntry).level == .error && notice(restoredEntry).occurrenceCount == 2,
            "Installing an archived conversation displays two failures as one red row")
        runtime.rehearseTurn("A new turn")
        runtime.receiveOMPEvent(.notice(savedNotice))
        expect(notice(runtime.entries.last!).occurrenceCount == 2,
            "Runtime delivery retains diagnostic counts carried by a notice")
        expect(first.item == firstItem, "Later groups never alter an earlier group's failure count")

        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
            NoticeRow(entry: first)
            NoticeRow(entry: second)
        }.padding(20).frame(width: 620).background(Color(nsColor: .windowBackgroundColor)).environment(app))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot render diagnostics") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("repeated-errors.png"))
    }

    @MainActor private static func checkNativeAsyncNotices() throws {
        let prefix = UUID().uuidString
        let decoder = OMPEventDecoder(prefix: prefix, directory: "/", capturesSnapshots: false)
        var turn = TurnRecord(index: 0)
        turn.status = .completed
        turn.completedAt = .now
        let finalText = "The real assistant final response"
        let body = "<system-notice>Background command completed.\nFull output — unchanged.</system-notice>"
        let native: JSONValue = ["role": "custom", "customType": "async-result", "display": true,
            "content": .array([["type": "text", "text": .string(body)]])]
        var items: [TimelineItem] = []
        decoder.onEvent = { event in
            switch event {
            case .messageCompleted(let id, let text):
                items.append(TimelineItem(id: id, turnID: turn.id, content: .assistant(AssistantMessage(text: text))))
            case .notice(let notice):
                items.append(TimelineItem(turnID: turn.id, content: .notice(notice)))
            default: break
            }
        }
        decoder.handle(["type": "message_end", "messageId": "final", "message": ["role": "assistant",
            "content": .array([["type": "text", "text": .string(finalText)]])]])
        decoder.handle(["type": "message_end", "messageId": "background", "message": native])
        expect(items.count == 2, "Displayed background completion retains one readable row")
        guard case .notice(let notice) = items.last!.content else { fatalError("Native completion became an assistant answer") }
        expect(notice.level == .info && notice.message == body, "Native completion is informational with its complete original body")
        expect(notice.isSystemNotice, "Native system payload uses the compact disclosure")
        expect(!Notice(level: .info, message: "Normal information").isSystemNotice,
            "Ordinary informational notices keep their existing presentation")
        let setup = Notice(level: .info, message: "xd://: mounted gui_read_selected_context, gui_open_file_location")
        expect(setup.isRuntimeSetupNoise, "Successful host-tool mounting is hidden runtime setup")
        expect(!Notice(level: .warning, message: setup.message).isRuntimeSetupNoise,
            "Mount warnings remain visible")
        expect(!Notice(level: .info, message: setup.message + "\nRegistration failed").isRuntimeSetupNoise,
            "Additional mount diagnostics remain visible")
        expect(!Notice(level: .info, message: "xd://: mounted ").isRuntimeSetupNoise,
            "A missing mounted tool list is not suppressed")
        expect(!Notice(level: .info, message: "xd://: mounted gui_tool,").isRuntimeSetupNoise,
            "Malformed mounted tool lists remain visible")
        let setupItem = TimelineItem(turnID: nil, content: .notice(setup))
        expect(setupItem.hasNothingToRead, "Stored runtime setup is removed before timeline grouping")
        let quotedSetup = TimelineItem(turnID: nil, content: .assistant(AssistantMessage(text: setup.message)))
        expect(!quotedSetup.hasNothingToRead, "Assistant text quoting a mounting diagnostic is preserved")
        let historyMessage = OMPHistoryMessage(native)
        expect(historyMessage?.role == "custom" && historyMessage?.text == body,
            "Native history inspection retains custom role and complete content")
        let summary = TurnSummary(turnID: turn.id, status: .completed, duration: 1,
            filesChanged: 0, additions: 0, deletions: 0, changes: FileChangeSummary(files: []))
        items.append(TimelineItem(turnID: turn.id, content: .turnEnd(summary)))
        let meta = TimelineMeta.build(items.map(TimelineEntry.init))
        expect(meta.finalAssistantIDByTurn[turn.id] == prefix + "-m-final",
            "A later background completion cannot replace the completed assistant answer")
        expect(TimelineGroup.build(items.map(TimelineEntry.init), showReasoning: false).contains { group in
            if case .work(_, let entries) = group {
                return entries.contains { if case .notice(let value) = $0.item.content { return value.message == body }; return false }
            }
            return false
        }, "Background completion body remains available in the turn's readable steps")
        let count = items.count
        var hidden = native.object!
        hidden["display"] = false
        decoder.handle(["type": "message_end", "messageId": "hidden", "message": .object(hidden)])
        expect(items.count == count, "Hidden native completions do not create visible replies or notices")

        let legacy = TimelineItem(id: prefix + "-async-background", turnID: turn.id,
            content: .assistant(AssistantMessage(text: body)))
        let normalized = legacy.normalizedOMPAsyncNotice
        expect(normalized.id == legacy.id && normalized.turnID == legacy.turnID && normalized.date == legacy.date,
            "Legacy normalization preserves row identity, turn and date")
        expect(normalized.content == .notice(Notice(level: .info, message: body)),
            "Old OMP background rows become notices without modifying their original body")
        let quoted = TimelineItem(id: prefix + "-m-final", turnID: turn.id,
            content: .assistant(AssistantMessage(text: body)))
        expect(quoted.normalizedOMPAsyncNotice == quoted,
            "A real assistant quoting system-notice text keeps its assistant role")
        let lookalike = TimelineItem(id: "unrecognized-async-background", turnID: turn.id,
            content: .assistant(AssistantMessage(text: body)))
        expect(lookalike.normalizedOMPAsyncNotice == lookalike,
            "Unknown imported IDs are not reclassified by a loose async substring")

        let threadID = UUID()
        var document = ThreadDocument(threadID: threadID)
        document.items = [setupItem, quoted, legacy]
        try JSONEncoder.storage.encode(document).write(to: Storage.threadURL(threadID))
        let restored = Storage.readDocument(threadID)!.document
        expect(restored.items.count == 2, "Saved runtime setup rows are excluded without leaving timeline gaps")
        expect(restored.items.last?.content == normalized.content,
            "Head-file history preparation normalizes old native background rows")
        expect(TimelineMeta.build(restored.items.map(TimelineEntry.init)).finalAssistantIDByTurn[turn.id] == quoted.id,
            "Loading saved history cannot promote the runtime notice to final assistant")

        let archivedID = UUID()
        let reference = ThreadTurnReference(id: turn.id, revision: 1)
        var archived = ThreadDocument(threadID: archivedID)
        archived.turnIndex = [reference]
        try JSONEncoder.storage.encode(archived).write(to: Storage.threadURL(archivedID))
        try FileManager.default.createDirectory(at: Storage.turnsURL(archivedID), withIntermediateDirectories: true)
        let shard = SavedAnswerTurn(revisions: ["1": StoredTurn(turn: turn, items: [setupItem, quoted, legacy],
            itemPositions: [quoted.id: 0, legacy.id: 1])])
        try JSONEncoder.storage.encode(shard).write(to: Storage.turnURL(archivedID, turn.id))
        expect(Storage.readRecentDocument(archivedID)?.document.items.last?.content == normalized.content,
            "Prefetched recent history normalizes archived native background rows")
        expect(Storage.readTurns(archivedID, references: [reference])?.document.items.last?.content == normalized.content,
            "Loading older archived turns uses the same background-notice classification")
        expect(Storage.readTurns(archivedID, references: [reference])?.document.items.count == 2,
            "Older archived turns exclude runtime setup rows too")
    }

    @MainActor private static func checkChronologicalProcess() {
        let turnID = UUID()
        func entry(_ id: String, _ content: TimelineItem.Content, turn: UUID? = nil) -> TimelineEntry {
            TimelineEntry(TimelineItem(id: id, turnID: turn ?? turnID, content: content))
        }
        let rows = [
            entry("prompt", .user(UserMessage(text: "Prompt"))),
            entry("thinking-a", .reasoning(ReasoningBlock(text: "First thought"))),
            entry("tool-a", .tool(ToolCall(kind: .read, title: "Read A"))),
            entry("system", .notice(Notice(level: .info, message: "<system-notice>Ready</system-notice>"))),
            entry("stage", .assistant(AssistantMessage(text: "Intermediate reply"))),
            entry("head-a", .tool(ToolCall(kind: .agent, title: "Delegate A"))),
            entry("head-b", .tool(ToolCall(kind: .agent, title: "Delegate B"))),
            entry("tool-b", .tool(ToolCall(kind: .command, title: "Run B"))),
            entry("thinking-b", .reasoning(ReasoningBlock(text: "Second thought"))),
            entry("warning", .notice(Notice(level: .warning, message: "A warning"))),
            entry("error", .notice(Notice(level: .error, message: "An error"))),
            entry("plan", .plan(ProposedPlan(markdown: "A plan", state: .proposed))),
            entry("steer", .user(UserMessage(text: "Later steering"))),
            entry("tool-c", .tool(ToolCall(kind: .read, title: "Read C"))),
            entry("final", .assistant(AssistantMessage(text: "Final reply")))
        ]
        func ids(_ groups: [TimelineGroup]) -> [[String]] {
            groups.map {
                switch $0 {
                case .single(let entry): [entry.id]
                case .work(_, let entries), .heads(_, let entries): entries.map(\.id)
                }
            }
        }
        let groups = TimelineGroup.build(rows, showReasoning: true)
        expect(ids(groups) == [["prompt"], ["thinking-a", "tool-a", "system"], ["stage"],
            ["head-a", "head-b"], ["tool-b", "thinking-b"], ["warning"], ["error"],
            ["plan"], ["steer"], ["tool-c"], ["final"]],
            "Only adjacent process steps may group; text, Hydra, warnings, errors, plans and steering keep their positions")
        expect(ids(TimelineGroup.build(rows, showReasoning: false)).flatMap { $0 }
            == rows.filter { $0.kind != .reasoning }.map(\.id),
            "Hiding thinking cannot reorder the remaining conversation")
        let projected = FinishedTurnContent(entries: rows, finalAssistantID: "final")
        expect(projected.prompt?.id == "prompt" && projected.final?.id == "final"
            && projected.process.map(\.id) == Array(rows.dropFirst().dropLast()).map(\.id),
            "Completion folds every earlier text, Hydra card and diagnostic into one ordered process")
        let interrupted = FinishedTurnContent(entries: rows, finalAssistantID: nil)
        expect(interrupted.final == nil && interrupted.process.count == rows.count - 1,
            "An interrupted turn must not promote intermediate narration to a final reply")
        let earlySteering = [rows[0], rows[12], rows[14]]
        let earlyProjection = FinishedTurnContent(entries: earlySteering, finalAssistantID: "final")
        expect(earlyProjection.prompt?.id == "prompt" && earlyProjection.process.map(\.id) == ["steer"],
            "Consecutive user events cannot move later steering outside the overall process fold")

        // A notice without a turn ID can land between native turn events. Completion
        // must still produce one disclosure, with that notice in its original place.
        let unscoped = TimelineEntry(TimelineItem(id: "unscoped", turnID: nil,
            content: .notice(Notice(level: .info, message: "Runtime update"))))
        let summary = TurnSummary(turnID: turnID, status: .completed, duration: 2,
            filesChanged: 0, additions: 0, deletions: 0, changes: FileChangeSummary(files: []))
        let end = entry("end", .turnEnd(summary))
        let ordered = Array(rows.prefix(4)) + [unscoped] + Array(rows.dropFirst(4)) + [end]
        let cache = TimelineBlockCache()
        for count in 1...ordered.count {
            let prefix = Array(ordered.prefix(count))
            let pills = HeadPills(later: [3, 1])
            expect(cache.blocks(for: prefix, showReasoning: true, isRunning: true, hydraMergeID: nil, pills: pills)
                == DisplayBlock.build(prefix, meta: TimelineMeta.build(prefix), showReasoning: true,
                    isRunning: true, hydraMergeID: nil, pills: pills),
                "Append cache must preserve ordering and waiting ownership at prefix \(count)")
        }
        let finished = cache.blocks(for: ordered, showReasoning: true, isRunning: false,
            hydraMergeID: nil, pills: HeadPills(later: [3, 1]))
        expect(finished.count == 1, "An unscoped in-turn notice cannot split the overall completed fold")
        guard case .turn(_, _, let content, _, let finalID, _, let waiting) = finished[0] else {
            fatalError("Expected one completed turn")
        }
        expect(content.map(\.id) == ordered.dropLast().map(\.id) && finalID == "final",
            "Completed display retains all process entries, thinking and final identity")
        expect(waiting.heads == [3, 1], "Head waits belong inside the turn fold in finish order")
        let withBackground = DisplayBlock.addingBackgroundTasks(["Native background work"], to: finished)
        guard case .turn(_, _, _, _, _, _, let background) = withBackground[0] else {
            fatalError("Waiting escaped its turn")
        }
        expect(withBackground.count == 1 && background.backgroundTasks == ["Native background work"],
            "Native background waiting must fold with the completed process too")
        let nextTurn = UUID()
        let following = ordered + [TimelineEntry(TimelineItem(id: "next", turnID: nextTurn,
            content: .user(UserMessage(text: "Next prompt"))))]
        let pills = HeadPills(earlier: [3], later: [1])
        expect(cache.blocks(for: following, showReasoning: true, isRunning: true, hydraMergeID: nil, pills: pills)
            == DisplayBlock.build(following, meta: TimelineMeta.build(following), showReasoning: true,
                isRunning: true, hydraMergeID: nil, pills: pills),
            "Starting another turn preserves the completed fold and assigns waiting only once")
    }

    @MainActor private static func checkFinishedHeadGroups() {
        let statuses: [HydraHeadInfo.Status] = [.completed, .completed, .failed, .completed, .completed, .stopped, .completed]
        let heads = statuses.enumerated().map { index, status in
            var head = HydraHeadInfo(index: index, task: "Task \(index)", kind: .native, origin: .delegated)
            head.status = status
            head.summary = "Report \(index)"
            return head
        }
        let groups = FinishedHeadsGroup.build(heads)
        expect(groups.map { $0.heads.map(\.index) } == [[0, 1], [2], [3, 4], [5], [6]],
            "Only consecutive successful heads combine; failed and stopped outcomes keep their finish positions")
        expect(groups.flatMap(\.heads) == heads, "Completion grouping preserves every task, outcome and report")
        let first = FinishedHeadsGroup.build(Array(heads.prefix(1)))
        let expanded = FinishedHeadsGroup.build(Array(heads.prefix(2)))
        expect(first.first?.id == expanded.first?.id, "The completion pill keeps its identity as more heads finish")
        expect(FinishedHeadsGroup.build([]).isEmpty, "An empty completion list has no pill")
    }

    @MainActor private static func checkFinishedHeadReports() async throws {
        let heads = (0..<6).map { index in
            var head = HydraHeadInfo(index: index, task: "Task \(index)", kind: .native, origin: .delegated)
            head.status = .completed
            head.summary = "Report marker \(index) with `head-\(index)`\n\n" + String(repeating: "Report body.\n\n", count: index == 5 ? 80 : 1)
            head.finishedAt = head.startedAt.addingTimeInterval(10)
            return head
        }
        for index in [0, 5, 1] {
            let host = NSHostingView(rootView: HydraReportsPopover(heads: heads, initiallyExpanded: [index]))
            let window = NSWindow(contentRect: NSRect(x: 10000, y: 10000, width: 460, height: 600),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(60))
            host.layoutSubtreeIfNeeded()
            let reports = textViews(in: host).map(\.string)
            expect(reports.contains { $0.contains("Report marker \(index)") },
                "Expanding head \(index) reveals its report, including heads beyond the avatar limit")
            expect(!reports.contains { text in heads.indices.contains { $0 != index && text.contains("Report marker \($0)") } },
                "Collapsed report cards keep their Markdown out of layout")
            expect(host.fittingSize.width == 460 && host.fittingSize.height <= 650,
                "Long reports keep the upstream digest's bounded viewport")
        }
    }

    @MainActor private static func checkPersistentCompletions() {
        var first = TurnRecord(index: 0)
        first.startedAt = Date(timeIntervalSince1970: 100)
        first.completedAt = Date(timeIntervalSince1970: 200)
        var second = TurnRecord(index: 1)
        second.startedAt = Date(timeIntervalSince1970: 300)
        second.completedAt = Date(timeIntervalSince1970: 400)
        let entries = [
            TimelineEntry(TimelineItem(id: "spawn-first", turnID: first.id, content: .tool(ToolCall(kind: .agent, title: "Delegate")))),
            TimelineEntry(TimelineItem(id: "spawn-second", turnID: second.id, content: .tool(ToolCall(kind: .agent, title: "Delegate again")))),
        ]
        var done = HydraHeadInfo(index: 1, task: "First task", kind: .native, origin: .delegated)
        done.status = .completed; done.toolUseID = "spawn-first"
        done.finishedAt = Date(timeIntervalSince1970: 350)
        var failed = HydraHeadInfo(index: 2, task: "Second task", kind: .native, origin: .delegated)
        failed.status = .failed; failed.toolUseID = UUID().uuidString + "-spawn-second"
        failed.finishedAt = Date(timeIntervalSince1970: 360)
        var legacy = HydraHeadInfo(index: 3, task: "Without a tool identity", kind: .native, origin: .delegated)
        legacy.status = .stopped; legacy.startedAt = Date(timeIntervalSince1970: 150)
        legacy.finishedAt = Date(timeIntervalSince1970: 370)
        let placement = HydraCompletionPlacement.byTurn(heads: [failed, done, legacy], entries: entries, turns: [first, second])
        expect(placement[first.id] == [1, 3] && placement[second.id] == [2],
               "A completed head stays on its dispatch turn even when it finishes in another turn")
        let summary = TurnSummary(turnID: first.id, status: .completed, duration: 100, filesChanged: 0, additions: 0, deletions: 0)
        let ended = entries.prefix(1) + [TimelineEntry(TimelineItem(id: "end-first", turnID: first.id, content: .turnEnd(summary)))]
        let blocks = DisplayBlock.build(Array(ended), meta: TimelineMeta.build(Array(ended)), showReasoning: true,
            isRunning: false, hydraMergeID: nil, pills: HeadPills(byTurn: placement))
        guard case .turn(_, _, _, _, _, _, let retained) = blocks.first else { fatalError("Expected completed turn") }
        expect(retained.heads == [1, 3], "A settled batch retains its completion cards without any running sibling")
        expect(FinishedHeadsGroup.build([done, legacy]).count == 2, "Stopped outcomes remain individually readable")
        let split = Array(ended) + [
            TimelineEntry(TimelineItem(id: "between", turnID: nil, content: .notice(Notice(level: .info, message: "Between turns")))),
            TimelineEntry(TimelineItem(id: "later-segment", turnID: first.id, content: .tool(ToolCall(kind: .read, title: "Late entry")))),
        ]
        let segmented = DisplayBlock.build(split, meta: TimelineMeta.build(split), showReasoning: true,
            isRunning: false, hydraMergeID: nil, pills: HeadPills(byTurn: placement))
        let shown = segmented.flatMap { block -> [Int] in
            if case .turn(_, _, _, _, _, _, let waiting) = block { return waiting.heads }
            return []
        }
        expect(shown == [1, 3], "Split segments of one native turn show completed cards exactly once")
        done.nativeCanonicalID = UUID()
        expect(HydraCompletionPlacement.byTurn(heads: [done], entries: entries, turns: [first, second]).isEmpty,
               "Legacy alias pages cannot duplicate the canonical worker's completed card")
    }

    @MainActor private static func checkCentredEditor(_ output: URL) async throws {
        let app = AppModel()
        app.settings.performanceMode = true
        app.settings.chimeWhenFinished = false
        app.settings.notifyWhenFinished = false
        let thread = ChatThread(projectID: nil, provider: .omp, model: nil, effort: nil, runtimeMode: .supervised)
        app.insertThread(thread)
        let runtime = app.runtime(for: thread.id)
        await runtime.ensureLoaded()
        runtime.draft = ComposerDraft(text: "Keep this draft while the editor docks")
        let window = NSWindow(contentRect: NSRect(x: 10000, y: 10000, width: 960, height: 720),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let resize = WindowLiveResize(window: window)
        func root(_ runtime: ThreadRuntime) -> AnyView {
            AnyView(ChatView(runtime: runtime).environment(app).environment(resize)
                .environment(\.chatColumnIsShown, false))
        }
        let host = FrameHostingView(rootView: root(runtime))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func editors(_ view: NSView) -> [ComposerNSTextView] {
            (view as? ComposerNSTextView).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        func editorFrame(_ editor: ComposerNSTextView) -> NSRect {
            let view = editor.enclosingScrollView ?? editor
            return view.convert(view.bounds, to: host)
        }
        func bottomGap(_ frame: NSRect) -> CGFloat {
            host.isFlipped ? host.bounds.maxY - frame.maxY : frame.minY
        }
        func snapshot(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot capture chat layout") }
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        guard let editor = editors(host).first else { fatalError("New conversation lost its native editor") }
        let centredGap = bottomGap(editorFrame(editor))
        expect(centredGap > 180, "An empty conversation puts the native editor near the centre")
        try snapshot("new-chat-centred")
        runtime.receiveOMPEvent(.ompUserMessage(requestID: nil, nativeID: "visual-first-user", text: "First native message", imageCount: 0, startsNewTurn: true))
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        expect(runtime.hasEntries, "Native consumption leaves the empty state")
        expect(editors(host).first === editor, "Docking preserves the native text editor and input-method state")
        expect(bottomGap(editorFrame(editor)) < 140 && bottomGap(editorFrame(editor)) < centredGap - 100,
               "The first native message docks the same editor beneath the conversation")
        expect(runtime.draft.text == "Keep this draft while the editor docks", "Visual docking preserves the draft")
        try snapshot("chat-editor-docked")

        let empty = ChatThread(projectID: nil, provider: .omp, model: nil, effort: nil, runtimeMode: .supervised)
        app.insertThread(empty)
        let next = app.runtime(for: empty.id)
        await next.ensureLoaded()
        host.rootView = root(next)
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        expect(editors(host).first.map { bottomGap(editorFrame($0)) > 180 } == true,
               "Switching to another empty conversation restores its centred editor")
        window.setContentSize(NSSize(width: 460, height: 340))
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        guard let narrowEditor = editors(host).first else { fatalError("Short chat lost its editor") }
        let narrow = editorFrame(narrowEditor)
        expect(narrow.minY >= 0 && narrow.maxY <= host.bounds.height && narrow.width <= host.bounds.width,
               "The editor remains reachable in a short, narrow pane")
        try snapshot("new-chat-narrow")

        let steps = [
            TimelineEntry(TimelineItem(id: "visual-read", turnID: nil, content: .tool(ToolCall(kind: .read, title: "OMPGUI/App/Views/Chat/ThreadTimeline.swift", status: .completed)))),
            TimelineEntry(TimelineItem(id: "visual-thought", turnID: nil, content: .reasoning(ReasoningBlock(text: "Keep each OMP work group in its original position. Preserve native tool details and file actions.\nThis line stays in the collapsed body.")))),
            TimelineEntry(TimelineItem(id: "visual-edit", turnID: nil, content: .tool(ToolCall(kind: .edit, title: "OMPGUI/App/Views/Chat/ActivityTree.swift", status: .completed)))),
            TimelineEntry(TimelineItem(id: "visual-command", turnID: nil, content: .tool(ToolCall(kind: .command, title: "make build", status: .completed))))
        ]
        let reveal = TimelineRevealBox()
        reveal.presentation.working["visual-steps"] = true
        host.rootView = AnyView(VStack(alignment: .leading, spacing: 20) {
            ActivityGroup(id: "visual-steps", entries: steps, runtime: runtime)
            Text("Ready for the next step.")
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(app).environment(\.revealTimelineEnd, reveal))
        window.setContentSize(NSSize(width: 760, height: 420))
        try await Task.sleep(for: .milliseconds(180))
        try snapshot("activity-tree")
        expect(!textViews(in: host).contains { $0.string.contains("This line stays in the collapsed body.") },
               "The inline preview does not mount the full thinking document")
        reveal.presentation.thoughts["visual-thought"] = true
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        expect(textViews(in: host).contains { $0.string.contains("This line stays in the collapsed body.") },
               "An expanded thought retains text after the preview's first line")
        try snapshot("activity-thinking-expanded")
        reveal.presentation.thoughts["visual-thought"] = false
        window.setContentSize(NSSize(width: 300, height: 420))
        try await Task.sleep(for: .milliseconds(180))
        try snapshot("activity-tree-narrow")

        let initialThinking = (0..<80).map { "Streaming paragraph \($0): latest reasoning remains readable." }.joined(separator: "\n\n")
        let streaming = TimelineEntry(TimelineItem(id: "streaming-scroll", turnID: nil,
            content: .reasoning(ReasoningBlock(text: initialThinking, isStreaming: true))))
        host.rootView = AnyView(ThinkingRow(entry: streaming).padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(app).environment(\.revealTimelineEnd, reveal))
        window.setContentSize(NSSize(width: 480, height: 600))
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        func bottomDistance(_ scroll: NSScrollView) -> CGFloat {
            guard let document = scroll.documentView else { return .infinity }
            return document.isFlipped ? document.frame.height - scroll.contentView.bounds.maxY : scroll.contentView.bounds.minY
        }
        expect(scrollViews(host).isEmpty, "A collapsed streaming thought mounts no full scroll reader")
        reveal.presentation.thoughts[streaming.id] = true
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        guard let thinkingScroll = scrollViews(host).first else { fatalError("Expanded thinking lost its scroll reader") }
        expect(thinkingScroll.contentSize.height <= 360.5 && thinkingScroll.contentSize.height > 100,
               "Long thinking is bounded to a 360-point viewport")
        expect((thinkingScroll.documentView?.frame.height ?? 0) > thinkingScroll.contentSize.height * 3,
               "The complete long thinking stays inside its independently scrollable document")
        expect(abs(bottomDistance(thinkingScroll)) < 3,
               "Opening live thinking must reach its end: distance=\(bottomDistance(thinkingScroll)), document=\(thinkingScroll.documentView!.frame), clip=\(thinkingScroll.contentView.bounds)")
        let previousHeight = thinkingScroll.documentView!.frame.height
        let moreThinking = initialThinking + "\n\n" + (80..<100).map { "New streamed paragraph \($0)." }.joined(separator: "\n\n")
        streaming.item.content = .reasoning(ReasoningBlock(text: moreThinking, isStreaming: true))
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        try snapshot("streaming-thinking")
        expect(thinkingScroll.documentView!.frame.height > previousHeight && abs(bottomDistance(thinkingScroll)) < 3,
               "An expanded streaming thought follows appended reasoning at the bottom")
        reveal.presentation.thoughts[streaming.id] = false
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        expect(scrollViews(host).isEmpty, "Collapsing a thought releases its full reader")
        reveal.presentation.thoughts[streaming.id] = true
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        expect(scrollViews(host).first.map { abs(bottomDistance($0)) < 3 } == true,
               "Reopening live thinking returns to its newest content")
    }

    @MainActor static func main() async throws {
        guard CaptureRun.isEnabled, let root = CaptureRun.storageRoot,
              root.path.contains("/build.noindex/verification/runs/") else {
            fatalError("Require isolated storage")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try checkNativeAsyncNotices()
        checkChronologicalProcess()
        checkFinishedHeadGroups()
        checkPersistentCompletions()
        if CommandLine.arguments.contains("--model-only") {
            print("Timeline model checks passed: \(checks)")
            return
        }
        _ = NSApplication.shared
        try await checkRepeatedDiagnostics(CaptureRun.storageRoot!.deletingLastPathComponent())
        try await checkFinishedHeadReports()
        try await checkCentredEditor(CaptureRun.storageRoot!.deletingLastPathComponent())
        let environment = EnvironmentValues()
        let marker = "Previous final response remains visible"
        let source = marker + " with 中文, **emphasis**, and `inline code`."

        // A coordinator may outlive its native view when SwiftUI rematerializes a
        // finished row. Equal inputs still need to populate the replacement storage.
        let paragraph = LinkParagraphView(source: source)
        let paragraphCoordinator = LinkParagraphView.Coordinator()
        let firstParagraph = LinkTextView()
        paragraph.updateTextView(firstParagraph, coordinator: paragraphCoordinator, environment: environment)
        let replacementParagraph = LinkTextView()
        paragraph.updateTextView(replacementParagraph, coordinator: paragraphCoordinator, environment: environment)
        expect(replacementParagraph.string == firstParagraph.string && replacementParagraph.string.contains(marker),
            "Recreated paragraph must retain the previous final response")
        expect(replacementParagraph.height(forWidth: 300) == firstParagraph.height(forWidth: 300),
            "Recreated paragraph must retain its measured glyph height")
        paragraph.updateTextView(replacementParagraph, coordinator: paragraphCoordinator, environment: environment)
        expect(replacementParagraph.string.contains(marker), "Equal updates preserve rendered paragraph storage")
        paragraph.updateTextView(firstParagraph, coordinator: paragraphCoordinator, environment: environment)
        expect(firstParagraph.string == replacementParagraph.string, "Returning to an earlier native view preserves text")

        let blocks = MarkdownParser.parse(source + "\n\n- First result\n- Second result")
        let prose = ProseRunRepresentable(blocks: blocks)
        let proseCoordinator = LinkParagraphView.Coordinator()
        let firstProse = LinkTextView()
        prose.updateTextView(firstProse, coordinator: proseCoordinator, environment: environment)
        let replacementProse = LinkTextView()
        prose.updateTextView(replacementProse, coordinator: proseCoordinator, environment: environment)
        expect(replacementProse.string == firstProse.string && replacementProse.string.contains("Second result"),
            "Recreated finished prose run must retain every paragraph and list")
        expect(replacementProse.height(forWidth: 300) == firstProse.height(forWidth: 300),
            "Recreated prose run must retain its full height")
        // Run the real append cache through tools, a completed answer, and a new
        // running turn. Every intermediate result must equal a fresh full build.
        let cache = TimelineBlockCache()
        let firstTurn = UUID(), nextTurn = UUID()
        var entries = [TimelineEntry(TimelineItem(id: "first-user", turnID: firstTurn, content: .user(UserMessage(text: "First prompt"))))]
        for index in 0..<70 {
            entries.append(TimelineEntry(TimelineItem(id: "work-\(index)", turnID: firstTurn,
                content: .tool(ToolCall(kind: .read, title: "Read fixture \(index)")))))
        }
        entries.append(TimelineEntry(TimelineItem(id: "first-answer", turnID: firstTurn, content: .assistant(AssistantMessage(text: source)))))
        let summary = TurnSummary(turnID: firstTurn, status: .completed, duration: 2,
            filesChanged: 0, additions: 0, deletions: 0, changes: FileChangeSummary(files: []))
        entries.append(TimelineEntry(TimelineItem(id: "first-end", turnID: firstTurn, content: .turnEnd(summary))))
        entries.append(TimelineEntry(TimelineItem(id: "next-user", turnID: nextTurn, content: .user(UserMessage(text: "Next prompt")))))
        entries.append(TimelineEntry(TimelineItem(id: "next-reasoning", turnID: nextTurn, content: .reasoning(ReasoningBlock(text: "Working")))))
        for count in 1...entries.count {
            let prefix = Array(entries.prefix(count))
            let actual = cache.blocks(for: prefix, showReasoning: false, isRunning: true, hydraMergeID: nil)
            let expected = DisplayBlock.build(prefix, meta: TimelineMeta.build(prefix), showReasoning: false,
                isRunning: true, hydraMergeID: nil)
            expect(actual == expected, "Append cache must match a full build at entry \(count)")
        }
        let blocksAfterNext = cache.blocks(for: entries, showReasoning: false, isRunning: true, hydraMergeID: nil)
        expect(blocksAfterNext.contains { block in
            if case .turn(_, let turnID, _, let summary, let final, _, _) = block {
                return turnID == firstTurn && summary != nil && final == "first-answer"
            }
            return false
        }, "A new running turn must retain the previous turn's selected final reply")

        // The projection's memoized rows must observe whether late final content
        // becomes readable, even though its TimelineEntry identity does not change.
        let app = AppModel()
        app.settings.chimeWhenFinished = false
        app.settings.notifyWhenFinished = false
        let thread = ChatThread(projectID: UUID(), provider: .omp, model: nil, effort: nil, runtimeMode: .auto)
        app.insertThread(thread)
        let runtime = app.runtime(for: thread.id)
        await runtime.ensureLoaded()
        app.settings.showReasoning = true
        let narration = TimelineEntry(TimelineItem(id: "earlier-narration", turnID: firstTurn,
            content: .assistant(AssistantMessage(text: "Earlier narration stays in the process"))))
        let thoughts = (0..<65).map { index in
            TimelineEntry(TimelineItem(id: "thought-\(index)", turnID: firstTurn,
                content: .reasoning(ReasoningBlock(text: "Process thought \(index).\nFull thinking detail \(index).", isStreaming: index == 0))))
        }
        let laterNarration = TimelineEntry(TimelineItem(id: "later-narration", turnID: firstTurn,
            content: .assistant(AssistantMessage(text: "A later stage stays in order"))))
        let separateThought = TimelineEntry(TimelineItem(id: "separate-thought", turnID: firstTurn,
            content: .reasoning(ReasoningBlock(text: "Independent group thought"))))
        let process = [narration] + thoughts + [laterNarration, separateThought]
        let answer = TimelineEntry(TimelineItem(id: "late-answer", turnID: firstTurn,
            content: .assistant(AssistantMessage(text: ""))))
        let stage = AnswerStage()
        let reveal = TimelineRevealBox()
        let host = NSHostingView(rootView: AnswerHarness(runtime: runtime, turnID: firstTurn,
            summary: summary, answer: answer, stage: stage, process: process,
            waiting: TurnWaiting(heads: [], backgroundTasks: ["Native background work"]))
            .environment(app).environment(\.revealTimelineEnd, reveal))
        let window = NSWindow(contentRect: NSRect(x: 10000, y: 10000, width: 560, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let blankHeight = host.fittingSize.height
        expect(!textViews(in: host).contains { $0.string.contains("Earlier narration") || $0.string.contains("Process thought") },
            "Completed process text and thinking start inside the overall fold")
        answer.item.content = .assistant(AssistantMessage(text: source))
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        expect(textViews(in: host).contains { $0.string.contains(marker) },
            "Late final content must appear without replacing its timeline entry")
        expect(host.fittingSize.height > blankHeight,
            "Late final content must restore the finished turn's layout height")
        stage.nextPrompt = true
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        expect(textViews(in: host).contains { $0.string.contains(marker) },
            "Starting a following turn must keep the earlier answer visible")
        answer.item.content = .assistant(AssistantMessage(text: " \n "))
        try await Task.sleep(for: .milliseconds(200))
        answer.item.content = .assistant(AssistantMessage(text: source))
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        expect(textViews(in: host).contains { $0.string.contains(marker) },
            "A second eligibility change must not reuse an empty finished projection")
        reveal.presentation.finished[firstTurn] = true
        reveal.presentation.working["work-thought-0"] = true
        reveal.presentation.thoughts[separateThought.id] = true
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let groupOnly = textViews(in: host).map(\.string)
        let collapsedThoughtHeight = host.fittingSize.height
        expect(!groupOnly.contains { $0.contains("Full thinking detail") },
            "Thoughts stay collapsed by default, including a streaming thought inside an open group")
        reveal.presentation.thoughts[thoughts[1].id] = true
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        expect(textViews(in: host).contains { $0.string.contains("Full thinking detail 1.") }
            && !textViews(in: host).contains { $0.string.contains("Full thinking detail 2.") },
            "Opening one thought displays its full text without opening another thought")
        reveal.presentation.thoughts[thoughts[1].id] = false
        thoughts[0].item.content = .reasoning(ReasoningBlock(text: "Process thought 0.\nFull thinking detail 0.\nNew streamed detail.", isStreaming: true))
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        expect(abs(host.fittingSize.height - collapsedThoughtHeight) < 1,
            "Streaming updates cannot reopen a collapsed thought or allocate its full reader")
        thoughts[0].item.content = .reasoning(ReasoningBlock(text: "Process thought 0.\nFull thinking detail 0.\nNew streamed detail."))
        for thought in thoughts { reveal.presentation.thoughts[thought.id] = true }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let expanded = textViews(in: host).map(\.string)
        expect(expanded.contains { $0.contains("Earlier narration") },
            "Opening the overall process restores intermediate text normally")
        expect((0..<65).allSatisfy { index in expanded.contains { $0.contains("Process thought \(index).") && $0.contains("Full thinking detail \(index).") } },
            "All 65 thoughts expose their complete text when opened, without a paging control")
        expect(!expanded.contains { $0.contains("Independent group thought") },
            "Opening one step group must not open another group from the same turn")
        expect(expanded.contains { $0.contains(marker) }, "Opening process steps keeps the final answer outside them")
        reveal.presentation.finished[firstTurn] = false
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        expect(textViews(in: host).contains { $0.string.contains(marker) }
            && !textViews(in: host).contains { $0.string.contains("Process thought") || $0.string.contains("Earlier narration") },
            "Closing the completed process returns to only the final text")
        print("Timeline answer checks passed: \(checks)")
    }
}
