import Foundation

@main struct Checks {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }
    static func json(_ value: String) -> JSONValue { JSONValue.parse(value)! }
    static func main() throws {
        let context = "/fixture/worker-checkout"
        let read = OMPFileReference.decode(toolName: "read", args: json(#"{"path":"src/My File.swift","offset":42}"#), directory: context)
        expect(read == FilePreviewReference(path: context + "/src/My File.swift", line: 42), "Structured path preserves source worker and one-based line")
        let edit = OMPFileReference.decode(toolName: "write", args: json(#"{"path":"xd://edit","content":"{\"path\":\"/fixture/other-worktree/a.swift\"}"}"#), directory: context)
        expect(edit?.path == "/fixture/other-worktree/a.swift", "Mounted edit references the inner file")
        expect(OMPFileReference.decode(toolName: "write", args: json(#"{"path":"xd://read","content":"?"}"#), directory: context) == nil, "Device help is not a file")
        expect(OMPFileReference.decode(toolName: "read", args: json(#"{"path":"xd://edit"}"#), directory: context) == nil, "Transport URLs cannot become files")
        expect(OMPFileReference.decode(toolName: "read", args: json(#"{"path":"https://example.com/a.swift"}"#), directory: context) == nil, "Remote URL cannot become a local file")
        expect(OMPFileReference.decode(toolName: "read", args: json(#"{"path":"file://remote/fixture/a.swift"}"#), directory: context) == nil, "Reject a non-local file host")
        expect(OMPFileReference.decode(toolName: "read", args: json(#"{"path":"relative.swift"}"#), directory: nil) == nil, "Missing original cwd never uses the selected chat")
        let template = ToolCall(kind: .read, title: "src/My File.swift", toolName: "read")
        var oldObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as! [String: Any]
        oldObject.removeValue(forKey: "fileReference")
        let old = try JSONDecoder().decode(ToolCall.self, from: JSONSerialization.data(withJSONObject: oldObject))
        expect(old.fileReference == nil, "Saved calls without the field still decode")

        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let history = root.appendingPathComponent("history.jsonl")
        let prefix = UUID().uuidString
        func journal(_ path: String) -> Data {
            let header = JSONValue.object(["type": .string("session"), "id": .string("fixture"), "cwd": .string(context)])
            let call = JSONValue.object(["type": .string("message"), "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("toolCall"), "id": .string("tool-1"), "name": .string("read"), "arguments": .object(["path": .string(path), "offset": .int(9)])])])])])
            return Data((header.compactString + "\n" + call.compactString + "\n").utf8)
        }
        try journal("a.swift").write(to: history, options: .atomic)
        let first = OMPToolHistory.readIdentities(sessionFile: history.path)
        var restored = old
        expect(OMPToolHistory.restore(&restored, timelineID: prefix + "-tool-1", identities: first), "Backfill existing native calls even with saved identity")
        expect(restored.fileReference == FilePreviewReference(path: context + "/a.swift", line: 9), "Journal cwd stays authoritative")
        expect(!OMPToolHistory.restore(&restored, timelineID: prefix + "-tool-1", identities: first), "Repeated restoration is idempotent")
        let modification = try history.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try journal("b.swift").write(to: history, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modification], ofItemAtPath: history.path)
        let second = OMPToolHistory.readIdentities(sessionFile: history.path)
        expect(second["tool-1"]?.fileReference?.path == context + "/b.swift", "Atomic replacement invalidates same-size same-mtime journal cache")

        let inline = json(#"{"path":"src/Foo.swift:30-50:raw"}"#)
        expect(OMPFileReference.initialReferences(toolName: "read", args: inline, directory: context) == [], "Native selectors wait for OMP canonical metadata")
        let canonical = OMPFileReference.fromResult(toolName: "read", details: json(#"{"resolvedPath":"/fixture/canonical/Foo.swift","displayContent":{"startLine":30}}"#))
        expect(canonical == [FilePreviewReference(path: "/fixture/canonical/Foo.swift", line: 30)], "Native completed read path and display start line win")
        let literal = OMPFileReference.fromResult(toolName: "read", details: json(#"{"meta":{"source":{"type":"path","value":"/fixture/report:20"}},"displayContent":{"startLine":1}}"#))
        expect(literal == [FilePreviewReference(path: "/fixture/report:20", line: 1)], "Canonical colon filename is retained exactly")
        let grouped = OMPFileReference.fromResult(toolName: "read", details: json(#"{"displayReadTargetLinks":["/fixture/a.swift",null,"/fixture/b.swift","/fixture/a.swift"]}"#))
        expect(grouped == [FilePreviewReference(path: "/fixture/a.swift"), FilePreviewReference(path: "/fixture/b.swift")], "Grouped reads expose distinct canonical local files")
        expect(OMPFileReference.fromResult(toolName: "read", details: json(#"{"displayReadTargetLinks":[null,"https://example.com/a.swift"]}"#)) == [], "Unlinkable grouped outputs suppress guessed targets")
        let nativeRead = JSONValue.object(["type": .string("message"), "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("toolCall"), "id": .string("tool-2"), "name": .string("read"), "arguments": inline])])])])
        let nativeResult = JSONValue.object(["type": .string("message"), "message": .object(["role": .string("toolResult"), "toolCallId": .string("tool-2"), "toolName": .string("read"), "details": json(#"{"resolvedPath":"/fixture/canonical/Foo.swift","displayContent":{"startLine":30}}"#)])])
        let header = JSONValue.object(["type": .string("session"), "id": .string("native"), "cwd": .string(context)])
        try Data(([header, nativeRead, nativeResult].map(\.compactString).joined(separator: "\n") + "\n").utf8).write(to: history, options: .atomic)
        let finalIdentities = OMPToolHistory.readIdentities(sessionFile: history.path)
        var selected = ToolCall(kind: .read, title: "src/Foo.swift:30-50:raw", toolName: "read")
        expect(OMPToolHistory.restore(&selected, timelineID: prefix + "-tool-2", identities: finalIdentities), "Restore selector calls from their authoritative result")
        expect(selected.fileReferences == canonical && selected.fileReference == canonical?.first, "Final metadata replaces provisional paths")
        let conflicting = JSONValue.object(["type": .string("message"), "message": .object(["role": .string("assistant"), "content": .array([.object(["type": .string("toolCall"), "id": .string("tool-2"), "name": .string("read"), "arguments": json(#"{"path":"different.swift"}"#)])])])])
        try Data(([header, nativeRead, nativeResult, conflicting].map(\.compactString).joined(separator: "\n") + "\n").utf8).write(to: history, options: .atomic)
        expect(OMPToolHistory.readIdentities(sessionFile: history.path)["tool-2"] == nil, "Conflicting native call arguments never select a file")
        print("20 file entry-point checks passed")
    }
}
