import Foundation

/// Exact native OMP identifiers, including settings-gated tools and xd:// devices.
/// Keep in sync with OMP's tools/builtin-names.ts and SDK-owned tool registrations.
enum OMPTool: String, CaseIterable, Sendable {
    case read
    case bash
    case edit
    case astGrep = "ast_grep"
    case astEdit = "ast_edit"
    case ask
    case debug
    case ida
    case eval
    case github
    case glob
    case grep
    case find
    case lsp
    case checkpoint
    case rewind
    case contextNotes = "context_notes"
    case newContext = "new_context"
    case securityScan = "security_scan"
    case task
    case wait
    case todo
    case webSearch = "web_search"
    case write
    case memoryEdit = "memory_edit"
    case retain
    case recall
    case reflect
    case learn
    case manageSkill = "manage_skill"

    // OMP's hidden, conditionally exposed tools.
    case yield
    case goal
    case think

    // Additional native registrations outside BUILTIN_TOOL_NAMES.
    case advise
    case securityPublish = "security_publish"
    case generateImage = "generate_image"
    case tts
    case vibeSpawn = "vibe_spawn"
    case vibeSend = "vibe_send"
    case vibeWait = "vibe_wait"
    case vibeKill = "vibe_kill"
    case vibeList = "vibe_list"

    // Tool sets owned by OMP's native commit, research and context commands.
    case proposeCommit = "propose_commit"
    case splitCommit = "split_commit"
    case gitOverview = "git_overview"
    case analyzeFiles = "analyze_files"
    case gitFileDiff = "git_file_diff"
    case recentCommits = "recent_commits"
    case proposeChangelog = "propose_changelog"
    case gitHunk = "git_hunk"
    case createChangelogEntries = "create_changelog_entries"
    case initExperiment = "init_experiment"
    case runExperiment = "run_experiment"
    case logExperiment = "log_experiment"
    case updateNotes = "update_notes"
    case rewrite
    case approve
    case recordDeltas = "record_deltas"
    case replaceMemoryFiles = "replace_memory_files"

    // Native actions invoked by writing to an xd:// device.
    case resolve
    case reject
    case propose
    case reportIssue = "report_issue"

    static func named(_ name: String) -> Self? {
        // This is OMP's documented exact legacy alias, not a name heuristic.
        name == "search" ? .grep : Self(rawValue: name)
    }

    static func deviceName(in path: String) -> String? {
        // Match OMP's parseXdUrl: the scheme is case-insensitive; the complete
        // device ID is case-sensitive. Topic URLs are documentation, not calls.
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.prefix(5).lowercased() == "xd://" else { return nil }
        let name = String(path.dropFirst(5))
        guard !name.isEmpty, name.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#")) == nil else { return nil }
        return name
    }

    var isActionDevice: Bool {
        switch self {
        case .resolve, .reject, .propose, .reportIssue: true
        default: false
        }
    }

    var kind: ToolCall.Kind {
        switch self {
        case .bash, .eval: .command
        case .read: .read
        case .write, .edit, .astEdit: .edit
        case .grep, .glob, .find, .astGrep: .search
        case .webSearch: .web
        case .task: .agent
        default: .other
        }
    }
}
