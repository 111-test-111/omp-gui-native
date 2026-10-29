import Foundation
import CryptoKit
import Darwin

/// One visible source, one serial index. No RPC or runtime launch.
actor OMPSessionRecordReader: OMPSessionRecordReading {
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumEntries = 50_000
    static let maximumLineBytes = 8 * 1024 * 1024
    static let textPageSize = 16_384
    static let fieldPageSize = 40
    static let maximumDepth = 16
    static let maximumDetailRows = 400
    static let maximumExpandedTextScalars = 65_536
    static let maximumJSONCopyBytes = 16 * 1024 * 1024
    static let maximumJSONCopyNodes = 500_000
    static let maximumJSONCopyDepth = 128

    private struct Span: Sendable {
        let offset: UInt64
        let count: Int
        let digest: SHA256.Digest
    }
    private struct Item: Sendable {
        var record: OMPSessionRecord
        let span: Span
        var toolIndex: Int?
        var result: Span?
        var isResult = false
        var starts: [Span] = []
        var isStart = false
    }
    private struct Node {
        let parent: String?
        let items: [Item]
    }
    private struct Index {
        let file: String
        let revision: PreviewFileMetadata
        let items: [Item] // oldest first, current ancestry only
        let sessionID: String
        let ancestry: Set<String>
        let aliases: [String: Alias]
        let roundsByEntry: [String: String]
    }
    private struct Alias {
        let target: String
        var section: OMPSessionDetailSection?
    }
    private struct CaptureCache {
        let file: String
        let sessionID: String
        let ancestry: Set<String>
        let summaries: [String: PreviewFileMetadata]
        let snapshot: OMPRequestRecordStore.Snapshot
    }
    private struct CaptureDetailCache {
        let file: String
        let id: String
        let revision: PreviewFileMetadata?
        let sections: [OMPSessionDetailSection: JSONValue]
    }
    private let root: URL
    private var index: Index?
    private var captureCache: CaptureCache?
    private var captureDetailCache: CaptureDetailCache?
    private let fractionalDates: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()
    private let dates = ISO8601DateFormatter()

    init(root: URL = StoragePaths.root.appendingPathComponent("omp/sessions", isDirectory: true)) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    func release() { index = nil; captureCache = nil; captureDetailCache = nil }

    func read(_ request: OMPSessionRecordRequest) throws -> OMPSessionRecordPage {
        let (handle, revision) = try open(request.file)
        defer { try? handle.close() }
        if index?.file != request.file || index?.revision != revision {
            // Reindex all complete lines on mutation: OMP can rewrite the title
            // slot in place, truncate, or atomically replace a same-sized file.
            index = nil
            let scanned = try scan(handle, size: Int(revision.byteCount))
            try validate(handle, file: request.file, revision: revision)
            index = Index(file: request.file, revision: revision, items: scanned.items, sessionID: scanned.sessionID,
                          ancestry: scanned.ancestry, aliases: scanned.aliases, roundsByEntry: scanned.roundsByEntry)
        }
        guard let index else { throw OMPSessionRecordError.unavailable }
        try Task.checkCancellation()
        let capturesRoot = root.deletingLastPathComponent().appendingPathComponent("requests")
        let captures = OMPRequestRecordStore(root: capturesRoot)
        let captureDirectory = OMPRequestRecordStore.directory(root: capturesRoot, file: request.file)
        let summaries = OMPRequestRecordStore.summaryMetadata(in: captureDirectory)
        var captured: OMPRequestRecordStore.Snapshot
        if let summaries, let cached = captureCache, cached.file == request.file,
           cached.sessionID == index.sessionID, cached.ancestry == index.ancestry,
           cached.summaries == summaries {
            captured = cached.snapshot
        } else {
            captured = try captures.read(file: request.file, sessionID: index.sessionID, ancestry: index.ancestry)
            captureCache = summaries.map {
                CaptureCache(file: request.file, sessionID: index.sessionID, ancestry: index.ancestry,
                             summaries: $0, snapshot: captured)
            }
        }
        captures.refreshRunning(&captured)
        captured.warning = captured.warning || OMPRequestRecordStore.healthWarning(root: capturesRoot, file: request.file)
        let rounds = Dictionary(index.items.filter { $0.record.kind == .user }.map { ($0.record.id, $0.record.roundNumber) },
                                uniquingKeysWith: { first, _ in first })
        let capturedRecords = captured.items.map { item in
            var record = item.record
            record.roundID = item.leafID.flatMap { index.roundsByEntry[$0] }
            record.roundNumber = record.roundID.flatMap { rounds[$0] ?? nil }
            return record
        }
        let chronological = request.viewMode == .tree || request.sortOrder == .oldestFirst
        let all = (index.items.map(\.record) + capturedRecords).enumerated().sorted {
            let first = $0.element.timestamp ?? .distantPast, second = $1.element.timestamp ?? .distantPast
            if first != second { return chronological ? first < second : first > second }
            // A request can share its completion's millisecond. Display the
            // request first, then retain native response/tool block order.
            if ($0.element.kind == .request) != ($1.element.kind == .request) {
                return $0.element.kind == .request
            }
            return $0.offset < $1.offset
        }.map(\.element)
        let filtered = all.filter { request.filter.matches($0) }
        let last = max(0, (filtered.count - 1) / OMPSessionRecordPage.size)
        let anchored = request.anchor.flatMap { id in filtered.firstIndex { $0.id == (index.aliases[id]?.target ?? id) } }
        let tree = request.viewMode == .tree ? OMPSessionRecordTree.page(records: all, filter: request.filter,
            order: request.sortOrder, page: request.page, anchor: request.anchor.map { index.aliases[$0]?.target ?? $0 },
            expanded: request.expandedRecordIDs, collapsed: request.collapsedRecordIDs,
            childPages: request.childPages, sessionID: "session:\(index.sessionID):") : nil
        let page = tree?.page ?? min(last, max(0, anchored.map { $0 / OMPSessionRecordPage.size } ?? request.page))
        let start = page * OMPSessionRecordPage.size
        let records = tree.map { $0.rows.filter { $0.continuationParentID == nil }.map(\.record) }
            ?? Array(filtered.dropFirst(start).prefix(OMPSessionRecordPage.size))
        let alias = request.selectedID.flatMap { index.aliases[$0] }
        let selected = request.selectedID.flatMap { id in index.items.first { $0.record.id == (alias?.target ?? id) } }
        var address = request.address
        if let section = alias?.section { address.section = section }
        var detail = try selected.map { try detail($0, address: address, expansion: request.detailExpansion,
                                                  viewMode: request.detailViewMode, includeJSON: request.includeJSON, handle: handle) }
        if var selected = captured.items.first(where: { $0.record.id == request.selectedID }) {
            if let projected = capturedRecords.first(where: { $0.id == selected.record.id }) { selected.record = projected }
            let documentRevision = PreviewFileMetadata.read(selected.file)
            selected.revision = documentRevision
            do {
                let sections: [OMPSessionDetailSection: JSONValue]
                if let cached = captureDetailCache, cached.file == request.file, cached.id == selected.record.id,
                   cached.revision == documentRevision {
                    sections = cached.sections
                } else {
                    sections = try captures.sections(selected, sessionID: index.sessionID, file: request.file)
                    captureDetailCache = CaptureDetailCache(file: request.file, id: selected.record.id,
                                                            revision: documentRevision, sections: sections)
                }
                detail = try renderDetail(selected.record, sections: sections, address: request.address,
                                          expansion: request.detailExpansion, viewMode: request.detailViewMode, includeJSON: request.includeJSON)
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Retention, corruption or a replaced sidecar must not make the
                // native journal unreadable or keep stale request content alive.
                captureDetailCache = nil
                if request.includeJSON { throw error }
                captured.warning = true
                detail = try renderDetail(selected.record, sections: [.capture: .object(["error": .string("capture_unavailable")])],
                                          address: .init(), viewMode: request.detailViewMode)
            }
        }
        try validate(handle, file: request.file, revision: revision)
        return OMPSessionRecordPage(records: records, total: filtered.count, page: page, detail: detail,
                                   captureWarning: captured.warning, treeRows: tree?.rows ?? [], totalRounds: tree?.totalRounds, totalRoots: tree?.totalRoots,
                                   expandedRecordIDs: tree?.expanded ?? [])
    }

    private func open(_ file: String) throws -> (FileHandle, PreviewFileMetadata) {
        let url = URL(fileURLWithPath: file).standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension == "jsonl", url.path.hasPrefix(root.path + "/") else {
            throw OMPSessionRecordError.outsideStore
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw OMPSessionRecordError.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw OMPSessionRecordError.unavailable }
            var path = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard fcntl(fd, F_GETPATH, &path) == 0,
                  URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
                throw OMPSessionRecordError.outsideStore
            }
            guard info.st_size >= 0, info.st_size <= Self.maximumBytes else { throw OMPSessionRecordError.tooLarge }
            return (handle, PreviewFileMetadata(info))
        } catch { try? handle.close(); throw error }
    }

    private func validate(_ handle: FileHandle, file: String, revision: PreviewFileMetadata) throws {
        try Task.checkCancellation()
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, PreviewFileMetadata(info) == revision,
              PreviewFileMetadata.read(URL(fileURLWithPath: file)) == revision else { throw OMPSessionRecordError.changed }
    }

    private func scan(_ handle: FileHandle, size: Int) throws -> (items: [Item], sessionID: String, ancestry: Set<String>, aliases: [String: Alias], roundsByEntry: [String: String]) {
        var pending = Data()
        var offset: UInt64 = 0
        var remaining = size
        var nodes: [String: Node] = [:]
        var leaf: String?
        var sawHeader = false
        var sessionID = ""
        var headerID = ""
        var count = 0
        var projectedCount = 0
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(65_536, remaining)) ?? Data()
            guard !chunk.isEmpty else { throw OMPSessionRecordError.changed }
            remaining -= chunk.count
            pending.append(chunk)
            while let end = pending.firstIndex(of: 10) {
                let line = Data(pending[..<end])
                let consumed = line.count + 1
                defer { pending.removeFirst(consumed); offset += UInt64(consumed) }
                guard line.count <= Self.maximumLineBytes else { throw OMPSessionRecordError.tooLarge }
                if line.isEmpty { continue }
                guard let entry = JSONValue.parse(line), let type = entry["type"]?.string else {
                    throw OMPSessionRecordError.invalidJournal
                }
                count += 1
                guard count <= Self.maximumEntries else { throw OMPSessionRecordError.tooLarge }
                if type == "session" {
                    guard !sawHeader, nodes.isEmpty, let id = identity(entry["id"]) else { throw OMPSessionRecordError.invalidJournal }
                    sessionID = "session:\(id.utf8.count):\(id):"
                    headerID = id; sawHeader = true; continue
                }
                // OMP's reserved, mutable title slot is not a branch node.
                if type == "title", entry["id"] == nil { continue }
                guard sawHeader else { throw OMPSessionRecordError.invalidJournal }
                guard let id = entry["id"]?.string, !id.isEmpty, id.utf8.count <= 512,
                      entry["parentId"] != nil, nodes[id] == nil else { throw OMPSessionRecordError.invalidJournal }
                let parent = entry["parentId"]?.string
                guard parent != nil || entry["parentId"]?.isNull == true else { throw OMPSessionRecordError.invalidJournal }
                let span = Span(offset: offset, count: line.count, digest: SHA256.hash(data: line))
                let items = try project(entry, id: id, sessionID: sessionID, span: span)
                projectedCount += items.count
                guard projectedCount <= Self.maximumEntries else { throw OMPSessionRecordError.tooLarge }
                nodes[id] = Node(parent: parent, items: items)
                if let active = entry["activeLeafId"] {
                    guard active.string != nil || active.isNull else { throw OMPSessionRecordError.invalidJournal }
                    leaf = active.string
                } else { leaf = id }
            }
            guard pending.count <= Self.maximumLineBytes else { throw OMPSessionRecordError.tooLarge }
        }
        // Incomplete tails are deliberately neither decoded nor indexed.
        guard sawHeader || size == 0 || !pending.isEmpty else { throw OMPSessionRecordError.invalidJournal }
        var seen = Set<String>()
        var ancestry: [Node] = []
        var ancestryIDs: [String] = []
        while let id = leaf {
            try Task.checkCancellation()
            guard seen.insert(id).inserted, let node = nodes[id] else { throw OMPSessionRecordError.invalidJournal }
            ancestry.append(node); ancestryIDs.append(id); leaf = node.parent
        }
        var items: [Item] = []
        var roundID: String?
        var roundNumber = 0
        var roundsByEntry: [String: String] = [:]
        for (id, node) in zip(ancestryIDs.reversed(), ancestry.reversed()) {
            if let user = node.items.first(where: { $0.record.kind == .user }) {
                roundID = user.record.id; roundNumber += 1
            }
            roundsByEntry[id] = roundID
            let response = node.items.first { $0.record.kind == .response }?.record.id
            for var item in node.items {
                item.record.roundID = roundID
                item.record.roundNumber = roundID == nil ? nil : roundNumber
                if item.toolIndex != nil { item.record.parentRecordID = response }
                items.append(item)
            }
        }
        guard items.count <= Self.maximumEntries else { throw OMPSessionRecordError.tooLarge }
        // Native user entries delimit rounds. A continued round can replace an
        // earlier normal stop; only its last assistant envelope can be final.
        var previousResponse: Int?
        for i in items.indices {
            if items[i].record.kind == .user { previousResponse = nil }
            else if items[i].record.kind == .response {
                if let previousResponse { items[previousResponse].record.isFinalReply = false }
                previousResponse = i
            }
        }
        // Exact native call IDs, on this branch only. Ambiguous IDs never join.
        var calls: [String: [Int]] = [:]
        var results: [String: [Int]] = [:]
        var starts: [String: [Int]] = [:]
        for i in items.indices {
            guard let id = items[i].record.toolCallID else { continue }
            if items[i].isResult { results[id, default: []].append(i) }
            else if items[i].isStart { starts[id, default: []].append(i) }
            else if items[i].toolIndex != nil { calls[id, default: []].append(i) }
        }
        var merged = Set<Int>()
        var aliases: [String: Alias] = [:]
        for id in Set(calls.keys).union(starts.keys) {
            try Task.checkCancellation()
            let callIndices = calls[id] ?? [], startIndices = starts[id] ?? []
            let call: Int
            if callIndices.count == 1 { call = callIndices[0] }
            else if callIndices.isEmpty, startIndices.count == 1 { call = startIndices[0] }
            else { continue }
            let result = results[id] ?? []
            var end: Int?
            if result.count == 1, result[0] > call,
               items[result[0]].record.title == "toolResult" || items[result[0]].record.title == items[call].record.title {
                end = result[0]
                items[call].result = items[result[0]].span
                items[call].record.status = items[result[0]].record.status
                merged.insert(result[0])
            }
            for start in startIndices where items[start].record.title == items[call].record.title {
                guard start >= call, end.map({ start < $0 }) ?? true else { continue }
                items[call].starts.append(items[start].span)
                if start != call {
                    merged.insert(start)
                    aliases[items[start].record.id] = Alias(target: items[call].record.id, section: .executionStart)
                }
            }
        }
        return (items.enumerated().compactMap { merged.contains($0.offset) ? nil : $0.element }, headerID, seen, aliases, roundsByEntry)
    }

    private func project(_ entry: JSONValue, id: String, sessionID: String, span: Span) throws -> [Item] {
        let type = entry["type"]?.string ?? ""
        if type == "credential_pin" { return [] }
        let message = entry["message"]
        let role = message?["role"]?.string
        var kind: OMPSessionRecordKind
        switch type {
        case "message": kind = role == "user" ? .user : role == "assistant" ? .response : role == "toolResult" ? .tool : .other
        case "compaction", "branch_summary", "reset_boundary": kind = .context
        case "model_change", "thinking_level_change", "service_tier_change": kind = .configuration
        case "model_usage": kind = .usage
        default: kind = .other
        }
        var status: OMPSessionRecordStatus?
        if role == "toolResult" { status = message?["isError"]?.bool == true ? .failed : .completed }
        else if role == "assistant" {
            switch message?["stopReason"]?.string {
            case "error": status = .failed
            case "aborted": status = .cancelled
            case "stop", "length", "toolUse": status = .completed
            default: status = nil
            }
        } else { status = nil }
        let blocks = message?["content"]?.array ?? []
        let start = type == "custom" && entry["customType"]?.string == "tool_execution_start" ? entry["data"] : nil
        let isStart = identity(start?["toolName"]) != nil && identity(start?["toolCallId"]) != nil
        let title: String
        var summary = excerpt(message?["content"] ?? entry["summary"] ?? entry["title"] ?? entry["model"] ?? entry["content"] ?? .string(""))
        let responseText = kind == .response ? messageText(message?["content"]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if responseText == "." { summary = "" }
        if type == "thinking_level_change" { summary = limited(entry["thinkingLevel"]?.string ?? "") }
        if isStart, let name = identity(start?["toolName"]) {
            // A start without a visible assistant call is still a tool
            // observation. Its recorded argument projection stays in details.
            title = name; kind = .tool; status = .unrecorded
            summary = toolSummary(name, arguments: start?["args"], fallback: start?["intent"]?.string)
        } else if type == "custom", entry["customType"]?.string == "session_exit" {
            title = "session_exit"
        } else {
            title = role == "toolResult" ? message?["toolName"]?.string ?? "toolResult" : (role ?? type)
            if role == "toolResult" { summary = "" }
        }
        let model = message?["model"]?.string ?? entry["model"]?.string
        let record = OMPSessionRecord(id: sessionID + "entry:" + id, entryID: id, kind: kind, status: status,
            title: limited(title), summary: summary, timestamp: date(entry), model: model.map(limited),
            toolCallID: identity(isStart ? start?["toolCallId"] : message?["toolCallId"]),
            duration: message?["duration"]?.double.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            tokens: message?["usage"]?["totalTokens"]?.int.flatMap { $0 >= 0 ? $0 : nil },
            isFinalReply: kind == .response && message?["stopReason"]?.string == "stop"
                && !responseText.isEmpty && responseText != "." && !blocks.contains { $0["type"]?.string == "toolCall" })
        // Every native assistant envelope is one response, even without prose.
        // Its tool blocks follow it in their original order.
        var items = [Item(record: record, span: span, isResult: role == "toolResult", isStart: isStart)]
        if role == "assistant" {
            for (i, block) in blocks.enumerated() where block["type"]?.string == "toolCall" {
                try Task.checkCancellation()
                guard items.count < Self.maximumEntries else { throw OMPSessionRecordError.tooLarge }
                let call = OMPSessionRecord(id: sessionID + "tool:" + id + ":\(i)", entryID: id, kind: .tool, status: .unrecorded,
                    title: limited(block["name"]?.string ?? "toolCall"),
                    summary: toolSummary(block["name"]?.string ?? "toolCall", arguments: block["arguments"]),
                    timestamp: record.timestamp, model: record.model, toolCallID: identity(block["id"]), duration: nil, tokens: nil)
                items.append(Item(record: call, span: span, toolIndex: i))
            }
        }
        return items
    }

    private func date(_ entry: JSONValue) -> Date? {
        if let text = entry["timestamp"]?.string { return fractionalDates.date(from: text) ?? dates.date(from: text) }
        if let time = entry["message"]?["timestamp"]?.double, time.isFinite, time > 0 {
            return Date(timeIntervalSince1970: time > 100_000_000_000 ? time / 1000 : time)
        }
        return nil
    }

    private func entry(_ span: Span, handle: FileHandle) throws -> JSONValue {
        try Task.checkCancellation()
        try handle.seek(toOffset: span.offset)
        let data = try handle.read(upToCount: span.count) ?? Data()
        guard data.count == span.count, SHA256.hash(data: data) == span.digest else { throw OMPSessionRecordError.changed }
        guard let value = JSONValue.parse(data) else { throw OMPSessionRecordError.invalidJournal }
        return value
    }

    private func detail(_ item: Item, address: OMPSessionDetailAddress, expansion: OMPSessionDetailExpansion,
                        viewMode: OMPSessionRecordViewMode, includeJSON: Bool, handle: FileHandle) throws -> OMPSessionRecordDetail {
        let value = try entry(item.span, handle: handle)
        let message = value["message"]
        var sections: [OMPSessionDetailSection: JSONValue] = [:]
        if item.toolIndex != nil || item.isStart {
            if let toolIndex = item.toolIndex { sections[.input] = message?["content"]?[toolIndex]?["arguments"] ?? .null }
            if let span = item.result {
                let result = try entry(span, handle: handle)["message"]
                sections[.output] = content(result?["content"])
                sections[.result] = result?["details"]
            }
        } else if item.isResult {
            sections[.output] = content(message?["content"])
            sections[.result] = message?["details"]
        } else if let message {
            sections[.message] = content(message["content"], omittingText: item.record.kind == .response && hasOnlyDotText(message["content"]))
        } else {
            sections[.message] = value["summary"] ?? value["content"]
            sections[.result] = value["details"] ?? value["data"]
        }
        if item.record.kind == .response {
            let thinking = (message?["content"]?.array ?? []).filter { $0["type"]?.string == "thinking" }
                .compactMap { $0["thinking"]?.string }.joined(separator: "\n\n")
            if !thinking.isEmpty { sections[.thinking] = .string(thinking) }
        }
        // Explicit metadata projection excludes credential pins, provider replay
        // payloads, image blobs and unknown future native secret-bearing fields.
        var metadata: [String: JSONValue] = [:]
        for key in ["id", "parentId", "type", "timestamp", "model", "role", "purpose", "thinkingLevel", "configured", "serviceTier", "tokensBefore", "tokensAfter", "firstKeptEntryId", "method", "title", "label", "customType"] {
            metadata[key] = value[key]
        }
        if item.toolIndex == nil {
            for key in ["provider", "model", "api", "usage", "stopReason", "errorMessage", "errorStatus", "errorId", "duration", "ttft", "completedAt", "toolCallId", "toolName", "isError"] {
                metadata[key] = message?[key] ?? value[key] ?? metadata[key]
            }
        }
        if let call = item.record.toolCallID { metadata["toolCallId"] = .string(call) }
        if item.record.kind == .tool { metadata["toolName"] = .string(item.record.title) }
        let startSpans = item.starts.isEmpty && item.isStart ? [item.span] : item.starts
        var startData: [JSONValue] = [], startMetadata: [JSONValue] = []
        for span in startSpans {
            let start = try entry(span, handle: handle)
            startData.append(start["data"] ?? .null)
            startMetadata.append(.object(Dictionary(uniqueKeysWithValues: ["id", "parentId", "type", "customType", "timestamp"].compactMap { key in
                start[key].map { (key, $0) }
            })))
        }
        if !startData.isEmpty {
            sections[.executionStart] = startData.count == 1 ? startData[0] : .array(startData)
            metadata["executionStartEntries"] = .array(startMetadata)
        }
        sections[.metadata] = .object(metadata)
        return try renderDetail(item.record, sections: sections, address: address, expansion: expansion,
                                viewMode: viewMode, includeJSON: includeJSON)
    }

    private func renderDetail(_ record: OMPSessionRecord, sections: [OMPSessionDetailSection: JSONValue], address: OMPSessionDetailAddress,
                              expansion: OMPSessionDetailExpansion = .init(),
                              viewMode: OMPSessionRecordViewMode = .tree, includeJSON: Bool = false) throws -> OMPSessionRecordDetail {
        let available = OMPSessionDetailSection.allCases.filter { sections[$0] != nil }
        let preferred: OMPSessionDetailSection
        if record.kind == .tool, sections[.input] != nil {
            preferred = .input
        } else if record.kind == .response,
                  sections[.message]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            preferred = sections[.thinking] != nil ? .thinking : .metadata
        } else if sections[.requestOptions]?.object?.isEmpty == true,
                  let first = available.first(where: { $0 != .requestOptions }) {
            preferred = first
        } else {
            preferred = available[0]
        }
        let section = address.section.flatMap { sections[$0] == nil ? nil : $0 } ?? preferred
        var selected = sections[section]!
        var path: [OMPSessionDetailKey] = []
        for key in address.path.prefix(Self.maximumDepth) {
            let next: JSONValue?
            switch key {
            case .field(let name): next = visibleKeys(selected).contains(name) ? selected[name] : nil
            case .index(let i): next = selected[i]
            }
            guard let next else { break }
            selected = next; path.append(key)
        }
        var rows: [OMPSessionDetailRow] = []
        var text: String?
        var isLimited = false
        var textBudget = Self.maximumExpandedTextScalars
        let expandAll = viewMode == .tree && expansion.expandAll
        var expanded = viewMode == .flat || expandAll ? [] : Set(expansion.paths.prefix(OMPSessionDetailExpansion.maximumBranches))
        @discardableResult func appendFields(_ container: JSONValue, parent: [OMPSessionDetailKey],
                                             start: Int, limit: Int, ancestors: [Bool], hasContinuation: Bool = false) throws -> Int {
            let keys = container.object != nil ? visibleKeys(container) : []
            guard keys.allSatisfy({ $0.utf8.count <= 512 }) else { throw OMPSessionRecordError.tooLarge }
            let count = container.array?.count ?? keys.count
            var loaded = 0
            for index in min(start, count)..<min(count, start + limit) {
                try Task.checkCancellation()
                guard rows.count < Self.maximumDetailRows else { isLimited = true; break }
                let key: OMPSessionDetailKey = container.array != nil ? .index(index) : .field(keys[index])
                let value = container.array?[index] ?? container[keys[index]] ?? .null
                let fieldPath = parent + [key]
                let childCount = value.array?.count ?? (value.object != nil ? visibleKeys(value).count : 0)
                let string = value.string
                let scalarCount = string?.unicodeScalars.count ?? 0
                let kind: OMPSessionDetailValueKind = value.object != nil ? .object : value.array != nil ? .array
                    : scalarCount > 160 || string?.contains("\n") == true ? .text : .scalar
                var row = OMPSessionDetailRow(key: key, preview: preview(value), path: fieldPath, valueKind: kind,
                    count: kind == .text ? scalarCount : childCount, ancestorContinuations: ancestors,
                    isLastSibling: index == min(count, start + limit) - 1 && !hasContinuation)
                let automatic = expandAll && row.canExpand && !expanded.contains(fieldPath)
                if automatic {
                    if expanded.count < OMPSessionDetailExpansion.maximumBranches { expanded.insert(fieldPath) }
                    else { isLimited = true }
                }
                row.isExpanded = row.canExpand && expanded.contains(fieldPath)
                let slot = rows.count
                rows.append(row); loaded += 1
                if row.isExpanded, kind == .text, let string {
                    let scalars = string.unicodeScalars
                    row.pageCount = max(1, (scalarCount + Self.textPageSize - 1) / Self.textPageSize)
                    row.page = min(row.pageCount - 1, max(0, expansion.pages[fieldPath] ?? 0))
                    let fragment = scalars.dropFirst(row.page * Self.textPageSize).prefix(Self.textPageSize)
                    guard fragment.count <= textBudget else {
                        isLimited = true; row.isExpanded = false
                        if automatic { expanded.remove(fieldPath) }
                        rows[slot] = row; continue
                    }
                    row.text = String(String.UnicodeScalarView(fragment)); textBudget -= fragment.count
                } else if row.isExpanded {
                    row.pageCount = max(1, (childCount + Self.fieldPageSize - 1) / Self.fieldPageSize)
                    row.page = min(row.pageCount - 1, max(0, expansion.pages[fieldPath] ?? 0))
                    row.loadedCount = try appendFields(value, parent: fieldPath, start: row.page * Self.fieldPageSize,
                        limit: Self.fieldPageSize, ancestors: ancestors + [!row.isLastSibling], hasContinuation: row.pageCount > 1)
                }
                rows[slot] = row
            }
            return loaded
        }
        let pages: Int
        let page: Int
        switch selected {
        case .object:
            let keys = visibleKeys(selected)
            pages = max(1, (keys.count + Self.fieldPageSize - 1) / Self.fieldPageSize)
            page = min(max(0, address.page), pages - 1)
            try appendFields(selected, parent: path, start: page * Self.fieldPageSize, limit: Self.fieldPageSize, ancestors: [])
            if keys.isEmpty { text = "{}" }
        case .array(let values):
            pages = max(1, (values.count + Self.fieldPageSize - 1) / Self.fieldPageSize)
            page = min(max(0, address.page), pages - 1)
            try appendFields(selected, parent: path, start: page * Self.fieldPageSize, limit: Self.fieldPageSize, ancestors: [])
            if values.isEmpty { text = "[]" }
        default:
            let string = selected.string ?? selected.compactString
            let scalars = string.unicodeScalars
            let count = scalars.count
            pages = max(1, (count + Self.textPageSize - 1) / Self.textPageSize)
            page = min(max(0, address.page), pages - 1)
            text = String(String.UnicodeScalarView(scalars.dropFirst(page * Self.textPageSize).prefix(Self.textPageSize)))
        }
        let copiedJSON = includeJSON ? try jsonCopy(selected) : nil
        return OMPSessionRecordDetail(record: record, sections: available,
            address: .init(section: section, path: path, page: page), rows: rows, text: text, pageCount: pages,
            isLimited: isLimited, viewMode: viewMode, expandedPaths: expanded, jsonCopy: copiedJSON)
    }

    /// Serialize the complete selected value, including undisplayed pages.
    /// Build bounded pretty JSON directly so deep indentation cannot allocate
    /// an oversized intermediate document. Credential/blob exclusions are the
    /// same at every depth as in the field reader.
    private func jsonCopy(_ value: JSONValue) throws -> String {
        var output = Data()
        var nodes = 0
        let options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        func append(_ data: Data) throws {
            guard data.count <= Self.maximumJSONCopyBytes - output.count else { throw OMPSessionRecordError.jsonCopyTooLarge }
            output.append(data)
        }
        func appendText(_ text: String) throws { try append(Data(text.utf8)) }
        func write(_ value: JSONValue, depth: Int) throws {
            try Task.checkCancellation()
            nodes += 1
            guard nodes <= Self.maximumJSONCopyNodes, depth <= Self.maximumJSONCopyDepth else {
                throw OMPSessionRecordError.jsonCopyTooLarge
            }
            let indent = String(repeating: "  ", count: depth)
            switch value {
            case .object:
                let keys = visibleKeys(value)
                try appendText("{")
                for (index, key) in keys.enumerated() {
                    try appendText("\n" + indent + "  ")
                    try append(JSONSerialization.data(withJSONObject: key, options: options))
                    try appendText(": ")
                    try write(value[key] ?? .null, depth: depth + 1)
                    if index + 1 < keys.count { try appendText(",") }
                }
                if !keys.isEmpty { try appendText("\n" + indent) }
                try appendText("}")
            case .array(let values):
                try appendText("[")
                for index in values.indices {
                    try appendText("\n" + indent + "  ")
                    try write(values[index], depth: depth + 1)
                    if index + 1 < values.count { try appendText(",") }
                }
                if !values.isEmpty { try appendText("\n" + indent) }
                try appendText("]")
            default:
                try append(JSONSerialization.data(withJSONObject: value.foundationObject, options: options))
            }
        }
        try write(value, depth: 0)
        return String(decoding: output, as: UTF8.self)
    }

    /// A lone dot is a display placeholder only for model prose. Native logs,
    /// reasoning, user messages and tool inputs/outputs keep their exact text.
    private func hasOnlyDotText(_ value: JSONValue?) -> Bool {
        messageText(value).trimmingCharacters(in: .whitespacesAndNewlines) == "."
    }

    private func messageText(_ value: JSONValue?) -> String {
        value?.string ?? (value?.array ?? []).filter { $0["type"]?.string == "text" }
            .compactMap { $0["text"]?.string }.joined(separator: "\n\n")
    }

    private func content(_ value: JSONValue?, omittingText: Bool = false) -> JSONValue {
        guard let blocks = value?.array else { return omittingText ? .string("") : value ?? .string("") }
        // Native image bytes and blob references are not loaded by this reader.
        let visible = blocks.compactMap { block -> JSONValue? in
            switch block["type"]?.string {
            case "text": return omittingText ? nil : block["text"]
            case "image": return .object(["type": .string("image"), "mimeType": block["mimeType"] ?? .null])
            case "redactedThinking": return .object(["type": .string("redactedThinking")])
            default: return nil
            }
        }
        if visible.allSatisfy({ $0.string != nil }) { return .string(visible.compactMap(\.string).joined(separator: "\n\n")) }
        return .array(visible)
    }

    /// List captions describe the operation's subject. Full inputs remain in
    /// lazy details; nulls, execution options and replacement bodies stay there.
    private func toolSummary(_ name: String, arguments: JSONValue?, fallback: String? = nil, depth: Int = 0) -> String {
        let args = arguments ?? .null
        func text(_ value: JSONValue?) -> String? {
            let raw: String?
            if let string = value?.string { raw = string }
            else if let number = value?.int { raw = String(number) }
            else if let values = value?.array {
                raw = values.prefix(6).compactMap { value in
                    value.string ?? value["path"]?.string ?? value["file_path"]?.string ?? value["name"]?.string
                }.map(limited).joined(separator: " · ")
            } else { raw = nil }
            guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return limited(raw).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }
        func first(_ keys: String...) -> String? {
            keys.lazy.compactMap { text(args[$0]) }.first
        }
        func joined(_ parts: String?...) -> String? {
            let values = parts.compactMap { $0 }
            return values.isEmpty ? nil : values.joined(separator: " · ")
        }
        if depth == 0, name == "write", let path = first("path", "file_path"),
           let device = OMPTool.deviceName(in: path), OMPTool.named(device) != nil,
           let content = args["content"]?.string, let inner = JSONValue.parse(content), inner.object != nil {
            return limited(joined(path, toolSummary(device, arguments: inner, depth: depth + 1)) ?? path)
        }
        guard let tool = OMPTool.named(name) else {
            // MCP and extension schemas are dynamic. Show a known subject or
            // recorded intent, never an arbitrary dump of unknown fields.
            return limited(first("command", "path", "file_path", "query", "pattern", "url", "action", "name", "i") ?? fallback ?? "")
        }
        let subject: String?
        switch tool {
        case .bash: subject = first("command")
        case .read, .write, .edit, .astEdit:
            subject = first("path", "file_path", "paths", "files")
        case .grep, .astGrep:
            subject = joined(first("pattern", "pat"), first("path", "paths"))
        case .glob, .find: subject = first("pattern", "path", "paths")
        case .webSearch: subject = first("query", "queries")
        case .eval: subject = first("title", "code")
        case .lsp:
            subject = joined(first("action"), first("file", "path", "symbol", "query"))
        case .debug, .ida:
            subject = joined(first("action", "command", "operation"), first("program", "file", "path", "function", "expression", "name", "address"))
        case .ask:
            subject = args["questions"]?.array?.prefix(3).compactMap { text($0["question"] ?? $0["header"]) }.joined(separator: " · ")
        case .task: subject = first("name", "task", "description", "prompt")
        case .wait, .vibeWait, .vibeKill:
            subject = first("ids", "agent_ids", "task_ids", "id", "agent_id")
        case .vibeSend:
            subject = joined(first("id", "agent_id"), first("message", "text"))
        case .vibeSpawn: subject = first("name", "title", "task", "prompt", "command")
        case .todo: subject = joined(first("op", "action"), first("task", "phase"))
        case .checkpoint: subject = first("goal")
        case .rewind: subject = first("report")
        case .contextNotes: subject = first("notes")
        case .securityScan:
            subject = joined(first("action"), first("target", "url", "path"))
        case .securityPublish: subject = first("url", "repo", "title")
        case .github:
            subject = joined(first("action", "method"), first("url", "repo", "path", "query"))
        case .memoryEdit: subject = joined(first("op"), first("id"))
        case .retain: subject = first("text", "content", "fact")
        case .recall, .reflect: subject = first("query")
        case .learn: subject = first("topic", "query", "path")
        case .manageSkill: subject = joined(first("action"), first("name"))
        case .goal: subject = joined(first("action", "operation"), first("objective", "goal"))
        case .think: subject = first("thought", "thinking")
        case .yield: subject = first("message")
        case .advise: subject = first("query", "message", "task")
        case .generateImage: subject = first("prompt")
        case .tts: subject = first("text")
        case .proposeCommit, .splitCommit: subject = first("message", "title", "commit")
        case .analyzeFiles, .gitFileDiff, .gitHunk, .replaceMemoryFiles, .recordDeltas:
            subject = first("path", "file", "paths", "files")
        case .recentCommits: subject = first("ref", "branch")
        case .proposeChangelog, .createChangelogEntries: subject = first("version", "title", "summary")
        case .initExperiment: subject = first("goal", "objective", "name")
        case .runExperiment: subject = first("command")
        case .logExperiment: subject = first("description", "label")
        case .updateNotes: subject = first("notes", "summary")
        case .rewrite: subject = first("instructions", "objective")
        case .approve: subject = first("id", "target")
        case .resolve, .reject, .propose, .reportIssue:
            subject = first("path", "file_path", "title", "reason", "message")
        case .newContext, .gitOverview, .vibeList: subject = nil
        }
        return limited(subject ?? first("i") ?? fallback ?? "")
    }

    private func visibleKeys(_ value: JSONValue) -> [String] {
        (value.object?.keys.filter { key in
            let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
            return !["apikey", "authorization", "password", "accesstoken", "refreshtoken", "credentials", "credential", "providerpayload", "signature", "base64", "imagedata"].contains(normalized)
                && !(value["type"]?.string == "image" && ["data", "blob"].contains(normalized))
        } ?? []).sorted()
    }

    private func limited(_ string: String) -> String { String(String.UnicodeScalarView(string.unicodeScalars.prefix(512))) }

    private func identity(_ value: JSONValue?) -> String? {
        guard let id = value?.string, !id.isEmpty, id.utf8.count <= 512 else { return nil }
        return id
    }

    private func preview(_ value: JSONValue) -> String {
        switch value {
        case .object: return "{\(visibleKeys(value).count)}"
        case .array(let values): return "[\(values.count)]"
        default: return String(String.UnicodeScalarView((value.string ?? value.compactString).unicodeScalars.prefix(160)))
                .replacingOccurrences(of: "\n", with: " ")
        }
    }

    private func excerpt(_ value: JSONValue) -> String {
        if let text = value.string { return limited(text).replacingOccurrences(of: "\n", with: " ") }
        if let blocks = value.array {
            var result = ""
            for block in blocks where block["type"]?.string == "text" {
                result += String((block["text"]?.string ?? "").prefix(max(0, 512 - result.count))) + " "
                if result.count >= 512 { break }
            }
            return limited(result).replacingOccurrences(of: "\n", with: " ")
        }
        if value.object != nil {
            return limited(visibleKeys(value).prefix(6).map { "\(limited($0)): \(preview(value[$0] ?? .null))" }.joined(separator: " · "))
        }
        return preview(value)
    }
}
