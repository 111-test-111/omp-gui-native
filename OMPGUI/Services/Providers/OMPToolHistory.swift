import Foundation
import Synchronization

/// Restores identities omitted by older GUI saves from OMP's public session JSONL.
/// The native call ID is authoritative; row titles and outputs are never evidence.
enum OMPToolHistory {
    struct Identity: Equatable, Sendable {
        var name: String
        var device: String?
        var input: String? = nil
        var fileReferences: [FilePreviewReference]? = nil
        var hasFileResult = false

        var fileReference: FilePreviewReference? { fileReferences?.count == 1 ? fileReferences?.first : nil }
    }

    private struct Cached: Sendable {
        var size: UInt64
        var modified: Date
        var fileNumber: UInt64?
        var cost: Int
        var identities: [String: Identity]
    }
    private struct Cache: Sendable {
        var sessions: [String: Cached] = [:]
        var order: [String] = []
    }
    private static let cache = Mutex(Cache())

    static func readIdentities(sessionFile: String) -> [String: Identity] {
        guard sessionFile.hasPrefix("/"),
              URL(fileURLWithPath: sessionFile).pathExtension == "jsonl" else { return [:] }
        let attributes = try? FileManager.default.attributesOfItem(atPath: sessionFile)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        let modified = attributes?[.modificationDate] as? Date
        let fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        if let size, let modified, let cached = cache.withLock({ value -> [String: Identity]? in
            guard let known = value.sessions[sessionFile], known.size == size, known.modified == modified,
                  known.fileNumber == fileNumber else { return nil }
            return known.identities
        }) { return cached }
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: sessionFile)) else { return [:] }
        defer { try? file.close() }
        var framer = StdioFramer(framing: .lines)
        var identities: [String: Identity] = [:]
        var ambiguous: Set<String> = []
        var fileInputs: [String: String] = [:]
        var fileResults: [String: [FilePreviewReference]] = [:]
        var hasHeader = false
        var directory: String?

        func record(_ id: String?, name: String?, device: String?, isCall: Bool,
                    args: JSONValue? = nil, details: JSONValue? = nil) {
            guard let id, !id.isEmpty, let name, !name.isEmpty, !ambiguous.contains(id) else { return }
            let input = (device ?? name) == "eval" ? args?.prettyString : nil
            let references = isCall
                ? args.flatMap { OMPFileReference.initialReferences(toolName: name, args: $0, directory: directory) }
                : details.flatMap { OMPFileReference.fromResult(toolName: device ?? name, details: $0) }
            if isCall, let args, let signature = OMPFileReference.argumentSignature(toolName: name, args: args) {
                if let previous = fileInputs[id], previous != signature {
                    identities.removeValue(forKey: id)
                    ambiguous.insert(id)
                    return
                }
                fileInputs[id] = signature
            } else if let references {
                if let previous = fileResults[id], previous != references {
                    identities.removeValue(forKey: id)
                    ambiguous.insert(id)
                    return
                }
                fileResults[id] = references
            }
            let identity = Identity(name: name, device: device, input: input,
                                    fileReferences: fileResults[id] ?? references, hasFileResult: fileResults[id] != nil)
            if let existing = identities[id] {
                // Results may omit arguments, but must agree with their call's name.
                // Two different device targets under one ID are equally ambiguous.
                if existing.name != name || (existing.device != nil && device != nil && existing.device != device)
                    || (existing.input != nil && input != nil && existing.input != input) {
                    identities.removeValue(forKey: id)
                    ambiguous.insert(id)
                } else {
                    identities[id] = Identity(name: name, device: device ?? existing.device, input: input ?? existing.input,
                                              fileReferences: fileResults[id] ?? references ?? existing.fileReferences,
                                              hasFileResult: fileResults[id] != nil)
                }
            } else {
                identities[id] = identity
            }
        }

        func consume(_ line: Data) {
            guard let entry = JSONValue.parse(line) else { return }
            if entry["type"]?.string == "session", entry["id"]?.string?.isEmpty == false {
                hasHeader = true
                directory = entry["cwd"]?.string
                return
            }
            guard hasHeader, entry["type"]?.string == "message", let message = entry["message"] else { return }
            switch message["role"]?.string {
            case "assistant":
                for block in message["content"]?.array ?? [] where block["type"]?.string == "toolCall" {
                    let name = block["name"]?.string
                    let args = block["arguments"]
                    let path = args?["path"]?.string ?? args?["file_path"]?.string
                    let device = name == "write" ? path.flatMap(OMPTool.deviceName) : nil
                    record(block["id"]?.string, name: name, device: device, isCall: true, args: args)
                }
            case "toolResult":
                let name = message["toolName"]?.string
                let device = name == "write" ? message["details"]?["xdev"]?["tool"]?.string : nil
                let details = message["details"]?["xdev"]?["inner"] ?? message["details"]
                record(message["toolCallId"]?.string, name: name, device: device, isCall: false, details: details)
            default: break
            }
        }

        do {
            while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
                for line in try framer.append(chunk) { consume(line) }
            }
            if let last = framer.finish() { consume(last) }
        } catch {
            // A missing tail or oversized entry must not make GUI history unreadable.
            // Complete, unambiguous entries already read remain usable.
        }
        // Paging saved turns otherwise rescans the same native session for each
        // page, including read tools that supplied no recoverable file path.
        // Keep this bounded by both session and identity counts; changing native
        // journals invalidate by metadata, and oversized journals are not held.
        let cost = identities.reduce(0) { total, entry in
            total + entry.key.utf8.count + entry.value.name.utf8.count + (entry.value.input?.utf8.count ?? 0)
                + (entry.value.fileReferences?.reduce(0) { $0 + $1.path.utf8.count + 32 } ?? 0) + 128
        }
        if let size, let modified, identities.count <= 6_000, cost <= 2 * 1_024 * 1_024 {
            cache.withLock { value in
                value.sessions[sessionFile] = Cached(size: size, modified: modified, fileNumber: fileNumber,
                                                     cost: cost, identities: identities)
                value.order.removeAll { $0 == sessionFile }
                value.order.append(sessionFile)
                while value.order.count > 8 || value.sessions.values.reduce(0, { $0 + $1.identities.count }) > 12_000
                    || value.sessions.values.reduce(0, { $0 + $1.cost }) > 8 * 1_024 * 1_024 {
                    guard !value.order.isEmpty else { break }
                    value.sessions.removeValue(forKey: value.order.removeFirst())
                }
            }
        }
        return identities
    }

    @discardableResult
    static func restore(_ call: inout ToolCall, timelineID: String,
                        identities: [String: Identity], nativeAgentID: String? = nil) -> Bool {
        guard let nativeID = nativeCallID(timelineID: timelineID, nativeAgentID: nativeAgentID),
              let identity = identities[nativeID], call.toolName == nil || call.toolName == identity.name,
              call.toolDevice == nil || identity.device == nil || call.toolDevice == identity.device else { return false }
        let before = call
        call.toolName = call.toolName ?? identity.name
        call.toolDevice = call.toolDevice ?? identity.device
        let missingTargets = call.fileReferences == nil || (call.status == .running && identity.hasFileResult)
        if missingTargets, let references = identity.fileReferences {
            call.fileReferences = references
            call.fileReference = references.count == 1 ? references.first : nil
        } else if call.fileReferences == nil {
            call.fileReference = call.fileReference ?? identity.fileReference
        }
        if call.ompTool == .eval, call.detail == nil { call.detail = identity.input }
        return call != before
    }

    static func nativeCallID(timelineID: String, nativeAgentID: String? = nil) -> String? {
        guard let prefixEnd = timelineID.index(timelineID.startIndex, offsetBy: 36, limitedBy: timelineID.endIndex),
              UUID(uuidString: String(timelineID[..<prefixEnd])) != nil,
              timelineID[prefixEnd...].hasPrefix("-") else { return nil }
        // OMPSession gives leads a UUID prefix and workers UUID-<native-agent-id>.
        var nativeID = String(timelineID[timelineID.index(after: prefixEnd)...])
        if let nativeAgentID {
            let prefix = nativeAgentID + "-"
            guard nativeID.hasPrefix(prefix) else { return nil }
            nativeID.removeFirst(prefix.count)
        }
        return nativeID.isEmpty ? nil : nativeID
    }
}
