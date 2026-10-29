import Foundation

/// OMP's structured snapshots only. Tool arguments, prose and partial results
/// cannot establish committed state, and malformed snapshots never imply a clear.
enum OMPTodoSnapshot {
    static func decode(_ value: JSONValue?) -> [TodoStep]? {
        guard let phases = value?.array else { return nil }
        var steps: [TodoStep] = []
        for phase in phases {
            guard let name = phase["name"]?.string, let tasks = phase["tasks"]?.array else { return nil }
            for task in tasks {
                guard let text = task["content"]?.string else { return nil }
                let status: TodoStep.Status
                switch task["status"]?.string {
                case "pending": status = .pending
                case "in_progress": status = .active
                case "completed": status = .done
                case "blocked": status = .blocked
                case "abandoned": status = .abandoned
                default: return nil
                }
                steps.append(TodoStep(text: text, status: status, phase: name.isEmpty ? nil : name,
                                      blocker: task["blocker"]?.string))
            }
        }
        return steps
    }

    /// get_subagent_messages exposes complete native entries. Reconstruct the
    /// latest persisted branch by parentId, as OMP does on loading its journal.
    /// Eval's successful mutations are user_todo_edit entries, not todo results.
    static func fromTranscript(_ value: JSONValue?) -> [TodoStep]? {
        snapshot(from: value)?.steps
    }

    static func snapshot(from value: JSONValue?, leafID: JSONValue? = nil) -> TodoSnapshot? {
        guard let entries = value?.array else { return nil }
        var byID: [String: JSONValue] = [:]
        var leaf: String?
        for entry in entries {
            // Header/title slots are file metadata, outside the branch graph.
            if ["session", "title", "session_index"].contains(entry["type"]?.string ?? "") { continue }
            guard let id = entry["id"]?.string, !id.isEmpty, let parent = entry["parentId"],
                  parent == .null || parent.string != nil, byID[id] == nil else { return nil }
            byID[id] = entry
            leaf = id
        }
        if let leafID {
            guard leafID == .null || leafID.string != nil else { return nil }
            leaf = leafID.string
        }
        var seen: Set<String> = []
        var branch: [JSONValue] = []
        while let id = leaf {
            guard seen.insert(id).inserted, let entry = byID[id] else { return nil }
            branch.append(entry)
            leaf = entry["parentId"]?.string
        }
        var current: [TodoStep]?
        for entry in branch {
            var phases: JSONValue?
            var canonical = false
            if entry["type"]?.string == "custom", entry["customType"]?.string == "user_todo_edit" {
                canonical = true
                phases = entry["data"]?["phases"]
            }
            if entry["type"]?.string == "message", let message = entry["message"],
               message["role"]?.string == "toolResult", message["isError"]?.bool != true {
                let raw = message["details"] ?? .null
                if raw["isError"]?.bool == true || raw["xdev"]?["inner"]?["isError"]?.bool == true { continue }
                let isTodo = message["toolName"]?.string == "todo"
                    || (message["toolName"]?.string == "write" && raw["xdev"]?["tool"]?.string == "todo")
                let details = raw["xdev"]?["inner"] ?? raw
                if isTodo, details["op"]?.string != "view" { canonical = true; phases = details["phases"] }
            }
            guard canonical else { continue }
            // An older unrecognized schema cannot invalidate a newer verified
            // clear; it merely prevents recovering a completion from that past.
            guard let steps = decode(phases) else { return current.map { TodoSnapshot(steps: $0) } }
            if current == nil { current = steps }
            if !steps.isEmpty { return TodoSnapshot(steps: current ?? steps, recentList: steps) }
        }
        return TodoSnapshot(steps: current ?? [])
    }
}
