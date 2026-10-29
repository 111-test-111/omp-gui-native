import Foundation
import Darwin

struct OMPContextJournalInspection: Sendable {
    let sessionID: String
    let ancestry: Set<String>
    let accounting: OMPContextAccounting
    let response: OMPAgentJournal.ContextReport
    let compactions: Int

    init(entries: [JSONValue]) throws {
        guard let sessionID = entries.first(where: { $0["type"]?.string == "session" })?["id"]?.string else {
            throw OMPSessionRecordError.invalidJournal
        }
        let rows = entries.filter { $0["parentId"] != nil }
        var index: [String: JSONValue] = [:]
        for row in rows {
            guard let id = row["id"]?.string, index.updateValue(row, forKey: id) == nil else {
                throw OMPSessionRecordError.invalidJournal
            }
        }
        var next = (rows.last?["activeLeafId"] ?? rows.last?["id"])?.string
        var ancestry = Set<String>(), compactions = 0
        while let id = next {
            guard ancestry.insert(id).inserted, let entry = index[id] else { throw OMPSessionRecordError.invalidJournal }
            if entry["type"]?.string == "compaction" { compactions += 1 }
            next = entry["parentId"]?.string
        }
        self.sessionID = sessionID; self.ancestry = ancestry; self.compactions = compactions
        accounting = OMPContextAccounting(entries: entries)
        response = try OMPAgentJournal.contextReport(entries)
    }
}

struct OMPContextCapturedRequest: Sendable {
    let record: OMPSessionRecord
    let metadata: OMPContextRequestMetadata
}

struct OMPContextSavedInspection: Sendable {
    let journal: OMPContextJournalInspection
    let request: OMPContextCapturedRequest?
    let captureWarning: Bool
}

/// A visible context pane owns one bounded reader. Request classification is
/// read from small summaries, never from redacted/truncated request bodies.
actor OMPContextInspectionReader {
    enum ReadError: Error { case awaitingFirstSave }

    private var file: String?
    private var revision: PreviewFileMetadata?
    private var journal: OMPContextJournalInspection?
    private var summaryRevision: [String: PreviewFileMetadata]?
    private var captures: OMPRequestRecordStore.Snapshot?

    func read(_ path: String, awaitingFirstSave: Bool = false) throws -> OMPContextSavedInspection {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let sessionRoot = StoragePaths.directory("omp/sessions").resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(sessionRoot), url.pathExtension == "jsonl" else { throw OMPSessionRecordError.outsideStore }
        var info = stat()
        guard url.path.withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0 else {
            let code = errno
            // OMP allocates a path before its first assistant message makes the
            // journal durable. Only absence is expected here, never access errors.
            if awaitingFirstSave && code == ENOENT { throw ReadError.awaitingFirstSave }
            if code == ENOENT { throw OMPSessionRecordError.unavailable }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        let before = PreviewFileMetadata(info)
        if awaitingFirstSave && before.byteCount == 0 { throw ReadError.awaitingFirstSave }
        if file != path || before != revision || journal == nil {
            let snapshot = try OMPAgentJournal.readIfChanged(path, since: nil)!
            // A partially written first line has no complete header yet.
            if awaitingFirstSave && !snapshot.hasCompleteLines { throw ReadError.awaitingFirstSave }
            let next = try OMPContextJournalInspection(entries: snapshot.entries)
            guard PreviewFileMetadata.read(URL(fileURLWithPath: path)) == before else { throw OMPSessionRecordError.changed }
            file = path; revision = before; journal = next; captures = nil; summaryRevision = nil
        }
        guard let journal else { throw OMPSessionRecordError.unavailable }
        let root = StoragePaths.root.appendingPathComponent("omp/requests", isDirectory: true)
        let reader = OMPRequestRecordStore(root: root)
        let metadata = OMPRequestRecordStore.summaryMetadata(in: OMPRequestRecordStore.directory(root: root, file: path))
        if captures == nil || metadata == nil || metadata != summaryRevision {
            captures = try reader.read(file: path, sessionID: journal.sessionID, ancestry: journal.ancestry)
            summaryRevision = metadata
        }
        try Task.checkCancellation()
        var snapshot = captures ?? .init()
        reader.refreshRunning(&snapshot)
        // A leaf-less capture has no proof of belonging to this branch.
        let latest = snapshot.items.filter { $0.record.title == "model_request" && $0.leafID != nil }
            .max { ($0.record.timestamp ?? .distantPast, $0.record.id) < ($1.record.timestamp ?? .distantPast, $1.record.id) }
        let request = latest.flatMap { item in item.context.map { OMPContextCapturedRequest(record: item.record, metadata: $0) } }
        guard PreviewFileMetadata.read(URL(fileURLWithPath: path)) == before else { throw OMPSessionRecordError.changed }
        return .init(journal: journal, request: request,
            captureWarning: snapshot.warning || OMPRequestRecordStore.healthWarning(root: root, file: path))
    }

    func release() { file = nil; revision = nil; journal = nil; summaryRevision = nil; captures = nil }
}
