import AppKit
import SwiftUI

enum DebugStepPresentation {
    static func title(_ record: OMPDebugRecord, details: OMPDebugDetails? = nil) -> String {
        let command = (details ?? record.details)?.input?["command"]?.string
        let action = record.action == "custom_request" ? ["stackTrace": "stack_trace", "threads": "threads", "scopes": "scopes",
            "variables": "variables", "evaluate": "evaluate", "modules": "modules", "loadedSources": "loaded_sources"][command ?? ""] : nil
        return Chrome.localized(OMPDebugRecord.title(action ?? record.action))
    }

    static func summary(_ record: OMPDebugRecord) -> String? {
        if record.failed { return record.error }
        let input = record.details?.input, result = record.details?.result
        let body = result?["customBody"] ?? result
        let expression = input?["expression"]?.string
        let evaluation = result?["evaluation"]?["result"]?.string
        if let expression { return expression + (evaluation.map { " = " + $0 } ?? "") }
        if let file = input?["file"]?.string {
            return URL(fileURLWithPath: file).lastPathComponent + (input?["line"]?.int.map { ":\($0)" } ?? "")
                + (input?["condition"]?.string.map { " · " + $0 } ?? "")
                + (input?["hit_condition"]?.string.map { " · " + $0 } ?? "")
        }
        if let program = input?["program"]?.string {
            return ([program] + (input?["args"]?.array?.compactMap(\.string) ?? [])).joined(separator: " ")
        }
        if let frames = body?["stackFrames"]?.array {
            let thread = input?["arguments"]?["threadId"]?.int ?? input?["thread_id"]?.int ?? record.session?.threadID
            return (thread.map { String(format: Chrome.localized("Thread %d"), $0) + " · " } ?? "")
                + String(format: Chrome.localized("%d frames"), frames.count)
                + (frames.first?["name"]?.string.map { " · " + $0 } ?? "")
        }
        if let threads = body?["threads"]?.array { return String(format: Chrome.localized("%d threads"), threads.count) }
        if let variables = body?["variables"]?.array {
            return variables.prefix(2).map { ($0["name"]?.string ?? "") + " = " + ($0["value"]?.string ?? "") }.joined(separator: " · ")
        }
        if let scopes = body?["scopes"]?.array { return scopes.compactMap { $0["name"]?.string }.joined(separator: " · ") }
        if record.action == "output", let output = record.details?.output { return output }
        if let command = input?["command"]?.string {
            return command + (input?["arguments"]?["threadId"]?.int.map { " · " + String(format: Chrome.localized("Thread %d"), $0) } ?? "")
        }
        if let source = record.session?.source { return source.label }
        return record.session?.frameName
    }

    static func symbol(_ record: OMPDebugRecord) -> String {
        if record.failed { return "exclamationmark.circle" }
        if record.phase == "begin" { return "circle.dotted" }
        if record.phase == "interrupted" { return "minus.circle" }
        switch record.action {
        case "launch", "attach": return "play.circle"
        case "stopped", "pause": return "pause.circle"
        case "terminated", "terminate": return "stop.circle"
        case "evaluate": return "function"
        case "set_breakpoint", "remove_breakpoint": return "dot.square"
        case "stack_trace", "threads": return "square.3.layers.3d"
        case "variables", "scopes": return "curlybraces"
        case "output": return "text.alignleft"
        default: return record.phase == "state" ? "circle.fill" : "checkmark"
        }
    }
}

struct DebugActivityList: View {
    let records: [OMPDebugRecord]
    let sessionFile: String?
    let history: DebugHistoryStore?
    var selectedID: String? = nil
    let select: (String) -> Void

    var body: some View {
        let titleCapHeight = NSFont.systemFont(ofSize: TypeScale.shared.ui(TypeScale.stockPointSize(.callout)), weight: .medium).capHeight
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Debug activity").font(.ui(.caption, weight: .semibold))
                Text(verbatim: "\(records.count)").font(.ui(.caption)).monospacedDigit()
                Spacer()
            }.foregroundStyle(Chrome.secondaryText).padding(12)
            ForEach(records) { record in
                let displayed = history?.resolvedRecord(record, sessionFile: sessionFile) ?? record
                let summary = DebugStepPresentation.summary(displayed).flatMap { $0.isEmpty ? nil : $0 }
                Button { select(record.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: DebugStepPresentation.symbol(record)).font(.symbol(.caption))
                            .foregroundStyle(record.failed ? .red : record.phase == "begin" ? Color.accentColor : Chrome.secondaryText)
                            .frame(width: 20, height: 16)
                            .alignmentGuide(.firstTextBaseline) { [titleCapHeight] dimensions in
                                dimensions[VerticalAlignment.center] + titleCapHeight / 2
                            }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(verbatim: DebugStepPresentation.title(displayed)).font(.ui(.callout, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right").font(.symbol(.caption2)).foregroundStyle(Chrome.secondaryText.opacity(0.6))
                            }
                            if let summary {
                                Text(verbatim: summary).font(.code(.caption)).foregroundStyle(record.failed ? .red : Chrome.secondaryText)
                                    .lineLimit(2).truncationMode(.middle)
                            } else if record.phase == "interrupted" {
                                Text("Interrupted").font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8).contentShape(.rect)
                    .background(selectedID == record.id ? Chrome.overlay(0.06) : .clear)
                }.buttonStyle(.plain).id(record.id).accessibilityIdentifier("debug-step:" + record.id)
                if record.id != records.last?.id { Divider().opacity(0.4).padding(.leading, 41) }
            }
        }
    }
}
