import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContextWorkspacePane: View {
    let runtime: ThreadRuntime
    let previews: FilePreviewStore
    let session: PreviewSession
    /// Offscreen layout verification can supply native facts without a process.
    var inspectionOverride: OMPContextLiveInspection? = nil
    @State private var showsMeasurementInfo = false
    @State private var reportError: String?
    private var state: ContextWorkspaceStore { session.contextInspection }
    private var contextValues: ContextWorkspaceOccupancy {
        .init(runtime: runtime, state: state, live: inspectionOverride)
    }
    private var live: OMPContextLiveInspection? { contextValues.live }
    private var presented: Bool {
        previews.isVisible && previews.isWindowPresented && previews.isWorkspacePresented
            && previews.activeSidebarTab == .panel(.context)
    }
    private var used: Int? { contextValues.used }
    private var window: Int? { contextValues.window }
    private var composition: OMPContextComposition? {
        state.saved?.request?.metadata.composition ?? live?.composition
    }
    private var usesRequestComposition: Bool { state.saved?.request?.metadata.composition != nil }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar
                ScrollView {
                    VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
                        occupancy(wide: geometry.size.width >= 700)
                        if let error = state.error {
                            Text(verbatim: error).foregroundStyle(Chrome.danger).textSelection(.enabled)
                        }
                        if runtime.thread?.providerSessionID == nil && runtime.activeOMPSession == nil {
                            note("Send a message to begin recording context data.")
                        }
                        if let composition { compositionSection(composition, wide: geometry.size.width >= 700) }
                        else { note("Detailed composition is available for requests recorded with the context inspector.") }
                        if geometry.size.width >= 700 {
                            HStack(alignment: .top, spacing: 28) {
                                latestRequest.frame(maxWidth: .infinity, alignment: .topLeading)
                                accounting.frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        } else {
                            latestRequest
                            accounting
                        }
                    }
                    .padding(Chrome.contentHorizontalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .usageReveal(trigger: session.key, active: presented, style: .fade)
                }
            }
        }
        .font(.ui(.callout))
        .foregroundStyle(Chrome.primaryText)
        .onChange(of: presented, initial: true) { _, visible in
            if visible { state.present(runtime) } else { state.suspend() }
            if !visible { showsMeasurementInfo = false }
        }
        .onChange(of: runtime.thread?.providerSessionID) { _, _ in state.refresh(.initial) }
        .onChange(of: runtime.isRunning || runtime.hasNativeWork) { _, _ in state.updateActivity() }
        .onChange(of: runtime.thread?.isArchived) { _, _ in state.updateActivity() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if presented { state.refresh() }
        }
        .onDisappear { state.suspend() }
        .accessibilityLabel(Text("Context inspector"))
        .alert("Context report", isPresented: Binding(get: { reportError != nil }, set: { if !$0 { reportError = nil } })) {
            Button("OK", role: .cancel) { reportError = nil }
        } message: { Text(verbatim: reportError ?? "") }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            ChromeCapsule {
                ChromeIconButton(symbol: "info.circle", isActive: showsMeasurementInfo,
                    help: "How these values are measured") { showsMeasurementInfo.toggle() }
                    .chromePopover(isPresented: $showsMeasurementInfo, arrowEdge: .bottom) {
                        measurementNotes
                    }
                ChromeIconButton(symbol: "doc.on.doc", help: "Copy context report as Markdown") { copyReport() }
                ChromeMenuButton(symbol: "square.and.arrow.up", help: "Export context report") {
                    ForEach(ContextReportFormat.allCases, id: \.self) { format in
                        PopoverItem(format.title, symbol: format == .markdown ? "doc.text" : "curlybraces") { exportReport(format) }
                    }
                }
                ChromeIconButton(symbol: "arrow.clockwise", isEnabled: !state.isManuallyRefreshing,
                    help: "Refresh context inspector") { state.refresh(.manual) }
            }
        }
        .padding(Chrome.workspaceToolbarInsets)
        .accessibilityIdentifier("context-inspector.toolbar")
    }

    private func occupancy(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
            heading("Current context")
            if wide {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        capacity
                        if live != nil { contextFacts }
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 10) {
                        if live == nil { contextFacts } else { nativeBreakdown }
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                capacity
                nativeBreakdown
                contextFacts
            }
        }
    }

    private var capacity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ContextMetricValue(value: number(used)).font(.ui(.title2, weight: .medium))
                Text(verbatim: "/ " + number(window)).foregroundStyle(Chrome.secondaryText)
                Spacer(minLength: 0)
                if let used, let window, window > 0 {
                    Text(verbatim: (Double(used) / Double(window)).formatted(.percent.precision(.fractionLength(1))))
                        .foregroundStyle(Chrome.secondaryText)
                }
            }.monospacedDigit().textSelection(.enabled)
            if let used, let window, window > 0 {
                UsageBar(fraction: min(1, Double(used) / Double(window)), tint: Chrome.accent, label: "Context window")
                metric("Remaining capacity", number(max(0, window - used)))
            }
            if let live {
                note(live.anchored ? "OMP estimate based on provider usage and local context changes."
                    : "OMP local estimate; no provider usage anchor is available yet.")
                metric("Context observed at", live.timestamp.formatted(date: .omitted, time: .standard))
            } else if contextValues.usesSavedResponse || runtime.thread?.hydra?.kind == .native || runtime.thread?.isArchived == true {
                note("Showing the latest saved response. Pending input and tool results may be absent.")
            } else {
                note("Detailed live breakdown requires OMP's public SDK context interface.")
                if runtime.ompContextIsCached { note("Showing the last saved native context snapshot.") }
            }
        }
    }

    private var contextFacts: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let model = contextValues.model {
                metric("Model", model)
            }
            metric("Automatic compaction", runtime.ompContext.autoCompactionEnabled.map { Chrome.localized($0 ? "Enabled" : "Disabled") } ?? "—")
            metric("Compactions on this branch", number(state.saved?.journal.compactions))
        }
    }

    @ViewBuilder private var nativeBreakdown: some View {
        if let live {
            categoryTable(live.categories, total: OMPInspectionNumber.sum(live.categories.map { $0.tokens }) ?? 0, prefix: "native")
        }
    }

    private func compositionSection(_ composition: OMPContextComposition, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Context composition · estimate")
            metric(usesRequestComposition ? "Latest observed request" : "Current session projection", "≈" + number(composition.total))
            if usesRequestComposition, let request = state.saved?.request {
                Text(verbatim: request.record.timestamp?.formatted(date: .abbreviated, time: .standard) ?? "—")
                    .foregroundStyle(Chrome.secondaryText)
                if let model = request.record.model { metric("Request model", model) }
            }
            note(usesRequestComposition
                ? "Measured from the transformed SDK request before provider serialization."
                : "Estimated from OMP's current session projection; request hooks may change it.")
            compositionBar(composition)
            let instructions = composition.categories.filter { ["system", "projectContext", "skills", "toolSchemas"].contains($0.kind) }
            let conversation = composition.categories.filter { !["system", "projectContext", "skills", "toolSchemas"].contains($0.kind) }
            if wide {
                HStack(alignment: .top, spacing: 28) {
                    categoryGroup("Instructions and tools", rows: instructions, total: composition.total)
                    categoryGroup("Conversation content", rows: conversation, total: composition.total)
                }
            } else {
                categoryGroup("Instructions and tools", rows: instructions, total: composition.total)
                categoryGroup("Conversation content", rows: conversation, total: composition.total)
            }
            if composition.limited { note("Composition reached its display budget. The estimate covers only the inspected portion.") }
        }
    }

    private var latestRequest: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Latest request · reported usage")
            if let request = state.saved?.request {
                metric("Status", Chrome.localized(request.record.status?.title ?? "Unknown"))
                metric("Reported input", number(request.metadata.reportedInput))
                metric("Fresh input", number(request.metadata.input))
                metric("Cache reads", number(request.metadata.cacheRead))
                metric("Cache writes", number(request.metadata.cacheWrite))
                metric("Output", number(request.metadata.output))
                metric("Reported reasoning", number(request.metadata.reasoning))
                metric("Reported input − estimate", request.metadata.difference.map { ($0 > 0 ? "+" : "") + number($0) } ?? "—")
                metric("Provider payload observed", request.metadata.payloadObserved.map { Chrome.localized($0 ? "Yes" : "No") } ?? "—")
                note("The difference includes provider framing and request transformations; it is not assigned to system text.")
                if request.record.status == .running { note("Usage remains unknown until OMP receives the provider's report.") }
            } else {
                note("No request capture is available on this branch.")
            }
            if state.saved?.captureWarning == true { note("Some request captures are unavailable or exceeded their retention limits.") }
        }
    }

    private var accounting: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Recorded session total")
            if let amounts = state.saved?.journal.accounting {
                metric("Total tokens", number(amounts.total))
                metric("Fresh input", number(amounts.input))
                metric("Cache reads", number(amounts.cacheRead))
                metric("Cache writes", number(amounts.cacheWrite))
                metric("Output", number(amounts.output))
                metric("Reported reasoning", number(amounts.reasoning))
                metric("Cache hit rate", amounts.cacheHitRate.map { $0.formatted(.percent.precision(.fractionLength(2))) } ?? "—")
                metric("Reported cost", amounts.cost.map { $0.formatted(.currency(code: "USD").precision(.fractionLength(2...6))) } ?? "—")
                Divider()
                metric("User messages", number(amounts.users))
                metric("Model responses", number(amounts.assistants))
                metric("Tool calls", number(amounts.toolCalls))
                metric("Tool results", number(amounts.toolResults))
                metric("Auxiliary model calls", number(amounts.auxiliaryCalls))
                note("Includes all retained branches and native auxiliary usage in this session file, plus reported task usage. In-flight usage may not be saved yet.")
                if amounts.missingReports > 0 { metric("Responses without usage", number(amounts.missingReports)) }
                if amounts.reasoningReports < amounts.reports { note("Reasoning totals cover only calls that report reasoning separately.") }
            } else {
                note("No saved native accounting is available yet.")
            }
        }
    }

    private var measurementNotes: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("How these values are measured")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(ContextWorkspaceReport.measurementNotes, id: \.self) { note($0) }
            }
        }
        .padding(Chrome.contentHorizontalPadding)
        .frame(width: 380, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .font(.ui(.callout))
        .foregroundStyle(Chrome.primaryText)
    }

    private func copyReport() {
        let report = ContextWorkspaceReport(runtime: runtime, state: state, live: inspectionOverride)
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(report.markdown, forType: .string) {
            reportError = Chrome.localized("Could not copy context report.")
        }
    }

    private func exportReport(_ format: ContextReportFormat) {
        // Freeze the selected conversation before presenting the save dialog.
        let report = ContextWorkspaceReport(runtime: runtime, state: state, live: inspectionOverride)
        let data = report.data(for: format)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .json ? .json : UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = report.baseFilename + "." + format.fileExtension
        panel.canCreateDirectories = true
        let failure = $reportError
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) }
            catch { failure.wrappedValue = error.localizedDescription }
        }
        if let window = NSApp.mainWindow ?? NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func heading(_ title: String) -> some View {
        Text(verbatim: Chrome.localized(title)).font(.ui(.callout, weight: .semibold))
    }
    private func note(_ text: String) -> some View {
        Text(verbatim: Chrome.localized(text)).font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func number(_ value: Int?) -> String { value?.formatted() ?? "—" }
    private func metric(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: Chrome.localized(title)).foregroundStyle(Chrome.secondaryText)
            Spacer(minLength: 0)
            ContextMetricValue(value: value).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.trailing).textSelection(.enabled).help(Text(verbatim: value))
        }
    }
    private func categoryGroup(_ title: String, rows: [OMPContextCategory], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !rows.isEmpty {
                Text(verbatim: Chrome.localized(title)).font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                categoryTable(rows, total: total, prefix: usesRequestComposition ? "request" : "projection")
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func categoryTable(_ rows: [OMPContextCategory], total: Int, prefix: String) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { row in
                ContextCategoryRow(row: row, total: total, state: state, scope: prefix)
                Divider()
            }
        }
    }
    private func compositionBar(_ composition: OMPContextComposition) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(composition.categories) { row in
                    ContextCategoryRow.color(row.kind)
                        .frame(width: composition.total > 0 ? geometry.size.width * Double(row.tokens) / Double(composition.total) : 0)
                }
            }.clipShape(Capsule())
        }.frame(height: 6).accessibilityHidden(true)
    }
}

private struct ContextCategoryRow: View {
    let row: OMPContextCategory
    let total: Int
    let state: ContextWorkspaceStore
    let scope: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    private var key: String { scope + ":" + row.kind }
    private var expanded: Bool { state.expandedCategories.contains(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle().fill(Self.color(row.kind)).frame(width: 5, height: 5)
                if row.items.isEmpty && row.omittedItems == 0 { title }
                else {
                    Button {
                        withAnimation(reduceMotion || performanceMode ? nil : .smooth(duration: 0.18)) {
                            if expanded { state.expandedCategories.remove(key) } else { state.expandedCategories.insert(key) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold)).frame(width: 8)
                            title
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityValue(Text(verbatim: Chrome.localized(expanded ? "Expanded" : "Collapsed")))
                }
                Spacer(minLength: 6)
                ContextMetricValue(value: "≈" + row.tokens.formatted()).fixedSize()
                ContextMetricValue(value: total > 0 ? (Double(row.tokens) / Double(total)).formatted(.percent.precision(.fractionLength(1))) : "—")
                    .monospacedDigit().foregroundStyle(Chrome.secondaryText).frame(minWidth: 44, alignment: .trailing)
            }.padding(.vertical, 8)
            if expanded {
                ForEach(row.items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: item.name).lineLimit(2).help(Text(verbatim: item.name)).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Text(verbatim: "≈" + item.tokens.formatted()).monospacedDigit()
                    }.font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).padding(.leading, 16).padding(.bottom, 4)
                }
                if row.omittedItems > 0 {
                    Text(verbatim: String(format: Chrome.localized("%lld more entries"), Int64(row.omittedItems)))
                        .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).padding(.leading, 16).padding(.bottom, 6)
                }
            }
        }
    }
    private var title: some View { Text(verbatim: Chrome.localized(row.title)).fixedSize(horizontal: false, vertical: true) }
    static func color(_ kind: String) -> Color {
        switch kind {
        case "system", "projectContext", "skills": .purple
        case "toolSchemas", "toolCalls", "toolResults": Chrome.warning
        case "userText": Chrome.accent
        case "assistantText", "thinking", "messages": .cyan
        case "images": Chrome.success
        default: Chrome.secondaryText
        }
    }
}

/// Same finite numeric transition as Usage, scoped to text so refreshes cannot
/// animate panel surfaces or change the accepted layout during a reveal.
private struct ContextMetricValue: View {
    let value: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    var body: some View {
        Text(verbatim: value).monospacedDigit()
            .contentTransition(reduceMotion || performanceMode ? .identity : .numericText())
            .animation(reduceMotion || performanceMode ? nil : .smooth(duration: 0.35), value: value)
    }
}
