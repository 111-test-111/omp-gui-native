import Foundation
import CryptoKit
import Darwin

/// Only reads GUI-owned capture sidecars. Native journals remain authoritative
/// for session identity and active ancestry; payload documents are loaded lazily.
struct OMPRequestRecordStore {
    struct Item {
        var record: OMPSessionRecord
        let file: URL
        var revision: PreviewFileMetadata?
        let pid: Int32?
        let ownerID: String?
        let wasRunning: Bool
        var leafID: String?
        var context: OMPContextRequestMetadata? = nil
    }
    struct Snapshot {
        var items: [Item] = []
        var warning = false
    }
    static let healthLifetime: TimeInterval = 86_400
    let root: URL

    static func directoryName(_ file: String) -> String {
        SHA256.hash(data: Data(file.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func directory(root: URL, file: String) -> URL {
        let canonical = URL(fileURLWithPath: file).standardizedFileURL.resolvingSymlinksInPath().path
        return root.appendingPathComponent(directoryName(canonical), isDirectory: true)
    }

    /// Normal retention keeps at most 512 summaries. A pathological directory is
    /// still bounded, and unrelated documents or temporary files do not consume
    /// the summary limit. A truncated selection is reported instead of hiding all.
    static func summaryNames(_ names: [String], limit: Int = 2_048) -> (names: [String], truncated: Bool) {
        let summaries = names.filter { $0.hasSuffix(".summary.json") }.sorted()
        let bound = max(0, limit)
        return (Array(summaries.prefix(bound)), summaries.count > bound)
    }

    /// A summary revision is immutable; names and file metadata form the cache
    /// key. A missing directory is an empty set; an unsafe or unlistable
    /// directory is not cacheable so its warning is recomputed.
    static func summaryMetadata(in directory: URL) -> [String: PreviewFileMetadata]? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        guard directory.resolvingSymlinksInPath().path == directory.path,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        var metadata: [String: PreviewFileMetadata] = [:]
        for name in names where name.hasSuffix(".summary.json") {
            if let value = PreviewFileMetadata.read(directory.appendingPathComponent(name)) { metadata[name] = value }
        }
        return metadata
    }

    /// Health marks are named by the canonical session path and expire without
    /// requiring a cleanup pass from a writer that may have exited.
    static func healthWarning(root: URL, file: String, now: Date = .now) -> Bool {
        let canonical = URL(fileURLWithPath: file).standardizedFileURL.resolvingSymlinksInPath().path
        let health = root.appendingPathComponent(directoryName(canonical) + ".health.json")
        guard let metadata = PreviewFileMetadata.read(health), metadata.mode & S_IFMT == S_IFREG else { return false }
        return now.timeIntervalSince1970 - Double(metadata.modificationSeconds) < healthLifetime
    }

    func read(file: String, sessionID: String, ancestry: Set<String>) throws -> Snapshot {
        var result = Snapshot()
        let canonical = URL(fileURLWithPath: file).standardizedFileURL.resolvingSymlinksInPath().path
        let directory = Self.directory(root: root, file: file)
        guard FileManager.default.fileExists(atPath: directory.path) else { return result }
        guard directory.resolvingSymlinksInPath().path == directory.path else { result.warning = true; return result }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            result.warning = true; return result
        }
        let selection = Self.summaryNames(names)
        if selection.truncated { result.warning = true }
        let now = Date()
        for name in selection.names {
            try Task.checkCancellation()
            guard result.items.count < 512 else { result.warning = true; break }
            let id = String(name.dropLast(".summary.json".count))
            guard UUID(uuidString: id) != nil else { continue }
            do {
                let value = try json(directory.appendingPathComponent(name), limit: 32_768)
                guard value["schema"]?.int == 1, value["id"]?.string == id,
                      value["sessionID"]?.string == sessionID, value["sessionFile"]?.string == canonical else { continue }
                if let leaf = value["leafID"]?.string, !ancestry.contains(leaf) { continue }
                guard value["leafID"]?.string != nil || value["leafID"]?.isNull == true,
                      let time = value["startedAt"]?.double, time.isFinite, time > 0,
                      let kind = value["kind"]?.string,
                      ["model_request", "side_request", "provider_payload", "provider_response"].contains(kind),
                      let statusName = value["status"]?.string, var status = OMPSessionRecordStatus(rawValue: statusName) else {
                    result.warning = true; continue
                }
                let pid = value["pid"]?.int.flatMap { Int32(exactly: $0) }.flatMap { $0 > 0 ? $0 : nil }
                let ownerID = value["ownerID"]?.string
                let wasRunning = status == .running
                status = refreshedStatus(status, pid: pid, ownerID: ownerID, now: now)
                let model = value["model"]?.string.map { String($0.prefix(512)) }
                let provider = value["provider"]?.string.map { String($0.prefix(512)) }
                let record = OMPSessionRecord(id: "session:\(sessionID.utf8.count):\(sessionID):request:" + id,
                    entryID: id, kind: .request, status: status, title: kind,
                    summary: [provider, model].compactMap { $0 }.joined(separator: " · "),
                    timestamp: Date(timeIntervalSince1970: time / 1000), model: model, toolCallID: nil,
                    duration: value["duration"]?.double.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                    tokens: value["tokens"]?.int.flatMap { $0 >= 0 ? $0 : nil })
                let document = directory.appendingPathComponent(id + ".json")
                result.items.append(Item(record: record, file: document, revision: PreviewFileMetadata.read(document),
                                         pid: pid, ownerID: ownerID, wasRunning: wasRunning, leafID: value["leafID"]?.string,
                                         context: OMPContextRequestMetadata(value)))
            } catch is CancellationError { throw CancellationError() }
            catch { result.warning = true }
        }
        return result
    }

    /// A cached snapshot may still contain a request whose journal status is
    /// running. Re-evaluate only those; completed evidence is authoritative and
    /// never changes back into running.
    func refreshRunning(_ snapshot: inout Snapshot) {
        let now = Date()
        for index in snapshot.items.indices where snapshot.items[index].wasRunning {
            let item = snapshot.items[index]
            snapshot.items[index].record.status = refreshedStatus(.running, pid: item.pid, ownerID: item.ownerID, now: now)
        }
    }

    private func refreshedStatus(_ status: OMPSessionRecordStatus, pid: Int32?, ownerID: String?,
                                 now: Date) -> OMPSessionRecordStatus {
        guard status == .running else { return status }
        guard let pid, pid > 0 else { return .interrupted }
        if kill(pid, 0) != 0, errno == ESRCH { return .interrupted }
        guard let ownerID, UUID(uuidString: ownerID) != nil,
              let lease = try? json(root.appendingPathComponent(ownerID + ".owner.json"), limit: 1_024),
              lease["id"]?.string == ownerID, lease["pid"]?.int == Int(pid),
              let updated = lease["updatedAt"]?.double, updated.isFinite,
              now.timeIntervalSince1970 * 1_000 - updated < 60_000 else { return .interrupted }
        return .running
    }

    func sections(_ item: Item, sessionID: String, file: String) throws -> [OMPSessionDetailSection: JSONValue] {
        let value = try json(item.file, limit: 5 * 1024 * 1024, expected: item.revision)
        guard value["schema"]?.int == 1, value["id"]?.string == item.record.entryID,
              value["sessionID"]?.string == sessionID,
              value["sessionFile"]?.string == URL(fileURLWithPath: file).resolvingSymlinksInPath().path else {
            throw OMPSessionRecordError.changed
        }
        var sections: [OMPSessionDetailSection: JSONValue] = [:]
        for section in OMPSessionDetailSection.allCases {
            sections[section] = value["sections"]?[section.rawValue]
        }
        var metadata = value.object ?? [:]
        metadata.removeValue(forKey: "sections")
        metadata.removeValue(forKey: "payloads")
        metadata.removeValue(forKey: "responses")
        metadata["status"] = .string(item.record.status?.rawValue ?? "interrupted")
        sections[.metadata] = .object(metadata)
        return sections
    }

    private func json(_ url: URL, limit: Int, expected: PreviewFileMetadata? = nil) throws -> JSONValue {
        try Task.checkCancellation()
        guard url.path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath().path == url.path else { throw OMPSessionRecordError.outsideStore }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw OMPSessionRecordError.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat(), actual = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit,
              fcntl(fd, F_GETPATH, &actual) == 0, String(cString: actual) == url.path else { throw OMPSessionRecordError.unavailable }
        let revision = PreviewFileMetadata(info)
        if let expected, revision != expected { throw OMPSessionRecordError.changed }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count == info.st_size, fstat(fd, &info) == 0, PreviewFileMetadata(info) == revision,
              PreviewFileMetadata.read(url) == revision else { throw OMPSessionRecordError.changed }
        guard let value = JSONValue.parse(data) else { throw OMPSessionRecordError.invalidJournal }
        return value
    }
}
