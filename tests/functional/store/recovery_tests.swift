import Foundation
@testable import OMPGUI

@main
@MainActor
struct RecoveryChecks {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        checks += 1
    }
    static func main() throws {
        guard CaptureRun.storageRoot != nil else { fatalError("Isolated capture storage required") }
        try FileManager.default.createDirectory(at: Storage.root, withIntermediateDirectories: true)
        var library = Library()
        library.projects = [Project(name: "A", path: "/a"), Project(name: "B", path: "/b")]
        library.threads = [ChatThread(projectID: nil, provider: .omp, model: nil, effort: nil, runtimeMode: .supervised)]
        let pristine = try JSONEncoder.storage.encode(library)
        let persisted = try JSONDecoder.storage.decode(Library.self, from: pristine)
        try pristine.write(to: Storage.libraryURL)
        guard case .loaded = Storage.loadLibraryRecovering() else { fatalError("Valid library failed") }
        let previous = Storage.root.appendingPathComponent("library-previous.json")
        expect(try Data(contentsOf: previous) == pristine, "A successful launch retains a known-readable previous library")
        var object = try JSONSerialization.jsonObject(with: pristine) as! [String: Any]
        var projects = object["projects"] as! [Any]
        projects.append(["id": "not-a-uuid", "path": 12])
        object["projects"] = projects
        let damaged = try JSONSerialization.data(withJSONObject: object)
        try damaged.write(to: Storage.libraryURL)
        guard case .recovered(let recovered, let skipped, let quarantine, let backup, let fromPrevious) = Storage.loadLibraryRecovering() else {
            fatalError("Partially damaged library was not recovered")
        }
        expect(recovered.projects.count == 2 && recovered.threads.count == 1 && skipped == 1 && !fromPrevious,
               "Good records load while only damaged records are skipped")
        expect(try Data(contentsOf: backup) == damaged, "Recovery preserves the byte-exact original")
        expect(quarantine != nil && FileManager.default.fileExists(atPath: quarantine!.path), "Unreadable records are quarantined separately")
        expect(try Data(contentsOf: Storage.libraryURL) == damaged, "A read alone never overwrites the damaged library")
        try Data("{broken".utf8).write(to: Storage.libraryURL)
        guard case .recovered(let fallback, _, _, _, true) = Storage.loadLibraryRecovering() else { fatalError("Missing previous-launch fallback") }
        expect(fallback.projects == persisted.projects, "Whole-file damage falls back to the prior readable launch")
        try Data("{\"projects\":[]}".utf8).write(to: Storage.libraryURL)
        guard case .failed = Storage.loadLibraryRecovering() else { fatalError("A missing core list must stay read-only") }
        expect(true, "Malformed schema is not interpreted as an empty library")
        projects = (try JSONSerialization.jsonObject(with: pristine) as! [String: Any])["projects"] as! [Any]
        projects.append(projects[0]); object["projects"] = projects
        try JSONSerialization.data(withJSONObject: object).write(to: Storage.libraryURL)
        guard case .recovered(let deduplicated, let duplicateCount, _, _, _) = Storage.loadLibraryRecovering() else { fatalError("Duplicate identities must be recoverable") }
        expect(deduplicated.projects.count == 2 && duplicateCount == 1, "Duplicate identities cannot crash observed dictionaries")
        try pristine.write(to: Storage.libraryURL)
        expect(DiskWriter.shared.writeSynchronously(library, to: Storage.libraryURL), "A library containing tasks saves")
        expect(try Data(contentsOf: Storage.preStandaloneLibraryURL) == pristine, "The pre-task index is backed up before schema publication")
        let id = UUID()
        var turn = TurnRecord(index: 0)
        turn.status = .completed
        let reference = ThreadTurnReference(id: turn.id, revision: 1)
        var head = ThreadDocument(threadID: id)
        head.turnIndex = [reference]
        let item = TimelineItem(id: "saved-answer", turnID: turn.id, content: .assistant(AssistantMessage(text: "Preserved answer")))
        let saved = StoredTurn(turn: turn, items: [item], itemPositions: [item.id: 1])
        let snapshot = ThreadSave(head: head, dirtyTurns: [turn.id: saved])
        let directory = Storage.turnsURL(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("damaged turn".utf8).write(to: Storage.turnURL(id, turn.id))
        expect(DiskWriter.shared.writeThreadSynchronously(snapshot), "Damaged revision is moved aside before writing a healthy turn")
        expect(Storage.decodeDocument(id)?.items.contains { $0.id == item.id } == true, "The new document remains readable after repair")
        let unreadable = Storage.threadsDirectory.appendingPathComponent("Unreadable")
        expect((try FileManager.default.contentsOfDirectory(atPath: unreadable.path)).count == 1, "Original damaged turn remains available for recovery")
        // Hold the writer queue so the asynchronous snapshot is still pending when
        // a synchronous quit-style save takes ownership of it.
        let blocked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            DiskWriter.shared.readSynchronously { blocked.signal(); release.wait() }
        }
        blocked.wait()
        let nextID = UUID()
        var later = TurnRecord(index: 1); later.status = .completed
        var firstHead = ThreadDocument(threadID: nextID)
        firstHead.turnIndex = [reference]
        DiskWriter.shared.writeThread(ThreadSave(head: firstHead, dirtyTurns: [turn.id: saved])) { _ in }
        var latestHead = firstHead
        latestHead.turnIndex = [reference, ThreadTurnReference(id: later.id, revision: 1)]
        let latest = ThreadSave(head: latestHead, dirtyTurns: [later.id: StoredTurn(turn: later, items: [], itemPositions: [:])])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { release.signal() }
        expect(DiskWriter.shared.writeThreadSynchronously(latest), "Synchronous save retains dirty revisions from a pending asynchronous save")
        expect(Storage.decodeDocument(nextID)?.items.contains { $0.id == item.id } == true, "A coalesced quit save cannot lose the earlier answer")
        print("Recovery checks passed: \(checks)")
    }
}
