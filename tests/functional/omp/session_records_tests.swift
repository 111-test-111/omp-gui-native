import AppKit
import SwiftUI
@testable import OMPGUI

private struct HistoryFailure: Error, CustomStringConvertible { let description: String }

private actor HistoryGate: OMPSessionRecordReading {
    let base: OMPSessionRecordReader
    var hold = false
    var held = false
    var calls = 0
    var active = 0
    var maximumActive = 0
    var continuation: CheckedContinuation<Void, Never>?
    init(root: URL) { base = OMPSessionRecordReader(root: root) }
    func holdNext() { hold = true }
    func unblock() { continuation?.resume(); continuation = nil; held = false }
    func release() async { await base.release() }
    func read(_ request: OMPSessionRecordRequest) async throws -> OMPSessionRecordPage {
        calls += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        let result = try await base.read(request)
        if hold {
            hold = false; held = true
            await withCheckedContinuation { continuation = $0 }
        }
        // Deliberately return the prepared snapshot even after cancellation.
        return result
    }
}

@main @MainActor
private enum SessionRecordChecks {
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw HistoryFailure(description: message) }
    }

    private static func eventually(_ message: String, _ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()) {
            if ContinuousClock.now >= deadline { throw HistoryFailure(description: message) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func entry(_ id: String, parent: String?, type: String = "message", fields: [String: JSONValue],
                              timestamp: String = "2026-10-24T09:30:00.123Z") -> JSONValue {
        .object(fields.merging(["id": .string(id), "parentId": parent.map(JSONValue.string) ?? .null,
            "type": .string(type), "timestamp": .string(timestamp)], uniquingKeysWith: { _, value in value }))
    }

    private static func user(_ id: String, parent: String?, text: String) -> JSONValue {
        entry(id, parent: parent, fields: ["message": ["role": "user", "content": .string(text)]])
    }

    private static func data(_ rows: [JSONValue]) -> Data {
        Data((rows.map(\.compactString).joined(separator: "\n") + "\n").utf8)
    }

    private static let header: [JSONValue] = [
        ["type": "title", "v": 1, "title": "History fixture", "pad": "   "],
        ["type": "session", "id": "fixture", "version": 3, "cwd": "/isolated"]
    ]

    private static func fixture() -> [JSONValue] {
        var rows = header
        for i in 0..<170 { rows.append(user("u\(i)", parent: i == 0 ? nil : "u\(i - 1)", text: "Record \(i) · 会话记录")) }
        var arguments = Dictionary(uniqueKeysWithValues: (0..<95).map { (String(format: "field%03d", $0), JSONValue.int($0)) })
        arguments["command"] = "printf 'hello'"
        arguments["api_key"] = "must-not-display"
        arguments["nested"] = ["deep": ["needle-only-in-details": true]]
        rows.append(entry("assistant", parent: "u169", fields: ["message": ["role": "assistant", "model": "fixture-model", "provider": "fixture",
            "stopReason": "toolUse", "duration": 1234, "ttft": 45, "usage": ["totalTokens": 33, "cost": ["total": 0.012]],
            "providerPayload": ["secret": "opaque"], "content": [
                ["type": "text", "text": "Inspecting the workspace"],
                ["type": "thinking", "thinking": "Check the files first"],
                ["type": "toolCall", "id": "exact-call", "name": "bash", "arguments": .object(arguments)],
                ["type": "toolCall", "id": "unrecorded", "name": "read", "arguments": ["path": "/isolated/source.swift"]]
            ]]]))
        rows.append(entry("result", parent: "assistant", fields: ["message": ["role": "toolResult", "toolCallId": "exact-call", "toolName": "bash",
            "isError": true, "content": [["type": "text", "text": .string(String(repeating: "Output 日志\n", count: 5000))]],
            "details": ["exitCode": 1, "password": "must-not-display", "nested": ["authorization": "secret", "ok": true]]]]))
        rows.append(entry("compact", parent: "result", type: "compaction", fields: ["summary": "Retained context", "tokensBefore": 500, "tokensAfter": 100, "firstKeptEntryId": "assistant"]))
        rows.append(entry("usage", parent: "compact", type: "model_usage", fields: ["purpose": "title", "model": "tiny", "usage": ["totalTokens": 10]]))
        rows.append(entry("credential", parent: "usage", type: "credential_pin", fields: ["credential": "never-display"]))
        rows.append(entry("off-branch", parent: "u0", fields: ["activeLeafId": "credential", "message": ["role": "user", "content": "Wrong branch"]]))
        return rows
    }

    private static func presentationRows(parent: String?) -> [JSONValue] {
        let start: JSONValue = ["toolCallId": "p-empty-call", "toolName": "bash", "startedAt": "2026-10-24T09:30:00.123Z",
                                "args": ["command": "pwd"], "intent": "Inspect workspace"]
        return [
            entry("p-empty", parent: parent, fields: ["message": ["role": "assistant", "stopReason": "toolUse", "content": [
                ["type": "thinking", "thinking": "Inspect the workspace first"],
                ["type": "toolCall", "id": "p-empty-call", "name": "bash", "arguments": ["command": "pwd"]]]]]),
            entry("p-empty-start", parent: "p-empty", type: "custom", fields: ["customType": "tool_execution_start", "data": start]),
            entry("p-empty-result", parent: "p-empty-start", fields: ["message": ["role": "toolResult", "toolCallId": "p-empty-call", "toolName": "bash", "isError": false, "content": "workspace"]]),
            entry("p-dot", parent: "p-empty-result", fields: ["message": ["role": "assistant", "stopReason": "toolUse", "content": [
                ["type": "thinking", "thinking": "Read the source"], ["type": "text", "text": " \n.\t "],
                ["type": "toolCall", "id": "p-dot-call", "name": "read", "arguments": ["path": "."]]]]]),
            entry("p-dot-start", parent: "p-dot", type: "custom", fields: ["customType": "tool_execution_start", "data": [
                "toolCallId": "p-dot-call", "toolName": "read", "startedAt": "2026-10-24T09:30:00.123Z", "args": ["path": "."]]]),
            entry("p-dot-result", parent: "p-dot-start", fields: ["message": ["role": "toolResult", "toolCallId": "p-dot-call", "toolName": "read", "isError": false, "content": "."]]),
            entry("p-prose", parent: "p-dot-result", fields: ["message": ["role": "assistant", "stopReason": "toolUse", "content": [
                ["type": "text", "text": "I will inspect the repository."],
                ["type": "toolCall", "id": "p-prose-call", "name": "bash", "arguments": ["command": "git status"]]]]]),
            entry("p-standalone-dot", parent: "p-prose", fields: ["message": ["role": "assistant", "stopReason": "stop", "content": [["type": "text", "text": "."]]]]),
            entry("p-custom", parent: "p-standalone-dot", type: "custom", fields: ["customType": "example", "data": ["value": "other data"]]),
            entry("p-malformed-start", parent: "p-custom", type: "custom", fields: ["customType": "tool_execution_start", "data": ["toolName": "bash"]]),
            entry("p-blank", parent: "p-malformed-start", fields: ["message": ["role": "assistant", "stopReason": "stop", "content": []]]),
            entry("p-failed", parent: "p-blank", fields: ["message": ["role": "assistant", "stopReason": "error", "errorMessage": "Provider failed", "content": []]]),
            entry("p-cancelled", parent: "p-failed", fields: ["message": ["role": "assistant", "stopReason": "aborted", "content": []]])
        ]
    }

    static func main() async throws {
        let output = CaptureRun.outputDirectory!
        let root = output.appendingPathComponent("journals")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("history.jsonl")
        let rows = fixture()
        try data(rows).write(to: file)
        try await readerChecks(file: file, root: root, rows: rows)
        print("PASS native history: ancestry, title slots, paging, filters, exact tool results and bounded private detail")
        try await mutationChecks(file: file, root: root, rows: rows)
        print("PASS native history mutations: partial tails, same-size rewrites, replacement, truncation and cleared leaf")
        try await boundaryChecks(root: root)
        print("PASS native history boundaries: symlinks, malformed ancestry, duplicate IDs and byte limits")
        try await storeChecks(file: file, root: root)
        print("PASS history store: source isolation, late reads, one in-flight request and visible-only file watches")
        try await detailNavigationChecks(root: root)
        print("PASS history detail navigation: atomic presentation, retained snapshots, repeated clicks, cancellation and failure")
        try await captureChecks(root: root)
        print("PASS request history: identity, branch isolation, lazy details, paging, corruption and interruption")
        try await presentationChecks(root: root)
        print("PASS history presentation: model responses, empty/failed replies, original prose/reasoning and canonical tool selection")
        try await mergingChecks(root: root)
        print("PASS merged tools: parallel/repeated starts, response-owned details, branch isolation, aliases and paging")
        try await chronologyChecks(root: root)
        print("PASS chronological history: interleaved requests, responses and native tool order with tied timestamps")
        try await sortingChecks(root: root)
        print("PASS history sorting: default order, reverse paging, anchors, retained details and late-read protection")
        try await captionChecks(root: root)
        print("PASS history captions: tool subjects, device arguments, bounded extension fallback and thinking levels")
        try await finalReplyChecks(root: root)
        print("PASS final replies: native round boundaries, continuation, completion reasons, filtering and reply symbols")
        try sourceChecks(file: file)
        try rowGeometryChecks(output: output)
        print("PASS history row geometry: retained heights across selection and overview/detail widths")
        try await layoutChecks(file: file, root: root, output: output)
        print("PASS history layout: narrow topbars, retained viewport, tool detail and fullscreen columns")
        try await treeChecks(root: root)
        print("PASS round trees: native ownership, whole-round paging, ancestor-preserving filters and chronological children")
        try await inlineDetailChecks(root: root)
        print("PASS inline details: concurrent branches, typed paths, bounded text pages, field continuations and retained source state")
        try await detailModeChecks(root: root)
        print("PASS detail modes: independent flat navigation, retained addresses, bounded recursive expansion and superseded bulk actions")
        try await treeLayoutChecks(root: root, output: output)
        print("PASS tree layout: aligned elbows, capped indentation and retained read-only text viewports")
    }

    private static func detailModeChecks(root: URL) async throws {
        let file = root.appendingPathComponent("detail-modes.jsonl")
        let long = String(repeating: "Structured parameter 日志😀\n", count: 1_200)
        let arguments: JSONValue = ["alpha": ["nested": ["text": .string(long), "api_key": "must-not-copy"]],
                                    "beta": ["flag": true, "image": ["type": "image", "mimeType": "image/png", "data": "must-not-copy"]],
                                    "empty": .array([]), "many": .array((0..<95).map(JSONValue.int))]
        try data(header + [user("mode-user", parent: nil, text: "Inspect parameter modes"),
            entry("mode-response", parent: "mode-user", fields: ["message": ["role": "assistant", "content": [
                ["type": "toolCall", "id": "mode-call", "name": "read", "arguments": arguments]]]])]).write(to: file)
        let gate = HistoryGate(root: root), state = SessionHistoryStore(reader: gate, watchRoot: root)
        defer { state.suspend() }
        let source = OMPSessionRecordSource(id: "modes", title: "Modes", file: file.path)
        let tool = "session:7:fixture:tool:mode-response:0"
        let alpha: [OMPSessionDetailKey] = [.field("alpha")]
        let textPath: [OMPSessionDetailKey] = [.field("alpha"), .field("nested"), .field("text")]
        state.present(sources: [source]); state.select(tool)
        try await eventually("Mode fixture did not load") { !state.isLoading && state.detail?.record.id == tool }
        state.toggleDetail(alpha)
        try await eventually("Initial tree branch did not expand") { !state.isLoading && state.detail?.rows.first { $0.path == alpha }?.isExpanded == true }
        let accepted = state.detail
        await gate.holdNext(); state.setDetailViewMode(.flat)
        try await eventually("Flat mode switch was not held") { await gate.held }
        try expect(state.detail == accepted && state.isDetailPending && state.viewMode == .tree,
                   "A pending detail mode change must retain its snapshot and leave the record-list mode alone")
        state.expandDetails()
        await gate.unblock()
        try await eventually("Flat detail did not commit") { !state.isLoading && state.detail?.viewMode == .flat }
        try expect(state.detail!.rows.count == 4 && state.detail!.rows.allSatisfy { !$0.isExpanded && $0.path.count == 1 },
                   "Flat details must contain a single field level without retained tree expansions")
        state.descend(.field("alpha"))
        try await eventually("Flat object navigation did not finish") { !state.isLoading && state.detail?.address.path == alpha }
        try expect(state.detail!.copyText.hasPrefix("nested:"), "Flat nested copy must not inherit tree indentation")
        state.descend(.field("nested"))
        try await eventually("Flat nested object did not finish") { !state.isLoading && state.detail?.address.path.count == 2 }
        state.descend(.field("text"))
        try await eventually("Flat text did not load") { !state.isLoading && state.detail?.text != nil }
        state.detailPage(1)
        try await eventually("Flat text page did not load") { !state.isLoading && state.detail?.address.page == 1 }
        try expect(state.detail!.text!.unicodeScalars.count <= 16_384, "Flat text must retain the original bounded pager")
        state.setDetailViewMode(.tree)
        try await eventually("Tree address was not restored") {
            !state.isLoading && state.detail?.viewMode == .tree && state.detail?.address.path.isEmpty == true
        }
        try expect(state.detail?.rows.first { $0.path == alpha }?.isExpanded == true,
                   "Switching back to tree must restore its inline branch state")
        state.collapseDetails()
        try await eventually("Tree collapse did not finish") { !state.isLoading && state.detail!.rows.allSatisfy { !$0.isExpanded } }
        state.expandDetails()
        try await eventually("Expand all parameters did not finish") { !state.isLoading && state.detail?.rows.first { $0.path == textPath }?.text != nil }
        try expect(state.detail!.rows.filter(\.canExpand).allSatisfy(\.isExpanded) && !state.detail!.isLimited,
                   "Expand all must recursively open nested containers and long text within the current field pages")
        state.toggleDetail(alpha)
        try await eventually("A branch did not collapse after expand-all") { !state.isLoading && state.detail?.rows.first { $0.path == alpha }?.isExpanded == false }
        state.refresh()
        try await eventually("Post-expansion refresh did not finish") { !state.isLoading }
        try expect(state.detail?.rows.first { $0.path == alpha }?.isExpanded == false,
                   "Expand-all must be a one-shot command, not a policy that reopens manually collapsed branches")
        state.setDetailViewMode(.flat)
        try await eventually("Flat reading position was not restored") {
            !state.isLoading && state.detail?.viewMode == .flat && state.detail?.address.path == textPath && state.detail?.address.page == 1
        }
        state.ascend(to: 0)
        try await eventually("Flat root navigation did not finish") { !state.isLoading && state.detail?.address.path.isEmpty == true }
        state.descend(.field("many"))
        try await eventually("Flat array did not load") { !state.isLoading && state.detail?.address.path == [.field("many")] }
        state.detailPage(2)
        try await eventually("Flat array's last page did not load") { !state.isLoading && state.detail?.address.page == 2 }
        try expect(state.detail!.rows.count == 15 && state.detail!.rows.first?.key == .index(80)
                   && state.detail!.rows.last?.key == .index(94), "Flat arrays must retain the original 40-field page boundaries")
        state.setSection(.metadata)
        try await eventually("Flat metadata did not load") { !state.isLoading && state.detail?.address.section == .metadata }
        state.setDetailViewMode(.tree)
        try await eventually("Mode switch changed the selected section") {
            !state.isLoading && state.detail?.viewMode == .tree && state.detail?.address.section == .metadata
        }
        state.setSection(.input)
        try await eventually("Tree input did not load") { !state.isLoading && state.detail?.address.section == .input }
        state.collapseDetails()
        try await eventually("Bulk-cancel setup did not finish") { !state.isLoading }
        await gate.holdNext(); state.expandDetails()
        try await eventually("Bulk expansion was not held") { await gate.held }
        state.collapseDetails(); await gate.unblock()
        try await eventually("Late expand-all replaced collapse-all") { !state.isLoading && state.detail!.rows.allSatisfy { !$0.isExpanded } }
        state.setViewMode(.flat)
        try await eventually("Record list mode switch did not finish") { !state.isLoading && state.totalRounds == nil }
        try expect(state.detailViewMode == .tree && state.detail?.viewMode == .tree,
                   "Record-list presentation changes must not change detail presentation")

        let visible = state.detail
        let copied = try await state.copyDetailJSON()!
        let json = JSONValue.parse(copied)!
        try expect(json["many"]?.array?.count == 95 && json["alpha"]?["nested"]?["text"]?.string == long
                   && json["beta"]?["flag"]?.bool == true && copied.contains("\n  \"alpha\": {"),
                   "JSON copy must preserve types and include complete values beyond visible field/text pages")
        try expect(!copied.contains("must-not-copy") && json["beta"]?["image"]?["mimeType"]?.string == "image/png",
                   "Complete JSON copy must still omit nested credentials and image bytes")
        try expect(state.detail == visible && state.detail?.jsonCopy == nil && !state.isCopyingJSON,
                   "JSON copy must not replace the visible snapshot or retain its full document in display state")

        await gate.holdNext()
        let copying = Task { try await state.copyDetailJSON() }
        try await eventually("JSON copy was not held") { await gate.held }
        try expect(state.isCopyingJSON && state.detail == visible, "Pending JSON copy must retain the accepted detail")
        state.select("session:7:fixture:entry:mode-user")
        try expect(await gate.maximumActive == 1, "JSON copy and navigation must share a single in-flight reader")
        await gate.unblock()
        try expect(try await copying.value == nil, "A late JSON copy must not be delivered after selection changes")
        try await eventually("Selection queued behind JSON copy did not finish") {
            !state.isLoading && state.detail?.record.entryID == "mode-user"
        }

        var request = OMPSessionRecordRequest(file: file.path, selectedID: tool, detailExpansion: .init(expandAll: true), detailViewMode: .flat)
        let flat = try await gate.base.read(request).detail!
        try expect(flat.expandedPaths.isEmpty && flat.rows.count == 4 && flat.rows.allSatisfy { !$0.isExpanded },
                   "The reader must ignore bulk expansion in flat mode, including direct callers")
        request.address = .init(section: .input, path: [.field("many")], page: 2); request.includeJSON = true
        let arrayCopy = try await gate.base.read(request).detail!
        try expect(arrayCopy.rows.count == 15 && JSONValue.parse(arrayCopy.jsonCopy!)?.array?.count == 95,
                   "JSON copy from a flat array page must include the complete selected array")
        request.address = .init(section: .input, path: textPath, page: 1)
        let textCopy = try await gate.base.read(request).detail!
        try expect(textCopy.text!.unicodeScalars.count < long.unicodeScalars.count && JSONValue.parse(textCopy.jsonCopy!)?.string == long,
                   "JSON copy from a text page must encode the complete string as valid JSON")
        let limitFile = root.appendingPathComponent("bulk-limits.jsonl")
        let branches: JSONValue = .array((0..<40).map { .object(["child": .object(["value": .int($0), "password": "must-not-display"])]) })
        try data(header + [entry("bulk-response", parent: nil, fields: ["message": ["role": "assistant", "content": [
            ["type": "toolCall", "id": "bulk-call", "name": "read", "arguments": ["branches": branches]]]]])]).write(to: limitFile)
        request = .init(file: limitFile.path, selectedID: "session:7:fixture:tool:bulk-response:0", detailExpansion: .init(expandAll: true))
        let limited = try await gate.base.read(request).detail!
        try expect(limited.isLimited && limited.expandedPaths.count == 64 && limited.rows.count <= 400
                   && !limited.copyText.contains("must-not-display"), "Bulk expansion must enforce branch/row budgets and nested credential exclusions")
        request = .init(file: root.appendingPathComponent("inline.jsonl").path, selectedID: "session:7:fixture:tool:inline-response:0",
                        detailExpansion: .init(expandAll: true))
        let textLimited = try await gate.base.read(request).detail!
        try expect(textLimited.isLimited && textLimited.rows.compactMap(\.text).reduce(0, { $0 + $1.unicodeScalars.count }) <= 65_536,
                   "Bulk expansion must share the existing long-text budget")

        var deep: JSONValue = "leaf"
        for _ in 0...OMPSessionRecordReader.maximumJSONCopyDepth { deep = .object(["next": deep]) }
        let deepFile = root.appendingPathComponent("json-copy-depth.jsonl")
        try data(header + [entry("deep-response", parent: nil, fields: ["message": ["role": "assistant", "content": [
            ["type": "toolCall", "id": "deep-call", "name": "read", "arguments": ["deep": deep]]]]])]).write(to: deepFile)
        do {
            _ = try await gate.base.read(.init(file: deepFile.path, selectedID: "session:7:fixture:tool:deep-response:0", includeJSON: true))
            throw HistoryFailure(description: "Oversized JSON copy must fail rather than silently truncate")
        } catch let failure as OMPSessionRecordError {
            try expect(failure == .jsonCopyTooLarge, "JSON export must report its own depth/size limit")
        }
    }

    private static func treeChecks(root: URL) async throws {
        let file = root.appendingPathComponent("tree.jsonl")
        var rows = header + [entry("setup", parent: nil, type: "model_change", fields: ["model": "fixture"]),
            user("round-a", parent: "setup", text: "Repeated prompt"),
            entry("tree-response", parent: "round-a", fields: ["message": ["role": "assistant", "stopReason": "toolUse", "content": [
                ["type": "toolCall", "id": "tree-call", "name": "read", "arguments": ["path": "source.swift"]]]]]),
            entry("tree-result", parent: "tree-response", fields: ["message": ["role": "toolResult", "toolCallId": "tree-call", "toolName": "read", "content": "source"]])]
        var parent = "tree-result"
        for index in 0..<950 {
            let id = "tree-event-\(index)"
            rows.append(entry(id, parent: parent, type: "custom", fields: ["content": .string("Event \(index)")]))
            parent = id
        }
        rows.append(user("round-b", parent: parent, text: "Repeated prompt"))
        rows.append(entry("tree-final", parent: "round-b", fields: ["message": ["role": "assistant", "stopReason": "stop", "content": "Finished"]]))
        try data(rows).write(to: file)
        let reader = OMPSessionRecordReader(root: root)
        let flat = try await reader.read(.init(file: file.path, filter: .init(kind: .tool)))
        let tool = flat.records[0], roundA = "session:7:fixture:entry:round-a", roundB = "session:7:fixture:entry:round-b"
        let response = "session:7:fixture:entry:tree-response"
        try expect(tool.roundID == roundA && tool.parentRecordID == response, "A native tool block lost its exact round/response ownership")
        var request = OMPSessionRecordRequest(file: file.path, viewMode: .tree)
        let initial = try await reader.read(request)
        try expect(initial.totalRounds == 2 && initial.totalRoots == 3 && initial.treeRows.filter { $0.depth == 0 }.count == 3,
                   "Repeated user text must form separate roots, with pre-round session events")
        request.expandedRecordIDs = [roundA, roundB, response]
        var page = try await reader.read(request)
        try expect(page.treeRows.contains { $0.id == tool.id && $0.depth == 2 }
                   && page.treeRows.contains { $0.continuationParentID == roundA }, "A long round must retain its root and append a scoped continuation")
        request.childPages[roundA] = 23
        page = try await reader.read(request)
        try expect(page.treeRows.contains { $0.record.entryID == "tree-event-949" }
                   && page.treeRows.contains { $0.continuationParentID == roundA && $0.page == 23 && $0.pageCount == 24 }
                   && page.treeRows.count < OMPSessionRecordTree.maximumRows,
                   "A very long round must reach its final child page without unbounded rows")
        let originalOrder = page.treeRows.filter { $0.record.roundID == roundA }.map(\.id)
        request.sortOrder = .newestFirst
        page = try await reader.read(request)
        try expect(page.treeRows.first?.id == roundB && page.treeRows.filter { $0.record.roundID == roundA }.map(\.id) == originalOrder,
                   "Newest-first must reverse roots without reversing their internal execution")
        request.filter = .init(kind: .tool); request.expandedRecordIDs = []
        page = try await reader.read(request)
        try expect(page.total == 1 && page.treeRows.map(\.id) == [roundA, response, tool.id]
                   && page.treeRows.prefix(2).allSatisfy(\.isContext), "Filtering must reveal exact ancestors without counting them as matching records")
        request.collapsedRecordIDs = [roundA]
        try expect(try await reader.read(request).treeRows.map(\.id) == [roundA], "A filtered ancestor must still be collapsible")

        let paging = root.appendingPathComponent("tree-pages.jsonl")
        try data(header + (0..<25).map { user("root\($0)", parent: $0 == 0 ? nil : "root\($0 - 1)", text: "Round \($0)") }).write(to: paging)
        let first = try await reader.read(.init(file: paging.path, viewMode: .tree))
        let last = try await reader.read(.init(file: paging.path, page: 1, viewMode: .tree))
        try expect(first.treeRows.count == 20 && last.treeRows.count == 5 && first.pageCount == 2 && first.totalRounds == 25,
                   "Tree pages must count complete rounds rather than flat records")
        let anchor = "session:7:fixture:entry:root23"
        try expect(try await reader.read(.init(file: paging.path, anchor: anchor, viewMode: .tree)).page == 1,
                   "A native reading anchor must resolve to its complete round page")
    }

    private static func inlineDetailChecks(root: URL) async throws {
        let file = root.appendingPathComponent("inline.jsonl")
        let long = String(repeating: "日志😀 line\n", count: 6_000)
        var args: [String: JSONValue] = ["alpha": ["same": ["text": .string(long)]], "beta": ["same": ["text": "Second branch"]],
            "many": .array((0..<750).map(JSONValue.int)), "private": ["password": "must-not-display", "ok": true]]
        for index in 0..<8 { args["text\(index)"] = .string(long) }
        try data(header + [user("inline-user", parent: nil, text: "Inspect structured values"),
            entry("inline-response", parent: "inline-user", fields: ["message": ["role": "assistant", "content": [
                ["type": "toolCall", "id": "inline-call", "name": "read", "arguments": .object(args)]]]])]).write(to: file)
        let gate = HistoryGate(root: root), state = SessionHistoryStore(reader: gate, watchRoot: root)
        defer { state.suspend() }
        let sources = [OMPSessionRecordSource(id: "inline", title: "Inline", file: file.path)]
        state.present(sources: sources)
        try await eventually("Tree mode did not become ready") { !state.isLoading && !state.treeRows.isEmpty }
        try expect(state.viewMode == .tree, "The history pane must default to the new tree view")
        let tool = "session:7:fixture:tool:inline-response:0"
        state.select(tool)
        try await eventually("Inline tool detail did not load") { !state.isLoading && state.detail?.record.id == tool }
        let before = state.detail
        await gate.holdNext(); state.toggleDetail([.field("alpha")])
        try await eventually("Inline expansion was not held") { await gate.held }
        state.toggleDetail([.field("beta")])
        try expect(state.detail == before, "A pending expansion must retain its complete accepted snapshot")
        await gate.unblock()
        try await eventually("Sibling expansion was lost to a late read") {
            !state.isLoading && state.detail?.rows.filter { $0.isExpanded }.count == 2
        }
        func expand(_ path: [OMPSessionDetailKey]) async throws {
            state.toggleDetail(path)
            try await eventually("Inline branch did not expand: \(path)") { !state.isLoading && state.detail?.rows.contains { $0.path == path && $0.isExpanded } == true }
        }
        try await expand([.field("alpha"), .field("same")])
        let textPath: [OMPSessionDetailKey] = [.field("alpha"), .field("same"), .field("text")]
        try await expand(textPath)
        let text = state.detail!.rows.first { $0.path == textPath }!
        try expect(text.text!.unicodeScalars.count == 16_384 && text.pageCount > 1 && state.detail!.address.path.isEmpty,
                   "Continuous expansion must remain in place and read only a bounded Unicode text page")
        state.detailBranchPage(textPath, page: 1)
        try await eventually("Inline text paging did not commit") { !state.isLoading && state.detail?.rows.first { $0.path == textPath }?.page == 1 }
        state.toggleDetail(textPath)
        state.detailBranchPage(textPath, page: 2)
        try await eventually("Closing a text branch did not commit") { !state.isLoading && state.detail?.rows.first { $0.path == textPath }?.isExpanded == false }
        try await expand(textPath)
        try expect(state.detail?.rows.first { $0.path == textPath }?.page == 0,
                   "A stale pager action must not change a branch that is closing")
        state.detailBranchPage(textPath, page: 1)
        try await eventually("Restored text page did not commit") { !state.isLoading && state.detail?.rows.first { $0.path == textPath }?.page == 1 }
        try await expand([.field("beta"), .field("same")])
        try expect(Set(state.detail!.rows.map(\.id)).count == state.detail!.rows.count,
                   "Identical nested keys in sibling branches must not share row identity")
        try await expand([.field("private")])
        try expect(!state.detail!.copyText.contains("must-not-display") && !state.detail!.rows.contains { $0.key.title == "password" },
                   "Inline expansion bypassed nested credential-field exclusion")
        try await expand([.field("many")])
        let outline = state.detail!.outlineRows
        let more = outline.firstIndex { $0.isContinuation && $0.row.key.title == "many" }!
        let many = outline.firstIndex { !$0.isContinuation && $0.row.key.title == "many" }!
        try expect(more > many + 40, "A field continuation must follow its visible subtree")
        state.detailBranchPage([.field("many")], page: 18)
        try await eventually("Inline array paging did not reach the final values") {
            !state.isLoading && state.detail?.rows.contains { $0.path == [.field("many"), .index(749)] } == true
        }
        try expect(state.detail!.rows.filter { $0.path.first == .field("many") && $0.path.count > 1 }.count == 30,
                   "A large array page must keep a bounded window rather than append every preceding value")
        state.setViewMode(.flat)
        try await eventually("Flat view switch lost the selected detail") { !state.isLoading && state.totalRounds == nil && state.detail?.record.id == tool }
        state.setViewMode(.tree)
        try await eventually("Returning to tree view lost expanded detail") { !state.isLoading && state.totalRounds == 1 && state.detail?.rows.first { $0.path == textPath }?.page == 1 }
        state.select(nil); state.select(tool)
        try await eventually("Returning from the overview lost inline state") { !state.isLoading && state.detail?.rows.first { $0.path == textPath }?.page == 1 }
        let other = root.appendingPathComponent("inline-other.jsonl")
        var otherHeader = header
        otherHeader[1] = ["type": "session", "id": "other", "version": 3, "cwd": "/isolated"]
        try data(otherHeader + [user("other-user", parent: nil, text: "Other source")]).write(to: other)
        state.updateSources(sources + [.init(id: "other", title: "Other", file: other.path)])
        state.selectSource("other")
        try await eventually("Other source did not load") { !state.isLoading && state.records.first?.entryID == "other-user" }
        try expect(state.detail == nil, "Another source inherited the previous source's selected detail")
        state.selectSource("inline")
        try await eventually("Returning source lost its branch state") {
            !state.isLoading && state.detail?.record.id == tool && state.detail?.rows.first { $0.path == textPath }?.page == 1
        }

        var request = OMPSessionRecordRequest(file: file.path, selectedID: tool)
        request.detailExpansion.paths = Set((0..<8).map { [.field("text\($0)")] })
        let bounded = try await gate.base.read(request).detail!
        try expect(bounded.isLimited && bounded.rows.compactMap(\.text).reduce(0, { $0 + $1.unicodeScalars.count }) <= 65_536,
                   "Simultaneous long values must share a total text budget")
    }

    private static func treeLayoutChecks(root: URL, output: URL) async throws {
        let geometry = SessionHistoryTreeGeometry(depth: 2, step: 14, maximumIndent: 56)
        let segments = geometry.segments(height: 240, anchorY: 19, ancestors: [false, true], last: true, expanded: true)
        try expect(segments.contains { $0.from == CGPoint(x: geometry.markerX - 14, y: 19) && $0.to.y == 19 }
                   && segments.contains { $0.from == CGPoint(x: geometry.markerX, y: 26) && $0.to.y == 240 },
                   "Elbows and child connectors must share the disclosure's center and stop correctly for the last sibling")
        try expect(geometry.segments(height: 80, anchorY: 20, ancestors: [false, true], last: true, expanded: false, hasDisclosure: false)
            .contains { $0.from.y == 20 && $0.to == CGPoint(x: geometry.gutterWidth + 5, y: 20) },
                   "A leaf connector must reach the content inset rather than stop before an absent disclosure")
        let deep = SessionHistoryTreeGeometry(depth: 12, step: 12, maximumIndent: 36)
        try expect(deep.gutterWidth == 60 && deep.segments(height: 280, anchorY: 18, ancestors: Array(repeating: true, count: 12), last: false, expanded: true)
            .allSatisfy { $0.from.x >= 0 && $0.to.x <= deep.gutterWidth + 9 }, "Deep connectors may not consume unbounded narrow-column width")
        let file = root.appendingPathComponent("inline.jsonl")
        let gate = HistoryGate(root: root)
        let state = SessionHistoryStore(reader: gate, watchRoot: root)
        let previews = FilePreviewStore(persistenceURL: output.appendingPathComponent("tree-previews.json"))
        previews.setContext(.init(threadID: UUID(), workingDirectory: root.path)); previews.openPanel(.trajectory)
        let session = previews.session!, model = AppModel()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = FrameHostingView(rootView: AnyView(SessionHistoryPane(previews: previews, session: session, state: state,
            sourceOverride: [.init(id: "inline-layout", title: "Tree fixture", file: file.path)])
            .modifier(HostedEnvironment(model: model, liveResize: WindowLiveResize(window: window), previews: previews))
            .background(Color(nsColor: .windowBackgroundColor))))
        window.contentView = host
        defer { state.suspend(); previews.suspend(); window.contentView = nil; window.close() }
        try await eventually("Tree layout did not load") { host.layoutSubtreeIfNeeded(); return !state.isLoading && !state.treeRows.isEmpty }
        state.select("session:7:fixture:tool:inline-response:0")
        try await eventually("Tree detail did not load") { !state.isLoading && state.detail != nil }
        for path: [OMPSessionDetailKey] in [[.field("alpha")], [.field("alpha"), .field("same")], [.field("alpha"), .field("same"), .field("text")]] {
            state.toggleDetail(path)
            try await eventually("Layout branch did not load") { !state.isLoading && state.detail?.rows.contains { $0.path == path && $0.isExpanded } == true }
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
        guard let textScroll = descendants(host).compactMap({ $0 as? NSScrollView }).first(where: { $0.accessibilityIdentifier() == "session-history.text-value" }),
              let editor = textScroll.documentView as? NSTextView else { throw HistoryFailure(description: "Expanded long text has no native scrollable reader") }
        try expect(!editor.isEditable && editor.isSelectable && textScroll.bounds.height <= 240.5
                   && editor.bounds.height > textScroll.bounds.height, "Long text must wrap in a capped, selectable, read-only scrolling region")
        editor.setSelectedRange(.init(location: 8, length: 12))
        textScroll.contentView.scroll(to: .init(x: 0, y: 80)); textScroll.reflectScrolledClipView(textScroll.contentView)
        let origin = textScroll.contentView.bounds.origin
        state.toggleDetail([.field("beta")])
        try await eventually("Sibling layout expansion did not finish") { !state.isLoading && state.detail?.rows.contains { $0.key.title == "beta" && $0.isExpanded } == true }
        host.layoutSubtreeIfNeeded()
        try expect(descendants(host).contains { $0 === textScroll } && editor.selectedRange() == NSRange(location: 8, length: 12)
                   && abs(textScroll.contentView.bounds.origin.y - origin.y) < 1, "Expanding a sibling replaced or moved an existing text selection/viewport")
        for width in [360, 1000] {
            previews.setFullscreen(width == 1000); window.setContentSize(.init(width: width, height: 600))
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
            guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw HistoryFailure(description: "No tree bitmap") }
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("history-tree-\(width).png"))
            try expect(!window.isVisible, "Tree acceptance must remain offscreen")
        }
        func toolbarPixels() throws -> Data {
            let rect = NSRect(x: 0, y: host.isFlipped ? 0 : host.bounds.height - 44, width: host.bounds.width, height: 44)
            guard let image = host.bitmapImageRepForCachingDisplay(in: rect) else { throw HistoryFailure(description: "No toolbar bitmap") }
            host.cacheDisplay(in: rect, to: image)
            guard let bytes = image.bitmapData else { throw HistoryFailure(description: "No toolbar pixels") }
            return Data(bytes: bytes, count: image.bytesPerRow * image.pixelsHigh)
        }
        let beforeModeChange = try toolbarPixels()
        await gate.holdNext(); state.setDetailViewMode(.flat)
        try await eventually("Hosted mode change was not held") { await gate.held }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        try expect(try toolbarPixels() == beforeModeChange,
                   "Pending detail-mode changes must not dim or repaint the retained section/copy toolbar")
        await gate.unblock()
        try await eventually("Flat detail layout did not become ready") { !state.isLoading && state.detail?.viewMode == .flat }
        for width in [360, 1000] {
            previews.setFullscreen(width == 1000); window.setContentSize(.init(width: width, height: 600))
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
            guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw HistoryFailure(description: "No flat detail bitmap") }
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("history-flat-detail-\(width).png"))
            try expect(!window.isVisible && state.viewMode == .tree, "Flat detail layout may not show a window or change the list's tree mode")
        }
    }

    private static func presentationChecks(root: URL) async throws {
        let file = root.appendingPathComponent("presentation.jsonl")
        try data(header + presentationRows(parent: nil)).write(to: file)
        let reader = OMPSessionRecordReader(root: root)
        let snapshot = try await reader.read(.init(file: file.path))
        let byEntry = Dictionary(snapshot.records.filter { $0.kind != .tool }.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
        try expect(snapshot.total == 12 && snapshot.records.filter { $0.kind == .response }.count == 7
                   && ["p-empty-start", "p-dot-start"].allSatisfy { byEntry[$0] == nil },
                   "Every assistant envelope must remain one response while matched starts fold into tools")
        try expect(byEntry["p-custom"]?.title == "custom" && byEntry["p-malformed-start"]?.title == "custom", "Unknown or malformed custom records must remain inspectable")
        try expect(byEntry["p-prose"]?.summary.trimmingCharacters(in: .whitespacesAndNewlines) == "I will inspect the repository.", "Meaningful assistant prose must remain a list row")
        try expect(byEntry["p-standalone-dot"]?.kind == .response && byEntry["p-standalone-dot"]?.summary == ""
                   && byEntry["p-dot"]?.summary == "", "Dot-only responses must remain selectable without a dot summary")
        try expect(byEntry["p-failed"]?.status == .failed && byEntry["p-cancelled"]?.status == .cancelled,
                   "Empty failed and cancelled responses must retain their native status")
        let tools = snapshot.records.filter { $0.kind == .tool }
        try expect(tools.count == 3 && tools.filter { $0.status == .completed }.count == 2, "Folded starts may not duplicate calls or break exact result correlation")
        let empty = tools.first { $0.toolCallID == "p-empty-call" }!
        var request = OMPSessionRecordRequest(file: file.path, selectedID: empty.id)
        let toolDetail = try await reader.read(request).detail!
        try expect(toolDetail.address.section == .input && !toolDetail.sections.contains(.message) && !toolDetail.sections.contains(.thinking),
                   "Tool details must contain tool input without repeating their model response")
        request.address.section = .executionStart
        try expect(try await reader.read(request).detail?.rows.contains { $0.key.title == "intent" && $0.preview == "Inspect workspace" } == true, "Folded execution intent must remain in tool details")
        request.address = .init(section: .metadata, path: [.field("executionStartEntries"), .index(0)])
        try expect(try await reader.read(request).detail?.rows.contains { $0.key.title == "id" && $0.preview == "p-empty-start" } == true, "Merged start entry identity must remain inspectable")
        request.selectedID = byEntry["p-dot"]!.id; request.address = .init(section: .message)
        try expect(try await reader.read(request).detail?.text == "", "Dot-only model prose must display as empty, including surrounding whitespace")
        request.address.section = .thinking
        try expect(try await reader.read(request).detail?.text == "Read the source", "Native reasoning must remain in its model response")
        request.address = .init()
        try expect(try await reader.read(request).detail?.address.section == .thinking,
                   "A dot placeholder must not hide available response reasoning")
        request.selectedID = tools.first { $0.toolCallID == "p-dot-call" }!.id
        request.address = .init(section: .input, path: [.field("path")])
        try expect(try await reader.read(request).detail?.text == ".", "A literal dot tool path must remain intact")
        request.address = .init(section: .output)
        try expect(try await reader.read(request).detail?.text == ".", "Tool output must not be mistaken for placeholder model prose")
        request.selectedID = "session:7:fixture:entry:p-dot"; request.address.section = .message
        try expect(try await reader.read(request).detail?.record.id == byEntry["p-dot"]!.id, "A response selection must keep its own identity")
        request.selectedID = byEntry["p-empty"]!.id; request.address = .init()
        let emptyResponse = try await reader.read(request).detail!
        try expect(emptyResponse.address.section == .thinking && emptyResponse.text == "Inspect the workspace first",
                   "A response without text must open its available reasoning")
        request.selectedID = byEntry["p-blank"]!.id
        try expect(try await reader.read(request).detail?.address.section == .metadata,
                   "A completely empty response must still open its native metadata")
        request.selectedID = "session:7:fixture:entry:p-empty-start"; request.address = .init(section: .result)
        let redirected = try await reader.read(request).detail!
        try expect(redirected.record.id == empty.id && redirected.address.section == .executionStart, "A folded start selection must resolve to execution details")
        request.selectedID = byEntry["p-standalone-dot"]!.id; request.address = .init(section: .message)
        try expect(try await reader.read(request).detail?.text == "", "Standalone dot replies must display an empty message")
        request.address = .init()
        try expect(try await reader.read(request).detail?.address.section == .metadata,
                   "A dot-only response without reasoning must open its metadata")
        let store = SessionHistoryStore(reader: reader, watchRoot: root, viewMode: .flat)
        store.present(sources: [.init(id: "folded", title: "Folded tools", file: file.path)])
        store.select("session:7:fixture:entry:p-empty-start")
        try await eventually("Folded selection did not become the canonical tool") { store.selectedID == empty.id && store.detail?.address.section == .executionStart && !store.isLoading }
        store.setSection(.output)
        try await eventually("Canonical tool selection kept redirecting back to start details") { store.detail?.text == "workspace" && !store.isLoading }
        store.select(byEntry["p-empty"]!.id)
        try await eventually("Response reasoning did not remain independently selectable") { store.detail?.text == "Inspect the workspace first" && !store.isLoading }
        store.suspend()
    }

    private static func mergingChecks(root: URL) async throws {
        let file = root.appendingPathComponent("merged-tools.jsonl"), reader = OMPSessionRecordReader(root: root)
        let assistant: JSONValue = ["role": "assistant", "stopReason": "toolUse", "content": [
            ["type": "text", "text": " . \n… "], ["type": "thinking", "thinking": "Parallel reasoning"],
            ["type": "toolCall", "id": "parallel-a", "name": "bash", "arguments": ["command": "A"]],
            ["type": "toolCall", "id": "parallel-b", "name": "read", "arguments": ["path": "B"]]]]
        let rows = header + [entry("parallel", parent: nil, fields: ["message": assistant]),
            entry("start-b1", parent: "parallel", type: "custom", fields: ["customType": "tool_execution_start", "data": ["toolName": "read", "toolCallId": "parallel-b", "attempt": 1]]),
            entry("start-a", parent: "start-b1", type: "custom", fields: ["customType": "tool_execution_start", "data": ["toolName": "bash", "toolCallId": "parallel-a", "intent": "Run A"]]),
            entry("start-b2", parent: "start-a", type: "custom", fields: ["customType": "tool_execution_start", "data": ["toolName": "read", "toolCallId": "parallel-b", "attempt": 2]]),
            entry("result-a", parent: "start-b2", fields: ["message": ["role": "toolResult", "toolName": "bash", "toolCallId": "parallel-a", "content": "Output A", "isError": true]]),
            entry("result-b", parent: "result-a", fields: ["message": ["role": "toolResult", "toolName": "read", "toolCallId": "parallel-b", "content": "Output B", "isError": false]])]
        try data(rows).write(to: file)
        let parallel = try await reader.read(.init(file: file.path))
        try expect(parallel.total == 3 && parallel.records.map(\.kind) == [.response, .tool, .tool]
                   && parallel.records.compactMap(\.toolCallID) == ["parallel-a", "parallel-b"],
                   "One response must precede parallel tools in their native block order")
        var responseRequest = OMPSessionRecordRequest(file: file.path, selectedID: parallel.records[0].id, address: .init(section: .message))
        try expect(try await reader.read(responseRequest).detail?.text == " . \n… ", "The response must retain exact original text")
        responseRequest.address.section = .thinking
        try expect(try await reader.read(responseRequest).detail?.text == "Parallel reasoning", "Shared reasoning must belong to the response")
        for record in parallel.records where record.kind == .tool {
            var request = OMPSessionRecordRequest(file: file.path, selectedID: record.id, address: .init(section: .output))
            let sections = try await reader.read(request).detail!.sections
            try expect(!sections.contains(.message) && !sections.contains(.thinking), "Parallel tools duplicated their model response")
            let isA = record.toolCallID == "parallel-a"
            try expect(try await reader.read(request).detail?.text == (isA ? "Output A" : "Output B"), "Parallel tool outputs were joined by order instead of ID")
            try expect(record.status == (isA ? .failed : .completed), "Parallel tool statuses were mixed")
            request.address = .init(section: .executionStart)
            var detail = try await reader.read(request).detail!
            if isA {
                try expect(detail.rows.contains { $0.key.title == "toolCallId" && $0.preview == "parallel-a" }, "Start metadata belongs to another parallel call")
            } else {
                try expect(detail.rows.count == 2 && detail.rows.allSatisfy { if case .index = $0.key { return true }; return false }, "Repeated starts must remain as paged details, not extra rows")
                request.address.path = [.index(1)]
                detail = try await reader.read(request).detail!
                try expect(detail.rows.contains { $0.key.title == "attempt" && $0.preview == "2" }, "A repeated start was discarded")
            }
        }
        // Without a visible assistant, the start still represents one observed
        // tool; do not turn its projected arguments into invented full input.
        let orphan = header + [entry("orphan-start", parent: nil, type: "custom", fields: ["customType": "tool_execution_start", "data": ["toolName": "bash", "toolCallId": "orphan", "args": ["command": "pwd"]]]),
            entry("orphan-result", parent: "orphan-start", fields: ["message": ["role": "toolResult", "toolName": "bash", "toolCallId": "orphan", "content": "orphan output"]])]
        try data(orphan).write(to: file, options: .atomic)
        let observed = try await reader.read(.init(file: file.path))
        try expect(observed.total == 1 && observed.records[0].title == "bash", "An unmatched start and result must form one observed tool row")
        let observedDetail = try await reader.read(.init(file: file.path, selectedID: observed.records[0].id)).detail!
        try expect(observedDetail.sections.contains(.executionStart) && observedDetail.sections.contains(.output) && !observedDetail.sections.contains(.input), "Start argument summaries must not pretend to be full tool input")
        // An identically named start on an abandoned branch is ineligible.
        try data(header + [rows[2], entry("off-start", parent: "parallel", type: "custom", fields: ["customType": "tool_execution_start", "data": ["toolName": "bash", "toolCallId": "parallel-a"]]),
            entry("current-result", parent: "parallel", fields: ["message": ["role": "toolResult", "toolName": "bash", "toolCallId": "parallel-a", "content": "current"]])]).write(to: file, options: .atomic)
        let branch = try await reader.read(.init(file: file.path))
        try expect(branch.total == 3, "Off-branch start observations leaked into the current list")
        let branchDetail = try await reader.read(.init(file: file.path, selectedID: branch.records.first { $0.toolCallID == "parallel-a" }!.id)).detail!
        try expect(!branchDetail.sections.contains(.executionStart), "Off-branch start metadata attached to the current tool")
        // Reused call IDs stay unpaired rather than silently choosing a call.
        let duplicate: JSONValue = ["role": "assistant", "content": [["type": "toolCall", "id": "duplicate", "name": "bash", "arguments": [:]]]]
        try data(header + [entry("dup-a", parent: nil, fields: ["message": duplicate]), entry("dup-b", parent: "dup-a", fields: ["message": duplicate]),
            entry("dup-start", parent: "dup-b", type: "custom", fields: ["customType": "tool_execution_start", "data": ["toolName": "bash", "toolCallId": "duplicate"]])]).write(to: file, options: .atomic)
        let ambiguous = try await reader.read(.init(file: file.path))
        try expect(ambiguous.total == 5, "Ambiguous data was discarded or guessed into one tool")
        for call in ambiguous.records where ["dup-a", "dup-b"].contains(call.entryID) {
            try expect(try await reader.read(.init(file: file.path, selectedID: call.id)).detail?.sections.contains(.executionStart) == false, "Duplicate call IDs attached a start to an arbitrary tool")
        }
        var paged = header
        var parent: String?
        for i in 0..<81 {
            let id = "page-\(i)", start = "page-start-\(i)"
            paged.append(entry(id, parent: parent, fields: ["message": ["role": "assistant", "content": [["type": "toolCall", "id": .string(id), "name": "bash", "arguments": [:]]]]]))
            paged.append(entry(start, parent: id, type: "custom", fields: ["customType": "tool_execution_start", "data": ["toolName": "bash", "toolCallId": .string(id)]]))
            parent = start
        }
        try data(paged).write(to: file, options: .atomic)
        var request = OMPSessionRecordRequest(file: file.path)
        let first = try await reader.read(request)
        try expect(first.total == 162 && first.records.count == 80 && first.pageCount == 3,
                   "Paging must count model responses and calls once, without start markers")
        request.anchor = "session:7:fixture:entry:page-start-80"
        let anchored = try await reader.read(request)
        try expect(anchored.page == 2 && anchored.records.count == 2 && anchored.records[1].toolCallID == "page-80", "Merged start anchors must keep their chronological reading page")
        request.filter.kind = .response; request.anchor = nil
        let responses = try await reader.read(request)
        try expect(responses.total == 81 && responses.records.first?.entryID == "page-0", "Response filtering must include tool-only replies in chronological order")
    }

    private static func chronologyChecks(root: URL) async throws {
        let file = root.appendingPathComponent("chronological.jsonl")
        let rows = header + [user("prompt", parent: nil, text: "Inspect"),
            entry("reply-1", parent: "prompt", fields: ["message": ["role": "assistant", "stopReason": "toolUse", "content": [
                ["type": "thinking", "thinking": "Inspect both files"],
                ["type": "toolCall", "id": "first-call", "name": "read", "arguments": ["path": "first"]],
                ["type": "toolCall", "id": "second-call", "name": "read", "arguments": ["path": "second"]]]]], timestamp: "2026-10-24T09:30:00.124Z"),
            entry("reply-2", parent: "reply-1", fields: ["message": ["role": "assistant", "stopReason": "stop", "content": [["type": "text", "text": "Read both files"]]]], timestamp: "2026-10-24T09:30:00.126Z"),
            entry("reply-3", parent: "reply-2", fields: ["message": ["role": "assistant", "stopReason": "stop", "content": []]], timestamp: "2026-10-24T09:30:00.128Z")]
        try data(rows).write(to: file)
        let directory = OMPRequestRecordStore.directory(root: root.deletingLastPathComponent().appendingPathComponent("requests"), file: file.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let leaves = ["prompt", "reply-1", "reply-2"]
        var ids: [String] = []
        for i in leaves.indices {
            let id = UUID().uuidString.lowercased(); ids.append(id)
            let time = formatter.date(from: "2026-10-24T09:30:00.\(124 + i * 2)Z")!.timeIntervalSince1970 * 1000
            let summary: JSONValue = ["schema": 1, "id": .string(id), "sessionID": "fixture", "sessionFile": .string(file.path),
                "leafID": .string(leaves[i]), "kind": "model_request", "status": "completed", "startedAt": .double(time)]
            try summary.data().write(to: directory.appendingPathComponent(id + ".summary.json"))
        }
        let reader = OMPSessionRecordReader(root: root)
        let page = try await reader.read(.init(file: file.path))
        try expect(page.records.map(\.entryID) == ["prompt", ids[0], "reply-1", "reply-1", "reply-1", ids[1], "reply-2", ids[2], "reply-3"]
                   && page.records.map(\.kind) == [.user, .request, .response, .tool, .tool, .request, .response, .request, .response],
                   "Chronological requests must precede their model responses, including replies without text")
        try expect(page.records.compactMap(\.toolCallID) == ["first-call", "second-call"],
                   "Tied timestamps reversed parallel native tool blocks")
        let reversed = try await reader.read(.init(file: file.path, sortOrder: .newestFirst))
        try expect(reversed.records.map(\.entryID) == [ids[2], "reply-3", ids[1], "reply-2", ids[0], "reply-1", "reply-1", "reply-1", "prompt"]
                   && reversed.records.compactMap(\.toolCallID) == ["first-call", "second-call"],
                   "Descending time must preserve request/response/tool ordering within a tied timestamp")
    }

    private static func sortingChecks(root: URL) async throws {
        let file = root.appendingPathComponent("sorting.jsonl")
        let formatter = ISO8601DateFormatter()
        var rows = header
        for i in 0..<170 {
            rows.append(entry("s\(i)", parent: i == 0 ? nil : "s\(i - 1)",
                fields: ["message": ["role": "user", "content": .string("Sorted record \(i)")]],
                timestamp: formatter.string(from: Date(timeIntervalSince1970: 1_792_832_400 + Double(i)))))
        }
        try data(rows).write(to: file)
        let reader = OMPSessionRecordReader(root: root)
        let ascending = try await reader.read(.init(file: file.path))
        try expect(ascending.records.first?.entryID == "s0" && ascending.records.last?.entryID == "s79",
                   "The default order must remain oldest first")
        var request = OMPSessionRecordRequest(file: file.path, sortOrder: .newestFirst)
        let newest = try await reader.read(request)
        try expect(newest.total == 170 && newest.pageCount == 3 && newest.records.first?.entryID == "s169"
                   && newest.records.last?.entryID == "s90", "Descending paging must start with the newest 80 records")
        request.page = 2
        let oldest = try await reader.read(request)
        try expect(oldest.records.count == 10 && oldest.records.last?.entryID == "s0", "Descending final-page remainder lost the oldest records")
        request.anchor = "session:7:fixture:entry:s20"
        let anchored = try await reader.read(request)
        try expect(anchored.page == 1 && anchored.records.contains { $0.id == request.anchor }, "Descending anchors must resolve before paging")

        let gate = HistoryGate(root: root), state = SessionHistoryStore(reader: gate, watchRoot: root, viewMode: .flat)
        let sources = [OMPSessionRecordSource(id: "sorting", title: "Sorting", file: file.path)]
        state.present(sources: sources)
        defer { state.suspend() }
        try await eventually("Default sorted store did not load") { !state.isLoading && state.records.first?.entryID == "s0" }
        state.select("session:7:fixture:entry:s5")
        try await eventually("Sort fixture detail did not load") { !state.isLoading && state.detail?.text == "Sorted record 5" }
        state.goToPage(1)
        try await eventually("The reading page did not load") { !state.isLoading && state.page == 1 }
        state.scrollID = state.records.first?.id
        let detail = state.detail
        await gate.holdNext(); state.setSortOrder(.newestFirst)
        try await eventually("Sort change was not held") { await gate.held }
        try expect(state.detail == detail && state.showsDetail && state.page == 0 && state.scrollID == nil,
                   "Sorting must reset paging while retaining the accepted detail")
        await gate.unblock()
        try await eventually("Descending sort did not commit") { !state.isLoading && state.records.first?.entryID == "s169" }
        try expect(state.detail == detail && state.oldestPage == 2 && state.newestPage == 0 && !state.hasFilter
                   && state.sortOrder.previousPageTitle == "Newer records" && state.sortOrder.nextPageTitle == "Older records",
                   "Sort order changed selection, filters or time-based page actions")
        state.suspend(); state.present(sources: sources)
        try await eventually("Returning did not retain descending order") { !state.isLoading && state.records.first?.entryID == "s169" }
        await gate.holdNext(); state.setSortOrder(.oldestFirst)
        try await eventually("Superseded sort was not held") { await gate.held }
        state.setSortOrder(.newestFirst)
        await gate.unblock()
        try await eventually("A late sort replaced the latest requested order") { !state.isLoading && state.records.first?.entryID == "s169" }
    }

    private static func captionChecks(root: URL) async throws {
        let file = root.appendingPathComponent("captions.jsonl"), reader = OMPSessionRecordReader(root: root)
        let cases: [(String, JSONValue, String)] = [
            ("bash", ["command": "git status --short", "async": .null, "cwd": "/workspace", "i": "Inspect checkout"], "git status --short"),
            ("read", ["path": "Sources/Space name.swift:10:40", "offset": 10, "i": "Read file"], "Sources/Space name.swift:10:40"),
            ("edit", ["path": "source.swift", "old_string": "old", "new_string": .string(String(repeating: "replacement", count: 500))], "source.swift"),
            ("grep", ["pattern": "TODO|FIXME", "path": "Sources", "skip": .null, "case": false], "TODO|FIXME · Sources"),
            ("ast_edit", ["paths": ["a.swift", "b.swift"], "ops": [["pat": "old", "out": "new"]]], "a.swift · b.swift"),
            ("web_search", ["query": "Swift concurrency", "recency": "month"], "Swift concurrency"),
            ("eval", ["language": "py", "title": "Check dimensions", "code": "print(1 + 1)"], "Check dimensions"),
            ("todo", ["op": "complete", "task": "Build app", "reason": .null], "complete · Build app"),
            ("ask", ["questions": [["question": "Choose a format", "options": [["label": "PDF"]]]]], "Choose a format"),
            ("task", ["name": "Inspect parser", "agent": "explore", "task": "Long instructions", "solutionSpace": "details"], "Inspect parser"),
            ("write", ["path": "xd://lsp", "content": "{\"action\":\"hover\",\"file\":\"source.swift\",\"line\":12}"], "xd://lsp · hover · source.swift"),
            ("mcp__demo__search", ["query": "Find documents", "authorization": "must-not-display", "limit": 10], "Find documents"),
            ("unknown_extension", ["authorization": "must-not-display", "payload": ["secret": "hidden"], "enabled": true], "")
        ]
        let blocks: [JSONValue] = cases.enumerated().map { i, value in
            ["type": "toolCall", "id": .string("caption-\(i)"), "name": .string(value.0), "arguments": value.1]
        }
        try data(header + [entry("calls", parent: nil, fields: ["message": ["role": "assistant", "stopReason": "toolUse", "content": .array(blocks)]]),
            entry("level", parent: "calls", type: "thinking_level_change", fields: ["thinkingLevel": "xhigh"])]).write(to: file)
        let page = try await reader.read(.init(file: file.path))
        for (i, expected) in cases.enumerated() {
            let record = page.records.first { $0.toolCallID == "caption-\(i)" }!
            try expect(record.summary == expected.2 && record.summary.unicodeScalars.count <= 512,
                       "\(expected.0) did not retain only its bounded operation subject")
        }
        try expect(page.records.last?.summary == "xhigh", "Thinking changes must expose the new level")
        let edit = page.records.first { $0.title == "edit" }!
        let details = try await reader.read(.init(file: file.path, selectedID: edit.id,
            address: .init(section: .input, path: [.field("new_string")]))).detail!
        try expect(details.text == String(repeating: "replacement", count: 500), "Short captions discarded full tool arguments")
    }

    private static func finalReplyChecks(root: URL) async throws {
        let file = root.appendingPathComponent("final-replies.jsonl"), reader = OMPSessionRecordReader(root: root)
        func reply(_ id: String, parent: String, stop: String?, text: String, tool: Bool = false) -> JSONValue {
            var blocks: [JSONValue] = [["type": "text", "text": .string(text)]]
            if tool { blocks.append(["type": "toolCall", "id": .string(id + "-call"), "name": "read", "arguments": ["path": "source.swift"]]) }
            var message: [String: JSONValue] = ["role": "assistant", "content": .array(blocks)]
            if let stop { message["stopReason"] = .string(stop) }
            return entry(id, parent: parent, fields: ["message": .object(message)])
        }
        let rows = header + [user("u1", parent: nil, text: "First round"),
            reply("preliminary", parent: "u1", stop: "stop", text: "An intermediate answer"),
            reply("tools", parent: "preliminary", stop: "toolUse", text: "Inspecting", tool: true),
            reply("final-1", parent: "tools", stop: "stop", text: "First final answer"),
            entry("level", parent: "final-1", type: "thinking_level_change", fields: ["thinkingLevel": "high"]),
            user("u2", parent: "level", text: "Second round"),
            reply("final-2", parent: "u2", stop: "stop", text: "Second final answer"),
            user("u3", parent: "final-2", text: "Third round"),
            reply("length", parent: "u3", stop: "length", text: "Truncated"),
            reply("failed", parent: "length", stop: "error", text: "Failed"),
            reply("cancelled", parent: "failed", stop: "aborted", text: "Cancelled"),
            reply("dot", parent: "cancelled", stop: "stop", text: "."),
            reply("inconsistent-tools", parent: "dot", stop: "stop", text: "Read next", tool: true),
            reply("unknown-stop", parent: "inconsistent-tools", stop: nil, text: "Unconfirmed")]
        try data(rows).write(to: file)
        var request = OMPSessionRecordRequest(file: file.path, filter: .init(kind: .response))
        let page = try await reader.read(request)
        try expect(page.records.filter(\.isFinalReply).map(\.entryID) == ["final-1", "final-2"],
                   "Only the final successful prose reply in each native user round may be marked final")
        try expect(page.records.allSatisfy { $0.symbol == ($0.isFinalReply ? "ellipsis.message" : "message") },
                   "Final and intermediate replies must use their distinct symbols")
        try expect(NSImage(systemSymbolName: "ellipsis.message", accessibilityDescription: nil) != nil, "The requested final reply symbol is unavailable")
        request.filter.query = "First final answer"
        let filtered = try await reader.read(request)
        try expect(filtered.records.count == 1 && filtered.records[0].isFinalReply, "Filtering changed a native round's final reply")
        request.selectedID = filtered.records[0].id
        try expect(try await reader.read(request).detail?.text == "First final answer", "Final reply details lost their original text")
    }

    private static func captureChecks(root: URL) async throws {
        let file = root.appendingPathComponent("captured.jsonl")
        let rows = header + [user("first", parent: nil, text: "prompt"), user("off", parent: "first", text: "off branch"),
                             user("current", parent: "first", text: "current branch")]
        try data(rows).write(to: file)
        let directory = root.deletingLastPathComponent().appendingPathComponent("requests/" + OMPRequestRecordStore.directoryName(file.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var ids: [String] = []
        func write(_ id: String, leaf: String, sessionID: String = "fixture", status: String = "completed",
                   kind: String = "model_request", pid: Int = 2147483647, ownerID: String? = nil,
                   sections: [String: JSONValue]? = nil, time: Double) throws {
            var fields: [String: JSONValue] = ["schema": 1, "id": .string(id), "sessionID": .string(sessionID), "sessionFile": .string(file.path),
                "leafID": .string(leaf), "kind": .string(kind), "status": .string(status), "model": "fixture-model", "provider": "fixture",
                "startedAt": .double(time), "updatedAt": .double(time), "pid": .int(pid), "tokens": 18]
            if let ownerID { fields["ownerID"] = .string(ownerID) }
            fields["sections"] = .object(sections ?? ["requestContext": ["messages": ["prompt"]], "requestPayload": .object(Dictionary(uniqueKeysWithValues: (0..<95).map { ("field\($0)", .int($0)) })),
                             "requestOutput": ["text": .string(String(repeating: "中文😀", count: 9000))], "capture": ["truncated": false]])
            let value = JSONValue.object(fields)
            try Data(value.compactString.utf8).write(to: directory.appendingPathComponent(id + ".json"), options: .atomic)
            var summary = fields; summary.removeValue(forKey: "sections")
            try Data(JSONValue.object(summary).compactString.utf8).write(to: directory.appendingPathComponent(id + ".summary.json"), options: .atomic)
        }
        for i in 0..<82 {
            let id = UUID().uuidString.lowercased(); ids.append(id)
            try write(id, leaf: "current", status: i == 81 ? "running" : "completed", time: 1_800_000_000_000 + Double(i))
        }
        try write(UUID().uuidString.lowercased(), leaf: "off", time: 1_800_000_000_100)
        try write(UUID().uuidString.lowercased(), leaf: "current", sessionID: "another", time: 1_800_000_000_101)
        let reader = OMPSessionRecordReader(root: root)
        var request = OMPSessionRecordRequest(file: file.path, filter: .init(kind: .request))
        var page = try await reader.read(request)
        try expect(page.total == 82 && page.records.count == 80 && page.records.first?.entryID == ids[0], "Capture paging or exact session/branch identity failed")
        let tree = try await reader.read(.init(file: file.path, filter: .init(kind: .request), viewMode: .tree))
        try expect(tree.totalRounds == 1 && tree.treeRows.filter { $0.record.kind == .request }.allSatisfy {
            $0.record.roundID == "session:7:fixture:entry:current" && $0.record.parentRecordID == nil && $0.depth == 1
        }, "Request dispatch leaves must locate the exact round without inventing response ownership")
        request.page = 1
        page = try await reader.read(request)
        try expect(page.records.count == 2 && page.records.last?.entryID == ids[81] && page.records.last?.status == .interrupted,
                   "Captured requests lost their chronological second page or interrupted status")
        request.selectedID = page.records.last!.id; request.address.section = .requestPayload
        var detail = try await reader.read(request).detail!
        try expect(detail.rows.count == 40 && detail.pageCount == 3, "Request payload fields must be lazy and paged")
        request.address = .init(section: .requestOutput, path: [.field("text")], page: 1)
        detail = try await reader.read(request).detail!
        try expect(detail.text!.unicodeScalars.count <= 16_384 && detail.pageCount == 2, "Request output must reuse bounded Unicode pages")
        request.filter.query = "fixture-model"; request.page = 0
        let searched = try await reader.read(request)
        try expect(searched.total == 82, "Request model search lost rows")
        // A new native header at the same path cannot adopt previous captures.
        try data([.object(["type": "session", "id": "replacement", "version": 3]), user("current", parent: nil, text: "new")]).write(to: file)
        let replaced = try await reader.read(request)
        try expect(replaced.total == 0, "New session reused captures from an older header")
        try data(rows).write(to: file)
        let corrupt = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".summary.json")
        try Data("{".utf8).write(to: corrupt)
        request.selectedID = nil
        page = try await reader.read(request)
        try expect(page.total == 82 && page.captureWarning, "One corrupt capture must not hide readable history")
        let store = SessionHistoryStore(reader: reader, watchRoot: root, viewMode: .flat)
        store.present(sources: [.init(id: "captures", title: "Captures", file: file.path)])
        store.setKind(.request)
        try await eventually("Capture source did not load") { !store.isLoading && store.total == 82 }
        try write(UUID().uuidString.lowercased(), leaf: "current", time: 1_800_000_000_200)
        try Data("revision".utf8).write(to: directory.deletingLastPathComponent().appendingPathComponent(".revision"), options: .atomic)
        try await eventually("Capture revision did not refresh without a native journal write") { !store.isLoading && store.total == 83 }
        store.suspend()

        let document = directory.appendingPathComponent(ids[0] + ".json")
        try FileManager.default.removeItem(at: document)
        try FileManager.default.createSymbolicLink(at: document, withDestinationURL: file)
        request.selectedID = "session:7:fixture:request:" + ids[0]
        let rejected = try await reader.read(request)
        try expect(rejected.captureWarning && rejected.total == 83 && rejected.detail?.copyText.contains("capture_unavailable") == true,
                   "Unsafe capture detail must be rejected without hiding native history")

        // A health mark belongs to one session, expires without a writer, and
        // never promotes a process or another session's failure.
        try FileManager.default.removeItem(at: corrupt)
        let capturesRoot = root.deletingLastPathComponent().appendingPathComponent("requests")
        let healthName = OMPRequestRecordStore.directoryName(
            URL(fileURLWithPath: file.path).standardizedFileURL.resolvingSymlinksInPath().path) + ".health.json"
        let health = capturesRoot.appendingPathComponent(healthName)
        request = .init(file: file.path)
        try Data("{}".utf8).write(to: health)
        try expect(try await reader.read(request).captureWarning, "A session health mark must warn that session")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: health.path)
        try expect(!(try await reader.read(request).captureWarning), "Stale session health must expire without a writer")
        try FileManager.default.removeItem(at: health)
        let otherHealth = capturesRoot.appendingPathComponent(String(repeating: "a", count: 64) + ".health.json")
        try Data("{}".utf8).write(to: otherHealth)
        try expect(!(try await reader.read(request).captureWarning), "Another session's health must not leak")
        try FileManager.default.removeItem(at: otherHealth)
        let processHealth = capturesRoot.appendingPathComponent(UUID().uuidString.lowercased() + ".health.json")
        try Data("{}".utf8).write(to: processHealth)
        try expect(!(try await reader.read(request).captureWarning), "Process-level health must stay out of session history")
        try FileManager.default.removeItem(at: processHealth)

        // An already-written provider response with an empty options section
        // must still open the evidence it actually contains.
        let providerID = UUID().uuidString.lowercased()
        try write(providerID, leaf: "current", kind: "provider_response", sections: [
            "requestOptions": .object([:]),
            "responses": .array([.object(["requestId": .string("observation")])]),
            "capture": .object(["truncated": false, "redacted": false])], time: 1_800_000_000_300)
        let providerDetail = try await reader.read(.init(file: file.path, selectedID: "session:7:fixture:request:" + providerID)).detail
        try expect(providerDetail?.address.section == .responses,
                   "An old provider response with empty options must open its responses")

        // Cached running evidence must still observe a lease that ended.
        let owner = UUID().uuidString.lowercased(), runningID = UUID().uuidString.lowercased()
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        let lease = capturesRoot.appendingPathComponent(owner + ".owner.json")
        try Data(JSONValue.object(["id": .string(owner), "pid": .int(pid),
            "updatedAt": .double(Date().timeIntervalSince1970 * 1000)]).compactString.utf8).write(to: lease, options: .atomic)
        try write(runningID, leaf: "current", status: "running", pid: pid, ownerID: owner, time: 1_800_000_000_400)
        let runningRequest = OMPSessionRecordRequest(file: file.path, filter: .init(kind: .request), anchor: "session:7:fixture:request:" + runningID)
        var runningPage = try await reader.read(runningRequest)
        try expect(runningPage.records.first { $0.entryID == runningID }?.status == .running,
                   "A live lease must keep a running request")
        try FileManager.default.removeItem(at: lease)
        runningPage = try await reader.read(runningRequest)
        try expect(runningPage.records.first { $0.entryID == runningID }?.status == .interrupted,
                   "A cached running request must re-check its lease")
    }

    private static func readerChecks(file: URL, root: URL, rows: [JSONValue]) async throws {
        let reader = OMPSessionRecordReader(root: root)
        var request = OMPSessionRecordRequest(file: file.path)
        let first = try await reader.read(request)
        try expect(first.records.count == 80 && first.total == 175 && first.pageCount == 3, "Only visible current-branch records may contribute to paging")
        try expect(first.records.first?.entryID == "u0" && first.records.last?.entryID == "u79",
                   "The first page must start with the oldest native records")
        try expect(!first.records.contains { ["off-branch", "credential", "result"].contains($0.entryID) }, "Off-branch, private and paired-result entries leaked into the list")
        request.page = 2
        let last = try await reader.read(request)
        try expect(last.records.count == 15 && last.records.first?.entryID == "u160" && last.records.last?.entryID == "usage", "Pre-compaction ancestors or final page remainder were lost")
        request.filter.kind = .tool; request.page = 0
        let tools = try await reader.read(request)
        try expect(tools.total == 2 && tools.records.last?.status == .unrecorded, "Missing persisted results must not claim to be running or completed")
        let call = tools.records.first { $0.toolCallID == "exact-call" }!
        try expect(call.summary == "printf 'hello'" && tools.records.last?.summary == "/isolated/source.swift",
                   "Tool list captions must show commands and read paths without unrelated argument fields")
        try expect(call.status == .failed && call.duration == nil, "Tool result status must correlate by exact ID without inheriting assistant duration")
        request.selectedID = call.id
        let input = try await reader.read(request).detail!
        try expect(input.address.section == .input && input.rows.count == 40 && input.pageCount == 3, "Tool arguments must load as bounded field pages")
        try expect(!input.copyText.contains("must-not-display") && !input.rows.contains { $0.key.title == "api_key" }, "Sensitive field names reached the detail projection")
        request.address = .init(section: .metadata)
        let toolMetadata = try await reader.read(request).detail!
        try expect(!toolMetadata.rows.contains { ["usage", "duration", "ttft", "stopReason", "provider"].contains($0.key.title) },
                   "Shared response metadata must not be duplicated into tool details")
        request.address = .init(section: .output, page: 1)
        let output = try await reader.read(request).detail!
        try expect(output.text!.count <= OMPSessionRecordReader.textPageSize && output.pageCount > 1 && output.address.page == 1, "Tool output must be independently paged")
        request.address = .init(section: .result, path: [.field("nested")])
        let nested = try await reader.read(request).detail!
        try expect(nested.rows.map(\.key.title) == ["ok"], "Nested detail must also exclude credential fields")
        request.selectedID = "session:7:fixture:entry:assistant"; request.address = .init(section: .metadata)
        let metadata = try await reader.read(request).detail!
        try expect(metadata.rows.contains { $0.key.title == "duration" && $0.preview == "1234" }
                   && !metadata.rows.contains { $0.key.title == "providerPayload" }, "Native timing must survive without exposing provider replay data")
        request.filter = .init(query: "needle-only-in-details")
        try expect(try await reader.read(request).total == 0, "Summary search must not claim to search unloaded tool bodies")
        request.filter = .init(kind: .tool, status: .failed)
        try expect(try await reader.read(request).total == 1, "Type and status filters must intersect")
        request.filter = .init(); request.selectedID = "session:7:fixture:entry:usage"; request.address = .init(section: .metadata)
        try expect(try await reader.read(request).detail!.rows.contains { $0.key.title == "usage" }, "Standalone model usage must remain inspectable")
        request.selectedID = nil; request.page = 1
        let historical = try await reader.read(request)
        request.anchor = historical.records.first!.id
        let more = user("new", parent: "credential", text: "Newest")
        try data(rows + [more]).write(to: file)
        let anchored = try await reader.read(request)
        try expect(anchored.records.contains { $0.id == request.anchor }, "Refreshing may not strand the historical reading anchor")
        try data(rows).write(to: file)
    }

    private static func mutationChecks(file: URL, root: URL, rows: [JSONValue]) async throws {
        let reader = OMPSessionRecordReader(root: root)
        let request = OMPSessionRecordRequest(file: file.path)
        let initial = try await reader.read(request)
        let tail = user("tail", parent: "credential", text: "Tail")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: tail.data())
        try expect(try await reader.read(request).total == initial.total, "An incomplete final line became a record")
        try handle.write(contentsOf: Data([10])); try handle.close()
        let appended = try await reader.read(.init(file: file.path, page: 2))
        try expect(appended.total == initial.total + 1 && appended.records.last?.entryID == "tail", "Completed tail was not appended chronologically")
        let small = header + [user("a", parent: nil, text: "AAAA")]
        try data(small).write(to: file, options: .atomic)
        try expect(try await reader.read(request).total == 1, "Atomic truncation retained old branch entries")
        let rewritten = header + [user("a", parent: nil, text: "BBBB")]
        let overwrite = try FileHandle(forWritingTo: file)
        try overwrite.write(contentsOf: data(rewritten)); try overwrite.close()
        try expect(try await reader.read(request).records.first?.summary == "BBBB", "Same-size in-place mutation reused a stale index")
        var selected = request
        selected.selectedID = "session:7:fixture:entry:a"
        var replacementHeader = header
        replacementHeader[1] = ["type": "session", "id": "replacement", "version": 3, "cwd": "/isolated"]
        try data(replacementHeader + [user("a", parent: nil, text: "Other session")]).write(to: file, options: .atomic)
        try expect(try await reader.read(selected).detail == nil, "Replacing the native session header reused another session's selection")
        let clear = entry("clear", parent: "a", type: "model_usage", fields: ["activeLeafId": .null])
        try data(rewritten + [clear]).write(to: file)
        try expect(try await reader.read(request).total == 0, "Explicit null activeLeafId must clear the current ancestry")
        // Identical tool call IDs on the same path are ambiguous, never guessed.
        let call: JSONValue = ["role": "assistant", "content": [["type": "toolCall", "id": "same", "name": "bash", "arguments": [:]]]]
        let ambiguous = header + [entry("a", parent: nil, fields: ["message": call]), entry("b", parent: "a", fields: ["message": call]),
            entry("r", parent: "b", fields: ["message": ["role": "toolResult", "toolCallId": "same", "content": "result"]])]
        try data(ambiguous).write(to: file)
        let records = try await reader.read(request).records
        try expect(records.filter { $0.status == .unrecorded }.count == 2 && records.contains { $0.entryID == "r" }, "Ambiguous native IDs silently joined the wrong call")
        try data(rows).write(to: file)
    }

    private static func boundaryChecks(root: URL) async throws {
        let reader = OMPSessionRecordReader(root: root)
        func rejected(_ url: URL, as expected: OMPSessionRecordError) async throws {
            do { _ = try await reader.read(.init(file: url.path)); throw HistoryFailure(description: "Accepted invalid fixture \(url.lastPathComponent)") }
            catch let error as OMPSessionRecordError { try expect(error == expected, "Unexpected rejection: \(error)") }
        }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside.jsonl")
        try data(header).write(to: outside)
        let link = root.appendingPathComponent("escape.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try await rejected(link, as: .outsideStore)
        let invalid = root.appendingPathComponent("invalid.jsonl")
        for rows in [header + [user("a", parent: "missing", text: "x")],
                     header + [user("a", parent: "a", text: "x")],
                     header + [user("a", parent: nil, text: "x"), user("a", parent: nil, text: "x")]] {
            try data(rows).write(to: invalid)
            try await rejected(invalid, as: .invalidJournal)
        }
        let huge = root.appendingPathComponent("large.jsonl")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(OMPSessionRecordReader.maximumBytes + 1)); try handle.close()
        try await rejected(huge, as: .tooLarge)
        try FileManager.default.removeItem(at: huge)
        try data(header + [user("huge", parent: nil, text: String(repeating: "x", count: OMPSessionRecordReader.maximumLineBytes))]).write(to: huge)
        try await rejected(huge, as: .tooLarge)
        try FileManager.default.removeItem(at: huge)
        let crowded = (0..<2_049).map { String(format: "%08d.summary.json", $0) } + ["orphan.json", "orphan.json.tmp"]
        let bounded = OMPRequestRecordStore.summaryNames(crowded)
        try expect(bounded.truncated && bounded.names.count == 2_048 && !bounded.names.contains("orphan.json"),
                   "A crowded capture directory must truncate summaries instead of hiding every request")
        let ordinary = OMPRequestRecordStore.summaryNames(["b.summary.json", "a.summary.json", "note.json"])
        try expect(!ordinary.truncated && ordinary.names == ["a.summary.json", "b.summary.json"],
                   "Unrelated capture files must not consume the summary limit")
    }

    private static func storeChecks(file: URL, root: URL) async throws {
        let second = root.appendingPathComponent("second.jsonl")
        try data(header + [user("second", parent: nil, text: "Different session")]).write(to: second)
        let sources = [OMPSessionRecordSource(id: "first", title: "First", file: file.path), .init(id: "second", title: "Second", file: second.path)]
        let gate = HistoryGate(root: root)
        let state = SessionHistoryStore(reader: gate, watchRoot: root, viewMode: .flat)
        defer { state.suspend() }
        await gate.holdNext(); state.present(sources: sources)
        try await eventually("First snapshot was not held") { await gate.held }
        state.selectSource("second"); state.refresh(); state.refresh()
        await gate.unblock()
        try await eventually("New source did not replace the held snapshot") { state.records.first?.entryID == "second" && !state.isLoading }
        try expect(await gate.maximumActive == 1, "More than one history read ran at a time")
        state.select("session:7:fixture:entry:second")
        try await eventually("Detail did not load") { state.detail != nil }
        await gate.holdNext(); state.refresh()
        try await eventually("Refresh was not held") { await gate.held }
        state.suspend(); await gate.unblock()
        try await Task.sleep(for: .milliseconds(80))
        try expect(!state.isPresented && !state.isLoading, "Late hidden completion revived the reader")
        let before = await gate.calls
        try data(header + [user("changed", parent: nil, text: "Changed")]).write(to: second, options: .atomic)
        try await Task.sleep(for: .milliseconds(750))
        try expect(await gate.calls == before, "Hidden history retained file observations")
        state.present(sources: sources)
        try await eventually("Returning must refresh replaced history") { state.records.first?.entryID == "changed" && !state.isLoading }
        try expect(state.selectedID == nil && state.detail == nil, "Missing selected record retained a stale detail")
        try data(header + [user("watched", parent: nil, text: "Watched")]).write(to: second, options: .atomic)
        try await eventually("Visible source replacement was not observed") { state.records.first?.entryID == "watched" }
        state.setKind(.tool)
        try await eventually("Kind filter must clear results") { state.records.isEmpty && !state.isLoading }
        state.setQuery("Different"); state.selectSource("first")
        try await eventually("Debounced query must retain the current source identity") { !state.isLoading && state.sourceID == "first" }
        try expect(state.filter.kind == .tool && state.filter.query == "Different", "Switching sources unexpectedly reset filters")
        state.clearFilters()
        state.setQuery("   ")
        try expect(!state.hasFilter, "Whitespace-only search must not count as an active filter")
    }

    private static func detailNavigationChecks(root: URL) async throws {
        let file = root.appendingPathComponent("navigation.jsonl")
        try data(fixture()).write(to: file)
        let gate = HistoryGate(root: root)
        let state = SessionHistoryStore(reader: gate, watchRoot: root, viewMode: .flat)
        defer { state.suspend() }
        state.present(sources: [.init(id: "navigation", title: "Navigation", file: file.path)])
        try await eventually("Navigation list did not load") { !state.records.isEmpty && !state.isLoading }
        let tool = "session:7:fixture:tool:assistant:2"
        await gate.holdNext(); state.select(tool)
        try await eventually("First detail was not held") { await gate.held }
        try expect(state.detail == nil && !state.showsDetail && !state.records.isEmpty,
                   "The first detail must not replace the overview with an unfinished snapshot")
        await gate.unblock()
        try await eventually("First detail did not become ready") { state.showsDetail && !state.isLoading }

        func navigate(_ action: () -> Void, until accepted: () -> Bool) async throws {
            let previous = state.detail
            await gate.holdNext(); action()
            try await eventually("Detail navigation was not held") { await gate.held }
            try expect(state.detail == previous && state.showsDetail, "Pending navigation cleared the accepted detail")
            try expect(!state.isDetailPending, "Same-record navigation must not disable displayed actions")
            await gate.unblock()
            try await eventually("Detail navigation did not commit") { accepted() && !state.isLoading }
        }
        try await navigate({ state.detailPage(2) }) { state.detail?.address.page == 2 }
        let previous = state.detail
        await gate.holdNext(); state.descend(.field("nested"))
        try await eventually("Child navigation was not held") { await gate.held }
        let calls = await gate.calls
        state.descend(.field("nested")); state.descend(.field("nested"))
        let repeatedCalls = await gate.calls
        try expect(state.detail == previous && repeatedCalls == calls, "Repeated clicks restarted or cleared a pending child")
        await gate.unblock()
        try await eventually("Repeated clicks descended more than one level") {
            state.detail?.address.path == [.field("nested")] && !state.isLoading
        }

        // A parent action while a child is unfinished supersedes that read.
        await gate.holdNext(); state.descend(.field("deep"))
        try await eventually("Superseded child was not held") { await gate.held }
        state.ascend(to: 0)
        await gate.unblock()
        try await eventually("A late child replaced the requested parent") {
            state.detail?.address.path.isEmpty == true && state.detail?.address.page == 0 && !state.isLoading
        }
        try await navigate({ state.setSection(.result) }) { state.detail?.address.section == .result }
        try await navigate({ state.descend(.field("nested")) }) { state.detail?.address.path == [.field("nested")] }
        try await navigate({ state.ascend(to: 0) }) { state.detail?.address.path.isEmpty == true }
        try await navigate({ state.setSection(.output) }) { state.detail?.address.section == .output }
        try await navigate({ state.detailPage(1) }) { state.detail?.address.page == 1 }

        let old = state.detail
        await gate.holdNext(); state.select("session:7:fixture:tool:assistant:3")
        try await eventually("Record switch was not held") { await gate.held }
        try expect(state.isDetailPending, "A held record switch must disable snapshot actions")
        state.setSection(.output); state.descend(.field("nested"))
        try expect(state.detail == old, "Record switch cleared its displayed snapshot")
        await gate.unblock()
        try await eventually("Stale controls navigated the newly selected record") {
            state.detail?.record.id == state.selectedID && state.detail?.address.section == .input && !state.isLoading
        }
        try expect(!state.isDetailPending, "A committed record switch must re-enable snapshot actions")
        try FileManager.default.removeItem(at: file)
        state.refresh()
        try await eventually("Deleted source did not fail") { state.error == .unavailable && !state.isLoading }
        try expect(state.detail == nil, "A failed source retained stale detail")
        try expect(await gate.maximumActive == 1, "Detail navigation introduced concurrent reads")
    }

    private static func sourceChecks(file: URL) throws {
        func thread() -> ChatThread { ChatThread(projectID: nil, provider: .omp, model: nil, effort: nil, runtimeMode: .auto) }
        var parent = thread(); parent.providerSessionID = file.path
        var child = thread(); child.parentThreadID = parent.id; child.providerSessionID = file.path + ".child.jsonl"
        child.hydra = .init(index: 1, task: "Inspect", kind: .native, origin: .delegated)
        child.hydra?.nativeObservationID = "observation"
        var alias = child; alias.id = UUID(); alias.hydra?.nativeCanonicalID = child.id
        var unrelated = thread(); unrelated.providerSessionID = "/foreign/unrelated.jsonl"
        let sources = SessionHistoryStore.sources(threadID: parent.id, threads: [unrelated, alias, child, parent])
        try expect(sources.count == 2 && sources[1].isAgent && sources[1].id.contains("observation"), "Source discovery must follow known canonical Hydra identities only")
        try expect(WorkspacePanel.trajectory.isImplemented && WorkspacePanel.trajectory.symbol == "point.bottomleft.forward.to.arrow.triangle.uturn.scurvepath", "Session history must be an implemented stable sidebar destination")
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private static func rowGeometryChecks(output: URL) throws {
        _ = NSApplication.shared
        let records = [
            OMPSessionRecord(id: "long", entryID: "long", kind: .tool, status: .unrecorded, title: "bash",
                summary: "git status --short && git diff --check && git diff --stat && git log -1 --oneline",
                timestamp: nil, model: nil, toolCallID: nil, duration: nil, tokens: nil),
            OMPSessionRecord(id: "wrapped", entryID: "wrapped", kind: .tool, status: .unrecorded, title: "bash",
                summary: String(repeating: "git -C /workspace/会话记录 status --short && ", count: 12),
                timestamp: nil, model: nil, toolCallID: nil, duration: nil, tokens: nil),
            OMPSessionRecord(id: "short", entryID: "short", kind: .tool, status: .completed, title: "read",
                summary: "Sources/SessionHistoryPane.swift", timestamp: nil, model: nil, toolCallID: nil, duration: nil, tokens: nil),
            OMPSessionRecord(id: "empty", entryID: "empty", kind: .response, status: .completed, title: "assistant",
                summary: "", timestamp: nil, model: nil, toolCallID: nil, duration: nil, tokens: nil)
        ]
        var measured: [JSONValue] = []
        var heights: [String: CGFloat] = [:]
        for record in records {
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            var reference: CGFloat?
            for (width, selected) in [(1000, false), (420, true), (600, true), (1000, false)] {
                host.rootView = AnyView(SessionHistoryRecordRow(record: record, selected: selected, overviewWidth: 1000, action: {})
                    .frame(width: CGFloat(width)))
                host.layoutSubtreeIfNeeded()
                let size = host.fittingSize
                try expect(size.height > 20 && abs(size.width - CGFloat(width)) < 0.5,
                           "Row measurement has no constrained native geometry: expected width \(width), got \(size)")
                if let reference {
                    try expect(abs(size.height - reference) < 0.5, "\(record.id) changed height when selection opened a narrower detail column: \(reference) -> \(size.height)")
                } else { reference = size.height; heights[record.id] = size.height }
                if record.status == .unrecorded {
                    let lines = record.id == "wrapped" ? 2 : 1
                    let caption = NSHostingView(rootView: Text(verbatim: record.summary).font(.ui(.caption)).lineLimit(lines)
                        .frame(width: CGFloat(width) - 42))
                    let withoutSummary = OMPSessionRecord(id: record.id, entryID: record.entryID, kind: record.kind,
                        status: record.status, title: record.title, summary: "", timestamp: nil, model: nil,
                        toolCallID: nil, duration: nil, tokens: nil)
                    let baseline = NSHostingView(rootView: SessionHistoryRecordRow(record: withoutSummary, selected: selected, overviewWidth: 1000, action: {})
                        .frame(width: CGFloat(width)))
                    try expect(size.height - baseline.fittingSize.height >= caption.fittingSize.height + 4,
                               "Stable row sizing clipped its native \(lines)-line caption")
                }
                measured.append(["record": .string(record.id), "width": .int(width), "selected": .bool(selected), "height": .double(size.height)])
            }
        }
        try expect(heights["wrapped"]! > heights["long"]! + 8,
                   "One-line summaries still reserved the same empty line as two-line summaries")
        let resized = NSHostingView(rootView: SessionHistoryRecordRow(record: records[0], selected: false, overviewWidth: 420, action: {})
            .frame(width: 420))
        try expect(resized.fittingSize.height > heights["long"]! + 8,
                   "A real overview resize must recalculate natural line counts")
        try JSONValue.array(measured).data(pretty: true).write(to: output.appendingPathComponent("history-row-geometry.json"))
    }

    private static func layoutChecks(file: URL, root: URL, output: URL) async throws {
        _ = NSApplication.shared
        try data(fixture() + presentationRows(parent: "credential")).write(to: file)
        let previews = FilePreviewStore(persistenceURL: output.appendingPathComponent("history-previews.json"))
        previews.setContext(.init(threadID: UUID(), workingDirectory: root.path)); previews.openPanel(.trajectory)
        let session = previews.session!
        let gate = HistoryGate(root: root)
        let state = SessionHistoryStore(reader: gate, watchRoot: root, viewMode: .flat)
        let sources = [OMPSessionRecordSource(id: "layout", title: "会话记录 · A long session title for native sidebar layout", file: file.path)]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let model = AppModel()
        let resize = WindowLiveResize(window: window)
        let host = FrameHostingView(rootView: AnyView(SessionHistoryPane(previews: previews, session: session, state: state, sourceOverride: sources)
            .modifier(HostedEnvironment(model: model, liveResize: resize, previews: previews))
            .background(Color(nsColor: .windowBackgroundColor))))
        window.contentView = host
        defer { state.suspend(); previews.suspend(); window.contentView = nil; window.close() }
        try await eventually("Production history view did not load") { host.layoutSubtreeIfNeeded(); return !state.records.isEmpty && !state.isLoading }
        state.goToPage(state.pageCount - 1)
        try await eventually("The latest chronological page did not load") { state.page == state.pageCount - 1 && !state.isLoading }
        func capture(_ name: String, width: Int) async throws {
            window.setContentSize(NSSize(width: width, height: 600)); host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
            var controls: [NSRect] = []
            for case let view as NoWindowDragView in descendants(host) where !view.isHiddenOrHasHiddenAncestor {
                var frame = view.convert(view.bounds, to: host)
                if !host.isFlipped { frame.origin.y = host.bounds.height - frame.maxY }
                if frame.height > 1 && frame.minY >= 0 && frame.minY < 40 { controls.append(frame) }
            }
            try expect(!controls.isEmpty && controls.allSatisfy { $0.minX >= -0.5 && $0.maxX <= host.bounds.width + 0.5 }, "History topbar overflowed at \(width) pt")
            try expect(!window.isVisible, "Layout checks may not launch a visible GUI")
            guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw HistoryFailure(description: "No offscreen bitmap") }
            for view in descendants(host) { view.needsDisplay = true }
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("history-\(name)-\(width).png"))
        }
        for width in [260, 360, 480] { try await capture("list", width: width) }
        let previousUI = TypeScale.shared.ui
        TypeScale.shared.ui = TypeScale.uiRange.upperBound
        try await capture("list-large-type", width: 480)
        TypeScale.shared.ui = previousUI
        func toolbarControls() -> Set<ObjectIdentifier> {
            Set(descendants(host).compactMap { view in
                guard view is NoWindowDragView else { return nil }
                var frame = view.convert(view.bounds, to: host)
                if !host.isFlipped { frame.origin.y = host.bounds.height - frame.maxY }
                return frame.height > 1 && frame.minY >= 0 && frame.minY < 40 ? ObjectIdentifier(view) : nil
            })
        }
        let list = descendants(host).compactMap { $0 as? NSScrollView }.first { $0.bounds.height > 200 }!
        list.contentView.scroll(to: NSPoint(x: 0, y: 140)); list.reflectScrolledClipView(list.contentView)
        try await Task.sleep(for: .milliseconds(60))
        let offset = list.contentView.bounds.origin.y
        let initialControls = toolbarControls()
        await gate.holdNext()
        state.select("session:7:fixture:tool:assistant:2")
        try await eventually("First production detail was not held") { await gate.held }
        host.layoutSubtreeIfNeeded()
        try expect(!state.showsDetail && toolbarControls() == initialControls, "Opening an unfinished detail replaced its controls or overview")
        await gate.unblock()
        try await eventually("Tool detail did not load in production view") { state.detail != nil && !state.isLoading }
        try await Task.sleep(for: .milliseconds(40)); host.layoutSubtreeIfNeeded()
        try expect(toolbarControls() == initialControls, "Opening a ready detail remounted its toolbar controls")
        for width in [260, 360, 480] { try await capture("tool", width: width) }
        state.select(nil)
        try await eventually("Back did not finish") { !state.isLoading }
        host.layoutSubtreeIfNeeded()
        try expect(descendants(host).contains { $0 === list } && abs(list.contentView.bounds.origin.y - offset) < 1, "Detail visits replaced or moved the history viewport")
        state.select("session:7:fixture:tool:assistant:2")
        try await eventually("Second tool detail did not load") { state.detail != nil && !state.isLoading }
        previews.setFullscreen(true)
        list.contentView.scroll(to: .zero); list.reflectScrolledClipView(list.contentView)
        try await capture("split", width: 1000)
        let divider = descendants(host).compactMap { $0 as? DragHandleView }.first { $0.bounds.height > 200 && $0.bounds.width == 9 }
        try expect(divider != nil && list.bounds.width >= 240 && list.bounds.width < 600, "Fullscreen did not retain a distinct resizable overview column")
        session.historyDetailFraction = 0.60
        try await capture("split-resized", width: 1000)
        try expect(list.bounds.width > 590 && list.bounds.width < 610, "The shared divider fraction did not resize the history columns")
        guard let detailScroll = descendants(host).compactMap({ $0 as? NSScrollView }).first(where: { $0 !== list && $0.bounds.height > 200 }) else {
            throw HistoryFailure(description: "Production detail has no native scroll view")
        }
        let detailControls = toolbarControls()
        func navigate(_ name: String, action: () -> Void, until accepted: () -> Bool) async throws {
            let before = state.detail
            await gate.holdNext(); action()
            try await eventually("Production navigation was not held") { await gate.held }
            host.layoutSubtreeIfNeeded()
            try expect(state.detail == before && toolbarControls() == detailControls && descendants(host).contains { $0 === detailScroll },
                       "Pending navigation remounted the toolbar or detail viewport")
            await gate.unblock()
            try await eventually("Production navigation did not finish") { accepted() && !state.isLoading }
            try await capture(name, width: 1000)
            try expect(toolbarControls() == detailControls && descendants(host).contains { $0 === detailScroll },
                       "Accepted navigation remounted the toolbar or detail viewport")
            try expect(abs(detailScroll.contentView.bounds.origin.y) < 1, "Detail navigation did not reset its retained viewport")
        }
        detailScroll.contentView.scroll(to: NSPoint(x: 0, y: 140)); detailScroll.reflectScrolledClipView(detailScroll.contentView)
        try await navigate("result", action: { state.setSection(.result) }) { state.detail?.address.section == .result }
        try await navigate("nested", action: { state.descend(.field("nested")) }) { state.detail?.address.path == [.field("nested")] }
        try await navigate("parent", action: { state.ascend(to: 0) }) { state.detail?.address.path.isEmpty == true }
        try await navigate("output", action: { state.setSection(.output) }) { state.detail?.address.section == .output }
        try await navigate("output-page", action: { state.detailPage(1) }) { state.detail?.address.page == 1 }
        previews.openPanel(.files)
        try await eventually("Hidden sidebar must suspend its reader") { !state.isPresented }
        previews.openPanel(.trajectory)
        try await eventually("Returning must retain selection and section") { state.detail?.address.section == .output && state.isPresented && !state.isLoading }
        try expect(session.historyDetailFraction == 0.60, "Sidebar visit lost the split fraction")
    }
}
