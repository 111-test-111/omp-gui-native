import AppKit
import Foundation
@testable import OMPGUI

@main
struct FastWriteDiffChecks {
    @MainActor private static var count = 0

    @MainActor private static func expect(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        count += 1
    }

    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        if arguments[1] == "export" {
            let bundle = Bundle(url: URL(fileURLWithPath: arguments[2]))!
            let source = try OMPSystemPrompt.guidanceExtension(enabled: false, bundle: bundle)
            expect(try OMPSystemPrompt.guidanceExtension(enabled: false) == source, "The runtime locates its own bundled resource when used by CLI checks")
            try source.write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)
            expect(String(decoding: source, as: UTF8.self).contains("installFileSnapshots(omp)"), "The shipped extension installs the hooks even with guidance disabled")
            expect(NSImage(systemSymbolName: "exclamationmark.square", accessibilityDescription: nil) != nil, "The replacement symbol exists on this macOS")
        } else {
            let url = URL(fileURLWithPath: arguments[2])
            let fixtures = JSONValue.parse(try Data(contentsOf: url))!.array!
            let root = url.deletingLastPathComponent().appendingPathComponent("files").path
            let decoder = OMPEventDecoder(prefix: "delayed", directory: root)
            var updates: [ToolUpdate] = []
            decoder.onEvent = { event in
                if case .toolUpdated(_, let update) = event { updates.append(update) }
            }
            for fixture in fixtures {
                let id = fixture["id"]!.string!
                decoder.handle(["type": "tool_execution_start", "toolName": "write", "toolCallId": .string(id), "args": fixture["args"]!])
                decoder.handle(["type": "tool_execution_end", "toolName": "write", "toolCallId": .string(id), "result": fixture["result"]!,
                                "isError": .bool(fixture["failed"]?.bool == true)])
                let update = updates.last!
                if fixture["failed"]?.bool == true {
                    expect(update.status == .failed, "Failed writes keep the native failure")
                    continue
                }
                expect(update.edits?.count == 1, "Each completed write identifies its file: \(id)")
                let edit = update.edits![0]
                if fixture["unavailable"]?.bool == true {
                    expect(edit.diff == nil && edit.additions == 0 && edit.deletions == 0, "Unreadable or oversized old/new text never fabricates an addition: \(id)")
                } else {
                    expect(edit.additions == fixture["additions"]?.int && edit.deletions == fixture["deletions"]?.int, "Delayed GUI events retain per-call counts: \(id)")
                    for token in fixture["tokens"]?.array ?? [] {
                        expect(edit.diff?.contains(token.string!) == true, "The original change survives subsequent writes: \(id) \(token.string!)")
                    }
                    expect(edit.diff?.contains("later-unrelated-content") != true, "Never substitute the current file for the tool result")
                }
                var call = ToolCall(kind: .edit, title: edit.path, toolName: "write")
                call.edits = update.edits!
                let reopened = try JSONDecoder().decode(ToolCall.self, from: JSONEncoder().encode(call))
                expect(reopened.edits == call.edits, "Persist each call's own diff across reopening: \(id)")
            }

            // Native patches remain authoritative if a newer OMP supplies both.
            decoder.handle(["type": "tool_execution_start", "toolName": "write", "toolCallId": "native", "args": ["path": "native.txt"]])
            let patch = "@@ -1 +1 @@\n-native-old\n+native-new\n"
            decoder.handle(["type": "tool_execution_end", "toolCallId": "native", "result": ["details": [
                "resolvedPath": .string(root + "/native.txt"), "diff": .string(patch),
                "ompGUI": ["fileSnapshot": ["version": 1, "path": .string(root + "/native.txt"), "oldText": "wrong", "newText": "wrong"]]
            ]]])
            expect(updates.last?.edits?.first?.diff == patch, "Preserve native patches ahead of supplemental snapshots")

            // Workers must use the native result even if their workspace is gone.
            let child = OMPEventDecoder(prefix: "worker", directory: root, capturesSnapshots: false)
            var childEdit: FileEdit?
            child.onEvent = { event in
                if case .toolUpdated(_, let update) = event { childEdit = update.edits?.first }
            }
            let first = fixtures.first!
            child.handle(["type": "tool_execution_start", "toolName": "write", "toolCallId": "child", "args": first["args"]!])
            child.handle(["type": "tool_execution_end", "toolCallId": "child", "result": first["result"]!])
            expect(childEdit?.diff?.contains("+created-0") == true, "Isolated workers render snapshots without reading the lead's files")
        }
        print("Fast-write GUI checks passed: \(count)")
    }
}
