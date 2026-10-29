import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A worker is observed through its owner's progress and durable journal. It has
/// no independent GUI RPC connection or session-management controls.
struct OMPAgentContextPanel: View {
    let runtime: ThreadRuntime
    @State private var refreshing = false
    @State private var error: String?

    var body: some View {
        let usage = runtime.displayedContextUsage
        let window = usage?.windowTokens ?? runtime.nativeAgentContextWindow
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Context window")
                Spacer(minLength: 8)
                Button { Task { await refresh() } } label: {
                    if refreshing {
                        ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                    } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.glass)
                .help("Refresh saved subagent context")
                .accessibilityLabel(Text("Refresh saved subagent context"))
                .disabled(refreshing || !runtime.canInspectOMPContext)
            }
            HStack {
                if let usage, let fraction = usage.fraction, let window {
                    Text(verbatim: "\(UsagePanel.tokens(usage.usedTokens)) / \(UsagePanel.tokens(window)) (\(fraction.formatted(.percent.precision(.fractionLength(0)))))")
                } else if let usage {
                    Text(verbatim: String(format: Chrome.localized("%@ / Unknown"), UsagePanel.tokens(usage.usedTokens)))
                } else if let window {
                    Text(verbatim: String(format: Chrome.localized("Unknown / %@"), UsagePanel.tokens(window)))
                } else { Text("Unknown") }
                Spacer(minLength: 0)
            }
            .monospacedDigit()
            if let fraction = usage?.fraction {
                UsageBar(fraction: min(fraction, 1), tint: Chrome.accent, label: "Context window")
            }
            Text("Context usage comes from OMP's latest reported response. Pending messages and tool results may not be included.")
                .font(.ui(.subheadline))
                .fixedSize(horizontal: false, vertical: true)
            Text("OMP manages this subagent's compaction and handoff.")
                .font(.ui(.subheadline))
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(verbatim: error)
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.danger)
                    .textSelection(.enabled)
            }
        }
        .font(.ui(.body))
        .foregroundStyle(Chrome.secondaryText)
        .task(id: runtime.threadID) { await refresh() }
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        error = nil
        do { try await runtime.refreshOMPContext() }
        catch is CancellationError where Task.isCancelled { }
        catch { self.error = error.localizedDescription }
    }
}

/// Saved context is available before a native connection finishes refreshing.
/// Cold conversations resume without sending a message or reviving workers.
struct OMPContextPanel: View {
    let runtime: ThreadRuntime
    @State private var instructions = ""
    @State private var working = false
    @State private var refreshing = false
    @State private var error: String?
    @State private var message: String?
    @State private var savedPath: String?
    @State private var showsStats = false
    @State private var showsSummary = false
    @State private var showsHandoff = false

    private var snapshot: OMPContextSnapshot { runtime.ompContext }
    private var connected: Bool { runtime.ompActivity?.connected == true && runtime.ompActivity?.stopped != true }
    private var busy: Bool { working || snapshot.pendingCommand != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            occupancy
            if runtime.ompContextIsCached {
                note("Showing the last saved native context snapshot.")
            }
            HStack {
                Text("Context management")
                    .font(.ui(.body, weight: .semibold))
                Spacer(minLength: 8)
                Button { Task { await refresh() } } label: {
                    if refreshing {
                        ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.glass)
                .help("Refresh native context and statistics")
                .accessibilityLabel(Text("Refresh native context and statistics"))
                .disabled(!runtime.canInspectOMPContext || refreshing || busy)
            }

            autoCompaction
            compactionStatus

            if connected && !runtime.canManageContext && !busy && snapshot.isCompacting != true {
                note("Context actions are available when OMP has finished its current work.")
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Compaction and handoff instructions")
                    .font(.ui(.callout))
                TextEditor(text: $instructions)
                    .font(.ui(.body))
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .frame(minHeight: 64, maxHeight: 96)
                    .chromeGlassInputSurface()
                    .accessibilityLabel(Text("Compaction and handoff instructions"))
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { contextButtons }.buttonStyle(.glass)
                VStack(alignment: .leading, spacing: 8) { contextButtons }.buttonStyle(.glass)
            }
            handoffStatus

            if let error, error != snapshot.handoffError {
                Text(verbatim: error)
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.danger)
                    .textSelection(.enabled)
            }
            if let message {
                Text(verbatim: message)
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
            }
            if let savedPath {
                Button("Reveal file") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: savedPath)])
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(Text(verbatim: savedPath))
            }

            DisclosureGroup(isExpanded: $showsStats) {
                VStack(alignment: .leading, spacing: 8) {
                    stat("Input tokens", snapshot.stats?.inputTokens)
                    stat("Output tokens", snapshot.stats?.outputTokens)
                    stat("Reasoning tokens", snapshot.stats?.reasoningTokens)
                    stat("Cache read tokens", snapshot.stats?.cacheReadTokens)
                    stat("Cache write tokens", snapshot.stats?.cacheWriteTokens)
                    stat("Total tokens", snapshot.stats?.totalTokens)
                    stat("User messages", snapshot.stats?.userMessages)
                    stat("Assistant messages", snapshot.stats?.assistantMessages)
                    stat("Tool calls", snapshot.stats?.toolCalls)
                    HStack {
                        Text("Reported cost (USD)")
                        Spacer(minLength: 8)
                        if let cost = snapshot.stats?.cost {
                            Text(verbatim: cost.formatted(.currency(code: "USD").precision(.fractionLength(4))))
                                .monospacedDigit()
                        } else { Text("Unknown") }
                    }
                    note("Missing native statistics are unknown.")
                }
                .font(.ui(.callout))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.top, 8)
            } label: {
                Text("Native session statistics")
                    .font(.ui(.callout))
            }
        }
        .foregroundStyle(Chrome.primaryText)
        .task(id: runtime.threadID) {
            guard runtime.canInspectOMPContext else { return }
            await refresh(ifNeeded: true)
        }
    }

    private var occupancy: some View {
        let usage = snapshot.usedTokens.map { ContextUsage(usedTokens: $0, windowTokens: snapshot.windowTokens) }
            ?? runtime.displayedContextUsage
        return VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Context window")
                Spacer(minLength: 8)
                if let usage, let window = usage.windowTokens, window > 0,
                   let fraction = usage.fraction {
                    Text(verbatim: "\(UsagePanel.tokens(usage.usedTokens)) / \(UsagePanel.tokens(window)) (\(fraction.formatted(.percent.precision(.fractionLength(0)))))")
                        .monospacedDigit()
                } else { Text("Unknown") }
            }
            .font(.ui(.body))
            .foregroundStyle(Chrome.secondaryText)
            if let fraction = usage?.fraction {
                UsageBar(fraction: min(fraction, 1), tint: Chrome.accent, label: "Context window")
            }
        }
    }

    private var autoCompaction: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Automatic compaction")
                    .font(.ui(.body))
                Spacer(minLength: 8)
                if let enabled = snapshot.autoCompactionEnabled {
                    Toggle("Automatic compaction", isOn: Binding(get: { enabled }, set: { enabled in
                        perform { try await runtime.setAutoCompaction(enabled) }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(disabled("set_auto_compaction"))
                } else {
                    Menu {
                        Button("Enable") { perform { try await runtime.setAutoCompaction(true) } }
                        Button("Disable") { perform { try await runtime.setAutoCompaction(false) } }
                    } label: { Text("Unknown") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 4).chromeGlassCapsule()
                    .disabled(disabled("set_auto_compaction"))
                    .accessibilityLabel(Text("Automatic compaction"))
                    .accessibilityValue(Text("Unknown"))
                }
            }
            if runtime.ompCapabilities["set_auto_compaction"] == .unsupported {
                note("This OMP process does not support automatic compaction controls.")
            }
        }
    }

    @ViewBuilder private var compactionStatus: some View {
        if snapshot.isCompacting == true || snapshot.pendingCommand == "compact" || snapshot.pendingCommand == "handoff" {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: Chrome.localized(snapshot.pendingCommand == "handoff" ? "Creating handoff…" : "Compacting context…"))
                    .font(.ui(.callout))
            }
        }
        if let reason = snapshot.compactionReason {
            HStack {
                Text("Compaction trigger")
                Spacer(minLength: 8)
                Text(verbatim: Chrome.localized(reasonTitle(reason)))
            }
            .font(.ui(.callout))
            .foregroundStyle(Chrome.secondaryText)
        }
        if let action = snapshot.compactionAction {
            HStack {
                Text("Compaction method")
                Spacer(minLength: 8)
                Text(verbatim: action)
            }
            .font(.ui(.callout))
            .foregroundStyle(Chrome.secondaryText)
        }
        if snapshot.outcomeUnknown {
            note("OMP has not confirmed the context action. Its outcome is unknown; do not repeat it while confirmation is pending.")
        } else if let outcome = snapshot.lastOutcome {
            Text(verbatim: outcomeText(outcome))
                .font(.ui(.callout))
                .lineLimit(outcome == .completed ? 1 : nil)
                .minimumScaleFactor(0.75)
                .foregroundStyle(outcome == .failed ? Chrome.danger : Chrome.secondaryText)
        }
        if let detail = snapshot.compactionError {
            Text(verbatim: detail).font(.ui(.callout)).foregroundStyle(Chrome.danger)
        }
        if let result = snapshot.lastResult {
            DisclosureGroup(isExpanded: $showsSummary) {
                ScrollView {
                    Text(verbatim: result.summary)
                        .font(.ui(.callout))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            } label: {
                Text("Compaction summary").font(.ui(.callout))
            }
        }
    }

    @ViewBuilder private var handoffStatus: some View {
        if let detail = snapshot.handoffError {
            Text(verbatim: detail)
                .font(.ui(.callout))
                .foregroundStyle(Chrome.danger)
                .textSelection(.enabled)
        }
        if let result = snapshot.lastHandoff {
            if result.completed {
                note("Handoff completed. Saved in this session.")
                if let document = result.document {
                    DisclosureGroup(isExpanded: $showsHandoff) {
                        ScrollView {
                            Text(verbatim: document)
                                .font(.ui(.callout))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
                    } label: {
                        Text("Handoff document").font(.ui(.callout))
                    }
                    HStack(spacing: 8) {
                        Button("Copy handoff") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(document, forType: .string)
                        }
                        Button("Save handoff…") { chooseHandoffSave(document) }
                    }
                    .buttonStyle(.glass)
                } else {
                    note("Refresh to load the handoff document from native session history.")
                }
                if let path = result.savedPath {
                    Text(verbatim: path)
                        .font(.ui(.caption))
                        .foregroundStyle(Chrome.secondaryText)
                        .textSelection(.enabled)
                    Button("Reveal file") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(.glass)
                }
            } else {
                note("OMP did not create a handoff.")
            }
        }
    }

    @ViewBuilder private var contextButtons: some View {
        Button("Compact now") {
            perform {
                try await runtime.compactContext(customInstructions: instructions)
            }
        }
        .disabled(disabled("compact"))
        .help(actionHelp("compact"))
        Button("Create handoff") {
            perform {
                _ = try await runtime.handoffContext(customInstructions: instructions)
            }
        }
        .disabled(disabled("handoff"))
        .help(actionHelp("handoff"))
        Button("Export HTML…") { chooseExport() }
            .disabled(disabled("export_html"))
            .help(actionHelp("export_html"))
    }

    private func stat(_ title: String, _ count: Int?) -> some View {
        HStack {
            Text(verbatim: Chrome.localized(title))
            Spacer(minLength: 8)
            if let count { Text(verbatim: count.formatted()).monospacedDigit() }
            else { Text("Unknown") }
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: Chrome.localized(text))
            .font(.ui(.subheadline))
            .foregroundStyle(Chrome.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func disabled(_ command: String) -> Bool {
        busy || !runtime.canManageContext || runtime.ompCapabilities[command] == .unsupported
    }

    private func actionHelp(_ command: String) -> String {
        Chrome.localized(runtime.ompCapabilities[command] == .unsupported
                         ? "This OMP process does not support this context action."
                         : "Use OMP's native context action")
    }

    private func outcomeText(_ outcome: OMPContextSnapshot.Outcome) -> String {
        switch outcome {
        case .completed:
            return String(format: Chrome.localized("Context compaction completed: before %@ tokens → after %@ tokens"),
                          snapshot.lastResult?.tokensBefore.map(UsagePanel.tokens) ?? Chrome.localized("Unknown"),
                          snapshot.tokensAfterCompaction.map(UsagePanel.tokens) ?? Chrome.localized("Unknown"))
        case .aborted: return Chrome.localized("Context compaction was cancelled.")
        case .skipped: return Chrome.localized("OMP skipped context compaction.")
        case .failed: return Chrome.localized("Context compaction failed.")
        case .retrying: return Chrome.localized("OMP will retry after compaction.")
        }
    }

    private func reasonTitle(_ reason: String) -> String {
        switch reason {
        case "threshold": "Context threshold reached"
        case "overflow": "Context limit exceeded"
        case "idle": "Session idle"
        case "incomplete": "Incomplete response"
        default: reason
        }
    }

    /// A refresh only reads native state. It leaves the mutation controls' enabled
    /// appearance alone while new values arrive in the fixed popover viewport.
    private func refresh(ifNeeded: Bool = false) async {
        guard !refreshing, !busy else { return }
        refreshing = true
        defer { refreshing = false }
        error = nil
        do { try await runtime.refreshOMPContext(ifNeeded: ifNeeded) }
        catch is CancellationError where Task.isCancelled { }
        catch { self.error = error.localizedDescription }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        error = nil
        message = nil
        savedPath = nil
        Task {
            defer { working = false }
            do { try await action() }
            catch { if !snapshot.outcomeUnknown { self.error = error.localizedDescription } }
        }
    }

    private func chooseHandoffSave(_ document: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "handoff.md"
        panel.canCreateDirectories = true
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try document.write(to: url, atomically: true, encoding: .utf8)
                savedPath = url.path
                message = Chrome.localized("Handoff saved.")
                error = nil
            } catch { self.error = error.localizedDescription }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func chooseExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "omp-session.html"
        panel.canCreateDirectories = true
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            perform {
                savedPath = try await runtime.exportContextHTML(to: url.path)
                message = Chrome.localized("Session exported.")
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
