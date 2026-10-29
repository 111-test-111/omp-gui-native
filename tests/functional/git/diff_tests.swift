import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    var description: String
}

@main
private enum DiffParserChecks {
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(description: message) }
    }

    private static func rows(_ file: DiffFile) -> [DiffLine] {
        file.hunks.flatMap(\.lines)
    }

    static func main() throws {
        let path = "source/你好.swift"
        let replacement = [
            " 228|before",
            " 229|",
            "-230|    let value = old",
            "+230|\tlet value = new | other",
            " 231|after",
        ].joined(separator: "\n")
        let native = DiffParser.parseHunks(replacement, path: path)
        try expect(native.path == path && native.hunks.count == 1, "Native edit has no hunk")
        try expect(native.additions == 1 && native.deletions == 1, "Native change counts differ")
        let nativeRows = rows(native)
        try expect(nativeRows[1].kind == .context && nativeRows[1].text.isEmpty, "Empty code line became a gap")
        try expect(nativeRows[2].text == "    let value = old" && nativeRows[2].oldNumber == 230, "Deletion gutter or indentation leaked")
        try expect(nativeRows[3].text == "\tlet value = new | other" && nativeRows[3].newNumber == 230, "Addition gutter or code pipe leaked")
        try expect(nativeRows.last?.oldNumber == 231 && nativeRows.last?.newNumber == 231, "Replacement moved unchanged lines")

        let legacy = DiffParser.parseHunks("   9 before\n- 10     old\n+ 10 \tnew\n  11 after", path: path)
        try expect(legacy.additions == 1 && legacy.deletions == 1, "Legacy numbered diff was dropped")
        try expect(rows(legacy)[1].text == "    old" && rows(legacy)[2].text == "\tnew", "Legacy indentation was stripped")

        let insertion = DiffParser.parseHunks(" 114|before\n 115|\n+116|one\n+117|two\n 116|after\n\n 200|later", path: path)
        try expect(insertion.hunks.count == 2 && insertion.additions == 2, "Insertion or blank gap was dropped")
        try expect(rows(insertion)[4].oldNumber == 116 && rows(insertion)[4].newNumber == 118, "Context after insertion has the wrong coordinates")
        try expect(rows(insertion).last?.newNumber == 202, "Context delta was lost across an omitted region")

        let deletion = DiffParser.parseHunks(" 1|before\n-2|one\n-3|two\n 4|after", path: path)
        try expect(deletion.deletions == 2 && rows(deletion).last?.newNumber == 2, "Context after deletion has the wrong coordinates")

        let gaps = DiffParser.parseHunks("-1|a\n+1|b\n...\n-10|c\n+10|d\n…\n-20|e\n+20|f", path: path)
        try expect(gaps.hunks.count == 3 && gaps.additions == 3 && gaps.deletions == 3, "Omitted regions were not separated")
        try expect(Set(rows(gaps).map(\.id)).count == rows(gaps).count, "Native line IDs repeat between hunks")

        let git = DiffParser.parseHunks("@@ -7,3 +7,4 @@\n before\n-old\n+new\n+extra\n after", path: path)
        try expect(git.additions == 2 && git.deletions == 1, "Git hunk counts regressed")
        try expect(rows(git).last?.oldNumber == 9 && rows(git).last?.newNumber == 10, "Git line coordinates regressed")
        let numberedCode = DiffParser.parseHunks("@@ -1 +1 @@\n-123|old\n+123|new", path: path)
        try expect(rows(numberedCode).first?.text == "123|old", "Git code was mistaken for an OMP gutter")

        let binary = DiffParser.parseHunks("diff --git a/image.png b/image.png\nBinary files a/image.png and b/image.png differ", path: "image.png")
        try expect(binary.isBinary && binary.hunks.isEmpty, "Binary patch detection regressed")
        let unknown = DiffParser.parseHunks("Edited file successfully", path: path)
        try expect(unknown.hunks.isEmpty && !unknown.isDeferred, "Unrecognized text was invented into a diff")
        let invalidNumber = DiffParser.parseHunks("+9999999999999999999999999|x", path: path)
        try expect(invalidNumber.hunks.isEmpty, "Out-of-range gutter number was accepted")
        let overflowingContext = DiffParser.parseHunks("+1|new\n \(Int.max)|context", path: path)
        try expect(rows(overflowingContext).last?.newNumber == nil, "Context overflow did not stay bounded")

        let manyLines = (1...20_001).map { "+\($0)|x" }.joined(separator: "\n")
        let deferred = DiffParser.parseHunks(manyLines, path: path)
        try expect(deferred.isDeferred && deferred.hunks.isEmpty, "Large native diff ignored the row limit")
        try expect(deferred.additions == 20_001 && deferred.deferredLineCount == 20_001, "Deferred native counts were lost")
        let expanded = DiffParser.parseHunks(deferred.deferredPatch!, path: deferred.path, limitsSize: false)
        try expect(!expanded.isDeferred && rows(expanded).count == 20_001, "Deferred native diff could not be reopened")

        let hugeLine = "+1|" + String(repeating: "x", count: 1_048_577)
        let huge = DiffParser.parseHunks(hugeLine, path: path)
        try expect(huge.isDeferred && huge.additions == 1, "Native byte limit was not preserved")
        let hugeExpanded = DiffParser.parseHunks(huge.deferredPatch!, path: path, limitsSize: false)
        try expect(rows(hugeExpanded).first?.text.count == 1_048_577, "Deferred long line was truncated")

        let hugeGit = "diff --git a/file b/file\n@@ -0,0 +1 @@\n+" + String(repeating: "x", count: 1_048_577)
        let deferredGit = DiffParser.parseHunks(hugeGit, path: path)
        try expect(deferredGit.isDeferred, "Git byte limit regressed")
        let expandedGit = DiffParser.parseHunks(deferredGit.deferredPatch!, path: path, limitsSize: false)
        try expect(expandedGit.additions == 1 && !expandedGit.isDeferred, "Deferred Git diff could not be reopened")

        let changed = DiffParser.parseHunks(replacement.replacingOccurrences(of: "new | other", with: "different | other"), path: path)
        try expect(changed.revision != native.revision, "Content changes did not invalidate the diff cache")

        var recordedCount = 0
        for argument in CommandLine.arguments.dropFirst() {
            struct RecordedEdit: Decodable {
                var path: String
                var diff: String
                var additions: Int
                var deletions: Int
            }
            let edits = try JSONDecoder().decode([RecordedEdit].self, from: Data(contentsOf: URL(fileURLWithPath: argument)))
            for edit in edits {
                let file = DiffParser.parseHunks(edit.diff, path: edit.path)
                try expect(!file.hunks.isEmpty || file.isDeferred, "A recorded edit still has no renderable diff")
                try expect(file.additions == edit.additions && file.deletions == edit.deletions, "Recorded edit counts differ after parsing")
            }
            recordedCount += edits.count
        }
        print("Diff parser regression checks passed; \(recordedCount) recorded edits validated.")
    }
}
