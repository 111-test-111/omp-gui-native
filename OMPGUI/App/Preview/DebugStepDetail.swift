import SwiftUI

struct DebugStepDetail: View {
    let record: OMPDebugRecord
    let sessionFile: String?
    let history: DebugHistoryStore
    var inspection: OMPDebugStop? = nil
    var previousInspection: OMPDebugStop? = nil
    let previews: FilePreviewStore
    let context: FilePreviewContext
    private enum Spacing {
        static let section: CGFloat = 16
        static let heading: CGFloat = 8
        static let field: CGFloat = 4
    }

    private var resolved: OMPDebugRecord? { history.resolvedRecord(record, sessionFile: sessionFile) }
    private var details: OMPDebugDetails? { resolved?.details }
    private var session: OMPDebugSession? { resolved?.session }
    private var cwd: String? { session?.cwd ?? details?.input?["cwd"]?.string ?? history.entry(for: record, sessionFile: sessionFile)?.detail?.cwd }
    private var input: [String: JSONValue] { details?.input?.object ?? [:] }
    private var argumentKeys: [String] { input.keys.filter { $0 != "action" }.sorted() }
    private var result: JSONValue? { details?.result?["customBody"] ?? details?.result }
    private var hasSavedVariables: Bool { inspection?.captures.contains { $0.operation == "variables" && $0.stepID == record.id } == true }
    private var hasStructuredResult: Bool {
        ["stackFrames", "threads", "scopes", "variables", "breakpoints", "sources", "modules", "sessions"]
            .contains { result?[$0]?.array?.isEmpty == false } || result?["evaluation"].map { !$0.isNull } == true
    }

    var body: some View {
        ScrollView {
            // Present one prepared snapshot. An unknown command has no truthful
            // provisional title; recovery and returning from cache are atomic.
            if resolved != nil {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    title
                    if let error = record.error, record.failed {
                        Text(verbatim: error).font(.code(.caption)).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if record.phase == "state" || ["launch", "attach", "continue", "pause", "step_over", "step_in", "step_out", "terminate"].contains(record.action) {
                        stop
                    }
                    structuredResult
                    if let inspection, !inspection.captures.isEmpty {
                        DebugSavedInspection(stop: inspection, previous: previousInspection,
                            showStack: result?["stackFrames"]?.array?.isEmpty != false, previews: previews, context: context).id(inspection.id)
                    }
                    if !argumentKeys.isEmpty {
                        section("Arguments") {
                            ForEach(argumentKeys, id: \.self) { key in
                                if key == "file", let source = OMPDebugSource(["source": ["path": input[key]!], "line": input["line"] ?? .null]) {
                                    sourceLink(source)
                                } else { valueRow(label(key), value: displayValue(input[key]!)) }
                            }
                        }
                    }
                    if let output = details?.output, !output.isEmpty {
                        if record.action == "output" || !hasStructuredResult {
                            section("Output") { literal(output) }
                        } else {
                            DisclosureGroup { literal(output).padding(.top, Spacing.heading) } label: {
                                Text("Tool output").font(.ui(.caption, weight: .semibold)).foregroundStyle(Chrome.secondaryText)
                            }
                        }
                    }
                    if let raw = details?.result {
                        DisclosureGroup { literal(raw.prettyString).padding(.top, Spacing.heading) } label: {
                            Text("Response data").font(.ui(.caption, weight: .semibold)).foregroundStyle(Chrome.secondaryText)
                        }
                    }
                    if record.phase != "state", record.phase != "begin", details?.inputJSON == nil, details?.resultJSON == nil, details?.output == nil,
                       inspection?.captures.isEmpty != false, details?.limited != true {
                        Text("No saved details for this step").font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                    }
                    if details?.limited == true {
                        Text("Snapshot truncated").font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
        .task(id: (sessionFile ?? "") + "\n" + record.id + "\n" + record.phase) {
            await history.recover(record, sessionFile: sessionFile)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: Spacing.heading) {
            HStack(spacing: 8) {
                Image(systemName: DebugStepPresentation.symbol(record)).foregroundStyle(record.failed ? .red : Color.accentColor)
                Text(verbatim: DebugStepPresentation.title(record, details: details)).font(.ui(.headline))
                Spacer(minLength: 0)
            }
            HStack {
                Text(record.startedAt, style: .time)
                if let end = record.endedAt {
                    Text(verbatim: String(format: Chrome.localized("%.1f s"), max(0, end.timeIntervalSince(record.startedAt))))
                }
            }.font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
        }
    }

    @ViewBuilder private var stop: some View {
        if let session, session.frameName?.isEmpty == false || session.source != nil || session.threadID != nil
            || session.stopReason?.isEmpty == false || session.exitCode != nil {
            section("Stop snapshot") {
                if let frame = session.frameName, !frame.isEmpty { literal(frame) }
                if let source = session.source { sourceLink(source) }
                if let threadID = session.threadID { valueRow("Debug thread", value: String(threadID)) }
                if let reason = session.stopReason, !reason.isEmpty { valueRow("Reason", value: session.stopDescription.flatMap { $0.isEmpty ? nil : $0 } ?? reason) }
                if let exit = session.exitCode { valueRow("Exit code", value: String(exit)) }
            }
        }
    }

    @ViewBuilder private var structuredResult: some View {
        if let frames = result?["stackFrames"]?.array, !frames.isEmpty {
            section("Call stack") {
                ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: "\(index)").font(.code(.caption)).foregroundStyle(Chrome.secondaryText).frame(width: 18, alignment: .trailing)
                        VStack(alignment: .leading, spacing: Spacing.field) {
                            literal(frame["name"]?.string ?? "")
                            if let source = OMPDebugSource(frame) { sourceLink(source) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        if let evaluation = result?["evaluation"], !evaluation.isNull {
            section("Result") {
                literal(evaluation["result"]?.displayText ?? evaluation.displayText)
                if let type = evaluation["type"]?.string { Text(verbatim: type).font(.code(.caption2)).foregroundStyle(Chrome.secondaryText) }
            }
        }
        if !hasSavedVariables, let variables = result?["variables"]?.array, !variables.isEmpty {
            section("Variables") { namedValues(variables, valueKey: "value") }
        }
        if let scopes = result?["scopes"]?.array, !scopes.isEmpty {
            section("Scopes") { namedValues(scopes, valueKey: "variablesReference") }
        }
        if let threads = result?["threads"]?.array, !threads.isEmpty {
            section("Debug threads") { namedValues(threads, valueKey: "id") }
        }
        if let breakpoints = result?["breakpoints"]?.array, !breakpoints.isEmpty {
            section("Breakpoints") {
                ForEach(Array(breakpoints.enumerated()), id: \.offset) { _, point in
                    VStack(alignment: .leading, spacing: Spacing.field) {
                        HStack {
                            Image(systemName: point["verified"]?.bool == true ? "checkmark.circle" : "circle")
                                .foregroundStyle(point["verified"]?.bool == true ? .green : Chrome.secondaryText)
                            if let source = breakpointSource(point) { sourceLink(source) }
                        }
                        if let message = point["message"]?.string { literal(message) }
                    }
                }
            }
        }
        if let sources = result?["sources"]?.array?.compactMap({ OMPDebugSource(["source": $0]) }), !sources.isEmpty {
            section("Sources") {
                ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                    sourceLink(source)
                }
            }
        }
        if let modules = result?["modules"]?.array, !modules.isEmpty { section("Modules") { namedValues(modules, valueKey: "path") } }
        if let sessions = result?["sessions"]?.array?.compactMap({ OMPDebugSession($0) }), !sessions.isEmpty {
            section("Debug sessions") {
                ForEach(Array(sessions.enumerated()), id: \.offset) { _, value in
                    valueRow(value.title, value: Chrome.localized(value.statusTitle), localized: false)
                }
            }
        }
    }

    private func namedValues(_ values: [JSONValue], valueKey: String) -> some View {
        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
            VStack(alignment: .leading, spacing: Spacing.field) {
                if value["name"]?.displayText.isEmpty == false || value["type"]?.string?.isEmpty == false {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: value["name"]?.displayText ?? "").font(.code(.callout)).textSelection(.enabled)
                        Spacer(minLength: 0)
                        if let type = value["type"]?.string { Text(verbatim: type).font(.code(.caption2)).foregroundStyle(Chrome.secondaryText).lineLimit(1) }
                    }
                }
                if let stored = value[valueKey] { literal(displayValue(stored)).foregroundStyle(Chrome.secondaryText) }
            }
        }
    }
    private func breakpointSource(_ value: JSONValue) -> OMPDebugSource? {
        if let source = OMPDebugSource(value) { return source }
        guard let path = details?.input?["file"] else { return nil }
        return OMPDebugSource(["source": ["path": path], "line": value["line"] ?? details?.input?["line"] ?? .null])
    }
    private func sourceLink(_ source: OMPDebugSource) -> some View {
        DebugSourceLink(source: source, cwd: cwd, previews: previews, context: context)
    }
    private func section<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.heading) {
            Text(verbatim: Chrome.localized(name)).font(.ui(.caption, weight: .semibold)).foregroundStyle(Chrome.secondaryText)
            VStack(alignment: .leading, spacing: Spacing.heading) { content() }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func literal(_ text: String) -> some View {
        Text(verbatim: text).font(.code(.caption)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func valueRow(_ name: String, value: String, localized: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: Spacing.field) {
            Text(verbatim: localized ? Chrome.localized(name) : name).font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
            literal(value)
        }
    }
    private func displayValue(_ value: JSONValue) -> String {
        if value.isNull { return "null" }
        if value.string == "" { return "\"\"" }
        return value.displayText
    }
    private func label(_ key: String) -> String {
        switch key {
        case "program": "Program"
        case "args": "Program arguments"
        case "cwd": "Working directory"
        case "adapter": "Adapter"
        case "file": "File"
        case "line": "Line"
        case "condition": "Condition"
        case "hit_condition": "Hit condition"
        case "expression": "Expression"
        case "frame_id": "Frame"
        case "variable_ref": "Variable reference"
        case "thread_id": "Debug thread"
        case "command": "Command"
        case "arguments": "Request arguments"
        case "timeout": "Timeout"
        default: key
        }
    }
}
