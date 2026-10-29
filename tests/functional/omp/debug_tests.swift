import AppKit
import SwiftUI
@testable import OMPGUI

@main struct DebugChecks {
    @MainActor static func main() async throws {
        func expect(_ value: Bool, _ message: String) { precondition(value, message); print("PASS \(message)") }
        var snapshot = OMPDebugSnapshot()
        let paused: JSONValue = ["id": "dap-one", "status": "stopped", "adapter": "fixture", "frameName": "main",
                                "source": ["path": "/isolated/main.c"], "line": 12]
        let frame: JSONValue = ["sessionFile": "/isolated/native.jsonl", "snapshot": ["supported": true, "active": true,
            "busy": false, "stopToken": "process:stop:1", "session": paused]]
        snapshot.observe(frame)
        expect(snapshot.canInspect && snapshot.preventsRecycle && snapshot.session?.source?.line == 12, "Live stop enables inspection and protects its native process")
        snapshot.observe(["sessionFile": "/isolated/native.jsonl", "record": ["id": "one", "action": "step_over", "phase": "begin", "timestamp": 1000]])
        snapshot.observe(["sessionFile": "/isolated/native.jsonl", "record": ["id": "one", "action": "step_over", "phase": "end", "timestamp": 2500]])
        expect(snapshot.records.count == 1 && snapshot.records[0].endedAt!.timeIntervalSince(snapshot.records[0].startedAt) == 1.5,
               "Begin/result pairs retain one action and its duration")
        for index in 0..<200 {
            snapshot.observe(["sessionFile": "/isolated/native.jsonl", "record": ["id": .string("record-\(index)"), "action": "variables", "phase": "end", "timestamp": 3000]])
        }
        expect(snapshot.records.count == 128, "History has a bounded persisted record budget")
        var document = ThreadDocument(threadID: UUID())
        document.ompDebug = snapshot.archive
        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(ThreadDocument.self, from: encoded)
        let restored = OMPDebugSnapshot(archive: decoded.ompDebug!)
        expect(!restored.canInspect && !restored.preventsRecycle && restored.stopToken == nil && restored.records.count == 128,
               "Restored history never restores adapter references or a live process")
        expect(!String(decoding: encoded, as: UTF8.self).contains("process:stop:1"), "Stop tokens remain process-local")
        snapshot.observe(["sessionFile": "/isolated/other.jsonl", "snapshot": ["supported": true, "active": false, "busy": false]])
        expect(snapshot.records.isEmpty && snapshot.session == nil && !snapshot.canInspect && !snapshot.runs.isEmpty,
               "Switching native journals clears live inspection while preserving this chat's older runs")
        var legacy = OMPDebugSnapshot()
        legacy.observe(["sessionFile": "/isolated/native.jsonl", "record": ["id": "launch", "action": "launch", "phase": "begin", "timestamp": 1000]])
        expect(legacy.preventsRecycle && !legacy.canInspect, "Fallback hooks protect pending debug work without claiming SDK support")
        legacy.observe(["sessionFile": "/isolated/native.jsonl", "record": ["id": "launch", "action": "launch", "phase": "end", "timestamp": 2000, "summary": paused]])
        legacy.observe(["sessionFile": "/isolated/native.jsonl", "record": ["id": "end", "action": "terminate", "phase": "end", "timestamp": 3000, "summary": paused]])
        expect(!legacy.preventsRecycle && legacy.session?.status == "terminated", "Pre-termination native summaries cannot leave a phantom live fallback session")
        let config = SessionConfiguration(provider: .omp, executable: nil, workingDirectory: URL(fileURLWithPath: "/isolated"),
            environment: [:], resumeID: nil, resumeAt: nil, model: nil, effort: nil, runtimeMode: .auto,
            interactionMode: .build, apiKey: nil, hydra: nil, antiSlopEnabled: false)
        let native = OMPSession(configuration: config)
        native.sessionFile = "/isolated/native.jsonl"
        var events = 0
        native.onEvent = { if case .ompDebug = $0 { events += 1 } }
        expect(native.handleDebugControl(["type": "omp_gui_debug", "sessionFile": "/foreign", "snapshot": frame["snapshot"]!]), "Private debug frames never enter chat projection")
        expect(events == 0, "Foreign native-file observations are ignored")
        _ = native.handleDebugControl(["type": "omp_gui_debug", "sessionFile": "/isolated/native.jsonl", "snapshot": frame["snapshot"]!])
        expect(events == 1 && native.nativeActivity.recycleBlockers.contains("debug-session"), "Debug state is published independently of a displayed turn and blocks recycling")
        native.disconnectDebugObservation()
        expect(!native.debugSnapshot.canInspect && !native.debugSnapshot.preventsRecycle, "Disconnect releases process ownership and live inspections")
        let commands = OMPSession.commands(["commands": [["name": "omp-gui-debug", "source": "extension"], ["name": "debug", "source": "builtin"]]])
        expect(!commands.contains(where: { $0.name == "omp-gui-debug" }), "Private inspection transport is hidden from the composer")
        expect(WorkspacePanel.debug.isImplemented, "Debug is a real sidebar destination")
        phaseChecks()
        try stepSnapshotChecks()
        let grouped = try runChecks()
        try await detailChecks(grouped: grouped)
    }

    @MainActor private static func stepSnapshotChecks() throws {
        let file = "/isolated/checkpoints.jsonl"
        var value = OMPDebugSnapshot()
        let summary: JSONValue = ["id": "dap", "status": "stopped", "adapter": "fixture", "program": "/isolated/burstd"]
        value.observe(["sessionFile": .string(file), "snapshot": ["supported": true, "active": true, "busy": false,
            "runID": "process:run:1", "stopID": "process:stop:1", "stopToken": "private", "session": summary]])
        func step(_ id: String, action: String = "evaluate", input: JSONValue? = nil, result: JSONValue? = nil) {
            let detail = OMPDebugDetails(input: input, result: result)
            value.observe(["sessionFile": .string(file), "record": ["id": .string(id), "action": .string(action), "phase": "end",
                "timestamp": 1000, "summary": summary, "details": ["inputJSON": detail.inputJSON.map(JSONValue.string) ?? .null,
                    "resultJSON": detail.resultJSON.map(JSONValue.string) ?? .null]]])
        }
        func read(_ operation: String, fields: [String: JSONValue] = [:], data: JSONValue) {
            let expected = value
            precondition(value.captureInspection(operation, fields: fields, data: data, expected: expected))
        }
        step("pause", action: "pause")
        read("stack", data: ["frames": [["id": 1, "name": "fill"]]])
        read("scopes", fields: ["frameID": 1], data: ["scopes": [["name": "Locals", "reference": 1],
            ["name": "Registers", "presentationHint": "registers", "reference": 3]]])
        step("read-a", action: "variables", input: ["scope_id": 1], result: ["variables": [["name": "index", "value": "1", "variablesReference": 0]]])
        read("variables", fields: ["frameID": 1, "reference": 3], data: ["variables": [["name": "x0", "value": "0x1", "reference": 0]]])
        step("read-b", action: "variables", input: ["scope_id": 1], result: ["variables": [["name": "index", "value": "2", "variablesReference": 0]]])
        read("variables", fields: ["frameID": 1, "reference": 3], data: ["variables": [["name": "x0", "value": "0x2", "reference": 0]]])
        let run = value.runs.last!
        precondition(run.inspection(after: "pause")?.variables(reference: 1, frameID: 1) == nil,
                     "A stop's first step cannot display values read by a later step")
        let first = run.inspection(after: "read-a")!, second = run.inspection(after: "read-b")!
        precondition(first.variables(reference: 1, frameID: 1)?.first?["value"]?.string == "1"
            && first.variables(reference: 3, frameID: 1)?.first?["value"]?.string == "0x1"
            && second.variables(reference: 1, frameID: 1)?.first?["value"]?.string == "2"
            && second.variables(reference: 3, frameID: 1)?.first?["value"]?.string == "0x2",
                     "Step details retain distinct model/sidebar variable and register reads within the same stop")
        precondition(run.inspection(before: "read-b") == first)
        let restored = OMPDebugSnapshot(archive: try JSONDecoder().decode(OMPDebugArchive.self, from: JSONEncoder().encode(value.archive!)))
        let savedFirst = restored.runs.last?.inspection(after: "read-a"), savedSecond = restored.runs.last?.inspection(after: "read-b")
        precondition(savedFirst?.frames == first.frames && savedFirst?.scopes(frameID: 1) == first.scopes(frameID: 1)
            && savedFirst?.variables(reference: 1, frameID: 1) == first.variables(reference: 1, frameID: 1)
            && savedFirst?.variables(reference: 3, frameID: 1) == first.variables(reference: 3, frameID: 1)
            && savedSecond?.variables(reference: 1, frameID: 1) == second.variables(reference: 1, frameID: 1)
            && savedSecond?.variables(reference: 3, frameID: 1) == second.variables(reference: 3, frameID: 1),
                     "Immutable step boundaries survive saving and restoring a conversation")

        var legacy = run
        for index in legacy.stops.indices {
            legacy.stops[index].captures = second.captures.map { capture in var capture = capture; capture.stepID = nil; return capture }
        }
        legacy.normalize()
        precondition(legacy.inspection(after: "read-a")?.variables(reference: 1, frameID: 1)?.first?["value"]?.string == "1"
            && legacy.inspection(after: "read-a")?.variables(reference: 3, frameID: 1) == nil
            && legacy.inspection(after: "read-b")?.variables(reference: 3, frameID: 1)?.first?["value"]?.string == "0x2",
                     "Legacy tool reads are replayed at their exact step; unattributed sidebar values are never backdated")
        print("PASS immutable per-step stack, variable and register snapshots, legacy migration and restoration")
    }

    @MainActor private static func runChecks() throws -> OMPDebugSnapshot {
        func expect(_ value: Bool, _ message: String) { precondition(value, message); print("PASS \(message)") }
        let file = "/isolated/grouped.jsonl"
        var snapshot = OMPDebugSnapshot()
        func record(_ id: String, _ phase: String, action: String = "launch") -> JSONValue {
            ["sessionFile": .string(file), "record": ["id": .string(id), "action": .string(action), "phase": .string(phase), "timestamp": 1000]]
        }
        func state(_ vm: String, _ stop: Int, status: String = "stopped", exit: Int? = nil) -> JSONValue {
            ["sessionFile": .string(file), "snapshot": ["supported": true, "active": .bool(status != "terminated"), "busy": false,
                "runID": .string(vm + ":run:debug-1"), "stopID": .string(vm + ":stop:\(stop)"), "stopToken": .string(vm + ":token:\(stop)"),
                "session": ["id": "debug-1", "status": .string(status), "adapter": "fixture", "program": .string("/isolated/" + vm),
                    "threadId": 7, "frameName": "commit", "stopReason": "breakpoint", "exitCode": exit.map(JSONValue.int) ?? .null]]]
        }
        snapshot.observe(record("launch-a", "begin")); snapshot.observe(state("vm-a", 1)); snapshot.observe(record("launch-a", "end"))
        let firstRun = snapshot.runID!
        let firstStop = snapshot.currentStopID!
        let expected = snapshot
        func capture(_ operation: String, fields: [String: JSONValue] = [:], data: JSONValue) {
            precondition(snapshot.captureInspection(operation, fields: fields, data: data, expected: expected))
        }
        capture("stack", data: ["frames": [["id": 1, "name": "IngestCoordinator.commit"], ["id": 2, "name": "worker"]]])
        capture("scopes", fields: ["frameID": 1], data: ["scopes": [["name": "Locals", "reference": 100],
            ["name": "Registers", "presentationHint": "registers", "reference": 200]]])
        capture("variables", fields: ["frameID": 1, "reference": 100], data: ["variables": [
            ["name": "worker", "value": "worker-2", "type": "String", "reference": 0],
            ["name": "state", "value": "locked", "reference": 101]]])
        capture("variables", fields: ["frameID": 1, "reference": 101], data: ["variables": [["name": "owner", "value": "worker-2", "reference": 0]]])
        capture("variables", fields: ["frameID": 1, "reference": 200], data: ["variables": [
            ["name": "x0", "value": "0x2a", "type": "uint64", "reference": 0],
            ["name": "Vector registers", "value": "", "reference": 201]]])
        capture("variables", fields: ["frameID": 1, "reference": 201], data: ["variables": [["name": "v0", "value": "{0, 1, 2, 3}", "reference": 0]]])
        capture("scopes", fields: ["frameID": 2], data: ["scopes": [["name": "Caller", "reference": 100]]])
        capture("variables", fields: ["frameID": 2, "reference": 100], data: ["variables": [["name": "caller", "value": "frame-two", "reference": 0]]])
        expect(snapshot.stops[0].variables(reference: 100, frameID: 1)?.first?["name"]?.string == "worker"
            && snapshot.stops[0].variables(reference: 100, frameID: 2)?.first?["name"]?.string == "caller",
               "Saved values remain scoped to their frame when an adapter reuses reference numbers")
        expect(snapshot.stops[0].scopes(frameID: 1)[1]["presentationHint"]?.string == "registers"
            && snapshot.stops[0].variables(reference: 201, frameID: 1)?.first?["name"]?.string == "v0",
               "Register scopes and expanded nested register values are captured as literal data")
        capture("variables", fields: ["reference": 300], data: ["variables": [["name": "unassociated", "value": "literal-only", "reference": 0]]])
        expect(snapshot.stops[0].variables(reference: 300, frameID: 1) == nil
            && snapshot.stops[0].variables(reference: 300, frameID: nil)?.first?["name"]?.string == "unassociated",
               "Unassociated historical values cannot impersonate a selected frame's variables")
        snapshot.observe(state("vm-a", 2))
        expect(snapshot.stops.count == 2 && snapshot.stops.first?.id == firstStop
            && !snapshot.captureInspection("variables", fields: ["frameID": 1, "reference": 100], data: ["variables": []], expected: expected),
               "A new stop preserves the previous snapshot and rejects a late response from it")
        snapshot.observe(state("vm-a", 2, status: "terminated", exit: 0))
        snapshot.observe(record("launch-b", "begin"))
        expect(snapshot.preventsRecycle, "A new launch retains process protection while a previous run is archived")
        snapshot.observe(state("vm-b", 1)); snapshot.observe(record("launch-b", "end"))
        expect(snapshot.runs.count == 2 && snapshot.runID != firstRun && snapshot.runs[0].id == firstRun
            && snapshot.runs[0].stops.first?.variables(reference: 200, frameID: 1)?.first?["value"]?.string == "0x2a",
               "Sequential launches, including reused native debug-1 IDs, have independent run and stop histories")
        expect(snapshot.runs[0].phase == .completed, "A subsequent launch cannot turn a completed previous run into an interruption")
        expect(!snapshot.captureInspection("stack", fields: [:], data: ["frames": []], expected: expected),
               "A previous run cannot populate the new debugger's snapshot")
        let liveRun = snapshot.runID
        snapshot.observe(record("blocked-launch", "begin"))
        snapshot.observe(state("vm-b", 1))
        snapshot.observe(["sessionFile": .string(file), "record": ["id": "blocked-launch", "action": "launch", "phase": "end", "timestamp": 2000, "failed": true]])
        expect(snapshot.runID == liveRun && snapshot.runs.count == 2 && snapshot.records.last?.failed == true,
               "A rejected launch while another root is active remains a failed step, not a new copy of the active debugger")
        let encoded = try JSONEncoder().encode(snapshot.archive!)
        let decoded = try JSONDecoder().decode(OMPDebugArchive.self, from: encoded)
        let restored = OMPDebugSnapshot(archive: decoded)
        expect(restored.runs.count == 2 && restored.runs[0].stops[0].frames.count == 2
            && restored.runs[0].stops[0].variables(reference: 100, frameID: 1)?.first?["value"]?.string == "worker-2"
            && !restored.canInspect && restored.stopToken == nil && restored.currentStopID == nil,
               "Run/stop/stack/variable/register snapshots survive document encoding without restoring live authority")
        expect(!String(decoding: encoded, as: UTF8.self).contains(":token:"), "Persisted stop identities never include native authorization tokens")
        var newProcess = OMPDebugSnapshot()
        newProcess.observe(["sessionFile": "/isolated/new-native.jsonl", "record": ["id": "new", "action": "launch", "phase": "begin", "timestamp": 2000]])
        newProcess.retainHistory(from: restored)
        expect(newProcess.runs.count == 3 && newProcess.runs[0].sessionFile == file, "A new native journal in the same chat preserves older run archives")
        var many = decoded
        many.runs = (0..<40).map { index in var run = decoded.runs[0]; run.id = "run-\(index)"; return run }
        expect(OMPDebugSnapshot(archive: many).runs.count == 32, "Run retention has a bounded conversation budget")
        return snapshot
    }

    @MainActor private static func phaseChecks() {
        func expect(_ value: Bool, _ message: String) { precondition(value, message); print("PASS \(message)") }
        let file = "/isolated/phases.jsonl"
        func state(_ status: String, active: Bool = true, busy: Bool = false, exit: Int? = nil) -> OMPDebugSnapshot {
            var value = OMPDebugSnapshot()
            value.observe(["sessionFile": .string(file), "snapshot": ["supported": true, "active": .bool(active), "busy": .bool(busy),
                "session": ["id": "dap", "adapter": "fixture", "status": .string(status), "exitCode": exit.map(JSONValue.int) ?? .null]]])
            return value
        }
        expect(OMPDebugSnapshot().phase == .idle && state("running").phase == .debugging
            && state("launching").phase == .starting && state("configuring").phase == .starting,
               "Debug status distinguishes idle, startup and running")
        var stopped = state("stopped", busy: true)
        expect(stopped.phase == .paused, "Reading a stopped process keeps the paused status")
        let begin: JSONValue = ["id": "continue", "action": "continue", "phase": "begin", "timestamp": 1000]
        stopped.observe(["sessionFile": .string(file), "record": begin])
        expect(stopped.phase == .debugging && stopped.presentationID != nil, "A pending resume shows debugging and emits live presentation intent")
        let intent = stopped.presentationID
        stopped.observe(["sessionFile": .string(file), "record": begin])
        stopped.observe(["sessionFile": .string(file), "record": ["id": "continue", "action": "continue", "phase": "end", "timestamp": 2000]])
        stopped.observe(["sessionFile": .string(file), "record": ["id": "read", "action": "threads", "phase": "begin", "timestamp": 3000]])
        expect(stopped.presentationID == intent, "Duplicate begins, results and active inspections do not request another panel reveal")
        stopped.observe(["sessionFile": .string(file), "record": ["id": "new-launch", "action": "launch", "phase": "begin", "timestamp": 4000]])
        expect(stopped.presentationID != intent && stopped.phase == .starting, "A new launch requests presentation even after earlier debug work")
        expect(state("terminated", active: false, exit: 0).phase == .completed
            && state("terminated", active: false, exit: 2).phase == .failed
            && state("terminated", active: false).phase == .ended, "Native exits distinguish completion, failure and an unknown exit")
        var terminal = state("terminated", active: false, busy: true)
        terminal.observe(["sessionFile": .string(file), "record": ["id": "terminate", "action": "terminate", "phase": "end", "timestamp": 2000]])
        expect(terminal.phase == .completed, "Unrelated bridge busy metadata cannot override a successfully terminated root")
        var oldRun = terminal.runs.last!
        oldRun.phase = .interrupted; oldRun.normalize()
        expect(oldRun.phase == .completed, "Previously misclassified archives recover their status from terminal evidence")
        var detached = state("running"); detached.disconnect()
        expect(detached.phase == .interrupted, "Losing a nonterminal native process is an interruption")
        let restored = OMPDebugSnapshot(archive: stopped.archive!)
        expect(restored.presentationID == nil && restored.phase == .interrupted, "Saved debug history never replays a live panel reveal")
        var failed = OMPDebugSnapshot()
        failed.observe(["sessionFile": .string(file), "record": ["id": "failure", "action": "launch", "phase": "end", "timestamp": 1000, "failed": true]])
        expect(failed.phase == .failed, "A failed launch without a native session reports failure")
    }

    @MainActor private static func detailChecks(grouped: OMPDebugSnapshot) async throws {
        func expect(_ value: Bool, _ message: String) { precondition(value, message); print("PASS \(message)") }
        guard let root = CaptureRun.outputDirectory else { fatalError("Requires isolated capture storage") }
        let cwd = root.appendingPathComponent("debuggee", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let source = cwd.appendingPathComponent("IngestCoordinator.swift")
        try "func commit() {\n    let segments = 16\n    print(segments)\n}\n".write(to: source, atomically: true, encoding: .utf8)
        let nativeFile = root.appendingPathComponent("native.jsonl")
        let location = OMPDebugSource(["source": ["path": "IngestCoordinator.swift"], "line": 2, "column": 5])!
        let target = await OMPDebugSourceResolver.resolve(location, cwd: cwd.path, directory: root.path)
        expect(target?.path == source.path && target?.line == 2 && target?.column == 5, "Native cwd resolves relative sources with exact line and column")
        let symbol = OMPDebugSource(["source": ["path": "/usr/lib/system/libsystem_kernel.dylib`__semwait_signal"], "line": 3])!
        expect(await OMPDebugSourceResolver.resolve(symbol, cwd: cwd.path, directory: root.path) == nil, "Library-symbol pseudo paths cannot open empty file tabs")
        let virtual = OMPDebugSource(["source": ["path": .string(source.path), "sourceReference": 7], "line": 2])!
        expect(await OMPDebugSourceResolver.resolve(virtual, cwd: cwd.path, directory: root.path) == nil, "Adapter source identity wins even when its display path exists")
        let missing = OMPDebugSource(["source": ["path": "missing.swift"]])!
        expect(await OMPDebugSourceResolver.resolve(missing, cwd: cwd.path, directory: root.path) == nil, "Missing sources stay inert")

        let paused: JSONValue = ["id": "dap", "status": "stopped", "adapter": "lldb-dap", "program": "ingestd", "cwd": .string(cwd.path),
            "threadId": 7, "frameName": "IngestCoordinator.commit", "source": ["path": "IngestCoordinator.swift"], "line": 2, "stopReason": "breakpoint"]
        let frames: JSONValue = [["id": 0, "name": "IngestCoordinator.commit", "source": ["path": "IngestCoordinator.swift"], "line": 2, "column": 5],
            ["id": 1, "name": "worker-2", "source": ["path": "/usr/lib/system/libsystem_kernel.dylib`__semwait_signal"], "line": 3]]
        let input: JSONValue = ["action": "custom_request", "command": "stackTrace", "arguments": ["threadId": 7]]
        let result: JSONValue = ["action": "custom_request", "success": true, "snapshot": paused, "customBody": ["stackFrames": frames]]
        let header: JSONValue = ["type": "session", "id": "native", "cwd": .string(cwd.path)]
        let call: JSONValue = ["type": "message", "message": ["role": "assistant", "content": [["type": "toolCall", "id": "call-stack", "name": "write",
            "arguments": ["path": "xd://debug", "content": .string(input.compactString)]]]]]
        let response: JSONValue = ["type": "message", "message": ["role": "toolResult", "toolName": "write", "toolCallId": "call-stack",
            "details": ["xdev": ["tool": "debug", "inner": result]], "content": [["type": "text", "text": "2 frames"]]]]
        try [header, call, response].map(\.compactString).joined(separator: "\n").write(to: nativeFile, atomically: true, encoding: .utf8)
        let old = OMPDebugRecord(["id": .string(UUID().uuidString + ":call-stack"), "action": "custom_request", "phase": "end", "timestamp": 1000])!
        let recovered = await OMPDebugHistory.read(sessionFile: nativeFile.path, record: old)
        expect(recovered?.details.input == input && recovered?.details.result == result && recovered?.details.output == "2 frames",
               "Older steps recover exact device call inputs, structured responses and output from the public journal")
        expect(recovered?.session?.cwd == cwd.path, "Historical source navigation uses the captured debuggee directory")
        let valuesFile = root.appendingPathComponent("legacy-values.jsonl")
        let savedScopes: JSONValue = ["scopes": [["name": "Locals", "variablesReference": 100],
            ["name": "Globals", "variablesReference": 101], ["name": "Registers", "presentationHint": "registers", "variablesReference": 102]]]
        let savedVariables: JSONValue = ["variables": [["name": "worker", "type": "String", "value": "worker-2", "variablesReference": 0],
            ["name": "segments", "type": "Int", "value": "16", "variablesReference": 0]]]
        let legacyValues: [(String, JSONValue, JSONValue)] = [
            ("scopes", ["action": "scopes", "frame_id": 0], savedScopes),
            ("variables", ["action": "variables", "variable_ref": 100], savedVariables)]
        for (action, request, body) in legacyValues {
            let legacyCall: JSONValue = ["type": "message", "message": ["role": "assistant", "content": [["type": "toolCall", "id": "legacy-values", "name": "write",
                "arguments": ["path": "xd://debug", "content": .string(request.compactString)]]]]]
            let legacyResult: JSONValue = ["type": "message", "message": ["role": "toolResult", "toolName": "write", "toolCallId": "legacy-values",
                "details": ["xdev": ["tool": "debug", "inner": body]], "content": []]]
            try [header, legacyCall, legacyResult].map(\.compactString).joined(separator: "\n").write(to: valuesFile, atomically: true, encoding: .utf8)
            let legacyRecord = OMPDebugRecord(["id": .string(UUID().uuidString + ":legacy-values"), "action": .string(action), "phase": "end", "timestamp": 1000])!
            let values = await OMPDebugHistory.read(sessionFile: valuesFile.path, record: legacyRecord)
            expect(values?.details.input == request && values?.details.result == body,
                   "Metadata-only \(action) steps recover exact stored values and register scope descriptors")
        }
        var batchLines = [header]
        var legacyRecords: [OMPDebugRecord] = []
        func legacyRecord(_ id: String, action: String, status: String = "stopped") -> OMPDebugRecord {
            OMPDebugRecord(["id": .string(id), "nativeCallID": .string(id), "action": .string(action), "phase": "end", "timestamp": .int(legacyRecords.count * 1000),
                "summary": ["id": "legacy-dap", "adapter": "fixture", "status": .string(status), "frameName": "commit", "cwd": .string(cwd.path)]])!
        }
        legacyRecords.append(legacyRecord("old-launch", action: "launch"))
        for (action, request, body) in legacyValues {
            let id = "batch-" + action
            batchLines.append(["type": "message", "message": ["role": "assistant", "content": [["type": "toolCall", "id": .string(id), "name": "debug", "arguments": request]]]])
            batchLines.append(["type": "message", "message": ["role": "toolResult", "toolName": "debug", "toolCallId": .string(id), "details": body, "content": []]])
            legacyRecords.append(legacyRecord(id, action: action))
        }
        legacyRecords.append(legacyRecord("old-end", action: "terminate", status: "terminated"))
        legacyRecords.append(legacyRecord("second-launch", action: "launch"))
        try batchLines.map(\.compactString).joined(separator: "\n").write(to: valuesFile, atomically: true, encoding: .utf8)
        var legacyHistory = OMPDebugSnapshot(archive: OMPDebugArchive(sessionFile: valuesFile.path, session: nil, records: legacyRecords))
        expect(legacyHistory.runs.count == 2 && legacyHistory.runs[0].records.count == 4,
               "Flat legacy archives migrate sequential launches into independent run groups")
        let batch = await OMPDebugHistory.read(sessionFile: valuesFile.path, records: legacyHistory.runs[0].records)
        expect(batch.count == 2, "One public journal scan recovers a run's exact scope and variable calls together")
        expect(legacyHistory.recoverDetails(runID: legacyHistory.runs[0].id, values: batch.mapValues(\.details), summaries: [:])
            && legacyHistory.runs[0].stops[0].variables(reference: 100, frameID: 0)?.first?["value"]?.string == "worker-2",
               "Recovered legacy reads become persisted values in their original run and stop")
        var foreign = old; foreign.id = "foreign"
        expect(await OMPDebugHistory.read(sessionFile: nativeFile.path, record: foreign) == nil, "Similar actions never substitute for an exact native call ID")
        try [header, call, response, call].map(\.compactString).joined(separator: "\n").write(to: nativeFile, atomically: true, encoding: .utf8)
        expect(await OMPDebugHistory.read(sessionFile: nativeFile.path, record: old) == nil, "Ambiguous duplicated native IDs are rejected")
        try [header, call, response].map(\.compactString).joined(separator: "\n").write(to: nativeFile, atomically: true, encoding: .utf8)
        let history = DebugHistoryStore()
        expect(history.resolvedRecord(old, sessionFile: nativeFile.path) == nil, "An unresolved old DAP step never supplies a provisional detail title")
        await history.recover(old, sessionFile: nativeFile.path)
        expect(history.resolvedRecord(old, sessionFile: nativeFile.path)?.details?.input?["command"]?.string == "stackTrace",
               "Historical title and body become available from the same prepared record")
        try Data().write(to: nativeFile)
        await history.recover(old, sessionFile: nativeFile.path)
        expect(history.resolvedRecord(old, sessionFile: nativeFile.path)?.details?.result == result,
               "Returning to a prepared step retains its exact details without rereading the journal")
        try [header, call, response].map(\.compactString).joined(separator: "\n").write(to: nativeFile, atomically: true, encoding: .utf8)
        let gate = DebugHistoryReadGate()
        let isolated = DebugHistoryStore(reader: { file, _ in await gate.read(file) })
        let firstRead = Task { await isolated.recover(old, sessionFile: nativeFile.path) }
        await gate.waitForReads(1)
        let otherFile = root.appendingPathComponent("other.jsonl").path
        let secondRead = Task { await isolated.recover(old, sessionFile: otherFile) }
        await gate.waitForReads(2)
        await gate.finish(nativeFile.path, value: recovered)
        await firstRead.value
        expect(isolated.resolvedRecord(old, sessionFile: nativeFile.path) == nil && isolated.resolvedRecord(old, sessionFile: otherFile) == nil,
               "A late journal result cannot cross a native conversation boundary")
        secondRead.cancel()
        await gate.finish(otherFile, value: recovered)
        await secondRead.value
        expect(isolated.resolvedRecord(old, sessionFile: otherFile) == nil, "Cancelled historical preparation does not populate the workspace cache")

        var snapshot = OMPDebugSnapshot()
        func observe(_ id: String, action: String, input: JSONValue, result: JSONValue, output: String = "", error: String? = nil) {
            let detail = OMPDebugDetails(input: input, result: result, output: output)
            let record: JSONValue = ["id": .string(id), "nativeCallID": .string(id), "action": .string(action), "phase": "end",
                "timestamp": .int(1000 + snapshot.records.count * 1000), "summary": paused, "failed": .bool(error != nil), "error": .optional(error),
                "details": ["inputJSON": .optional(detail.inputJSON), "resultJSON": .optional(detail.resultJSON), "output": .optional(detail.output), "limited": .bool(detail.limited)]]
            snapshot.observe(["sessionFile": .string(nativeFile.path), "record": record])
        }
        observe("launch", action: "launch", input: ["action": "launch", "program": "./ingestd", "args": ["--workers", "4"], "cwd": .string(cwd.path)], result: ["snapshot": paused])
        observe("breakpoint", action: "set_breakpoint", input: ["action": "set_breakpoint", "file": "IngestCoordinator.swift", "line": 2, "condition": "segments > 0", "hit_condition": "3"], result: ["breakpoints": [["verified": true, "line": 2]]])
        observe("stack", action: "custom_request", input: input, result: result, output: "2 frames")
        observe("vars", action: "variables", input: ["action": "variables", "variable_ref": 100], result: ["variables": [
            ["name": "worker", "type": "String", "value": "worker-2", "variablesReference": 0],
            ["name": "segments", "type": "Int", "value": "16", "variablesReference": 0],
            ["name": "state", "type": "InstrumentedLock", "value": "held=true owner=worker-2(4099) acq=16 waits=4", "variablesReference": 101]]])
        observe("eval", action: "evaluate", input: ["action": "evaluate", "expression": "self.snapshot().description", "frame_id": 0],
                result: ["evaluation": ["result": "state.lock[held=true owner=worker-2(4099) acq=16 waits=4]", "type": "String"]])
        observe("continue", action: "continue", input: ["action": "continue", "timeout": 5], result: ["success": false], error: "Aborted: The operation timed out.")
        observe("output", action: "output", input: ["action": "output"], result: ["output": "worker-2 committed segment 16\nqueue=0 pending=0\nExit code: 0"], output: "worker-2 committed segment 16\nqueue=0 pending=0\nExit code: 0")
        observe("threads", action: "threads", input: ["action": "threads"], result: ["threads": [["id": 25790292, "name": "Thread 1"]]])
        observe("empty", action: "scopes", input: ["action": "scopes"], result: ["scopes": []])
        var reason = OMPDebugRecord(["id": "reason", "action": "stopped", "phase": "state", "timestamp": 10000,
            "summary": ["id": "dap", "adapter": "fixture", "status": "stopped", "stopReason": "signal", "stopDescription": "signal SIGSTOP"]])!
        snapshot.records.append(reason)
        reason.id = "one-line"; reason.session = nil; reason.action = "modules"; reason.phase = "end"
        reason.details = OMPDebugDetails(input: ["action": "modules"], result: ["modules": []])
        snapshot.records.append(reason)
        snapshot.records.append(old)
        snapshot.disconnect()
        let archive = try JSONDecoder().decode(OMPDebugArchive.self, from: JSONEncoder().encode(snapshot.archive!))
        let restored = OMPDebugSnapshot(archive: archive)
        expect(restored.records[3].details?.result?["variables"]?[2]?["value"]?.string?.contains("owner=worker-2") == true && !restored.canInspect,
               "Saved variable values remain readable snapshots without restoring live inspection authority")
        let oldArchive: JSONValue = ["sessionFile": .string(nativeFile.path), "records": [["id": "old", "action": "pause", "phase": "end", "failed": false,
            "startedAt": 1, "session": ["id": "old", "status": "stopped", "adapter": "DAP", "source": ["path": "old.c", "line": 4]]]]]
        let migrated = try JSONDecoder().decode(OMPDebugArchive.self, from: oldArchive.data())
        expect(migrated.records.first?.session?.source?.line == 4 && migrated.records.first?.details == nil, "First-version metadata archives still decode")
        let giant = OMPDebugDetails(input: ["expression": .string(String(repeating: "中文😀\"", count: 10000))],
            result: ["variables": .array((0..<400).map { ["name": .string("item-\($0)"), "value": .string(String(repeating: "x", count: 10000))] })], output: String(repeating: "y", count: 30000))
        expect(giant.limited && giant.cost <= 44 * 1024 && giant.input != nil && giant.result != nil, "Clipped step details stay valid JSON within the byte budget")
        var oversized = archive
        oversized.records = (0..<128).map { index in var record = archive.records[0]; record.id = "large-\(index)"; record.details = giant; return record }
        let bounded = OMPDebugSnapshot(archive: oversized)
        expect(bounded.records.count == 128 && bounded.records.compactMap(\.details).reduce(0) { $0 + $1.cost } <= 1024 * 1024,
               "Archives bound aggregate detail memory while retaining the process sequence")
        var manyRuns = bounded.archive!
        let budgetRun = manyRuns.runs[0]
        manyRuns.runs = (0..<12).map { index in var run = budgetRun; run.id = "budget-\(index)"; return run }
        expect(OMPDebugSnapshot(archive: manyRuns).runs.reduce(0) { $0 + $1.cost } <= 8 * 1024 * 1024,
               "Multiple runs share a bounded 8 MiB conversation payload budget")
        try await layoutChecks(snapshot: restored, grouped: grouped, source: target!, root: root)
    }

    @MainActor private static func layoutChecks(snapshot: OMPDebugSnapshot, grouped: OMPDebugSnapshot, source: FilePreviewReference, root: URL) async throws {
        _ = NSApplication.shared
        let model = AppModel()
        let context = FilePreviewContext(threadID: UUID(), workingDirectory: root.path)
        let runtime = model.runtime(for: context.threadID)
        let config = SessionConfiguration(provider: .omp, executable: nil, workingDirectory: root,
            environment: [:], resumeID: nil, resumeAt: nil, model: nil, effort: nil, runtimeMode: .auto,
            interactionMode: .build, apiKey: nil, hydra: nil, antiSlopEnabled: false)
        let native = OMPSession(configuration: config)
        runtime.observe(native); native.onEvent?(.ompDebug(snapshot))
        let previews = FilePreviewStore(persistenceURL: root.appendingPathComponent("previews.json"))
        previews.setContext(context); previews.openPanel(.debug)
        let window = ThreadWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 760), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.filePreviews = previews
        let host = FrameHostingView(rootView: AnyView(DebugWorkspacePane(runtime: runtime, previews: previews, context: context)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))))
        window.contentView = host
        defer { previews.suspend(); window.contentView = nil; window.close() }
        func capture(_ name: String) async throws {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            func invalidate(_ view: NSView) {
                view.needsDisplay = true; view.layer?.setNeedsDisplay(); view.subviews.forEach(invalidate)
            }
            invalidate(host)
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
            try png.write(to: root.appendingPathComponent("debug-\(name).png"))
            precondition(host.bounds.width == window.contentView?.bounds.width && !window.isVisible)
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            var controls: [NSRect] = []
            for case let view as NoWindowDragView in descendants(host) {
                var frame = view.convert(view.bounds, to: host)
                if !host.isFlipped { frame.origin.y = host.bounds.height - frame.maxY }
                // The full sidebar adds one noninteractive drag exclusion over
                // its entire surface; it is not a toolbar control hit target.
                if frame == host.bounds { continue }
                if frame.width > 1 && frame.height > 1 { controls.append(frame) }
            }
            precondition(!controls.isEmpty && controls.allSatisfy { $0.minX >= -0.5 && $0.maxX <= host.bounds.width + 0.5
                && $0.minY >= 0 && $0.maxY <= 50 }, "Debug action hit targets must fit the fixed top toolbar, including narrow sidebars")
            precondition((controls.map(\.midY).max()! - controls.map(\.midY).min()!) < 1, "Debug toolbar actions share one baseline")
        }
        // Hidden NSHostingView windows expose no AX descendants on this SDK.
        // Verify navigation and file reading here; real clicks/VoiceOver remain
        // system acceptance, which requires an owner-authorized GUI launch.
        for (appearance, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            window.appearance = NSAppearance(named: appearance)
            previews.session?.debugRecordID = nil
            try await capture("activity-\(name)")
            previews.session?.debugRecordID = "stack"
            try await capture("stack-\(name)")
            previews.session?.debugRecordID = "vars"
            try await capture("variables-\(name)")
            previews.session?.debugRecordID = "eval"
            try await capture("evaluate-\(name)")
        }
        for id in ["threads", "reason", "empty", "one-line"] {
            previews.session?.debugRecordID = id
            try await capture(id)
        }
        let old = snapshot.records.last!
        previews.session?.debugRecordID = old.id
        func preparedLegacyRecord() -> OMPDebugRecord? {
            runtime.ompDebug.archive?.runs.first(where: { $0.id == snapshot.runID })?.records.first(where: { $0.id == old.id })
        }
        for _ in 0..<100 where preparedLegacyRecord()?.details == nil {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(preparedLegacyRecord()?.details?.input?["command"]?.string == "stackTrace",
                     "The production workspace prepares and persists a legacy DAP command in its original run")
        try await capture("recovered-stack")
        window.setContentSize(NSSize(width: 280, height: 760))
        try await capture("evaluate-narrow")
        previews.session?.debugRecordID = "launch"
        try await capture("first-step-narrow")
        previews.session?.debugRecordID = "output"
        try await capture("last-step-narrow")
        previews.session?.debugRecordID = nil
        try await capture("activity-narrow")
        var manySteps = snapshot
        manySteps.session = nil
        manySteps.records = (0..<128).map { index in
            var record = snapshot.records[index % snapshot.records.count]
            record.id = "many-\(index)"
            return record
        }
        native.onEvent?(.ompDebug(manySteps))
        previews.session?.debugRecordID = "many-51"
        try await capture("many-steps-narrow")
        previews.session?.debugRecordID = nil
        try await capture("long-activity-narrow")
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        guard let viewport = scrollViews(host).first(where: { ($0.documentView?.bounds.height ?? 0) > 2000 }) else { fatalError("No activity viewport") }
        viewport.contentView.scroll(to: NSPoint(x: 0, y: 900)); viewport.reflectScrolledClipView(viewport.contentView)
        try await capture("scrolled-activity-narrow")
        let offset = viewport.contentView.bounds.origin.y
        precondition(offset > 600, "The regression fixture scrolls well past the first screen")
        previews.session?.debugRecordID = "many-51"
        try await capture("scrolled-detail-narrow")
        previews.session?.debugRecordID = nil
        try await capture("returned-activity-narrow")
        precondition(scrollViews(host).contains(where: { $0 === viewport }) && abs(viewport.contentView.bounds.origin.y - offset) < 0.5,
                     "Detail round trips preserve the native activity viewport and precise scroll offset")
        manySteps.connected = true; manySteps.active = true
        func appendStep(_ id: String) {
            var step = snapshot.records.first!
            step.id = id; step.action = "output"
            step.details = OMPDebugDetails(output: String(repeating: "new debug output ", count: 16))
            manySteps.records = Array((manySteps.records + [step]).suffix(128))
            native.onEvent?(.ompDebug(manySteps))
        }
        func bottomGap() -> CGFloat {
            max(0, (viewport.documentView?.bounds.height ?? 0) - viewport.contentView.bounds.maxY)
        }
        appendStep("follow-first")
        try await capture("following-new-step")
        precondition(bottomGap() < 24, "A live activity list follows a newly appended step")
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: viewport)
        viewport.contentView.scroll(to: NSPoint(x: 0, y: 900)); viewport.reflectScrolledClipView(viewport.contentView)
        try await capture("follow-paused")
        let manualOffset = viewport.contentView.bounds.origin.y
        appendStep("follow-paused-next")
        try await capture("follow-paused-new-step")
        precondition(abs(viewport.contentView.bounds.origin.y - manualOffset) < 1,
                     "New activity cannot move the viewport after manual scroll input")
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: viewport)
        viewport.contentView.scroll(to: NSPoint(x: 0, y: (viewport.documentView?.bounds.height ?? 0) - viewport.contentView.bounds.height))
        viewport.reflectScrolledClipView(viewport.contentView)
        try await capture("follow-resumed")
        appendStep("follow-resumed-next")
        try await capture("following-again")
        precondition(bottomGap() < 24, "Returning to the bottom resumes following new steps")
        native.onEvent?(.ompDebug(snapshot))
        previews.session?.debugRecordID = "stack"
        _ = previews.open(source, context: context)
        for _ in 0..<100 where previews.snapshot == nil { try await Task.sleep(for: .milliseconds(10)) }
        precondition(previews.snapshot != nil && previews.error == nil, "A verified source opens actual file contents")
        precondition(previews.selectedTab?.url.path == source.path, "Preview opens the verified debuggee file rather than the GUI working directory")
        precondition(previews.selectedTab?.location?.line == 2 && previews.selectedTab?.location?.column == 5, "File preview retains source navigation")
        previews.openPanel(.debug)
        precondition(previews.session?.debugRecordID == "stack", "Source tab round trip preserves the selected historical step")

        // Exercise the same runtime/window registration path used while the
        // real workspace sidebar is unmounted, without showing a GUI window.
        previews.openPanel(.files); previews.setVisible(false)
        var live = OMPDebugSnapshot()
        live.observe(["sessionFile": .string(snapshot.sessionFile!), "snapshot": ["supported": true, "active": false, "busy": false]])
        native.onEvent?(.ompDebug(live))
        precondition(!previews.isVisible && previews.activeSidebarTab == .panel(.files), "Restoration and metadata alone do not take over the sidebar")
        live.observe(["sessionFile": .string(snapshot.sessionFile!), "record": ["id": "live-launch", "action": "launch", "phase": "begin", "timestamp": 20000]])
        live.observe(["sessionFile": .string(snapshot.sessionFile!), "record": ["id": "live-launch", "action": "launch", "phase": "end", "timestamp": 21000]])
        native.onEvent?(.ompDebug(live))
        precondition(previews.isVisible && previews.activeSidebarTab == .panel(.debug) && previews.session?.debugRecordID == nil,
                     "A coalesced live begin/result opens a collapsed sidebar, selects Debug and clears stale step selection")
        previews.openPanel(.files); previews.setVisible(false)
        live.observe(["sessionFile": .string(snapshot.sessionFile!), "snapshot": ["supported": true, "active": true, "busy": false,
            "session": ["id": "dap", "status": "stopped", "adapter": "fixture"]],
            "record": ["id": "live-read", "action": "threads", "phase": "begin", "timestamp": 22000]])
        native.onEvent?(.ompDebug(live))
        precondition(!previews.isVisible && previews.activeSidebarTab == .panel(.files), "Ongoing debug inspection respects a later user panel choice")
        let foreignContext = FilePreviewContext(threadID: UUID(), workingDirectory: root.path)
        previews.setContext(foreignContext)
        live.observe(["sessionFile": .string(snapshot.sessionFile!), "record": ["id": "next-launch", "action": "launch", "phase": "begin", "timestamp": 23000]])
        native.onEvent?(.ompDebug(live))
        precondition(!previews.isVisible, "A debug begin in another conversation does not open this workspace")
        previews.setContext(context)
        native.onEvent?(.ompDebug(snapshot))
        native.onEvent?(.ompDebug(grouped))
        let historyID = grouped.runs[0].id
        previews.session?.selectDebugRun(historyID)
        previews.session?.debugRecordID = grouped.runs[0].records[0].id
        window.setContentSize(NSSize(width: 640, height: 1000))
        window.appearance = NSAppearance(named: .darkAqua)
        try await capture("saved-registers-wide")
        let selectedRecord = previews.session?.debugRecordID
        var nextRun = grouped
        nextRun.observe(["sessionFile": "/isolated/grouped.jsonl", "record": ["id": "third-launch", "action": "launch", "phase": "begin", "timestamp": 3000]])
        native.onEvent?(.ompDebug(nextRun))
        precondition(previews.session?.debugRunID == historyID && previews.session?.debugRecordID == selectedRecord,
                     "New debug runs cannot replace a pinned historical run or its selected stop detail")
        precondition(runtime.ompDebug.runs.first(where: { $0.id == historyID })?.stops[0].variables(reference: 200, frameID: 1)?.first?["value"]?.string == "0x2a")
        try await capture("history-during-new-launch")
        window.setContentSize(NSSize(width: 280, height: 1000))
        try await capture("saved-registers-narrow")
        previews.session?.selectDebugRun(nil)
        precondition(previews.session?.debugRecordID == nil && previews.session?.debugRunID == nil,
                     "The Latest debug run choice resumes following live work without reusing a historical frame")
        previews.setFullscreen(true)
        previews.openPanel(.debug)
        previews.session?.selectDebugRun(historyID)
        window.setContentSize(NSSize(width: 1000, height: 760))
        try await capture("fullscreen-overview")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func divider() -> DragHandleView? {
            descendants(host).compactMap { $0 as? DragHandleView }.first { $0.bounds.height > 200 && $0.bounds.width == 9 }
        }
        precondition(divider() == nil, "Fullscreen without a selected step keeps the overview full-width")
        let overview = scrollViews(host).first { $0.bounds.width > 900 }!
        previews.session?.debugRecordID = grouped.runs[0].records[0].id
        try await capture("fullscreen-step")
        precondition(divider() != nil && scrollViews(host).contains { $0 === overview }
                     && overview.bounds.width > 240 && overview.bounds.width < 600,
                     "Selecting a debug step keeps the actual activity viewport visible in the left column")
        let detail = scrollViews(host).first { $0 !== overview && $0.bounds.height > 200 }!
        precondition(detail.convert(detail.bounds, to: host).minX > overview.convert(overview.bounds, to: host).maxX,
                     "The selected debug step opens to the right of its activity list")
        let handle = divider()!
        let start = handle.convert(handle.bounds, to: host).midX
        handle.onBegin?(); handle.onChange?(CGSize(width: 120, height: 0)); handle.onEnd?()
        try await capture("fullscreen-resized")
        let dividedAt = handle.convert(handle.bounds, to: host).midX
        precondition(abs(dividedAt - start - 120) < 1, "The debug divider follows native drag input")
        let fraction = previews.session!.debugDetailFraction
        let resize = WindowLiveResize(window: window)
        host.rootView = AnyView(WorkspaceSidebarPane(store: previews)
            .modifier(HostedEnvironment(model: model, liveResize: resize, previews: previews)))
        try await capture("fullscreen-remounted")
        previews.openPanel(.files)
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        previews.openPanel(.debug)
        try await capture("fullscreen-tab-return")
        precondition(previews.session!.debugDetailFraction == fraction
                     && divider().map { abs($0.convert($0.bounds, to: host).midX - dividedAt) < 1 } == true,
                     "The debug split survives actual sidebar tab unmounting and remounting")
        precondition(previews.session!.gitDetailFraction == 0.42, "Each panel owns its independent column allocation")
        host.rootView = AnyView(DebugWorkspacePane(runtime: runtime, previews: previews, context: context)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor)))
        previews.setFullscreen(false)
        window.setContentSize(NSSize(width: 280, height: 760))
        try await capture("fullscreen-exit")
        precondition(divider() == nil, "Nonfullscreen debug keeps its original single-column detail")
        let menuWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        menuWindow.isReleasedWhenClosed = false
        menuWindow.appearance = NSAppearance(named: .darkAqua)
        var menuRuns = runtime.ompDebug.runs
        menuRuns[0].session?.program = "/isolated/long-debug-run-title-that-must-stay-on-a-single-line-with-an-ellipsis.py"
        let menuHost = FrameHostingView(rootView: AnyView(PopoverMenu(width: 360) {
            DebugRunMenu(runs: menuRuns, selection: historyID) { _ in }
        }.frame(width: 360).frame(maxHeight: .infinity, alignment: .top).background(Color(nsColor: .windowBackgroundColor))))
        menuWindow.contentView = menuHost
        menuHost.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        menuHost.layoutSubtreeIfNeeded()
        let menuBitmap = menuHost.bitmapImageRepForCachingDisplay(in: menuHost.bounds)!
        menuHost.cacheDisplay(in: menuHost.bounds, to: menuBitmap)
        try menuBitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("debug-run-menu.png"))
        precondition(!menuWindow.isVisible)
        menuWindow.contentView = nil; menuWindow.close()
        let evidence: JSONValue = ["offscreen": true, "widths": [640, 400, 280], "appearances": ["dark", "light"],
            "sourceNavigation": true, "scrollRoundTrip": true, "automaticPresentation": true, "automaticScrollFollowing": true,
            "runPicker": true, "pinnedHistory": true, "savedRegisters": true, "fullscreenColumns": true, "retainedDivider": true,
            "manualAcceptance": "Real window clicks and VoiceOver; hidden NSHostingView has no AX descendants."]
        try evidence.data(pretty: true).write(to: root.appendingPathComponent("layout.json"))
        print("PASS production sidebar offscreen activity/stack/variables/evaluation in light/dark and narrow layout; source navigation round trip")
    }
}

private actor DebugHistoryReadGate {
    private var continuations: [String: CheckedContinuation<OMPDebugHistory.Detail?, Never>] = [:]
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []
    private var reads = 0

    func read(_ file: String) async -> OMPDebugHistory.Detail? {
        await withCheckedContinuation { continuation in
            continuations[file] = continuation
            reads += 1
            for (count, waiter) in waiting where reads >= count { waiter.resume() }
            waiting.removeAll { reads >= $0.0 }
        }
    }
    func waitForReads(_ count: Int) async {
        if reads >= count { return }
        await withCheckedContinuation { waiting.append((count, $0)) }
    }
    func finish(_ file: String, value: OMPDebugHistory.Detail?) {
        continuations.removeValue(forKey: file)?.resume(returning: value)
    }
}
