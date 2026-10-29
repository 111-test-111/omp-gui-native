import AppKit
import SwiftUI

struct DebugWorkspacePane: View {
    let runtime: ThreadRuntime
    let previews: FilePreviewStore
    let context: FilePreviewContext
    @State private var inspector = DebugWorkspaceStore()
    @State private var followsLatest = true
    @State private var userScrolling = false
    @State private var lastScrollInput: TimeInterval = 0
    @State private var bottomDistance: CGFloat = .infinity
    @State private var followTask: Task<Void, Never>?
    private static let activityTail = "debug.activity-tail"

    private var snapshot: OMPDebugSnapshot { runtime.ompDebug }
    private var runs: [OMPDebugRun] { snapshot.runs }
    private var viewedRun: OMPDebugRun? {
        if let id = previews.session?.debugRunID { return runs.first { $0.id == id } }
        return runs.last
    }
    private var records: [OMPDebugRecord] { viewedRun?.records ?? [] }
    private var isLiveRun: Bool { viewedRun?.id == snapshot.runID && snapshot.connected }
    private var viewedPhase: OMPDebugPhase { isLiveRun ? snapshot.phase : viewedRun?.phase ?? .idle }
    private var isPresented: Bool {
        previews.isVisible && previews.isWindowPresented && previews.isWorkspacePresented
            && previews.activeSidebarTab == .panel(.debug)
    }
    private var selectedIndex: Int? { records.firstIndex { $0.id == previews.session?.debugRecordID } }
    private var showsOverview: Bool { previews.isFullscreen || selectedIndex == nil }
    private var inspectionKey: String? { isPresented && isLiveRun && showsOverview ? snapshot.inspectionKey : nil }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if !runs.isEmpty {
                        toolbar(proxy: proxy, compact: geometry.size.width < 480)
                        WorkspaceDetailColumns(isFullscreen: previews.isFullscreen, hasDetail: selectedIndex != nil,
                                               fraction: Binding(get: { previews.session?.debugDetailFraction ?? 0.42 },
                                                                 set: { previews.session?.debugDetailFraction = $0 })) { _ in
                            overview(proxy: proxy)
                                .id(viewedRun?.id)
                        } detail: {
                            if let selectedIndex, let history = previews.session?.debugHistory {
                                let record = records[selectedIndex]
                                DebugStepDetail(record: record, sessionFile: viewedRun?.sessionFile, history: history,
                                    inspection: viewedRun?.inspection(after: record.id), previousInspection: viewedRun?.inspection(before: record.id),
                                    previews: previews, context: context)
                                    .id((viewedRun?.id ?? "") + record.id)
                            }
                        }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "ladybug").font(.symbol(.title2))
                            Text("No debug session").font(.ui(.callout))
                        }
                        .foregroundStyle(Chrome.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .onChange(of: inspectionKey, initial: true) { _, _ in refresh() }
        .task(id: viewedRun?.id) {
            if let run = viewedRun { await previews.session?.debugHistory.prepareRun(run, runtime: runtime) }
        }
        .onDisappear { inspector.stop(); followTask?.cancel() }
        .accessibilityLabel(Text("Debug"))
    }

    private func toolbar(proxy: ScrollViewProxy, compact: Bool) -> some View {
        HStack(spacing: 6) {
            if selectedIndex != nil && !previews.isFullscreen {
                ChromeCapsule {
                    ChromeIconButton(symbol: "chevron.left", help: "Back to debug activity") { previews.session?.debugRecordID = nil }
                }
            }
            runSelector
            Spacer(minLength: 0)
            statusBadge(compact: compact && selectedIndex != nil).layoutPriority(-1)
            if let selectedIndex {
                badge {
                    Text(verbatim: String(format: Chrome.localized(compact ? "%d / %d" : "Step %d of %d"), selectedIndex + 1, records.count))
                        .monospacedDigit().fixedSize()
                }
                .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("Step %d of %d"), selectedIndex + 1, records.count)))
            }
            ChromeCapsule {
                if let selectedIndex, !compact {
                    ChromeIconButton(symbol: "chevron.up", isEnabled: selectedIndex > 0, help: "Previous debug step") { move(-1) }
                    ChromeIconButton(symbol: "chevron.down", isEnabled: selectedIndex + 1 < records.count, help: "Next debug step") { move(1) }
                }
                if selectedIndex != nil && compact {
                    ChromeMenuButton(symbol: "ellipsis", help: "Debug step navigation") {
                        PopoverItem("Previous debug step", symbol: "chevron.up", isEnabled: (selectedIndex ?? 0) > 0) { move(-1) }
                        PopoverItem("Next debug step", symbol: "chevron.down", isEnabled: (selectedIndex ?? 0) + 1 < records.count) { move(1) }
                        PopoverItem("Latest debug step", symbol: "arrow.down.to.line", isEnabled: selectedIndex != records.indices.last) { latest(proxy) }
                    }
                } else {
                    ChromeIconButton(symbol: "arrow.down.to.line", isEnabled: !records.isEmpty && selectedIndex != records.indices.last,
                                     help: "Latest debug step") { latest(proxy) }
                }
                if showsOverview && isLiveRun && snapshot.canInspect {
                    ChromeIconButton(symbol: "arrow.clockwise", isEnabled: !inspector.loading && !inspector.loadingScopes,
                                     help: "Refresh debug inspection") { refresh() }
                }
            }
        }
        .padding(Chrome.workspaceToolbarInsets)
        .accessibilityIdentifier("debug.toolbar")
    }

    private var runSelector: some View {
        ChromeTextMenu(symbol: nil, title: runTitle(viewedRun), help: "Choose debug run",
                       titleText: Text(verbatim: runTitle(viewedRun)), menuWidth: DebugRunMenu.maxWidth, allowsTitleTruncation: true) {
            DebugRunMenu(runs: runs, selection: previews.session?.debugRunID) { previews.session?.selectDebugRun($0) }
        }
        .help(Text(verbatim: runTitle(viewedRun)))
        .accessibilityIdentifier("debug.run-selector")
        .accessibilityValue(Text(verbatim: runTitle(viewedRun)))
    }

    private func runTitle(_ run: OMPDebugRun?) -> String {
        DebugRunMenu.title(run, in: runs)
    }

    private func latest(_ proxy: ScrollViewProxy) {
        guard let record = records.last else { return }
        if selectedIndex != nil { previews.session?.debugRecordID = record.id }
        else {
            followsLatest = true
            proxy.scrollTo(Self.activityTail, anchor: .bottom)
        }
    }

    private func move(_ offset: Int) {
        guard let selectedIndex else { return }
        let target = selectedIndex + offset
        if records.indices.contains(target) { previews.session?.debugRecordID = records[target].id }
    }

    private func overview(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if isLiveRun && snapshot.canInspect {
                    if let session = snapshot.session { stopLocation(session, current: true) }
                    stack
                    variables
                } else if let record = records.last, let stop = viewedRun?.inspection(after: record.id) {
                    stopLocation(stop.session, current: false)
                    if !stop.captures.isEmpty {
                        DebugSavedInspection(stop: stop, previews: previews, context: context).id(stop.id).padding(12)
                    }
                }
                if isLiveRun && !snapshot.supported && (snapshot.active || snapshot.busy) {
                    Text("Live inspection unavailable")
                        .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).padding(12)
                }
                if isLiveRun, let error = inspector.error {
                    Text(verbatim: error).font(.ui(.caption)).foregroundStyle(.red)
                        .padding(12).textSelection(.enabled)
                }
                DebugActivityList(records: records, sessionFile: viewedRun?.sessionFile, history: previews.session?.debugHistory,
                                  selectedID: previews.isFullscreen ? previews.session?.debugRecordID : nil,
                                  select: { previews.session?.debugRecordID = $0 })
                Color.clear.frame(height: 1).id(Self.activityTail).accessibilityHidden(true)
            }
            .padding(.bottom, 12)
            .background(DebugActivityScrollInput { downward in
                guard isPresented, showsOverview else { return }
                lastScrollInput = ProcessInfo.processInfo.systemUptime
                followsLatest = downward && bottomDistance <= 12
                followTask?.cancel()
            })
        }
        .defaultScrollAnchor(followsLatest && isLiveRun ? .bottom : nil, for: .sizeChanges)
        .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting {
                userScrolling = true; followsLatest = false; followTask?.cancel()
            } else if phase == .idle, userScrolling {
                userScrolling = false; followsLatest = bottomDistance <= 12
            }
        }
        .onScrollGeometryChange(for: DebugScrollMetrics.self, of: DebugScrollMetrics.init) { old, new in
            bottomDistance = new.bottomDistance
            if old.offset != new.offset, userScrolling || ProcessInfo.processInfo.systemUptime - lastScrollInput < 0.4 {
                followsLatest = new.bottomDistance <= 12
            }
            if old.height != new.height { follow(proxy) }
        }
        .onChange(of: records) { _, _ in follow(proxy) }
        .onChange(of: viewedRun?.id, initial: true) { _, _ in
            followsLatest = true; lastScrollInput = 0; follow(proxy)
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard followsLatest, isLiveRun, isPresented, selectedIndex == nil else { return }
        let run = viewedRun?.id
        followTask?.cancel()
        followTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, followsLatest, isLiveRun, isPresented, selectedIndex == nil, viewedRun?.id == run else { return }
            proxy.scrollTo(Self.activityTail, anchor: .bottom)
        }
    }

    private func statusBadge(compact: Bool) -> some View {
        badge(tint: statusColor) {
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                if !compact {
                    Text(verbatim: Chrome.localized(viewedPhase.title))
                        .font(.ui(.callout, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .help(Text(verbatim: Chrome.localized(viewedPhase.title)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Chrome.localized(viewedPhase.title)))
        .accessibilityValue(Text(verbatim: viewedRun?.title ?? ""))
    }

    private func badge<Content: View>(tint: Color? = nil, @ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.ui(.caption, weight: .medium)).foregroundStyle(tint ?? Chrome.secondaryText)
            .padding(.horizontal, 8).frame(height: Chrome.capsuleHeight)
            .background(tint?.opacity(0.10) ?? Chrome.overlay(0.06), in: .capsule)
            .overlay { Capsule().strokeBorder(tint?.opacity(0.20) ?? Chrome.overlay(0.08), lineWidth: 0.5) }
    }

    private var statusColor: Color {
        switch viewedPhase {
        case .starting: .indigo
        case .debugging: .blue
        case .paused: Chrome.warning
        case .completed: Chrome.success
        case .interrupted: .purple
        case .failed: Chrome.danger
        case .ended, .idle: Chrome.secondaryText
        }
    }

    private func stopLocation(_ session: OMPDebugSession, current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(current ? "Current stop" : "Stop snapshot")
            HStack(spacing: 6) {
                Image(systemName: "pause.fill").font(.symbol(.caption)).foregroundStyle(.orange)
                if let name = session.frameName ?? (current ? inspector.frames.first?.name : nil) {
                    Text(verbatim: name).font(.code(.callout)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let reason = session.stopReason {
                    Text(verbatim: stopReason(reason)).font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).lineLimit(1)
                }
            }
            if let source = session.source ?? (current ? inspector.frames.first?.source : nil) {
                DebugSourceLink(source: source, cwd: session.cwd, previews: previews, context: context)
            }
            if session.stopReason == "exception", let detail = session.stopDescription, !detail.isEmpty {
                Text(verbatim: detail).font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).lineLimit(3).textSelection(.enabled)
            }
        }
        .padding(12)
    }

    private var stack: some View {
        let frameCapHeight = AppFont.monospaced(size: TypeScale.shared.code(TypeScale.stockPointSize(.callout))).capHeight
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                sectionTitle("Call stack")
                if inspector.limitedStack { omission }
                Spacer()
                if inspector.loading { ProgressView().controlSize(.mini) }
            }.padding(.horizontal, 12).padding(.vertical, 8)
            ForEach(inspector.frames) { frame in
                Button { inspector.selectFrame(frame.id) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.right")
                            .font(.symbol(.caption)).frame(width: 10).foregroundStyle(Color.accentColor)
                            .opacity(inspector.selectedFrameID == frame.id ? 1 : 0)
                            .alignmentGuide(.firstTextBaseline) { [frameCapHeight] dimensions in
                                dimensions[VerticalAlignment.center] + frameCapHeight / 2
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: frame.name).font(.code(.callout)).lineLimit(1)
                            if let source = frame.source {
                                Text(verbatim: source.label).font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .contentShape(.rect)
                    .background(inspector.selectedFrameID == frame.id ? Chrome.overlay(0.06) : .clear)
                }
                .buttonStyle(.plain)
            }
            if !inspector.loading && inspector.frames.isEmpty {
                Text("No stack frames").font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).padding(.horizontal, 12)
            }
            if let selected = inspector.frames.first(where: { $0.id == inspector.selectedFrameID }), let source = selected.source {
                sourceLink(source).padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
    }

    private var variables: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionTitle("Variables")
                if inspector.limitedVariables { omission }
                Spacer()
                if inspector.loadingScopes { ProgressView().controlSize(.mini) }
            }.padding(12)
            ForEach(inspector.rows) { node in variableRow(node) }
        }
    }

    private func variableRow(_ node: DebugWorkspaceStore.Node) -> some View {
        Button { inspector.toggle(node.id) } label: {
            HStack(spacing: 6) {
                Group {
                    if node.loading { ProgressView().controlSize(.mini) }
                    else if node.canExpand { Image(systemName: inspector.expanded.contains(node.id) ? "chevron.down" : "chevron.right").font(.symbol(.caption2)) }
                    else { Color.clear }
                }.frame(width: 12, height: 14)
                Text(verbatim: node.variable.name).font(node.isScope ? .ui(.callout, weight: .medium) : .code(.callout)).lineLimit(1)
                if !node.isScope {
                    Text(verbatim: node.variable.value).font(.code(.callout)).foregroundStyle(Chrome.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
                if node.error != nil { Image(systemName: "exclamationmark.circle").foregroundStyle(.red).help(node.error ?? "") }
                if node.limited || (node.variable.reference > 0 && !node.canExpand) { omission }
            }
            .padding(.leading, 12 + CGFloat(node.depth) * 12).padding(.trailing, 12).padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help([node.variable.type, node.variable.value.isEmpty ? nil : node.variable.value].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityLabel(Text(verbatim: node.variable.name + " " + node.variable.value))
        .contextMenu {
            if !node.isScope {
                Button("Copy value") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(node.variable.value, forType: .string) }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(verbatim: Chrome.localized(title)).font(.ui(.caption, weight: .semibold)).foregroundStyle(Chrome.secondaryText)
    }
    private var omission: some View {
        Text(verbatim: "…").font(.ui(.caption)).foregroundStyle(Chrome.secondaryText).help(Text("Inspection limit reached"))
    }
    private func sourceLink(_ source: OMPDebugSource) -> some View {
        DebugSourceLink(source: source, cwd: viewedRun?.session?.cwd ?? viewedRun?.stops.last?.session.cwd, previews: previews, context: context)
    }
    private func refresh() {
        if inspectionKey != nil { inspector.bind(runtime.activeOMPSession, snapshot: snapshot) }
        else { inspector.stop(keepingValues: isPresented && isLiveRun && snapshot.canInspect && selectedIndex != nil) }
    }
    private func stopReason(_ reason: String) -> String {
        let key = switch reason {
        case "breakpoint": "Breakpoint"
        case "exception": "Exception"
        case "step": "Step"
        case "entry": "Entry"
        case "pause": "Pause"
        case "data breakpoint": "Data breakpoint"
        default: reason
        }
        return Chrome.localized(key)
    }
}

private struct DebugScrollMetrics: Equatable {
    var offset: CGFloat
    var height: CGFloat
    var bottomDistance: CGFloat
    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y
        height = geometry.contentSize.height
        bottomDistance = max(0, height - geometry.visibleRect.maxY)
    }
}

/// Observe input before a pending follow task can move the viewport. Bounds
/// changes alone also come from new rows and must never count as user input.
private struct DebugActivityScrollInput: NSViewRepresentable {
    var onInput: (Bool) -> Void
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.onInput = onInput }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: NSView {
        var onInput: (Bool) -> Void = { _ in }
        private var wheel: Any?
        private var liveScroll: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil, let scroll = enclosingScrollView else { return }
            liveScroll = NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onInput(false) }
            }
            wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === window, event.scrollingDeltaY != 0,
                      let scroll = enclosingScrollView, let content = window?.contentView, let parent = content.superview else { return event }
                let point = parent.convert(event.locationInWindow, from: nil)
                guard content.hitTest(point)?.enclosingScrollView === scroll else { return event }
                onInput(event.scrollingDeltaY < 0)
                return event
            }
        }
        func detach() {
            if let wheel { NSEvent.removeMonitor(wheel) }; wheel = nil
            if let liveScroll { NotificationCenter.default.removeObserver(liveScroll) }; liveScroll = nil
        }
    }
}

struct DebugRunMenu: View {
    static let maxWidth: CGFloat = 360
    let runs: [OMPDebugRun]
    let selection: String?
    let select: (String?) -> Void

    var body: some View {
        PopoverItem("Latest debug run", isChecked: selection == nil) { select(nil) }
        PopoverDivider()
        ForEach(runs.reversed()) { run in
            let title = Self.title(run, in: runs)
            PopoverItem(title, text: Text(verbatim: title), isChecked: selection == run.id) { select(run.id) }
                .frame(maxWidth: Self.maxWidth)
                .help(Text(verbatim: title))
        }
    }

    static func title(_ run: OMPDebugRun?, in runs: [OMPDebugRun]) -> String {
        guard let run else { return Chrome.localized("Debug") }
        let index = (runs.firstIndex { $0.id == run.id } ?? 0) + 1
        if let title = run.title { return String(format: Chrome.localized("%@ · %d"), title, index) }
        return String(format: Chrome.localized("Debug run %d"), index)
    }
}
