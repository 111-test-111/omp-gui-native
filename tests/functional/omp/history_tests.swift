import Foundation

// The isolated protocol-model harness does not load GUI state or active profiles.
enum AppText { static func localized(_ key: String) -> String { key } }

@main
struct OMPHistoryChecks {
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }

    private static func rejects(_ body: () throws -> Void, _ message: String) {
        do { try body(); fatalError(message) } catch { }
    }

    private static func json(_ text: String) -> JSONValue { JSONValue.parse(text)! }
    static func main() throws {
        let idle = json(#"{"isStreaming":false,"isCompacting":false,"queuedMessageCount":0,"hasPendingAsyncWork":false,"isSettled":true}"#)
        var activity = OMPActivityTracker()
        let initialEvents = activity.eventRevision
        expect(activity.accept(idle, revision: activity.revision), "Accept initial native state")
        let snapshotRevision = activity.revision
        expect(activity.accept(idle, revision: activity.revision), "Concurrent identical state read remains valid")
        expect(activity.revision > snapshotRevision && activity.eventRevision == initialEvents,
               "State reads advance state-publication fences without invalidating history")
        activity.beginPrompt("new")
        expect(activity.eventRevision > initialEvents, "New admission invalidates history snapshot")
        let beginRevision = activity.eventRevision
        activity.observe(["type": "unknown_future_event"])
        expect(activity.eventRevision == beginRevision, "Unknown events cannot manufacture history changes")
        activity.observe(["type": "agent_start"])
        expect(activity.eventRevision > beginRevision, "Native lifecycle invalidates history snapshot")
        let liveRevision = activity.eventRevision
        activity.endPrompt("new")
        activity.answer("dialog")
        activity.stop()
        expect(activity.eventRevision == liveRevision + 3, "Prompt settlement, answers and stop each fence history")

        let raw = json(#"{"entries":[{"id":"u1","parentId":null,"type":"message","message":{"role":"user","content":"repeat"}},{"id":"old","parentId":"u1","type":"message","message":{"role":"user","content":"abandoned"}},{"id":"a1","parentId":"u1","type":"message","message":{"role":"assistant","content":[{"type":"text","text":"answer"}]}},{"id":"u2","parentId":"a1","type":"message","message":{"role":"user","content":[{"type":"text","text":"repeat"},{"type":"image","data":"YWJj","mimeType":"image/png"}]}}],"leafId":"u2"}"#)
        let history = try OMPHistorySnapshot(raw, sessionFile: "/session.jsonl", sessionID: "s")
        expect(history.activeUserEntries.map(\.id) == ["u1", "u2"], "Active path excludes abandoned append-history")
        let path = try history.activePath()
        expect(path.map(\.id) == ["u1", "a1", "u2"], "Parent links determine order")
        let first = UUID(), second = UUID()
        let inputs = [OMPHistoryUserInput(id: first, text: "repeat", imageCount: 0),
                      OMPHistoryUserInput(id: second, text: "repeat", imageCount: 1)]
        expect(history.mapUserEntries(to: inputs) == [first: "u1", second: "u2"], "Repeated texts map only through complete prefix")
        expect(history.mapUserEntries(to: [OMPHistoryUserInput(id: first, text: "repeat", imageCount: 1)]).isEmpty,
               "Never skip the first repeat to select a later attachment match")
        expect(history.mapUserEntries(to: [OMPHistoryUserInput(id: first, text: "raw GUI text", imageCount: 0)]).isEmpty,
               "Hidden-context mismatches stay unavailable")
        expect(history.mapUserEntries(to: [OMPHistoryUserInput(id: first, text: "repeat", imageCount: 0, nativeEntryID: "u2")]).isEmpty,
               "Stale saved bindings cannot override prefix identity")
        expect(OMPHistoryMessage(json(#"{"role":"user","content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]}"#))?.text == "firstsecond",
               "Text blocks concatenate exactly as OMP restores the editor")

        rejects({ _ = try OMPHistorySnapshot(json(#"{"entries":[{"id":"a","parentId":"b","type":"x"},{"id":"b","parentId":"a","type":"x"}],"leafId":"a"}"#), sessionFile: "f", sessionID: "s") }, "Reject parent cycles")
        rejects({ _ = try OMPHistorySnapshot(json(#"{"entries":[{"id":"a","parentId":null,"type":"x"},{"id":"a","parentId":null,"type":"x"}],"leafId":"a"}"#), sessionFile: "f", sessionID: "s") }, "Reject duplicate native IDs")
        rejects({ _ = try OMPHistorySnapshot(json(#"{"entries":[],"leafId":"missing"}"#), sessionFile: "f", sessionID: "s") }, "Reject missing current leaf")

        print("OMP native history checks passed")
    }
}
