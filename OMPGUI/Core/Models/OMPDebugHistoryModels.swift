import Foundation

/// Literal, bounded results. Frame/variable numbers here are historical labels;
/// only the live transport's unpersisted stop token can authorize adapter reads.
struct OMPDebugCapture: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var operation: String
    var frameID: Int?
    var reference: Int?
    var payload: OMPDebugDetails
    var stepID: String?

    init(operation: String, frameID: Int? = nil, reference: Int? = nil, data: JSONValue, stepID: String? = nil) {
        self.operation = operation; self.frameID = frameID; self.reference = reference
        self.stepID = stepID
        id = operation + ":" + (frameID.map(String.init) ?? "_") + ":" + (reference.map(String.init) ?? "_") + ":" + (stepID ?? "_")
        payload = OMPDebugDetails(result: data)
    }

    var data: JSONValue? { payload.result }
    var key: String { operation + ":" + (frameID.map(String.init) ?? "_") + ":" + (reference.map(String.init) ?? "_") }
}

struct OMPDebugStop: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var timestamp: Date
    var session: OMPDebugSession
    var captures: [OMPDebugCapture] = []
    var limited = false

    var frames: [OMPDebugFrame] {
        captures.last { $0.operation == "stack" }?.data?["frames"]?.array?.compactMap(OMPDebugFrame.init) ?? []
    }

    func scopes(frameID: Int) -> [JSONValue] {
        captures.last { $0.operation == "scopes" && $0.frameID == frameID }?.data?["scopes"]?.array ?? []
    }

    func variables(reference: Int, frameID: Int?) -> [JSONValue]? {
        captures.last { $0.operation == "variables" && $0.reference == reference
            && $0.frameID == frameID }?.data?["variables"]?.array
    }

    mutating func capture(_ value: OMPDebugCapture) {
        captures.removeAll { $0.id == value.id }; captures.append(value)
        limited = limited || value.payload.limited || value.data?["limited"]?.bool == true
        if captures.count > 128 { captures.removeFirst(captures.count - 128); limited = true }
        trim(to: 128 * 1024)
    }

    /// Resolve sparse reads to one immutable view after the selected step.
    /// Older/later replies must not replace a newer step's values.
    func after(_ step: Int, positions: [String: Int]) -> OMPDebugStop {
        var result = self
        result.captures = []
        for capture in captures.enumerated().sorted(by: {
            let lhs = $0.element.stepID.flatMap { positions[$0] } ?? Int.max
            let rhs = $1.element.stepID.flatMap { positions[$0] } ?? Int.max
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }).map(\.element) where capture.stepID.flatMap({ positions[$0] }).map({ $0 <= step }) == true {
            result.captures.removeAll { $0.key == capture.key }
            result.captures.append(capture)
        }
        return result
    }

    var cost: Int { captures.reduce(0) { $0 + $1.payload.cost } }

    mutating func trim(to budget: Int) {
        var remaining = budget
        for index in captures.indices.reversed() {
            let cost = captures[index].payload.cost
            if cost > remaining { captures.remove(at: index); limited = true }
            else { remaining -= cost }
        }
    }

    /// Tool reads and sidebar reads share the same normalized snapshot shape.
    /// Custom raw stack frames stay in their tool detail: their IDs need not
    /// match the public manager's mapped IDs used by scopes/variables.
    mutating func captureTool(_ record: OMPDebugRecord) {
        guard record.phase == "end", !record.failed, let details = record.details,
              let result = details.result else { return }
        let body = result["customBody"] ?? result
        let input = details.input
        let action = record.action == "custom_request" ? input?["command"]?.string : record.action
        switch action {
        case "stack_trace":
            if let frames = body["stackFrames"]?.array {
                capture(OMPDebugCapture(operation: "stack", data: ["frames": .array(frames)], stepID: record.id))
            }
        case "scopes":
            guard let values = body["scopes"]?.array else { return }
            let frame = input?["frame_id"]?.int ?? input?["arguments"]?["frameId"]?.int ?? frames.first?.id ?? 0
            let scopes: [JSONValue] = values.map { value in
                ["name": value["name"] ?? "", "reference": value["variablesReference"] ?? 0,
                 "presentationHint": value["presentationHint"] ?? .null, "expensive": value["expensive"] ?? false]
            }
            capture(OMPDebugCapture(operation: "scopes", frameID: frame, data: ["scopes": .array(scopes)], stepID: record.id))
        case "variables":
            guard let values = body["variables"]?.array,
                  let reference = input?["variable_ref"]?.int ?? input?["scope_id"]?.int ?? input?["arguments"]?["variablesReference"]?.int else { return }
            let frame = input?["frame_id"]?.int ?? captures.last { capture in
                (capture.operation == "scopes" && capture.data?["scopes"]?.array?.contains { $0["reference"]?.int == reference } == true)
                    || (capture.operation == "variables" && capture.data?["variables"]?.array?.contains { $0["reference"]?.int == reference } == true)
            }?.frameID
            let variables: [JSONValue] = values.map { value in
                ["name": value["name"] ?? "", "value": value["value"] ?? "", "type": value["type"] ?? .null,
                 "reference": value["variablesReference"] ?? 0]
            }
            capture(OMPDebugCapture(operation: "variables", frameID: frame, reference: reference,
                data: ["variables": .array(variables)], stepID: record.id))
        default: break
        }
    }
}

struct OMPDebugRun: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var sessionFile: String
    var nativeID: String?
    var startedAt: Date
    var session: OMPDebugSession?
    var phase: OMPDebugPhase
    var records: [OMPDebugRecord] = []
    var stops: [OMPDebugStop] = []

    var title: String? {
        (session ?? records.last(where: { $0.session != nil })?.session)?.program.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? records.compactMap { $0.details?.input?["program"]?.string }.first.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? session?.adapter
    }
    var cost: Int { records.reduce(0) { $0 + ($1.details?.cost ?? 0) } + stops.reduce(0) { $0 + $1.cost } }

    var terminalPhase: OMPDebugPhase? {
        let summary = session ?? records.last(where: { $0.session != nil })?.session
        guard summary?.status == "terminated" else { return nil }
        if records.contains(where: { $0.action == "terminate" && $0.phase == "end" && !$0.failed }) { return .completed }
        let exit = summary?.exitCode ?? records.last(where: { $0.session?.id == summary?.id && $0.session?.exitCode != nil })?.session?.exitCode
        return exit.map { $0 == 0 ? .completed : .failed } ?? .ended
    }

    func inspection(after recordID: String) -> OMPDebugStop? {
        guard let index = records.firstIndex(where: { $0.id == recordID }), records[index].phase != "begin" else { return nil }
        let stopID = records[index].stopID ?? records[...index].last(where: { $0.stopID != nil })?.stopID
        guard let stop = stops.first(where: { $0.id == stopID }) else { return nil }
        return stop.after(index, positions: Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) }))
    }

    func inspection(before recordID: String) -> OMPDebugStop? {
        guard let index = records.firstIndex(where: { $0.id == recordID }), index > 0 else { return nil }
        return inspection(after: records[index - 1].id)
    }

    mutating func recover(values: [String: OMPDebugDetails], summaries: [String: OMPDebugSession]) -> Bool {
        var changed = false
        for index in records.indices where records[index].details == nil {
            guard let value = values[records[index].id] else { continue }
            records[index].details = value
            records[index].session = summaries[records[index].id] ?? records[index].session
            if let stop = stops.firstIndex(where: { $0.id == records[index].stopID }) { stops[stop].captureTool(records[index]) }
            changed = true
        }
        return changed
    }

    mutating func normalize() {
        records = Array(records.suffix(128)); stops = Array(stops.suffix(64))
        for index in records.indices {
            if let value = records[index].details {
                records[index].details = OMPDebugDetails(input: value.input, result: value.result, output: value.output, limited: value.limited)
            }
        }
        for index in stops.indices {
            // V1 saved the latest reads per stop without a step boundary. Exact
            // tool reads can be replayed. Unattributed sidebar reads are only
            // exposed at the last recorded step of that stop, never beforehand.
            let members = records.filter { $0.stopID == stops[index].id && $0.phase != "begin" }
            if stops[index].captures.contains(where: { $0.stepID == nil }) {
                var tools = stops[index]
                tools.captures = []
                for record in members { tools.captureTool(record) }
                stops[index].captures = stops[index].captures.compactMap { capture in
                    guard capture.stepID == nil else { return capture }
                    let field = capture.operation == "stack" ? "frames" : capture.operation
                    if tools.captures.contains(where: { $0.key == capture.key && $0.data?[field] == capture.data?[field] }) { return nil }
                    var value = capture
                    value.stepID = members.last?.id
                    value.id = value.key + ":" + (value.stepID ?? "_")
                    return value
                }
                for record in members { stops[index].captureTool(record) }
            }
            var bounded: [OMPDebugCapture] = []
            for value in stops[index].captures.suffix(128) {
                var value = value
                value.payload = OMPDebugDetails(result: value.payload.result, limited: value.payload.limited)
                bounded.append(value)
            }
            stops[index].captures = bounded
            stops[index].trim(to: 128 * 1024)
        }
        phase = terminalPhase ?? phase
        trim()
    }

    mutating func trim(to budget: Int = 1024 * 1024) {
        records = Array(records.suffix(128)); stops = Array(stops.suffix(64))
        var remaining = max(0, budget)
        for index in stops.indices.reversed() {
            stops[index].trim(to: remaining); remaining -= stops[index].cost
        }
        for index in records.indices.reversed() {
            guard let detail = records[index].details else { continue }
            if detail.cost > remaining { records[index].details = OMPDebugDetails(limited: true) }
            else { remaining -= detail.cost }
        }
    }

    static func migrate(records: [OMPDebugRecord], sessionFile: String, session: OMPDebugSession?) -> [OMPDebugRun] {
        var runs: [OMPDebugRun] = []
        for var record in records {
            let starts = ["launch", "attach"].contains(record.action)
                && runs.last?.records.contains(where: { $0.action == "launch" || $0.action == "attach" }) == true
                && runs.last?.records.last?.id != record.id
            if runs.isEmpty || starts {
                runs.append(OMPDebugRun(id: "legacy:" + sessionFile + ":" + record.id, sessionFile: sessionFile,
                    startedAt: record.startedAt, phase: .ended))
            }
            let index = runs.count - 1
            if let summary = record.session { runs[index].session = summary }
            if let summary = record.session, summary.status == "stopped" {
                let control = ["launch", "attach", "continue", "pause", "step_over", "step_in", "step_out"].contains(record.action)
                let justStopped = runs[index].records.last?.phase == "state" && runs[index].records.last?.action == "stopped"
                if runs[index].stops.isEmpty || record.phase == "state" || (control && !justStopped) {
                    runs[index].stops.append(OMPDebugStop(id: "saved:" + record.id, timestamp: record.startedAt, session: summary))
                }
                record.stopID = runs[index].stops.last?.id
                runs[index].stops[runs[index].stops.count - 1].captureTool(record)
            }
            runs[index].records.append(record)
            if record.action == "terminate", !record.failed { runs[index].phase = .completed }
            else if record.session?.status == "terminated" {
                runs[index].phase = record.session?.exitCode.map { $0 == 0 ? .completed : .failed } ?? .ended
            } else if record.session != nil { runs[index].phase = .interrupted }
        }
        if !runs.isEmpty, let session { runs[runs.count - 1].session = session }
        if runs.isEmpty, let session {
            runs = [OMPDebugRun(id: "legacy:" + session.id, sessionFile: sessionFile, startedAt: .distantPast, session: session, phase: .ended)]
        }
        return runs
    }
}

/// New archives nest each run's steps and stop snapshots. The flat first-version
/// shape is decoded once, never written alongside a duplicate copy of history.
struct OMPDebugArchive: Codable, Equatable, Sendable {
    var sessionFile: String
    var session: OMPDebugSession?
    var runs: [OMPDebugRun]

    var records: [OMPDebugRecord] {
        get { runs.last?.records ?? [] }
        set {
            if runs.isEmpty { runs = OMPDebugRun.migrate(records: newValue, sessionFile: sessionFile, session: session) }
            else { runs[runs.count - 1].records = newValue }
        }
    }

    init(sessionFile: String, session: OMPDebugSession?, runs: [OMPDebugRun]) {
        self.sessionFile = sessionFile; self.session = session; self.runs = runs
    }
    init(sessionFile: String, session: OMPDebugSession?, records: [OMPDebugRecord]) {
        self.init(sessionFile: sessionFile, session: session, runs: OMPDebugRun.migrate(records: records, sessionFile: sessionFile, session: session))
    }
    private enum CodingKeys: String, CodingKey { case sessionFile, session, runs, records }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionFile = try values.decode(String.self, forKey: .sessionFile)
        session = try values.decodeIfPresent(OMPDebugSession.self, forKey: .session)
        if let saved = try values.decodeIfPresent([OMPDebugRun].self, forKey: .runs) { runs = saved }
        else { runs = OMPDebugRun.migrate(records: try values.decodeIfPresent([OMPDebugRecord].self, forKey: .records) ?? [], sessionFile: sessionFile, session: session) }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sessionFile, forKey: .sessionFile)
        try values.encodeIfPresent(session, forKey: .session)
        try values.encode(runs, forKey: .runs)
    }
}
