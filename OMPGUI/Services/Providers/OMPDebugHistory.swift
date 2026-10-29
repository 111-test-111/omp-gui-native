import Foundation

/// Read-only recovery from exact call IDs in OMP's public journal. Batch a run
/// into one bounded scan; missing/nested calls never borrow a similar response.
enum OMPDebugHistory {
    struct Detail: Sendable {
        var details: OMPDebugDetails
        var session: OMPDebugSession?
        var cwd: String?
    }
    private struct Match {
        var record: OMPDebugRecord
        var input: JSONValue?
        var result: JSONValue?
        var output: String?
        var session: OMPDebugSession?
        var callSeen = false
        var resultSeen = false
        var ambiguous = false
        var limited = false
    }

    static func read(sessionFile: String, record: OMPDebugRecord) async -> Detail? {
        await read(sessionFile: sessionFile, records: [record])[record.id]
    }

    @concurrent static func read(sessionFile: String, records: [OMPDebugRecord]) async -> [String: Detail] {
        guard sessionFile.hasPrefix("/"), URL(fileURLWithPath: sessionFile).pathExtension == "jsonl" else { return [:] }
        var matches: [String: Match] = [:]
        for record in records.prefix(128) where record.phase != "state" && record.phase != "begin" {
            var nativeID = record.nativeCallID ?? record.id
            if record.nativeCallID == nil, nativeID.count > 37, UUID(uuidString: String(nativeID.prefix(36))) != nil,
               nativeID.dropFirst(36).first == ":" { nativeID = String(nativeID.dropFirst(37)) }
            guard !nativeID.isEmpty else { continue }
            if matches[nativeID] != nil { matches[nativeID]?.ambiguous = true }
            else { matches[nativeID] = Match(record: record) }
        }
        guard !matches.isEmpty, let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: sessionFile)) else { return [:] }
        defer { try? file.close() }
        var framer = StdioFramer(framing: .lines)
        var header = false, ambiguous = false, scanned = 0
        var cwd: String?
        func consume(_ line: Data) {
            guard let entry = JSONValue.parse(line) else { return }
            if entry["type"]?.string == "session" {
                if header { ambiguous = true }
                header = entry["id"]?.string?.isEmpty == false
                cwd = entry["cwd"]?.string.map { String($0.prefix(8192)) }
                return
            }
            guard header, entry["type"]?.string == "message", let message = entry["message"] else { return }
            if message["role"]?.string == "assistant" {
                for block in message["content"]?.array ?? [] where block["type"]?.string == "toolCall" {
                    guard let id = block["id"]?.string, var match = matches[id] else { continue }
                    if match.callSeen { match.ambiguous = true }; match.callSeen = true
                    let args = block["arguments"]
                    var input: JSONValue?
                    if block["name"]?.string == "debug" { input = args }
                    else if block["name"]?.string == "write", (args?["path"]?.string ?? args?["file_path"]?.string) == "xd://debug" {
                        input = args?["content"]?.string.flatMap(JSONValue.parse)
                    } else { match.ambiguous = true }
                    if input?["action"]?.string != match.record.action { match.ambiguous = true }
                    let bounded = OMPDebugDetails(input: input)
                    match.input = bounded.input; match.limited = match.limited || bounded.limited
                    matches[id] = match
                }
            } else if message["role"]?.string == "toolResult", let id = message["toolCallId"]?.string, var match = matches[id] {
                if match.resultSeen { match.ambiguous = true }; match.resultSeen = true
                var result: JSONValue?
                if message["toolName"]?.string == "debug" { result = message["details"] }
                else if message["toolName"]?.string == "write", message["details"]?["xdev"]?["tool"]?.string == "debug" {
                    result = message["details"]?["xdev"]?["inner"]
                } else { match.ambiguous = true }
                if let action = result?["action"]?.string, action != match.record.action { match.ambiguous = true }
                let output = message["content"]?.array?.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
                let bounded = OMPDebugDetails(result: result, output: output)
                match.result = bounded.result; match.output = bounded.output; match.limited = match.limited || bounded.limited
                match.session = OMPDebugSession(result?["snapshot"])
                matches[id] = match
            }
        }
        do {
            while let chunk = try file.read(upToCount: 64 * 1024), !chunk.isEmpty {
                scanned += chunk.count
                guard scanned <= 128 * 1024 * 1024, !Task.isCancelled else { return [:] }
                for line in try framer.append(chunk) { consume(line) }
                if ambiguous { return [:] }
            }
            if let last = framer.finish() { consume(last) }
        } catch { return [:] }
        guard header, !ambiguous, !Task.isCancelled else { return [:] }
        var recovered: [String: Detail] = [:]
        var budget = 1024 * 1024
        for match in matches.values.sorted(by: { $0.record.startedAt > $1.record.startedAt }) where match.callSeen && !match.ambiguous && match.input != nil {
            let details = OMPDebugDetails(input: match.input, result: match.result, output: match.output, limited: match.limited)
            guard details.cost <= budget else { continue }
            budget -= details.cost
            recovered[match.record.id] = Detail(details: details, session: match.session, cwd: cwd)
        }
        return recovered
    }
}
