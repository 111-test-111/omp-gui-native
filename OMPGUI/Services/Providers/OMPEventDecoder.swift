import Foundation

/// Converts OMP's agent events into the existing timeline vocabulary. Each native
/// subagent gets its own decoder; its message IDs, file snapshots and usage never
/// enter the lead's stream.
@MainActor
final class OMPEventDecoder {
    let prefix: String
    var directory: String
    let capturesSnapshots: Bool
    var contextWindow: Int?
    var onEvent: ((ProviderEvent) -> Void)?
    private var currentMessage = ""
    private var tools: [String: (name: String, args: JSONValue, path: String?, isTodo: Bool)] = [:]
    private var snapshots = EditSnapshots()

    init(prefix: String, directory: String, capturesSnapshots: Bool = true) {
        self.prefix = prefix
        self.directory = directory
        self.capturesSnapshots = capturesSnapshots
    }

    /// A native branch changes the conversation behind this process. Cached tool
    /// arguments and file baselines must never leak into the replacement path.
    func resetForSession() {
        currentMessage = ""
        tools.removeAll()
        snapshots = EditSnapshots()
    }

    func handle(_ frame: JSONValue) {
        switch frame["type"]?.string {
        case "message_start":
            if frame["message"]?["role"]?.string == "assistant" {
                currentMessage = frame["messageId"]?.string ?? UUID().uuidString
            }
        case "message_update":
            let event = frame["assistantMessageEvent"] ?? .null
            let messageID = frame["messageId"]?.string ?? currentMessage
            let block = event["contentIndex"]?.int ?? 0
            if event["type"]?.string == "text_delta", let delta = event["delta"]?.string {
                onEvent?(.messageDelta(id: "\(prefix)-m-\(messageID)", text: delta))
            } else if event["type"]?.string == "thinking_delta", let delta = event["delta"]?.string {
                onEvent?(.reasoningDelta(id: "\(prefix)-r-\(messageID)-\(block)", text: delta))
            }
        case "message_end":
            let message = frame["message"] ?? .null
            if message["role"]?.string == "custom", message["customType"]?.string == "async-result",
               message["display"]?.bool != false {
                let text = ToolText.blocks(message["content"])
                if !text.isEmpty {
                    // A native background completion is runtime information,
                    // never an assistant reply that can replace a final answer.
                    onEvent?(.notice(Notice(level: .info, message: text)))
                }
                return
            }
            guard message["role"]?.string == "assistant" else { return }
            let messageID = frame["messageId"]?.string ?? currentMessage
            var text: [String] = []
            for (index, block) in (message["content"]?.array ?? []).enumerated() {
                if block["type"]?.string == "text", let value = block["text"]?.string { text.append(value) }
                if block["type"]?.string == "thinking", let value = block["thinking"]?.string {
                    onEvent?(.reasoningCompleted(id: "\(prefix)-r-\(messageID)-\(index)", text: value))
                }
            }
            if !text.isEmpty { onEvent?(.messageCompleted(id: "\(prefix)-m-\(messageID)", text: text.joined())) }
            let usage = message["usage"] ?? .null
            let input = usage["input"]?.int
            let output = usage["output"]?.int ?? 0
            let read = usage["cacheRead"]?.int
            let write = usage["cacheWrite"]?.int
            // OMP reports three disjoint input buckets. Preserve missing or
            // malformed counts as unknown rather than manufacturing a 0% hit.
            let promptInput: Int? = if let input, let read, let write,
                input >= 0, read >= 0, write >= 0,
                input <= Int.max - read, input + read <= Int.max - write {
                input + read + write
            } else { nil }
            let fallbackTotal = [input, output, read, write].compactMap { $0 }.reduce(Int?.some(0)) { total, count in
                guard let total, count >= 0 else { return nil }
                let sum = total.addingReportingOverflow(count)
                return sum.overflow ? nil : sum.partialValue
            }
            let total = usage["totalTokens"]?.int ?? fallbackTotal ?? 0
            if total > 0 {
                onEvent?(.usage(ContextUsage(usedTokens: total, windowTokens: contextWindow)))
                let model = [message["provider"]?.string, message["model"]?.string].compactMap { $0 }.joined(separator: "/")
                onEvent?(.tokenSpend(TokenSpend(provider: .omp, totalTokens: total, inputTokens: promptInput,
                                               outputTokens: output, cachedInputTokens: read, model: model.nilIfEmpty)))
            }
            if message["stopReason"]?.string == "error", let error = message["errorMessage"]?.string {
                onEvent?(.notice(Notice(level: .error, message: error)))
                if error.contains("code=unsupported_native_inflight_message") {
                    onEvent?(.notice(Notice(level: .warning, message: AppText.localized("OMP's model channel rejected a message during an active response. OMP manages retry and delivery; the original error is retained in this turn."))))
                }
            }
        case "tool_execution_start":
            startTool(frame)
        case "tool_execution_update":
            guard let id = frame["toolCallId"]?.string else { return }
            guard tools[id]?.isTodo != true else { return }
            let result = frame["partialResult"] ?? frame["result"] ?? .null
            let text = ToolText.blocks(result["content"])
            let detail = evalDetail(tools[id], result: result)
            let details = result["details"]?["xdev"]?["inner"] ?? result["details"] ?? .null
            let references = tools[id].flatMap { OMPFileReference.fromResult(toolName: $0.name, details: details) }
            if !text.isEmpty || detail != nil || references != nil {
                onEvent?(.toolUpdated(id: "\(prefix)-\(id)", update: ToolUpdate(detail: detail, output: text.nilIfEmpty,
                            fileReferences: references)))
            }
        case "tool_execution_end":
            finishTool(frame)
        case "auto_compaction_start", "compaction_start":
            onEvent?(.notice(Notice(level: .info, message: AppText.localized("Compacting the conversation…"))))
        case "auto_compaction_end", "compaction_end":
            onEvent?(.contextUsageCleared)
        case "auto_retry_start":
            onEvent?(.notice(Notice(level: .warning, message: frame["errorMessage"]?.string ?? frame["error"]?.string ?? AppText.localized("OMP is retrying."))))
        case "notice":
            if let message = frame["message"]?.string, !message.isEmpty {
                let level = Notice.Level(rawValue: frame["level"]?.string ?? "") ?? .info
                onEvent?(.notice(Notice(level: level, message: message)))
            }
        default: break
        }
    }

    private func startTool(_ frame: JSONValue) {
        guard let id = frame["toolCallId"]?.string, let name = frame["toolName"]?.string else { return }
        let args = frame["args"] ?? .null
        let rawPath = args["path"]?.string ?? args["file_path"]?.string
        let device = name == "write" ? rawPath.flatMap(OMPTool.deviceName) : nil
        let effectiveName = device ?? name
        let nativeTool = OMPTool.named(effectiveName)
        let content = args["content"]?.string
        // OMP uses a JSON argument object for mounted tools; its four action
        // devices accept their own payloads. Empty/?/help requests read docs.
        let isDeviceHelp = device != nil && nativeTool?.isActionDevice != true && content.map {
            ["", "?", "help"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        } == true
        let innerArgs: JSONValue? = if device != nil, nativeTool?.isActionDevice != true,
            let content, let parsed = JSONValue.parse(content), parsed.object != nil { parsed } else { nil }
        let callArgs = innerArgs ?? args
        let subjectPath = callArgs["path"]?.string ?? callArgs["file_path"]?.string
        // The outer xd:// path is a transport address. File snapshots belong
        // to the wrapped edit's file, never to the transport or another tool.
        let filePath = device == nil ? rawPath : innerArgs?["path"]?.string ?? innerArgs?["file_path"]?.string
        let path = filePath.flatMap { value -> String? in
            guard !value.contains("://") else { return nil }
            return value.hasPrefix("/") ? value : URL(fileURLWithPath: directory).appendingPathComponent(value).path
        }
        let isTodo = effectiveName == "todo" && !isDeviceHelp
        tools[id] = (effectiveName, args, path, isTodo)
        // OMP returns the canonical list on completion. Wait for it rather than
        // displaying a second generic tool row or projecting uncommitted args.
        if isTodo { return }
        if capturesSnapshots, !isDeviceHelp, ["write", "edit", "ast_edit"].contains(effectiveName), let path {
            snapshots.capture(id, path: path)
        }
        let kind = isDeviceHelp ? .read : nativeTool?.kind ?? (effectiveName.hasPrefix("mcp__") ? .mcp : .other)
        let title: String
        if effectiveName == "bash", !isDeviceHelp { title = ToolTitles.unwrapShell(callArgs["command"]?.string ?? effectiveName) }
        else if effectiveName == "task", !isDeviceHelp { title = callArgs["i"]?.string?.nilIfEmpty ?? effectiveName }
        else if effectiveName == "eval", !isDeviceHelp { title = callArgs["title"]?.string?.nilIfEmpty ?? effectiveName }
        else if let subjectPath { title = ToolTitles.relativePath(subjectPath, to: directory) }
        else { title = callArgs["pattern"]?.string ?? effectiveName }
        let detail = device == nil && effectiveName != "eval" && (kind == .command || kind == .read || kind == .edit) ? nil : args.prettyString
        let references = isDeviceHelp ? nil : OMPFileReference.initialReferences(toolName: name, args: args, directory: directory)
        onEvent?(.toolStarted(id: "\(prefix)-\(id)", call: ToolCall(kind: kind, title: title, detail: detail,
                    toolName: name, toolDevice: device,
                    fileReference: references?.count == 1 ? references?.first : nil, fileReferences: references)))
    }

    private func finishTool(_ frame: JSONValue) {
        guard let id = frame["toolCallId"]?.string else { return }
        let result = frame["result"] ?? .null
        let output = ToolText.blocks(result["content"])
        let rawDetails = result["details"] ?? .null
        let details = rawDetails["xdev"]?["inner"] ?? rawDetails
        let failed = frame["isError"]?.bool == true || result["isError"]?.bool == true
            || rawDetails["isError"]?.bool == true || details["isError"]?.bool == true
        let tool = tools.removeValue(forKey: id)
        if tool?.isTodo == true || (tool == nil && frame["toolName"]?.string == "todo") {
            if !failed, let steps = OMPTodoSnapshot.decode(details["phases"]) {
                onEvent?(.todos(steps))
                return
            }
            // Failed calls and unknown result schemas retain the usual inspector.
            let rawPath = tool?.args["path"]?.string ?? tool?.args["file_path"]?.string
            let device = rawPath.flatMap(OMPTool.deviceName)
            onEvent?(.toolStarted(id: "\(prefix)-\(id)", call: ToolCall(kind: .other, title: "todo", detail: tool?.args.prettyString,
                        toolName: frame["toolName"]?.string ?? (device == nil ? "todo" : "write"), toolDevice: device)))
        }
        var edits: [FileEdit]?
        if let tool, ["edit", "write", "ast_edit", "resolve"].contains(tool.name) {
            let rows = details["perFileResults"]?.array ?? [details]
            let native = rows.compactMap { row -> FileEdit? in
                let path = row["path"]?.string ?? row["resolvedPath"]?.string ?? tool.path
                guard let path, !path.contains("://") else { return nil }
                let relative = ToolTitles.relativePath(path, to: directory)
                if let old = row["oldText"]?.string, let new = row["newText"]?.string {
                    return FileEdit(path: relative, old: old, new: new)
                }
                if let diff = row["diff"]?.string, !diff.isEmpty {
                    let stats = ToolTitles.diffStats(diff)
                    return FileEdit(path: relative, diff: diff, additions: stats.additions, deletions: stats.deletions)
                }
                return nil
            }
            if !native.isEmpty { edits = native; snapshots.discard(id) }
            else if let snapshot = details["ompGUI"]?["fileSnapshot"], snapshot["version"]?.int == 1,
                    let path = snapshot["path"]?.string, path.hasPrefix("/"), !path.contains("://"), !failed {
                // Captured by OMP's awaited hooks, so even a queued start/end pair
                // retains this call's original bytes after subsequent writes.
                let relative = ToolTitles.relativePath(path, to: directory)
                if let old = snapshot["oldText"]?.string, let new = snapshot["newText"]?.string {
                    edits = [FileEdit(path: relative, old: old, new: new)]
                } else {
                    edits = [FileEdit(path: relative)]
                }
                snapshots.discard(id)
            } else if capturesSnapshots, let path = tool.path {
                edits = snapshots.finish(id, path: path, relativeTo: directory)
            } else if let path = details["resolvedPath"]?.string ?? tool.path, !path.contains("://") {
                // Isolated worktrees can disappear before the host reads this frame.
                // A path without a native diff is safer than comparing the lead's file.
                edits = [FileEdit(path: ToolTitles.relativePath(path, to: directory))]
            }
        }
        onEvent?(.toolUpdated(id: "\(prefix)-\(id)", update: ToolUpdate(detail: evalDetail(tool, result: result), output: output.nilIfEmpty,
                    status: failed ? .failed : .completed, exitCode: details["exitCode"]?.int, edits: edits,
                    fileReferences: tool.flatMap { OMPFileReference.fromResult(toolName: $0.name, details: details) },
                    nativeBackgroundJobID: details["async"]?["state"]?.string == "running" ? details["async"]?["jobId"]?.string : nil)))
    }

    private func evalDetail(_ tool: (name: String, args: JSONValue, path: String?, isTodo: Bool)?, result: JSONValue) -> String? {
        guard let tool, tool.name == "eval" else { return nil }
        let raw = result["details"] ?? .null
        let details = raw["xdev"]?["inner"] ?? raw
        // Keep native structured diagnostics, including caught nested failures.
        // Image bytes stay in OMP's result; never duplicate them into text detail.
        var visible: [String: JSONValue] = [:]
        for key in ["cells", "statusEvents", "jsonOutputs", "notice", "async", "isError", "meta"] {
            if let value = details[key], !value.isNull { visible[key] = value }
        }
        return visible.isEmpty ? tool.args.prettyString : tool.args.prettyString + "\n\n" + JSONValue.object(visible).prettyString
    }
}

/// File previews preserve OMP's source directory at the time of the call. Device
/// transport URLs never refer to local files; only a file device's inner JSON
/// arguments can supply one. Shared by the live decoder and session restoration.
enum OMPFileReference {
    private static func fileArguments(toolName: String, args: JSONValue) -> (name: String, args: JSONValue)? {
        let rawPath = args["path"]?.string ?? args["file_path"]?.string
        let device = toolName == "write" ? rawPath.flatMap(OMPTool.deviceName) : nil
        let name = device ?? toolName
        guard ["read", "write", "edit", "ast_edit", "resolve"].contains(name) else { return nil }
        if device != nil {
            guard let content = args["content"]?.string,
                  let inner = JSONValue.parse(content), inner.object != nil else { return nil }
            return (name, inner)
        } else {
            return (name, args)
        }
    }

    static func argumentSignature(toolName: String, args: JSONValue) -> String? {
        guard let file = fileArguments(toolName: toolName, args: args),
              let path = file.args["path"]?.string ?? file.args["file_path"]?.string else { return nil }
        return file.name + "\0" + path + "\0" + (file.args["offset"]?.int.map(String.init) ?? "")
    }

    static func initialReferences(toolName: String, args: JSONValue, directory: String?) -> [FilePreviewReference]? {
        guard let file = fileArguments(toolName: toolName, args: args) else { return nil }
        guard let reference = decode(toolName: toolName, args: args, directory: directory) else { return [] }
        // OMP prefers literal filenames before recovering selectors and grouped
        // paths. Wait for its result instead of guessing which interpretation won.
        if file.name == "read", reference.path.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            || reference.path.contains(":") || reference.path.contains(";") || reference.path.contains(",") {
            return []
        }
        return [reference]
    }

    static func fromResult(toolName: String, details: JSONValue) -> [FilePreviewReference]? {
        guard ["read", "write", "edit", "ast_edit", "resolve"].contains(toolName) else { return nil }
        if let links = details["displayReadTargetLinks"]?.array {
            var seen: Set<String> = []
            return links.compactMap { link in
                guard let path = link.string,
                      let reference = decode(toolName: "read", args: .object(["path": .string(path)]), directory: nil),
                      seen.insert(reference.path).inserted else { return nil }
                return reference
            }
        }
        let source = details["meta"]?["source"]
        let raw = details["resolvedPath"]?.string
            ?? (source?["type"]?.string == "path" ? source?["value"]?.string : nil)
        if let raw {
            guard var reference = decode(toolName: "read", args: .object(["path": .string(raw)]), directory: nil) else { return [] }
            reference.line = (details["displayContent"]?["startLine"]?.int).flatMap { $0 > 0 ? $0 : nil }
            return [reference]
        }
        if details["displayReadTargets"]?.array != nil { return [] }
        return nil
    }

    static func decode(toolName: String, args: JSONValue, directory: String?) -> FilePreviewReference? {
        guard let file = fileArguments(toolName: toolName, args: args) else { return nil }
        let (name, fileArgs) = file
        guard let raw = fileArgs["path"]?.string ?? fileArgs["file_path"]?.string,
              !raw.isEmpty, !raw.contains("\0") else { return nil }
        let path: String
        if raw.lowercased().hasPrefix("file://") {
            guard let url = URL(string: raw), url.isFileURL,
                  url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else { return nil }
            path = url.path
        } else if raw.contains("://") {
            return nil
        } else if raw.hasPrefix("/") {
            path = raw
        } else if raw.hasPrefix("~/") {
            path = (raw as NSString).expandingTildeInPath
        } else if let directory, directory.hasPrefix("/") {
            path = URL(fileURLWithPath: directory).appendingPathComponent(raw).path
        } else {
            return nil
        }
        guard path.hasPrefix("/"), !path.isEmpty else { return nil }
        // Older native read arguments used a one-based offset. Never turn it into a
        // negative jump or parse a line suffix from a literal filename.
        let line = name == "read" ? (fileArgs["offset"]?.int).flatMap { $0 > 0 ? $0 : nil } : nil
        return FilePreviewReference(path: URL(fileURLWithPath: path).standardizedFileURL.path, line: line)
    }
}
