import Foundation

enum ContextReportFormat: CaseIterable, Hashable {
    case markdown, json
    var fileExtension: String { self == .markdown ? "md" : "json" }
    var title: String { self == .markdown ? "Export Markdown…" : "Export JSON…" }
}

/// A frozen report of the accepted panel values. It holds no runtime, reader,
/// prompt bodies or native file paths, so a save dialog can outlive navigation.
struct ContextWorkspaceReport: Sendable {
    static let measurementNotes = [
        "Context and composition are estimates; usage is reported by the provider.",
        "Input includes cache reads and writes. Reasoning is part of output.",
        "Totals include retained branches and reported task usage.",
        "Auto-refresh runs every 5 seconds during active work; — means unknown."
    ]

    let capturedAt: Date
    let baseFilename: String
    let markdown: String
    let json: JSONValue

    func data(for format: ContextReportFormat) -> Data {
        format == .markdown ? Data(markdown.utf8) : json.data(pretty: true)
    }

    @MainActor init(runtime: ThreadRuntime, state: ContextWorkspaceStore,
                    live override: OMPContextLiveInspection? = nil, capturedAt: Date = .now) {
        let occupancy = ContextWorkspaceOccupancy(runtime: runtime, state: state, live: override)
        let live = occupancy.live, saved = state.saved
        let request = saved?.request
        let composition = request?.metadata.composition ?? live?.composition
        let requestComposition = request?.metadata.composition != nil
        let used = occupancy.used, window = occupancy.window, model = occupancy.model
        let remaining = used.flatMap { used in window.map { max(0, $0 - used) } }
        let fraction = used.flatMap { used in window.flatMap { $0 > 0 ? Double(used) / Double($0) : nil } }
        let title = runtime.thread?.title ?? Chrome.localized("Context")
        let source = occupancy.source, sourceTitle = occupancy.sourceTitle

        func text(_ key: String) -> String { Chrome.localized(key) }
        func number(_ value: Int?, estimate: Bool = false) -> String {
            value.map { (estimate ? "≈" : "") + $0.formatted() } ?? "—"
        }
        func date(_ value: Date?) -> String { value.map(Self.timestamp) ?? "—" }
        func percent(_ value: Double?) -> String {
            value?.formatted(.percent.precision(.fractionLength(1))) ?? "—"
        }
        func yesNo(_ value: Bool?) -> String { value.map { text($0 ? "Yes" : "No") } ?? "—" }
        var lines = ["# " + text("Context report"), "",
            "- " + text("Conversation") + ": " + Self.escape(title),
            "- " + text("Snapshot time") + ": " + date(capturedAt),
            "- " + text("Last successful context refresh") + ": " + date(state.updatedAt), ""]
        func table(_ title: String, _ rows: [(String, String)]) {
            lines += ["## " + text(title), "", "| " + text("Metric") + " | " + text("Value") + " |", "| --- | ---: |"]
            lines += rows.map { "| " + Self.escape(text($0.0)) + " | " + Self.escape($0.1) + " |" }
            lines.append("")
        }
        func categories(_ rows: [OMPContextCategory], total: Int?) {
            lines += ["| " + text("Category") + " | " + text("Tokens") + " | " + text("Share of estimate") + " |", "| --- | ---: | ---: |"]
            func share(_ count: Int) -> String { percent(total.flatMap { $0 > 0 ? Double(count) / Double($0) : nil }) }
            for row in rows {
                lines.append("| " + Self.escape(text(row.title)) + " | " + number(row.tokens, estimate: true) + " | " + share(row.tokens) + " |")
                for item in row.items {
                    lines.append("| ↳ " + Self.escape(item.name) + " | " + number(item.tokens, estimate: true) + " | " + share(item.tokens) + " |")
                }
                if row.omittedItems > 0 {
                    lines.append("| ↳ " + Self.escape(String(format: text("%lld more entries"), Int64(row.omittedItems))) + " | — | — |")
                }
            }
            lines.append("")
        }

        table("Current context", [
            ("Used tokens", number(used, estimate: true)), ("Context window", number(window)),
            ("Remaining capacity", number(remaining, estimate: true)), ("Usage", percent(fraction)),
            ("Data source", text(sourceTitle)), ("Context observed at", date(live?.timestamp)),
            ("Model", model ?? "—"),
            ("Automatic compaction", runtime.ompContext.autoCompactionEnabled.map { text($0 ? "Enabled" : "Disabled") } ?? "—"),
            ("Compactions on this branch", number(saved?.journal.compactions))
        ])
        if let live {
            lines += ["### " + text("Native context breakdown"), ""]
            categories(live.categories, total: OMPInspectionNumber.sum(live.categories.map { $0.tokens }))
        }
        table("Context composition · estimate", [
            ("Data source", text(requestComposition ? "Latest observed request" : "Current session projection")),
            ("Estimated tokens", number(composition?.total, estimate: true)),
            ("Observed at", date(requestComposition ? request?.record.timestamp : live?.timestamp)),
            ("Model", (requestComposition ? request?.record.model : live?.model) ?? "—")
        ])
        if let composition {
            categories(composition.categories, total: composition.total)
            if composition.limited {
                lines += [text("Composition reached its display budget. The estimate covers only the inspected portion."), ""]
            }
        }
        let metadata = request?.metadata
        table("Latest request · reported usage", [
            ("Status", request?.record.status.map { text($0.title) } ?? "—"),
            ("Observed at", date(request?.record.timestamp)), ("Request model", request?.record.model ?? "—"),
            ("Reported input", number(metadata?.reportedInput)), ("Fresh input", number(metadata?.input)),
            ("Cache reads", number(metadata?.cacheRead)), ("Cache writes", number(metadata?.cacheWrite)),
            ("Output", number(metadata?.output)), ("Reported reasoning", number(metadata?.reasoning)),
            ("Reported input − estimate", metadata?.difference.map { ($0 > 0 ? "+" : "") + $0.formatted() } ?? "—"),
            ("Provider payload observed", yesNo(metadata?.payloadObserved))
        ])
        let accounting = saved?.journal.accounting
        table("Recorded session total", [
            ("Total tokens", number(accounting?.total)), ("Fresh input", number(accounting?.input)),
            ("Cache reads", number(accounting?.cacheRead)), ("Cache writes", number(accounting?.cacheWrite)),
            ("Output", number(accounting?.output)), ("Reported reasoning", number(accounting?.reasoning)),
            ("Cache hit rate", accounting?.cacheHitRate?.formatted(.percent.precision(.fractionLength(2))) ?? "—"),
            ("Reported cost", accounting?.cost?.formatted(.currency(code: "USD").precision(.fractionLength(2...6))) ?? "—"),
            ("User messages", number(accounting?.users)), ("Model responses", number(accounting?.assistants)),
            ("Tool calls", number(accounting?.toolCalls)), ("Tool results", number(accounting?.toolResults)),
            ("Auxiliary model calls", number(accounting?.auxiliaryCalls)), ("Responses without usage", number(accounting?.missingReports))
        ])
        lines += ["## " + text("How these values are measured"), ""]
        lines += Self.measurementNotes.map { "- " + text($0) }
        if let accounting, accounting.reasoningReports < accounting.reports {
            lines.append("- " + text("Reasoning totals cover only calls that report reasoning separately."))
        }
        if saved?.captureWarning == true { lines.append("- " + text("Some request captures are unavailable or exceeded their retention limits.")) }
        if let error = state.error { lines.append("- " + Self.escape(error)) }

        var requestJSON: JSONValue = .null
        if let request {
            let value = request.metadata
            requestJSON = ["id": .string(request.record.entryID), "observedAt": Self.jsonDate(request.record.timestamp),
                "model": Self.jsonString(request.record.model), "status": Self.jsonString(request.record.status?.rawValue),
                "reportedInput": Self.jsonNumber(value.reportedInput), "input": Self.jsonNumber(value.input),
                "output": Self.jsonNumber(value.output), "cacheRead": Self.jsonNumber(value.cacheRead),
                "cacheWrite": Self.jsonNumber(value.cacheWrite), "reasoning": Self.jsonNumber(value.reasoning),
                "reportedInputMinusEstimate": Self.jsonNumber(value.difference), "payloadObserved": value.payloadObserved.map(JSONValue.bool) ?? .null]
        }
        var accountingJSON: JSONValue = .null
        if let value = accounting {
            accountingJSON = ["scope": "retained_session_branches_and_reported_tasks",
                "total": Self.jsonNumber(value.total), "input": Self.jsonNumber(value.input), "output": Self.jsonNumber(value.output),
                "cacheRead": Self.jsonNumber(value.cacheRead), "cacheWrite": Self.jsonNumber(value.cacheWrite),
                "reasoning": Self.jsonNumber(value.reasoning), "costUSD": value.cost.map(JSONValue.double) ?? .null,
                "cacheHitRate": value.cacheHitRate.map(JSONValue.double) ?? .null,
                "users": .int(value.users), "assistants": .int(value.assistants), "toolCalls": .int(value.toolCalls),
                "toolResults": .int(value.toolResults), "auxiliaryCalls": .int(value.auxiliaryCalls),
                "reports": .int(value.reports), "missingReports": .int(value.missingReports), "reasoningReports": .int(value.reasoningReports)]
        }
        var compositionJSON: JSONValue = .null
        if let composition {
            compositionJSON = ["source": .string(requestComposition ? "observed_request" : "session_projection"),
                "estimated": true, "total": .int(composition.total), "limited": .bool(composition.limited),
                "observedAt": Self.jsonDate(requestComposition ? request?.record.timestamp : live?.timestamp),
                "categories": Self.jsonCategories(composition.categories)]
        }
        json = ["schemaVersion": 1, "capturedAt": Self.jsonDate(capturedAt), "lastRefreshedAt": Self.jsonDate(state.updatedAt),
            "conversation": ["id": .string(runtime.threadID.uuidString), "title": .string(title)],
            "units": ["tokens": "tokens", "cost": "USD"],
            "context": ["source": .string(source), "estimated": true, "usedTokens": Self.jsonNumber(used),
                "windowTokens": Self.jsonNumber(window), "remainingTokens": Self.jsonNumber(remaining),
                "fraction": fraction.map(JSONValue.double) ?? .null, "observedAt": Self.jsonDate(live?.timestamp),
                "model": Self.jsonString(model), "nativeCategories": live.map { Self.jsonCategories($0.categories) } ?? .null,
                "autoCompaction": runtime.ompContext.autoCompactionEnabled.map(JSONValue.bool) ?? .null,
                "branchCompactions": Self.jsonNumber(saved?.journal.compactions)],
            "composition": compositionJSON, "latestRequest": requestJSON, "accounting": accountingJSON,
            "captureWarning": .bool(saved?.captureWarning == true), "lastRefreshError": Self.jsonString(state.error)]
        self.capturedAt = capturedAt
        baseFilename = "omp-context-" + Self.timestamp(capturedAt).replacingOccurrences(of: ":", with: "-")
        markdown = lines.joined(separator: "\n") + "\n"
    }

    private static func timestamp(_ date: Date) -> String { date.ISO8601Format() }
    private static func jsonDate(_ date: Date?) -> JSONValue { date.map { .string(timestamp($0)) } ?? .null }
    private static func jsonNumber(_ number: Int?) -> JSONValue { number.map(JSONValue.int) ?? .null }
    private static func jsonString(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }
    private static func jsonCategories(_ rows: [OMPContextCategory]) -> JSONValue {
        .array(rows.map { row in ["kind": .string(row.kind), "tokens": .int(row.tokens),
            "items": .array(row.items.map { ["name": .string($0.name), "tokens": .int($0.tokens)] }),
            "omittedItems": .int(row.omittedItems)] })
    }
    private static func escape(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["|", "`", "*", "_", "[", "]", "$", "#"] {
            text = text.replacingOccurrences(of: character, with: "\\" + character)
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
