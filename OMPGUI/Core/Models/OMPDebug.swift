import Foundation

/// DAP source identity is distinct from a filesystem path. Optional fields also
/// decode the FilePreviewReference shape saved by the first sidebar version.
struct OMPDebugSource: Codable, Equatable, Hashable, Sendable {
    var path: String?
    var line: Int?
    var column: Int?
    var name: String?
    var sourceReference: Int?
    var address: String?

    init?(_ value: JSONValue) {
        path = value["source"]?["path"]?.string.map { String($0.prefix(8192)) }
        name = value["source"]?["name"]?.string.map { String($0.prefix(256)) }
        sourceReference = value["source"]?["sourceReference"]?.int
        address = value["instructionPointerReference"]?.string.map { String($0.prefix(256)) }
        line = value["line"]?.int.flatMap { $0 > 0 ? $0 : nil }
        column = value["column"]?.int.flatMap { $0 > 0 ? $0 : nil }
        guard path?.isEmpty == false || name?.isEmpty == false || address != nil else { return nil }
    }

    var label: String {
        let file = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? name ?? address ?? ""
        return file + (line.map { ":\($0)" } ?? "")
    }
}

/// Strings contain valid, bounded JSON, so old archives can omit details and
/// future native result fields remain inspectable without schema migrations.
struct OMPDebugDetails: Codable, Equatable, Sendable {
    var inputJSON: String?
    var resultJSON: String?
    var output: String?
    var limited: Bool

    var input: JSONValue? { inputJSON.flatMap(JSONValue.parse) }
    var result: JSONValue? { resultJSON.flatMap(JSONValue.parse) }
    var cost: Int { (inputJSON?.utf8.count ?? 0) + (resultJSON?.utf8.count ?? 0) + (output?.utf8.count ?? 0) }

    init(input: JSONValue? = nil, result: JSONValue? = nil, output: String? = nil, limited: Bool = false) {
        self.limited = limited
        func encode(_ value: JSONValue?, budget: Int) -> String? {
            guard let value else { return nil }
            var remaining = budget, nodes = 0
            func visit(_ value: JSONValue, depth: Int) -> JSONValue {
                nodes += 1
                guard depth <= 8, nodes <= 800, remaining >= 32 else { self.limited = true; return "…" }
                switch value {
                case .string(let text):
                    let clipped = Self.clip(text, bytes: min(4096, remaining / 6))
                    self.limited = self.limited || clipped != text
                    let result = JSONValue.string(clipped); remaining -= result.data().count
                    return result
                case .array(let values):
                    var result: [JSONValue] = []
                    for child in values {
                        guard result.count < 200, nodes < 800, remaining >= 64 else { self.limited = true; break }
                        remaining -= 4; result.append(visit(child, depth: depth + 1))
                    }
                    return .array(result)
                case .object(let values):
                    var result: [String: JSONValue] = [:]
                    for key in values.keys.sorted() {
                        guard result.count < 200, nodes < 800, remaining >= 64 else { self.limited = true; break }
                        let name = Self.clip(key, bytes: 128)
                        remaining -= JSONValue.string(name).data().count + 4
                        result[name] = visit(values[key]!, depth: depth + 1)
                    }
                    return .object(result)
                default: remaining -= 24; return value
                }
            }
            let text = visit(value, depth: 0).compactString
            guard text.utf8.count <= budget else { self.limited = true; return "\"…\"" }
            return text
        }
        inputJSON = encode(input, budget: 8 * 1024)
        resultJSON = encode(result, budget: 24 * 1024)
        self.output = output.map { Self.clip($0, bytes: 12 * 1024) }
        self.limited = self.limited || self.output != output
    }

    init(_ value: JSONValue) {
        self.init(input: value["inputJSON"]?.string.flatMap(JSONValue.parse),
                  result: value["resultJSON"]?.string.flatMap(JSONValue.parse), output: value["output"]?.string,
                  limited: value["limited"]?.bool == true)
    }

    static func clip(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var prefix = Data(text.utf8.prefix(max(0, bytes - 3)))
        while String(data: prefix, encoding: .utf8) == nil && !prefix.isEmpty { prefix.removeLast() }
        return String(decoding: prefix, as: UTF8.self) + "…"
    }
}

struct OMPDebugSession: Codable, Equatable, Sendable {
    var id: String
    var status: String
    var adapter: String
    var program: String?
    var frameName: String?
    var stopReason: String?
    var stopDescription: String?
    var source: OMPDebugSource?
    var cwd: String?
    var threadID: Int?
    var exitCode: Int?

    init?(_ value: JSONValue?) {
        guard let value, let id = value["id"]?.string, !id.isEmpty,
              let status = value["status"]?.string,
              ["launching", "configuring", "running", "stopped", "terminated"].contains(status) else { return nil }
        self.id = String(id.prefix(256))
        self.status = status
        adapter = String((value["adapter"]?.string ?? "DAP").prefix(256))
        program = value["program"]?.string.map { String($0.prefix(2048)) }
        frameName = value["frameName"]?.string.map { String($0.prefix(2048)) }
        stopReason = value["stopReason"]?.string.map { String($0.prefix(256)) }
        stopDescription = value["stopDescription"]?.string.map { String($0.prefix(2048)) }
        source = OMPDebugSource(value)
        cwd = value["cwd"]?.string.map { String($0.prefix(8192)) }
        threadID = value["threadId"]?.int
        exitCode = value["exitCode"]?.int
    }

    var title: String { program.map { URL(fileURLWithPath: $0).lastPathComponent } ?? adapter }
    var statusTitle: String { OMPDebugRecord.title(status) }
}

struct OMPDebugRecord: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var action: String
    var startedAt: Date
    var endedAt: Date?
    var phase: String
    var failed: Bool
    var error: String?
    var session: OMPDebugSession?
    var nativeCallID: String?
    var details: OMPDebugDetails?
    var stopID: String?

    init?(_ value: JSONValue) {
        guard let id = value["id"]?.string, let action = value["action"]?.string,
              let time = value["timestamp"]?.double, time.isFinite,
              let phase = value["phase"]?.string, ["begin", "end", "state", "interrupted"].contains(phase) else { return nil }
        self.id = String(id.prefix(512)); self.action = String(action.prefix(128))
        startedAt = Date(timeIntervalSince1970: time / 1000)
        endedAt = phase == "begin" || phase == "state" ? nil : startedAt
        self.phase = phase
        failed = value["failed"]?.bool == true
        error = value["error"]?.string.map { String($0.prefix(2048)) }
        session = OMPDebugSession(value["summary"])
        nativeCallID = value["nativeCallID"]?.string.map { String($0.prefix(256)) }
        details = value["details"].map(OMPDebugDetails.init)
        stopID = value["stopID"]?.string
    }

    var title: String { Self.title(action) }
    static func title(_ action: String) -> String {
        switch action {
        case "launch": "Launch"
        case "attach": "Attach"
        case "continue": "Continue"
        case "step_over": "Step over"
        case "step_in": "Step into"
        case "step_out": "Step out"
        case "pause": "Pause"
        case "terminate": "Terminate"
        case "stack_trace": "Call stack"
        case "scopes": "Scopes"
        case "variables": "Variables"
        case "evaluate": "Evaluate"
        case "set_breakpoint": "Set breakpoint"
        case "remove_breakpoint": "Remove breakpoint"
        case "sessions": "Debug sessions"
        case "threads": "Debug threads"
        case "output": "Output"
        case "custom_request": "DAP request"
        case "modules": "Modules"
        case "loaded_sources": "Sources"
        case "disassemble": "Disassembly"
        case "read_memory": "Read memory"
        case "launching": "Launching"
        case "configuring": "Configuring"
        case "running": "Running"
        case "stopped": "Paused"
        case "terminated": "Ended"
        default: action // Unrecognized native action names remain literal protocol data.
        }
    }
}

enum OMPDebugPhase: String, Codable, Equatable, Sendable {
    case idle, starting, debugging, paused, completed, ended, interrupted, failed

    var title: String {
        switch self {
        case .idle: "Debug idle"
        case .starting: "Starting debug session"
        case .debugging: "Debugging"
        case .paused: "Debug paused"
        case .completed: "Debug completed"
        case .ended: "Debug ended"
        case .interrupted: "Debug interrupted"
        case .failed: "Debug failed"
        }
    }
}

struct OMPDebugSnapshot: Equatable, Sendable {
    var sessionFile: String?
    var session: OMPDebugSession?
    var records: [OMPDebugRecord] = []
    var connected = false
    var supported = false
    var active = false
    var busy = false
    var stopToken: String?
    // Live UI intent, deliberately absent from the saved archive. Retain it
    // through result/state frames so a fast begin/result pair cannot lose it.
    private(set) var presentationID: String?
    private(set) var runID: String?
    private var nativeRunID: String?
    private var runStartedAt: Date?
    private var pastRuns: [OMPDebugRun] = []
    private var needsNewRun = false
    private(set) var stops: [OMPDebugStop] = []
    private(set) var currentStopID: String?

    var runs: [OMPDebugRun] { pastRuns + (currentRun.map { [$0] } ?? []) }
    private var currentRun: OMPDebugRun? {
        guard let runID, let sessionFile else { return nil }
        return OMPDebugRun(id: runID, sessionFile: sessionFile, nativeID: nativeRunID,
            startedAt: runStartedAt ?? records.first?.startedAt ?? .distantPast,
            session: session, phase: phase, records: records, stops: stops)
    }

    var phase: OMPDebugPhase {
        let latest = records.last { $0.phase != "state" }
        let knownSession = session ?? records.last(where: { $0.session != nil })?.session
        let pending = records.last { $0.phase == "begin" }
        // A newly starting root can make the bridge busy before its begin frame
        // arrives. The previous root's terminal evidence takes precedence.
        if knownSession?.status == "terminated", pending == nil,
           let sessionFile {
            return OMPDebugRun(id: runID ?? "", sessionFile: sessionFile, startedAt: .distantPast,
                session: knownSession, phase: .ended, records: records).terminalPhase ?? .ended
        }
        if connected && (active || busy || pending != nil) {
            if knownSession?.status == "launching" || knownSession?.status == "configuring"
                || pending?.action == "launch" || pending?.action == "attach" { return .starting }
            if let action = pending?.action, ["continue", "step_over", "step_in", "step_out", "terminate"].contains(action) { return .debugging }
            if knownSession?.status == "stopped" { return .paused }
            return .debugging
        }
        if latest?.action == "terminate", latest?.phase == "end", latest?.failed == false { return .completed }
        if knownSession?.status == "terminated" {
            if let code = knownSession?.exitCode { return code == 0 ? .completed : .failed }
            return .ended
        }
        if latest?.phase == "interrupted" || (!connected && knownSession != nil) { return .interrupted }
        if latest?.failed == true { return .failed }
        if knownSession?.status == "stopped" { return .paused }
        return .idle
    }

    var canInspect: Bool { connected && supported && active && !busy && session?.status == "stopped" && stopToken != nil }
    var inspectionKey: String? { canInspect ? stopToken : nil }
    var preventsRecycle: Bool { connected && (active || busy) }
    var archive: OMPDebugArchive? {
        guard let sessionFile, !runs.isEmpty else { return nil }
        return OMPDebugArchive(sessionFile: sessionFile, session: session, runs: runs)
    }

    init() {}
    init(archive: OMPDebugArchive) {
        sessionFile = archive.sessionFile
        var saved = Array(archive.runs.suffix(32))
        for index in saved.indices {
            saved[index].normalize()
            if [.starting, .debugging, .paused].contains(saved[index].phase) { saved[index].phase = .interrupted }
        }
        pastRuns = saved
        if let last = pastRuns.popLast() {
            runID = last.id; nativeRunID = last.nativeID; runStartedAt = last.startedAt
            session = last.session ?? archive.session; records = last.records; stops = last.stops
        }
        needsNewRun = true
        disconnect()
        trimHistory()
    }

    mutating func observe(_ frame: JSONValue) {
        guard let file = frame["sessionFile"]?.string, !file.isEmpty else { return }
        if let sessionFile, sessionFile != file {
            finishRun(); clearLiveRun(); needsNewRun = true
        }
        sessionFile = file; connected = true
        if let snapshot = frame["snapshot"] {
            let incoming = OMPDebugSession(snapshot["session"])
            bindRun(nativeID: snapshot["runID"]?.string, summary: incoming)
            supported = snapshot["supported"]?.bool == true
            active = snapshot["active"]?.bool == true
            busy = snapshot["busy"]?.bool == true
            stopToken = snapshot["stopToken"]?.string
            session = incoming
            if let incoming, incoming.status == "stopped", !busy {
                ensureStop(id: snapshot["stopID"]?.string, summary: incoming)
            } else if incoming?.status != "stopped" { currentStopID = nil }
        }
        if let value = frame["record"], var record = OMPDebugRecord(value) {
            // A late completion keeps its original run; it cannot change the
            // currently inspected program, stop or source directory.
            if let index = pastRuns.firstIndex(where: { $0.records.contains { $0.id == record.id } }) {
                if let previous = pastRuns[index].records.firstIndex(where: { $0.id == record.id }) {
                    record.startedAt = pastRuns[index].records[previous].startedAt
                    record.stopID = pastRuns[index].records[previous].stopID
                    pastRuns[index].records[previous] = record
                    if let stop = pastRuns[index].stops.firstIndex(where: { $0.id == record.stopID }) { pastRuns[index].stops[stop].captureTool(record) }
                }
                trimHistory(); return
            }
            let launch = record.phase == "begin" && ["launch", "attach"].contains(record.action)
                && !records.contains(where: { $0.id == record.id })
            if launch, runID != nil, !records.isEmpty, !active || session?.status == "terminated" {
                finishRun(); clearLiveRun()
            }
            if !supported, record.phase == "end", !record.failed, ["launch", "attach"].contains(record.action),
               let summary = record.session, let previous = session, summary.id != previous.id {
                let pending = records.filter { $0.id == record.id }
                records.removeAll { $0.id == record.id }
                finishRun(); clearLiveRun()
                records = pending.map { value in var value = value; value.stopID = nil; return value }
                runStartedAt = pending.first?.startedAt
            }
            if runID == nil || needsNewRun {
                if needsNewRun { finishRun(); clearLiveRun() }
                runID = "run:" + UUID().uuidString; runStartedAt = runStartedAt ?? record.startedAt; needsNewRun = false
            }
            if let nativeID = frame["runID"]?.string { bindRun(nativeID: nativeID, summary: record.session) }
            if record.phase == "begin", records.first(where: { $0.id == record.id })?.phase != "begin",
               presentationID == nil || !active || record.action == "launch" || record.action == "attach" {
                presentationID = file + "\n" + record.id
            }
            if !supported, let summary = record.session, summary.status == "stopped" {
                let newStop = currentStopID == nil || (record.phase == "state" && record.action == "stopped")
                    || (record.phase == "end" && ["launch", "attach", "continue", "pause", "step_over", "step_in", "step_out"].contains(record.action))
                ensureStop(id: newStop ? "saved:" + record.id : currentStopID, summary: summary)
            }
            if record.phase != "state" || record.action == "stopped" { record.stopID = record.stopID ?? currentStopID }
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                record.startedAt = records[index].startedAt
                record.nativeCallID = record.nativeCallID ?? records[index].nativeCallID
                if record.details?.inputJSON == nil { record.details?.inputJSON = records[index].details?.inputJSON }
                if record.details == nil { record.details = records[index].details }
                records[index] = record
            } else { records.append(record) }
            if record.phase == "begin" { busy = true }
            if let index = stops.firstIndex(where: { $0.id == record.stopID }) { stops[index].captureTool(record) }
            if !supported {
                if let summary = record.session { session = summary; active = summary.status != "terminated" }
                busy = records.contains { $0.phase == "begin" }
                // The native terminate result describes the session before disposal.
                if record.action == "terminate", record.phase == "end", !record.failed {
                    active = false; session?.status = "terminated"
                }
            }
        }
        trimHistory()
    }

    private mutating func bindRun(nativeID: String?, summary: OMPDebugSession?) {
        guard nativeID != nil || summary != nil else { return }
        if needsNewRun || (nativeRunID != nil && nativeID != nil && nativeID != nativeRunID) {
            let pending = records.filter { $0.phase == "begin" && ["launch", "attach"].contains($0.action) }
            records.removeAll { value in pending.contains { $0.id == value.id } }
            finishRun(); clearLiveRun()
            records = pending.map { value in var value = value; value.stopID = nil; return value }
            runStartedAt = pending.first?.startedAt
        }
        if runID == nil {
            runID = "run:" + UUID().uuidString; runStartedAt = runStartedAt ?? .now
        }
        nativeRunID = nativeID ?? nativeRunID; needsNewRun = false
    }

    private mutating func ensureStop(id: String?, summary: OMPDebugSession) {
        let id = id ?? currentStopID ?? "stop:" + UUID().uuidString
        if let index = stops.firstIndex(where: { $0.id == id }) { stops[index].session = summary }
        else { stops.append(OMPDebugStop(id: id, timestamp: .now, session: summary)) }
        currentStopID = id
    }

    private mutating func finishRun() {
        guard var run = currentRun else { return }
        if [.starting, .debugging, .paused].contains(run.phase) { run.phase = .interrupted }
        pastRuns.removeAll { $0.id == run.id }; pastRuns.append(run)
    }
    private mutating func clearLiveRun() {
        runID = nil; nativeRunID = nil; runStartedAt = nil; records = []; stops = []; currentStopID = nil
        session = nil; active = false; busy = false; stopToken = nil
    }

    /// Called only after a successful, fenced public inspector response.
    @discardableResult mutating func captureInspection(_ operation: String, fields: [String: JSONValue], data: JSONValue,
                                                      expected: OMPDebugSnapshot) -> Bool {
        guard canInspect, expected.canInspect, sessionFile == expected.sessionFile, runID == expected.runID,
              stopToken == expected.stopToken, session?.id == expected.session?.id,
              currentStopID == expected.currentStopID, let index = stops.firstIndex(where: { $0.id == currentStopID }),
              ["stack", "scopes", "variables"].contains(operation) else { return false }
        stops[index].capture(OMPDebugCapture(operation: operation, frameID: fields["frameID"]?.int,
            reference: fields["reference"]?.int, data: data,
            stepID: expected.records.last(where: { $0.stopID == expected.currentStopID })?.id))
        trimHistory(); return true
    }

    /// A newly started native process inherits this chat's archives, even when
    /// it creates a different public JSONL. It never inherits live references.
    mutating func retainHistory(from previous: OMPDebugSnapshot) {
        let known = Set(runs.map(\.id))
        var retained = previous.runs.filter { !known.contains($0.id) }
        for index in retained.indices where [.starting, .debugging, .paused].contains(retained[index].phase) { retained[index].phase = .interrupted }
        pastRuns.insert(contentsOf: retained, at: 0)
        trimHistory()
    }

    @discardableResult mutating func recoverDetails(runID: String, values: [String: OMPDebugDetails], summaries: [String: OMPDebugSession]) -> Bool {
        if self.runID == runID {
            guard var run = currentRun, run.recover(values: values, summaries: summaries) else { return false }
            records = run.records; stops = run.stops
        } else {
            guard let index = pastRuns.firstIndex(where: { $0.id == runID }), pastRuns[index].recover(values: values, summaries: summaries) else { return false }
        }
        trimHistory(); return true
    }

    private mutating func trimHistory() {
        pastRuns = Array(pastRuns.suffix(runID == nil ? 32 : 31))
        var budget = 8 * 1024 * 1024
        if var current = currentRun {
            current.trim(to: min(1024 * 1024, budget)); budget -= current.cost
            records = current.records; stops = current.stops
        }
        for index in pastRuns.indices.reversed() {
            pastRuns[index].trim(to: min(1024 * 1024, budget)); budget -= pastRuns[index].cost
        }
    }

    mutating func disconnect() {
        connected = false; supported = false; active = false; busy = false; stopToken = nil
        presentationID = nil
        currentStopID = nil
        for index in records.indices where records[index].phase == "begin" { records[index].phase = "interrupted" }
    }
}

struct OMPDebugFrame: Identifiable, Equatable, Sendable {
    var id: Int
    var name: String
    var source: OMPDebugSource?
    init?(_ value: JSONValue) {
        guard let id = value["id"]?.int, id >= 0 else { return nil }
        self.id = id; name = String((value["name"]?.string ?? "").prefix(1024))
        source = OMPDebugSource(value)
    }
}

struct OMPDebugVariable: Equatable, Sendable {
    var name: String
    var value: String
    var type: String?
    var reference: Int
    init(_ data: JSONValue) {
        name = String((data["name"]?.string ?? "").prefix(512))
        value = String((data["value"]?.string ?? "").prefix(4096))
        type = data["type"]?.string.map { String($0.prefix(256)) }
        reference = max(0, data["reference"]?.int ?? 0)
    }
}
