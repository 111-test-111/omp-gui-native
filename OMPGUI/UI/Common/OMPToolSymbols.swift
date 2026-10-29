/// One explicit system or custom SF Symbol for each native OMP tool. The exhaustive switch makes
/// adding a known tool without choosing its symbol a compile-time error.
enum OMPToolSymbols {
    static func symbol(for call: ToolCall) -> SFSymbolResource {
        if let tool = call.ompTool { return symbol(for: tool) }
        if call.toolName != nil {
            return call.kind == .mcp ? "powerplug" : "wrench.and.screwdriver"
        }
        return symbol(for: call.kind)
    }

    static func symbol(for kind: ToolCall.Kind) -> SFSymbolResource {
        switch kind {
        case .command: "terminal"
        case .read: "text.menu"
        case .edit: "pencil"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .mcp: "puzzlepiece.extension"
        case .agent: "person.2"
        case .other: "wrench.and.screwdriver"
        }
    }

    static func symbol(for tool: OMPTool) -> SFSymbolResource {
        switch tool {
        case .read: "text.menu"
        case .bash: "terminal"
        case .edit: "highlighter"
        case .astGrep: "point.3.connected.trianglepath.dotted"
        case .astEdit: "point.3.filled.connected.trianglepath.dotted"
        case .ask: "questionmark.message"
        case .debug: "ladybug"
        case .ida: "cpu"
        case .eval: "curlybraces"
        case .github: "point.bottomleft.forward.to.point.topright.scurvepath"
        case .glob: .custom("tool-glob-folder")
        case .grep: "magnifyingglass"
        case .find: .custom("tool-find-folder")
        case .lsp: "chevron.left.forwardslash.chevron.right"
        case .checkpoint: "flag"
        case .rewind: "arrowshape.turn.up.backward.2"
        case .contextNotes: "note.text"
        case .newContext: "arrow.trianglehead.2.clockwise.rotate.90"
        case .securityScan: "viewfinder.trianglebadge.exclamationmark"
        case .task: "person.2"
        case .wait: "timelapse"
        case .todo: "checklist"
        case .webSearch: "safari"
        case .write: "pencil.tip.crop.circle.badge.plus"
        case .memoryEdit: "brain.head.profile"
        case .retain: "tray.and.arrow.down"
        case .recall: "tray.and.arrow.up"
        case .reflect:
            if #available(macOS 27.0, *) { "ring.light" } else { "lightbulb" }
        case .learn: "apple.intelligence"
        case .manageSkill: "books.vertical"
        case .yield: "arrow.turn.up.right"
        case .goal: "target"
        case .think: "brain.head.profile"
        case .advise: "bubble.left.and.bubble.right"
        case .securityPublish: "shield.lefthalf.filled"
        case .generateImage: "photo.badge.plus"
        case .tts: "waveform"
        case .vibeSpawn: "plus.message"
        case .vibeSend: "paperplane"
        case .vibeWait: "clock"
        case .vibeKill: "stop.circle"
        case .vibeList: "list.bullet.rectangle"
        case .proposeCommit: "checkmark.seal"
        case .splitCommit: "arrow.triangle.branch"
        case .gitOverview: "checkmark.rectangle.stack"
        case .analyzeFiles: .custom("tool-analyze-files")
        case .gitFileDiff: "plus.forwardslash.minus"
        case .recentCommits: "clock.badge.checkmark"
        case .proposeChangelog: "text.pad.header"
        case .gitHunk: "square.grid.3x3.square"
        case .createChangelogEntries: "text.badge.plus"
        case .initExperiment: "flask"
        case .runExperiment: "play.rectangle"
        case .logExperiment: "chart.xyaxis.line"
        case .updateNotes: "text.pad.header"
        case .rewrite: "arrow.trianglehead.2.clockwise.rotate.90"
        case .approve: "hand.thumbsup"
        case .recordDeltas: "square.stack.3d.up"
        case .replaceMemoryFiles: "arrow.left.arrow.right.square"
        case .resolve: "checkmark.circle"
        case .reject: "xmark.circle"
        case .propose: "doc.badge.clock"
        case .reportIssue: "exclamationmark.message"
        }
    }
}
