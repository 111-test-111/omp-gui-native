import Foundation

/// A fixed product catalogue. Configuration describes global gates, never live session availability.
enum OMPToolCatalogue {
    enum Group: CaseIterable, Sendable {
        case files, execution, code, web, coordination, context, memory, media, gui, workflows, preludes

        var title: String {
            switch self {
            case .files: "Files and search"
            case .execution: "Execution and debugging"
            case .code: "Code intelligence"
            case .web: "Web and security"
            case .coordination: "Interaction and delegation"
            case .context: "Context management"
            case .memory: "Memory and skills"
            case .media: "Images and speech"
            case .gui: "GUI tools"
            case .workflows: "Specialized workflows"
            case .preludes: "eval capabilities"
            }
        }
    }

    enum Call: Equatable, Sendable {
        case direct, discoverable, device, eval, workflow

        func title(xdev: Bool?) -> String {
            switch self {
            case .direct: "Direct call"
            case .discoverable: xdev.map { $0 ? "xd://" : "Direct call" } ?? "Direct / xd://"
            case .device: "write xd://"
            case .eval: "eval"
            case .workflow: "Workflow call"
            }
        }
    }

    enum Status: Equatable, Sendable {
        case builtIn, enabled, disabled, automatic, conditional, host, unknown

        var compactTitle: String {
            switch self {
            case .enabled: "Enabled"
            case .disabled: "Disabled"
            case .conditional: "On demand"
            case .unknown: "Unknown"
            default: title
            }
        }

        var title: String {
            switch self {
            case .builtIn: "Built-in"
            case .enabled: "Config enabled"
            case .disabled: "Config disabled"
            case .automatic: "Automatic"
            case .conditional: "Conditional"
            case .host: "GUI provided"
            case .unknown: "Config unknown"
            }
        }
    }

    indirect enum Gate: Sendable {
        case builtIn, flag(String), any([Gate]), all([Gate]), find, task, memory, conditional, host

        var keys: [String] {
            switch self {
            case .flag(let key): [key]
            case .any(let gates), .all(let gates): gates.flatMap(\.keys)
            case .find: ["find.enabled"]
            case .task: ["task.maxRecursionDepth"]
            default: []
            }
        }

        var usesGUIMemory: Bool {
            switch self {
            case .memory: true
            case .any(let gates), .all(let gates): gates.contains { $0.usesGUIMemory }
            default: false
            }
        }

        var controls: [Control] {
            switch self {
            case .flag(let key): [.flag(key)]
            case .any(let gates): gates.flatMap(\.controls)
            // The remaining gates are dependencies, not additional switches to mutate.
            case .all(let gates): gates.first?.controls ?? []
            case .find: [.find]
            case .task: [.depth]
            case .memory: [.memory]
            default: []
            }
        }

        func status(_ configuration: Configuration) -> Status {
            switch self {
            case .builtIn: return .builtIn
            case .host: return .host
            case .conditional: return .conditional
            case .memory: return configuration.memoryEnabled ? .enabled : .disabled
            case .flag(let key):
                return configuration.values[key]?.bool.map { $0 ? .enabled : .disabled } ?? .unknown
            case .find:
                switch configuration.values["find.enabled"]?.string {
                case "on": return .enabled
                case "off": return .disabled
                case "auto": return .automatic
                default: return .unknown
                }
            case .task:
                guard let depth = configuration.values["task.maxRecursionDepth"]?.int,
                      depth >= -1 else { return .unknown }
                return depth == 0 ? .disabled : .enabled
            case .any(let gates):
                let states = gates.map { $0.status(configuration) }
                if states.contains(.enabled) { return .enabled }
                return !states.isEmpty && states.allSatisfy { $0 == .disabled } ? .disabled : .unknown
            case .all(let gates):
                let states = gates.map { $0.status(configuration) }
                if states.contains(.disabled) { return .disabled }
                return !states.isEmpty && states.allSatisfy { $0 == .enabled } ? .enabled : .unknown
            }
        }
    }

    struct Configuration: Sendable {
        var values: [String: JSONValue] = [:]
        // GUI sessions deliberately override OMP's external memory backend.
        var memoryEnabled = false
        var xdev: Bool? { values["tools.xdev"]?.bool }
    }

    enum Control: Hashable, Identifiable, Sendable {
        case flag(String), find, depth, memory

        var key: String? {
            switch self {
            case .flag(let key): key
            case .find: "find.enabled"
            case .depth: "task.maxRecursionDepth"
            case .memory: nil
            }
        }

        var id: String { key ?? "gui:memory" }

        var settingsPage: String? {
            switch self {
            case .memory: "Memory"
            case .flag("generate_image.enabled"): "Providers"
            default: nil
            }
        }

        var inlineTitle: String {
            switch self {
            case .flag("eval.js"): "JS"
            case .flag("eval.py"): "Py"
            default: title
            }
        }

        var title: String {
            switch self {
            case .flag("eval.js"): "JavaScript"
            case .flag("eval.py"): "Python"
            case .find: "Search mode"
            case .depth: "Delegation depth"
            case .memory: "Memory tools"
            default: "Tool enabled"
            }
        }

        func accepts(_ value: JSONValue) -> Bool {
            switch (self, value) {
            case (.flag, .bool), (.memory, .bool): true
            case (.find, .string(let value)): ["auto", "on", "off"].contains(value)
            case (.depth, .int(let value)): value >= -1
            default: false
            }
        }

        func value(in configuration: Configuration) -> JSONValue? {
            if self == .memory { return .bool(configuration.memoryEnabled) }
            guard let key, let value = configuration.values[key], accepts(value) else { return nil }
            return value
        }
    }

    struct Entry: Identifiable, Sendable {
        let name: String
        let purpose: String
        let group: Group
        var call: Call = .direct
        var gate: Gate = .conditional
        var condition: String?
        var id: String { (group == .preludes ? "eval:" : "tool:") + name }
        var controls: [Control] { gate.controls }
        var editableControls: [Control] { controls.filter { $0.settingsPage == nil } }

        func statusTitle(_ configuration: Configuration) -> String {
            if case .all(let gates) = gate, gates.first?.status(configuration) == .enabled,
               gates.dropFirst().contains(where: { $0.status(configuration) == .disabled }) {
                return gate.usesGUIMemory ? "Memory disabled" : "eval disabled"
            }
            let status = gate.status(configuration)
            return status == .conditional ? condition ?? status.title : status.title
        }

        func callExample(_ configuration: Configuration) -> String {
            switch call {
            case .device: "read \(name)\nwrite \(name) content={…}"
            case .discoverable where configuration.xdev != false:
                "read xd://\(name)\nwrite xd://\(name) content={…}\ntools.xdev"
            case .eval: "eval → \(name)"
            default: name
            }
        }
    }

    private static let evalGate = Gate.any([.flag("eval.js"), .flag("eval.py")])

    static let entries: [Entry] = OMPTool.allCases.map { tool in
        Entry(name: tool.isActionDevice ? "xd://" + tool.rawValue : tool.rawValue,
              purpose: tool.cataloguePurpose, group: tool.catalogueGroup, call: tool.catalogueCall,
              gate: tool.catalogueGate, condition: tool.catalogueCondition)
    } + [
        Entry(name: "gui_read_selected_context", purpose: "Read shared file context", group: .gui, call: .discoverable, gate: .host),
        Entry(name: "gui_open_file_location", purpose: "Open a file in the preview", group: .gui, call: .discoverable, gate: .host),
        Entry(name: "browser", purpose: "Automate Chromium tabs", group: .preludes, call: .eval,
              gate: .all([.flag("browser.enabled"), evalGate]), condition: "Requires Chromium"),
        Entry(name: "computer", purpose: "Capture and control the desktop", group: .preludes, call: .eval,
              gate: .all([.flag("computer.enabled"), evalGate]), condition: "Desktop permissions"),
        Entry(name: "archive", purpose: "Search local conversation history", group: .preludes, call: .eval,
              gate: .all([.flag("archive.enabled"), evalGate])),
        Entry(name: "ratchet", purpose: "Optimize prompts with evaluation flows", group: .preludes, call: .eval,
              gate: .all([.flag("ratchet.enabled"), evalGate])),
    ]

    /// Retain only tool switches from the public config response, never credentials.
    static let configurationKeys = Array(Set(entries.flatMap { $0.gate.keys } + ["tools.xdev"])).sorted()

    static func members(of control: Control) -> [String] {
        entries.filter { $0.controls.contains(control) }.map(\.name)
    }
}

private extension OMPTool {
    var catalogueCall: OMPToolCatalogue.Call {
        if isActionDevice { return .device }
        switch self {
        case .astGrep, .astEdit, .debug, .ida, .lsp, .github, .checkpoint, .rewind, .securityScan,
             .memoryEdit, .retain, .recall, .reflect, .generateImage, .tts: return .discoverable
        case .securityPublish, .proposeCommit, .splitCommit, .gitOverview, .analyzeFiles, .gitFileDiff,
             .recentCommits, .proposeChangelog, .gitHunk, .createChangelogEntries, .initExperiment,
             .runExperiment, .logExperiment, .updateNotes, .rewrite, .approve, .recordDeltas, .replaceMemoryFiles:
            return .workflow
        default: return .direct
        }
    }

    var catalogueGate: OMPToolCatalogue.Gate {
        switch self {
        case .read, .write, .edit: .builtIn
        case .bash: .flag("bash.enabled")
        case .eval: .any([.flag("eval.js"), .flag("eval.py")])
        case .glob: .flag("glob.enabled")
        case .grep: .flag("grep.enabled")
        case .find: .find
        case .astGrep: .flag("astGrep.enabled")
        case .astEdit: .flag("astEdit.enabled")
        case .debug: .flag("debug.enabled")
        case .ida: .flag("ida.enabled")
        case .lsp: .flag("lsp.enabled")
        case .github: .flag("github.enabled")
        case .webSearch: .flag("web_search.enabled")
        case .securityScan: .flag("security.enabled")
        case .ask: .flag("ask.enabled")
        case .task: .task
        case .todo: .flag("todo.enabled")
        case .advise: .flag("advisor.enabled")
        case .checkpoint, .rewind: .flag("checkpoint.enabled")
        case .contextNotes, .newContext: .flag("compaction.experimentalContextManagement")
        case .goal: .flag("goal.enabled")
        case .think: .flag("externalThinking")
        case .memoryEdit, .retain, .recall, .reflect: .memory
        case .learn: .all([.flag("autolearn.enabled"), .memory])
        case .manageSkill: .flag("autolearn.enabled")
        case .generateImage: .flag("generate_image.enabled")
        case .tts: .flag("speechgen.enabled")
        case .reportIssue: .flag("dev.autoqa")
        default: .conditional
        }
    }

    var catalogueCondition: String? {
        switch self {
        case .debug: "Requires DAP adapter"
        case .ida: "Requires IDA"
        case .lsp: "Requires language server"
        case .github: "Requires GitHub CLI"
        case .find: "Judge model"
        case .think: "Compatible model"
        case .generateImage: "Image provider"
        case .tts: "Speech provider"
        case .goal: "Goal mode"
        case .yield: "Subagent only"
        case .wait: "Background or messaging mode"
        case .advise: "Advisor mode"
        case .vibeSpawn, .vibeSend, .vibeWait, .vibeKill, .vibeList: "Vibe mode"
        case .resolve, .reject: "Staged action"
        case .propose: "Plan mode"
        case .securityPublish: "Security workflow"
        case .proposeCommit, .splitCommit, .gitOverview, .analyzeFiles, .gitFileDiff, .recentCommits,
             .proposeChangelog, .gitHunk, .createChangelogEntries: "Commit workflow"
        case .initExperiment, .runExperiment, .logExperiment, .updateNotes: "Research workflow"
        case .rewrite, .approve: "Context rewrite"
        case .recordDeltas, .replaceMemoryFiles: "Memory consolidation"
        default: nil
        }
    }

    var catalogueGroup: OMPToolCatalogue.Group {
        switch self {
        case .read, .write, .edit, .glob, .grep, .find, .astGrep, .astEdit: .files
        case .bash, .eval, .debug, .ida: .execution
        case .lsp, .github: .code
        case .webSearch, .securityScan, .securityPublish: .web
        case .ask, .task, .wait, .todo, .yield, .advise, .vibeSpawn, .vibeSend, .vibeWait, .vibeKill, .vibeList: .coordination
        case .checkpoint, .rewind, .contextNotes, .newContext, .goal, .think, .resolve, .reject, .propose, .reportIssue: .context
        case .memoryEdit, .retain, .recall, .reflect, .learn, .manageSkill: .memory
        case .generateImage, .tts: .media
        default: .workflows
        }
    }

    var cataloguePurpose: String {
        switch self {
        case .read: "Read files and resources"
        case .write: "Create or overwrite files"
        case .edit: "Edit file contents"
        case .glob: "Find paths by pattern"
        case .grep: "Search file contents"
        case .find: "Search code by meaning"
        case .astGrep: "Search syntax trees"
        case .astEdit: "Edit syntax trees"
        case .bash: "Execute shell commands"
        case .eval: "Run Python or JavaScript"
        case .debug: "Debug programs with DAP"
        case .ida: "Analyze binaries with IDA"
        case .lsp: "Query language servers"
        case .github: "Work with GitHub"
        case .webSearch: "Search the web"
        case .securityScan: "Run security analysis"
        case .securityPublish: "Publish security findings"
        case .ask: "Ask the user a question"
        case .task: "Delegate to subagents"
        case .wait: "Wait for background work"
        case .todo: "Manage task steps"
        case .yield: "Return a subagent result"
        case .advise: "Consult an advisor"
        case .vibeSpawn: "Start a vibe session"
        case .vibeSend: "Send input to a vibe session"
        case .vibeWait: "Wait for a vibe session"
        case .vibeKill: "Stop a vibe session"
        case .vibeList: "List vibe sessions"
        case .checkpoint: "Save a context checkpoint"
        case .rewind: "Restore a context checkpoint"
        case .contextNotes: "Maintain context notes"
        case .newContext: "Start a fresh context"
        case .goal: "Manage goal execution"
        case .think: "Use external thinking"
        case .resolve: "Apply a staged action"
        case .reject: "Discard a staged action"
        case .propose: "Submit a plan for approval"
        case .reportIssue: "Report a tool issue"
        case .memoryEdit: "Edit saved memories"
        case .retain: "Store long-term memories"
        case .recall: "Retrieve long-term memories"
        case .reflect: "Synthesize saved memories"
        case .learn: "Save reusable learning"
        case .manageSkill: "Manage skills"
        case .generateImage: "Generate or edit images"
        case .tts: "Generate speech"
        case .proposeCommit: "Propose a commit"
        case .splitCommit: "Split a proposed commit"
        case .gitOverview: "Inspect Git status"
        case .analyzeFiles: "Analyze changed files"
        case .gitFileDiff: "Inspect a file diff"
        case .recentCommits: "Inspect recent commits"
        case .proposeChangelog: "Propose changelog entries"
        case .gitHunk: "Inspect a diff hunk"
        case .createChangelogEntries: "Generate changelog entries"
        case .initExperiment: "Initialize a research experiment"
        case .runExperiment: "Run a research experiment"
        case .logExperiment: "Record experiment results"
        case .updateNotes: "Update research notes"
        case .rewrite: "Rewrite compressed context"
        case .approve: "Approve a context rewrite"
        case .recordDeltas: "Record memory changes"
        case .replaceMemoryFiles: "Replace consolidated memories"
        }
    }
}
