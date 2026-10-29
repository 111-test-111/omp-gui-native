import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case usage
    case dictation
    case hydra
    case appearance
    case browser
    case providers
    case models
    case tools
    case mcp
    case skills
    case memory
    case sourceControl
    case shortcuts
    case archive
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .usage: "Usage"
        case .dictation: "Dictation"
        case .appearance: "Appearance"
        case .browser: "Browser"
        case .providers: "Providers"
        case .mcp: "MCP"
        case .skills: "Skills"
        case .memory: "Memory"
        case .models: "Models"
        case .tools: "Tools"
        case .hydra: "Hydra"
        case .sourceControl: "Source control"
        case .shortcuts: "Shortcuts"
        case .archive: "Archive"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gear"
        case .usage: "chart.bar.xaxis"
        case .dictation: "mic"
        case .appearance: "paintpalette"
        case .browser: "globe"
        case .providers: "cpu"
        case .mcp: "powerplug"
        case .skills: "books.vertical"
        case .memory: "brain"
        case .models: "slider.horizontal.3"
        case .tools: "wrench.and.screwdriver"
        // Never drawn: the sidebar gives the Hydra row the team mark instead. Kept so
        // the switch stays exhaustive and anything else that asks gets a sane symbol.
        case .hydra: "point.3.connected.trianglepath.dotted"
        case .sourceControl: "arrow.triangle.branch"
        case .shortcuts: "command"
        case .archive: "archivebox"
        case .about: "info.circle"
        }
    }

    /// What the mark needs to sit level in the sidebar's square icon slot: SidebarSymbol fits
    /// every glyph into that square, and one that is not itself square comes out small in it.
    var symbolScale: CGFloat {
        switch self {
        case .general: 1.15
        case .mcp: 1.25
        default: 1
        }
    }

    var tint: Color {
        switch self {
        case .general: Chrome.gray
        case .usage: Chrome.accent
        case .dictation: Chrome.blue
        case .appearance: Color(red: 0.85, green: 0.44, blue: 0.36)
        case .browser: Chrome.blue
        case .providers: Chrome.blue
        case .skills: Chrome.orange
        case .memory: Chrome.blue
        case .mcp: Color(red: 0.95, green: 0.55, blue: 0.20)
        case .models: Color(red: 0.686, green: 0.322, blue: 0.871)
        case .tools: Chrome.blue
        case .hydra: Color(red: 0.188, green: 0.690, blue: 0.780)
        case .sourceControl: Color(red: 0.345, green: 0.337, blue: 0.839)
        case .shortcuts: Color(red: 0.32, green: 0.48, blue: 0.93)
        case .archive: Chrome.orange
        case .about: Color(red: 0.204, green: 0.780, blue: 0.349)
        }
    }

    var keywords: [String] {
        switch self {
        case .general: ["permissions", "worktree", "reasoning", "thinking", "notifications", "panel", "limits", "credits", "settle", "settled", "finish", "finished", "done", "sound", "chime", "icon", "icons", "emoji", "symbol", "symbols", "project mark", "compact", "concise", "anti-slop", "slop", "verbose", "comments", "replies"]
        case .usage: ["usage", "token", "tokens", "activity", "heatmap", "statistics", "charts", "daily", "weekly", "cumulative", "cache", "用量", "统计", "图表", "缓存", "模型", "项目"]
        case .appearance: ["appearance", "theme", "transparency", "transparent", "opacity", "glass", "dark", "light", "accent", "tint", "catppuccin", "dracula", "tokyo", "nord", "gruvbox", "solarized", "github", "claude", "codex", "cursor", "matrix", "text", "size", "font", "zoom", "wallpaper", "sidebar", "performance", "gpu"]
        case .browser: ["browser", "search", "search engine", "google", "bing", "duckduckgo", "baidu", "language", "locale", "links", "default browser", "浏览器", "搜索", "搜索引擎", "必应", "百度", "语言", "中文", "英文", "链接", "打开方式", "默认浏览器"]
        case .models: ["model", "effort", "reasoning", "fast", "slider", "picker"]
        case .tools: ["tools", "tool", "xd://", "eval", "parameters", "schema", "description", "prompt", "工具", "参数", "描述", "提示词"]
        case .hydra: ["hydra", "heads", "subagents", "sub-agents", "agents", "team", "orchestrator", "worker", "pair", "pairs", "parallel", "delegate", "queue"]
        case .providers: ["kimi", "pi", "codex", "claude", "cursor", "opencode", "opencode zen", "opencode go", "zen", "grok", "deepseek", "meta", "muse", "spark", "zai", "z.ai", "glm", "coding plan", "devin", "cognition", "antigravity", "agy", "google", "gemini", "copilot", "github", "command code", "commandcode", "cmd", "binary", "path", "sign in", "login", "api key", "usage", "limits", "limit", "plan", "quota", "credits", "balance", "omp", "prompt", "instructions", "append_system.md", "custom prompt", "提示词", "自定义提示词", "image", "images", "generate", "edit", "backend", "图片", "生图", "后端"]
        case .mcp: ["mcp", "model context protocol", "servers", "tools", "connect", "integrations", "github", "playwright", "notion", "linear", "slack", "figma", "supabase", "stripe", "resend", "email", "context7", "sentry", "postgres", "browser", "netlify", "deploy", "hosting"]
        case .sourceControl: ["git", "commit", "pull request", "titles", "text generation", "github", "clone", "repository", "repositories", "repo", "sign in", "token", "connect", "account"]
        case .memory: ["memory", "mnemopi", "recall", "retain", "global", "worktree", "记忆", "共享"]
        case .skills: ["skills", "skill.md", "global", "preview", "source", "技能", "全局", "预览", "源码"]
        case .dictation: ["dictation", "speech", "microphone", "language", "听写", "语音", "麦克风", "语言", "权限"]
        case .shortcuts: ["keyboard", "keys"]
        case .archive: ["archived", "restore"]
        case .about: ["version", "license"]
        }
    }
}

/// Settings is a page in the main window; external entry points share its navigation.
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    private(set) var isPresented = false
    var page: SettingsPage = .general

    func present(page: SettingsPage? = nil) {
        if let page { self.page = page }
        isPresented = true
    }

    func dismiss() { isPresented = false }
}

struct SettingsView: View {
    @Bindable private var navigation = SettingsNavigation.shared
    private var page: SettingsPage {
        get { navigation.page }
        nonmutating set { navigation.page = newValue }
    }
    @State private var search = ""
    @State private var scrollTracker = SettingsScrollTracker()

    private var visiblePages: [SettingsPage] {
        let query = search.trimmed
        guard !query.isEmpty else { return SettingsPage.allCases }
        return SettingsPage.allCases.filter { page in
            page.title.localizedCaseInsensitiveContains(query)
                || Chrome.localized(page.title).localizedCaseInsensitiveContains(query)
                || page.keywords.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 212)
            SettingsPages(page: page, scrollTracker: scrollTracker)
                .padding(.trailing, Chrome.sheetInset)
                .padding(.vertical, Chrome.sheetInset)
        }
        .onDisappear { scrollTracker.end() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand { WindowManager.shared.hideSettings() }
        // A search that filters the selected page out of the list left the detail pane on a
        // page no row was selected for; the first match takes over instead.
        .onChange(of: visiblePages) { _, pages in
            guard !pages.isEmpty, !pages.contains(page), let first = pages.first else { return }
            page = first
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: Chrome.trafficLightDiameter)
                .padding(.top, Chrome.trafficLightTop)
            SidebarRow(title: "Back", action: { WindowManager.shared.hideSettings() }) {
                SidebarIconBadge { SidebarSymbol("arrow.left") }
            }
            .help("Back to your threads")
            .padding(.horizontal, Chrome.listInset)
            .padding(.top, 10)
            SidebarSearchField(text: $search) {
                if let first = visiblePages.first { page = first }
            }
            .padding(.horizontal, Chrome.listInset)
            .padding(.top, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visiblePages) { item in
                        SettingsNavRow(title: item.title, isSelected: page == item, action: { page = item }) {
                            SidebarIconBadge {
                                if item == .hydra {
                                    // The Hydra page wears the team mark, the same one as the composer button.
                                    HydraMarkImage()
                                        .frame(width: Chrome.symbolSize * 1.15, height: Chrome.symbolSize * 1.15)
                                } else {
                                    SidebarSymbol(item.symbol, scale: item.symbolScale)
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                if item == .about, UpdateChecker.shared.updateAvailable {
                                    UpdateAvailableDot()
                                }
                            }
                        }
                    }
                    if visiblePages.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No results")
                                .font(.ui(.body, weight: .semibold))
                                .foregroundStyle(Chrome.primaryText.opacity(0.92))
                            Text("Try a setting or a provider name.")
                                .font(.ui(.subheadline))
                                .foregroundStyle(Chrome.secondaryText)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 14)
                    }
                }
                .padding(.horizontal, Chrome.listInset)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .allowsHitTesting(!scrollTracker.isFrozen)
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, _ in
                scrollTracker.note()
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { scrollTracker.note() } else { scrollTracker.coast() }
            }
            .scrollIndicators(.never)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background { WindowDragArea() }
    }

}

/// Slightly taller than a chat row, with a quiet label and an explicit selected state.
/// Existing page order and grouping remain owned by SettingsPage.
private struct SettingsNavRow<Icon: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let icon: Icon
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon.frame(width: Chrome.iconSize, height: Chrome.iconSize)
                Text(verbatim: Chrome.localized(title))
                    .font(.ui(.body))
                    .foregroundStyle(isSelected || isHovering ? Chrome.primaryText : Chrome.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Chrome.rowHorizontalPadding)
            .frame(minHeight: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
                    .fill(Chrome.overlay(isSelected ? 0.10 : isHovering ? 0.05 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Keep at most one host per settings page. Detached hosts retain their view state,
/// but still run onDisappear and cancel page-scoped tasks when the reader leaves.
private struct SettingsPages: NSViewRepresentable {
    let page: SettingsPage
    let scrollTracker: SettingsScrollTracker

    func makeNSView(context: Context) -> NSView { NSView() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ pane: NSView, context: Context) {
        context.coordinator.show(page, in: pane, environment: context.environment, scrollTracker: scrollTracker)
    }

    @MainActor final class Coordinator {
        private var pages: [SettingsPage: FrameHostingView] = [:]
        private var shown: SettingsPage?

        func show(_ page: SettingsPage, in pane: NSView, environment: EnvironmentValues, scrollTracker: SettingsScrollTracker) {
            let root = AnyView(SettingsDetail(page: page, scrollTracker: scrollTracker).environment(\.self, environment))
            if shown == page {
                pages[page]?.rootView = root
                return
            }
            if let shown, let previous = pages[shown] {
                if let responder = previous.window?.firstResponder as? NSView, responder.isDescendant(of: previous) {
                    previous.window?.makeFirstResponder(nil)
                }
                previous.removeFromSuperview()
            }
            scrollTracker.end()
            let host: FrameHostingView
            if let cached = pages[page] {
                host = cached
                host.rootView = root
            } else {
                host = FrameHostingView(rootView: root)
                pages[page] = host
            }
            host.frame = pane.bounds
            pane.addSubview(host)
            shown = page
        }
    }
}

private struct SettingsDetail: View {
    let page: SettingsPage
    let scrollTracker: SettingsScrollTracker
    @Environment(AppModel.self) private var model
    @State private var modelSearch = ""
    @State private var mcpSearch = ""
    @State private var toolSearch = ""
    @State private var archiveFilter = ArchiveFilter()
    @State private var usageStore = UsageSettingsStore()
    @State private var usageRefreshID = 0
    @State private var scrollChrome = ChromeScrollModel()
    @State private var scrollPosition = ScrollPosition(edge: .top)

    var body: some View {
        Group {
            if page == .archive, model.archivedThreads.isEmpty {
                // An empty archive is one symbol in the middle of the pane: no sentence, no chrome,
                // no button with nothing to delete.
                Image(systemName: "archivebox")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Chrome.secondaryText.opacity(0.6))
                    .accessibilityLabel(Text("No archived threads"))
            } else {
                pageScroll
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .detailSheet()
        .onAppear {
            scrollPosition.scrollTo(edge: .top)
            scrollChrome.update(travel: 0)
            modelSearch = ""
            mcpSearch = ""
            toolSearch = ""
            archiveFilter = ArchiveFilter()
        }
        .onDisappear { scrollTracker.end() }
    }

    private var pageScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
                Text(verbatim: Chrome.localized(page.title))
                    .font(.ui(size: 20, weight: .medium))
                    .foregroundStyle(Chrome.primaryText)
                    .accessibilityAddTraits(.isHeader)
                pageLayout
            }
            .frame(maxWidth: 800, alignment: .leading)
            .padding(.horizontal, Chrome.contentHorizontalPadding + 8)
            .frame(maxWidth: .infinity)
            // The large page title scrolls under the same compact chrome title on every page.
            .padding(.top, Chrome.chromeTopPadding + Chrome.capsuleHeight + 12)
            .padding(.bottom, 24)
            .allowsHitTesting(!scrollTracker.isFrozen)
        }
        .scrollIndicators(.never)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self, of: Self.travel) { _, travel in
            scrollTracker.note()
            scrollChrome.update(travel: travel)
        }
        .onScrollPhaseChange { _, phase in
            // Fingers on the content freeze the rows (no click can land then anyway); the
            // moment the scroll coasts or settles they come back, so a click that stops a
            // flick always reaches its target. Wheel scrolling reports no phases and is
            // caught by the movement above instead.
            if phase == .interacting { scrollTracker.note() } else { scrollTracker.coast() }
        }
        .chromeEdgeFade(scrollChrome)
        .overlay(alignment: .top) {
            HStack(spacing: 10) {
                ChromeCompactTitle(title: page.title, model: scrollChrome)
                if page == .models {
                    ChromeSearchField(query: $modelSearch, prompt: "Search models")
                }
                if page == .mcp {
                    ChromeSearchField(query: $mcpSearch, prompt: "Search servers")
                }
                if page == .tools {
                    ChromeSearchField(query: $toolSearch, prompt: "Search tools")
                }
                if page == .providers {
                    ProvidersRefreshButton()
                }
                if page == .usage {
                    UsageRefreshButton(loadedAt: usageStore.loadedAt, isLoading: usageStore.isLoading) {
                        usageRefreshID += 1
                    }
                }
                if page == .archive {
                    ArchiveChromeControls(filter: $archiveFilter)
                }
                if page == .about {
                    AboutUpdateChromeAccessory()
                }
            }
            .frame(minHeight: Chrome.capsuleHeight)
            .padding(.horizontal, Chrome.chromeHorizontalPadding)
            .padding(.top, Chrome.chromeTopPadding)
        }
    }

    @ViewBuilder
    private var pageLayout: some View {
        if page == .general || page == .appearance || page == .shortcuts {
            LazyVStack(alignment: .leading, spacing: Chrome.sectionSpacing) { pageContent }
        } else {
            VStack(alignment: .leading, spacing: Chrome.sectionSpacing) { pageContent }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .general: GeneralSettingsPage()
        case .dictation: DictationSettingsPage()
        case .usage: UsageSettingsPage(store: usageStore, refreshID: usageRefreshID)
        case .appearance: AppearanceSettingsPage()
        case .browser: BrowserSettingsPage()
        case .providers: ProvidersSettingsPage()
        case .mcp: MCPSettingsPage(query: mcpSearch)
        case .tools: ToolsSettingsPage(query: toolSearch)
        case .skills: SkillsSettingsPage()
        case .memory: MemorySettingsPage()
        case .models:
            ModelsSettingsPage(query: modelSearch)
        case .hydra: HydraSettingsPage()
        case .sourceControl: SourceControlSettingsPage()
        case .shortcuts: ShortcutsSettingsPage()
        case .archive: ArchiveSettingsPage(filter: $archiveFilter)
        case .about: AboutSettingsPage()
        }
    }

    private nonisolated static func travel(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentOffset.y + geometry.contentInsets.top
    }
}

struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

private struct GeneralSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        ChromeSection(title: "New threads") {
            ChromeCard {
                NewThreadDefaultsRows()
                ChromeRowDivider()
                ChromeRow(title: "Permissions", detail: settings.defaultRuntimeMode.summary) {
                    GlassPickerButton(options: RuntimeMode.allCases.map { ($0, $0.title) }, selection: $settings.defaultRuntimeMode, symbol: { $0.symbol })
                }
                ChromeRowDivider()
                ChromeRow(title: "Workspace", detail: "Where a new thread makes its changes") {
                    ChromeVisualPicker(options: WorkspaceMode.allCases.map { ($0, $0.title) }, selection: $settings.defaultWorkspaceMode) { mode in
                        Image(systemName: mode == .local ? "folder" : "arrow.triangle.branch")
                    }
                }
            }
        }
            ChromeSection(title: "Conversation") {
                ChromeCard {
                    ChromeRow(title: "Show thinking", detail: "The working line opens to the agent's thinking") {
                        SettingsSwitch(isOn: $settings.showReasoning)
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Concise AI replies", detail: "Built-in guidance for shorter replies, useful code comments, and focused work, including Hydra heads. Changes apply on the next message.") {
                        SettingsSwitch(isOn: $settings.antiSlopEnabled)
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Working line", detail: "A card with the turn's progress bar, or a plain line") {
                        ChromeVisualPicker(options: [(true, "Card"), (false, "Line")], selection: $settings.showsWorkingCard) { isCard in
                            Image(systemName: isCard ? "rectangle.fill" : "minus")
                        }
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Timeline haptics", detail: "Play haptic feedback when hovering over timeline ticks and progress bars") {
                        GlassPickerButton(options: TimelineHapticStyle.allCases.map { ($0, $0.title) }, selection: $settings.timelineHapticStyle)
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Recent downloads", detail: "The attach button offers recent downloads first") {
                        SettingsSwitch(isOn: $settings.recentDownloadsPicker)
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Notify when a turn finishes") {
                    SettingsSwitch(isOn: $settings.notifyWhenFinished)
                }
                ChromeRowDivider()
                ChromeRow(title: "Chime when a turn finishes", detail: "A soft chime, whether or not the thread is in view") {
                    SettingsSwitch(isOn: $settings.chimeWhenFinished)
                }
                // Switching it on plays the chime once, so you hear what you are getting.
                .onChange(of: settings.chimeWhenFinished) { _, isOn in
                    if isOn { FinishChime.play() }
                }
                ChromeRowDivider()
                ChromeRow(title: "Confirm before deleting threads") {
                    SettingsSwitch(isOn: $settings.confirmBeforeDeleting)
                }
                ChromeRowDivider()
                ChromeRow(title: "Continue after a usage limit", detail: "When the provider's limit is spent, the chat waits for the reset and then tells the agent to carry on") {
                    SettingsSwitch(isOn: $settings.autoContinueAfterLimit)
                }
                ChromeRowDivider()
                ChromeRow(
                    title: "Show a usage panel",
                    detail: "The plan's limits and credits in a floating panel beside every chat, for the model in use or a pair's two; the usage popover's pop-out button switches it on as well, and it keeps the corner it was last dragged to"
                ) {
                    SettingsSwitch(isOn: $settings.showsUsagePanel)
                }
            }
        }
        ChromeSection(title: "Projects") {
            ChromeCard {
                ChromeRow(title: "Projects", detail: "Activates every project at once unless explicitly overridden") {
                    SettingsSwitch(isOn: $settings.projectsEnabled)
                }
                ChromeRowDivider()
                ChromeRow(title: "Marks", detail: "An emoji or symbol for each project, drawn before the thread's name in the activity list and on the project's own row") {
                    ProjectMarksRow()
                }
            }
        }
        ChromeSection(title: "Finished threads") {
            ChromeCard {
                ChromeRow(title: "Done with a thread", detail: settings.threadFinishAction.detail) {
                    ChromeVisualPicker(options: ThreadFinishAction.allCases.map { ($0, $0.title) }, selection: $settings.threadFinishAction) { action in
                        Image(systemName: action == .settle ? "checkmark" : "archivebox")
                    }
                }
                ChromeRowDivider()
                ChromeRow(title: "Sound when settling", detail: "A small note as the thread settles") {
                    SettingsSwitch(isOn: $settings.settleSound)
                }
                // Switching it on plays the note once, so you hear what you are getting.
                .onChange(of: settings.settleSound) { _, isOn in
                    if isOn { SettleChime.play() }
                }
                .disabled(settings.threadFinishAction != .settle)
                .opacity(settings.threadFinishAction == .settle ? 1 : 0.5)
            }
        }
        ChromeSection(title: "Power") {
            ChromeCard {
                ChromeRow(
                    title: "Prevent sleep while tasks are running",
                    detail: "Keep your Mac awake while OMP GUI runs tasks. The display can turn off, and you can still sleep manually or close the lid."
                ) {
                    SettingsSwitch(isOn: $settings.preventSleepDuringTasks)
                }
            }
        }
        ChromeSection(title: "Languages") {
            ChromeCard {
                ChromeRow(title: "App language", detail: "Changes apply after the app restarts.") {
                    GlassPickerButton(options: AppLanguage.allCases.map { ($0, $0.title) }, selection: $settings.appLanguage)
                }
            }
        }
    }
}

/// The main interface, font sizes and other appearance settings.
private struct AppearanceSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        ChromeSection(title: "Main interface") {
            ChromeCard {
                ChromeRow(title: "Theme", detail: settings.theme.detail) {
                    ThemePickerButton(selection: $settings.theme)
                }
                ChromeRowDivider()
                ChromeRow(title: "Transparency", detail: "How much shows through the window") {
                    BackdropOpacitySlider(value: $settings.backdropOpacity)
                }
                .disabled(settings.performanceMode)
                .opacity(settings.performanceMode ? 0.5 : 1)
                ChromeRowDivider()
                ChromeRow(title: "Performance Mode", detail: "Disable window transparency, blurs, glows and background effects for lowest GPU usage") {
                    SettingsSwitch(isOn: $settings.performanceMode)
                }
            }
            WallpaperCard()
        }
        FontSizeSection()
        CodeHighlightingSection()
        ChromeSection(title: "Other") {
            ChromeCard {
                ChromeRow(title: "Auto-hide top controls", detail: "Show the upper-right controls only while the pointer is over their area") {
                    SettingsSwitch(isOn: $settings.autoHideTopControls)
                }
                ChromeRowDivider()
                ChromeRow(title: "Open the sidebar at launch", detail: "Collapsed otherwise; the list button in the toolbar shows and hides it any time") {
                    SettingsSwitch(isOn: Binding(
                        get: { model.sidebar.startsOpen },
                        set: { model.sidebar.startsOpen = $0 }
                    ))
                }
                ChromeRowDivider()
                ChromeRow(title: "Section order", detail: "Whether Projects or Tasks comes first in the sidebar list") {
                    ChromeVisualPicker(options: SidebarSectionOrder.allCases.map { ($0, $0.title) }, selection: $settings.sidebarSectionOrder) { order in
                        Image(systemName: order == .projectsFirst ? "folder" : "checklist")
                    }
                }
            }
        }
    }
}

/// Font sizes use the same section and card spacing as the other settings.
private struct FontSizeSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        ChromeSection(
            title: "Fonts",
            trailing: AnyView(
                Button("Reset font sizes") { settings.resetFontSizes() }
                    .font(.ui(.body))
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(settings.isDefault)
            )
        ) {
            ChromeCard {
                ChromeRow(title: "Monospaced font", detail: "For code and the terminal. Installed font name; blank or unmatched uses the default.") {
                    TextField("Default", text: $settings.monospacedFontName)
                        .textFieldStyle(.chromeGlass)
                        .font(.ui(.subheadline))
                        .lineLimit(1)
                        .accessibilityLabel(Text("Monospaced font"))
                        .accessibilityIdentifier("monospacedFontName")
                        .frame(width: 220)
                }
                ChromeRowDivider()
                ChromeRow(title: "Interface font size", detail: "Adjust OMP GUI's base font size") {
                    FontSizeButtons(value: $settings.uiFontSize, range: TypeScale.uiRange)
                }
                ChromeRowDivider()
                ChromeRow(title: "Content font size", detail: "Adjust the base font size of conversations") {
                    FontSizeButtons(value: $settings.contentFontSize, range: TypeScale.contentRange)
                }
                ChromeRowDivider()
                ChromeRow(title: "Code font size", detail: "Adjust the base font size of code in chat and diff views") {
                    FontSizeButtons(value: $settings.codeFontSize, range: TypeScale.codeRange)
                }
            }
        }
    }
}

/// The syntax palette shared by chat, source views and the Markdown preview.
private struct CodeHighlightingSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        ChromeSection(title: "Code highlighting") {
            ChromeCard {
                ChromeRow(
                    title: "Theme",
                    detail: "The palette for syntax in chat, source views and the Markdown preview. Follows light and dark appearance."
                ) {
                    Picker("Code highlighting", selection: $settings.codeHighlightTheme) {
                        ForEach(CodeHighlightTheme.allCases) { theme in
                            Text(verbatim: Chrome.localized(theme.title)).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel(Text(verbatim: Chrome.localized("Code highlighting")))
                    .accessibilityIdentifier("codeHighlightTheme")
                }
            }
        }
    }
}

private struct FontSizeButtons: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 8) {
            ChromeIconButton(symbol: "minus", isEnabled: value > range.lowerBound, help: "Decrease Font Size") {
                value = TypeScale.clamp(value - 1, to: range)
            }

            Text(verbatim: "\(value) pt")
                .font(Font.ui(size: 12).monospacedDigit())
                .frame(width: 56)
                .help(Text(verbatim: "\(range.lowerBound)–\(range.upperBound)"))

            ChromeIconButton(symbol: "plus", isEnabled: value < range.upperBound, help: "Increase Font Size") {
                value = TypeScale.clamp(value + 1, to: range)
            }
        }
    }
}

/// Clear glass on the left, a solid base on the right, the stock look in the middle,
/// with a reset that shows only once the slider has left the stock look.
private struct BackdropOpacitySlider: View {
    @Binding var value: Double

    private var isOffStock: Bool { abs(value - AppSettings.defaultBackdropOpacity) >= 0.005 }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dotted")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .help("Transparent")
            Slider(value: $value, in: 0...1)
                .controlSize(.small)
                .frame(width: 140)
            Image(systemName: "circle.fill")
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .help("Solid")
        }
        // The reset takes no room in the row, so the slider ends flush with the card's
        // other controls whether or not it shows; it fades in to the slider's left once
        // the value has left the stock look.
        .overlay(alignment: .leading) {
            if isOffStock {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { value = AppSettings.defaultBackdropOpacity }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.ui(.subheadline, weight: .medium))
                        .foregroundStyle(Chrome.secondaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Back to the stock look")
                .offset(x: -28)
                .transition(.opacity.combined(with: .offset(x: 6)))
            }
        }
        .animation(.snappy(duration: 0.2), value: isOffStock)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Window transparency"))
    }
}

private struct ProvidersRefreshButton: View {
    @Environment(AppModel.self) private var model

    private var busy: Bool { model.providers.isRefreshing || model.omp.isLoading || model.providers.subscriptionUsage.isLoading }

    var body: some View {
        ChromeCapsule {
            ChromeIconButton(
                symbol: "arrow.clockwise",
                isEnabled: !busy,
                help: busy ? "Checking providers…" : "Check providers again"
            ) {
                Task {
                    model.providers.subscriptionUsage.invalidate()
                    await model.omp.refresh(force: true)
                    await model.providers.refreshEverything()
                    await model.providers.subscriptionUsage.refresh()
                }
            }
        }
    }
}

/// Native configuration, provider authentication and compact read-only usage.
private struct ProvidersSettingsPage: View {
    var body: some View { OMPSettingsPage() }
}

private struct SourceControlSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        GitHubSettingsSection()
        ChromeSection(title: "Text generation") {
            ChromeCard {
                ChromeRow(
                    title: "Thread titles and commit messages",
                    detail: "Uses OMP and its native model configuration."
                ) {
                    GlassPickerButton(options: TextGenerationChoice.allCases.map { ($0, $0.title) }, selection: $settings.textGeneration, asset: { ProviderKind(rawValue: $0.rawValue)?.iconName })
                }
            }
        }
        ChromeSection(title: "Commit message instructions") {
            ChromeCard {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $settings.commitInstructions)
                        .font(.ui(.body))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 90)
                    if settings.commitInstructions.isEmpty {
                        Text("For example: use conventional commit prefixes")
                            .font(.ui(.body))
                            .foregroundStyle(Chrome.secondaryText)
                            .padding(.horizontal, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(12)
                .chromeGlassInputSurface()
            }
        }
        ChromeSection(title: "Worktrees and pull requests") {
            ChromeCard {
                ChromeRow(title: "Worktrees", detail: Storage.worktreesDirectory.path) {
                    Button("Reveal") { Workspace.revealInFinder(Storage.worktreesDirectory.path) }
                        .buttonStyle(.glass)
                }
                ChromeRowDivider()
                ChromeRow(title: "Pull requests", detail: "Opened with the GitHub CLI (gh) or GitLab CLI (glab) from your PATH.") {
                    EmptyView()
                }
            }
        }
    }
}

/// Clears the whole archive from the page's chrome row, asking first the way a single
/// delete does when the setting is on. The question hangs off the button as a popover,
/// like the sidebar's delete menu, rather than a sheet over the whole window.
private struct ArchiveDeleteAllButton: View {
    @Environment(AppModel.self) private var model
    let threadIDs: Set<UUID>
    let isFiltered: Bool
    @State private var isConfirming = false
    @State private var pendingIDs: Set<UUID> = []
    @State private var pendingIsFiltered = false

    var body: some View {
        ChromeTextButton(
            symbol: "trash",
            title: String(format: Chrome.localized(isFiltered ? "Delete matching chats (%lld)" : "Delete all archived chats (%lld)"), threadIDs.count),
            help: isFiltered ? "Delete matching archived chats" : "Delete every archived thread",
            isEnabled: !threadIDs.isEmpty,
            isDestructive: true
        ) {
            if model.settings.confirmBeforeDeleting {
                pendingIDs = threadIDs
                pendingIsFiltered = isFiltered
                isConfirming = true
            } else {
                model.deleteArchivedThreads(ids: threadIDs)
            }
        }
        .chromePopover(isPresented: $isConfirming, arrowEdge: .bottom) {
            PopoverMenu {
                PopoverSectionHeader(pendingIsFiltered ? "Delete matching archived chats?" : "Delete all archived threads?")
                PopoverNote(String(format: Chrome.localized(pendingIsFiltered
                    ? "The histories of the %lld matching chats will be removed. Files in your projects stay as they are."
                    : "The histories of all %lld threads will be removed. Files in your projects stay as they are."), pendingIDs.count))
                PopoverDivider()
                PopoverItem(String(format: Chrome.localized("Delete %lld threads"), pendingIDs.count), symbol: "trash", isDestructive: true) {
                    model.deleteArchivedThreads(ids: pendingIDs)
                    isConfirming = false
                }
            }
        }
    }
}

/// What the archive page shows: lifted into the settings scroll so the chrome row's search
/// field and Delete all act on the same rows as the page.
/// The archive page's chrome row: its search field and Delete all, which deletes what is shown.
private struct ArchiveChromeControls: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: ArchiveFilter

    var body: some View {
        let archived = model.archivedThreads
        let known = Set(ArchiveFilter.projects(in: archived, from: model.projects).map(\.id))
        ChromeSearchField(query: $filter.query, prompt: "Search archived chats")
        ArchiveDeleteAllButton(threadIDs: Set(filter.apply(to: archived, known: known).map(\.id)), isFiltered: filter.isActive)
    }
}

private struct ArchiveSettingsPage: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: ArchiveFilter
    @State private var pendingDeletion: ArchiveRow?

    private struct ArchiveRow: Identifiable {
        let thread: ChatThread
        let title: String
        var id: UUID { thread.id }
    }

    private struct ArchiveGroup: Identifiable {
        let id: ArchiveFilter.ProjectScope
        let title: String
        let rows: [ArchiveRow]
    }

    var body: some View {
        let archived = model.archivedThreads
        let projects = ArchiveFilter.projects(in: archived, from: model.projects)
        let known = Set(projects.map(\.id))
        let options: [(value: ArchiveFilter.ProjectScope, title: String)] = [(.all, "All projects")]
            + projects.map { (.project($0.id), $0.name) } + [(.none, "No project")]
        let rows = filter.apply(to: archived, known: known).map { thread in
            let title: String
            if let info = thread.hydra, !info.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                title = "\(info.persona.name) · \(info.task)"
            } else {
                title = thread.title
            }
            return ArchiveRow(thread: thread, title: title)
        }
        let grouped = Dictionary(grouping: rows) { ArchiveFilter.scope(of: $0.thread, known: known) }
        let groups = options.filter { $0.value != .all }.compactMap { option -> ArchiveGroup? in
            guard let rows = grouped[option.value], !rows.isEmpty else { return nil }
            return ArchiveGroup(id: option.value, title: option.title, rows: rows)
        }
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            HStack(spacing: 8) {
                GlassPickerButton(options: ArchiveFilter.ChatType.allCases.map { ($0, $0.title) }, selection: $filter.chatType)
                    .accessibilityLabel(Text("Chat type"))
                GlassPickerButton(options: options, selection: $filter.project, symbol: { _ in "folder" })
                    .accessibilityLabel(Text("Project"))
            }
            if groups.isEmpty {
                Text("No matching chats")
                    .font(.ui(.body))
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Chrome.sectionSpacing)
            }
            ForEach(groups) { group in
                ChromeSection(
                    title: group.title,
                    trailing: AnyView(Text(verbatim: String(format: Chrome.localized("%lld chats"), group.rows.count))
                        .font(.ui(.body))
                        .foregroundStyle(Chrome.secondaryText))
                ) {
                    ChromeCard(lazy: true) {
                        ForEach(group.rows) { row in
                            if row.id != group.rows.first?.id { ChromeRowDivider() }
                            ChromeRow(title: row.title) {
                                HStack(spacing: 8) {
                                    Button("Restore") { model.unarchive(row.id) }
                                        .buttonStyle(.glass)
                                    Button("Delete", role: .destructive) {
                                        if model.settings.confirmBeforeDeleting {
                                            pendingDeletion = row
                                        } else {
                                            model.delete(row.id)
                                        }
                                    }
                                    .buttonStyle(.glass)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            pendingDeletion.map { String(format: Chrome.localized("Delete \"%@\"?"), $0.title) } ?? Chrome.localized("Delete the archived thread?"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { row in
            Button("Delete thread", role: .destructive) {
                model.delete(row.id)
                pendingDeletion = nil
            }
        } message: { _ in
            Text("Its history will be removed. Files in your project stay as they are.")
        }
    }
}

private struct AboutSettingsPage: View {
    private static let upstreamURL = URL(string: "https://getdroppycode.app")!

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            AboutSoftwareUpdateSection()
            appCard
            ChromeSection(title: "Credits") {
                ChromeCard {
                    UpstreamAttributionRow(url: Self.upstreamURL)
                    ChromeRowDivider()
                    ChromeRow(title: "Working indicators", detail: "Ported from Zeron by Wing, MIT License.") {
                        CreditLink(title: "zeronsh/zeron", url: URL(string: "https://github.com/zeronsh/zeron")!)
                    }
                    ChromeRowDivider()
                    ChromeRow(title: "Terminal", detail: "SwiftTerm by Miguel de Icaza, MIT License.") {
                        CreditLink(title: "SwiftTerm", url: URL(string: "https://github.com/migueldeicaza/SwiftTerm")!)
                    }
                    ChromeRowDivider()
                    LicensesRow()
                }
            }
        }
    }

    private var appCard: some View {
        ChromeCard {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("OMP GUI")
                        .font(.ui(.title3, weight: .semibold))
                    Text(verbatim: String(format: Chrome.localized("Version %@ (%@)"), AppInfo.version, AppInfo.build))
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                }
                Spacer()
            }
            .padding(16)
            ChromeRowDivider()
            Text("A native OMP interface, forked from Tivano. Based on Droppy Code by Jordy Spruit (Droppy).")
                .font(.ui(.body))
                .padding(.leading, 16)
                .padding(.trailing, Chrome.rowControlTrailingPadding)
                .padding(.vertical, 11)
            ChromeRowDivider()
            Text("OMP GUI is licensed under the GNU AGPL v3.0 with attribution terms; SwiftTerm is MIT licensed.")
                .font(.ui(.callout))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.leading, 16)
                .padding(.trailing, Chrome.rowControlTrailingPadding)
                .padding(.vertical, 11)
        }
    }
}

/// The license, the third-party notices and the trademark policy, as shipped in the bundle,
/// read in a popover: every copy of the app carries the notices for what it builds on.
private struct LicensesRow: View {
    @State private var isPresented = false

    private static let files: [(title: String, resource: String)] = [
        ("OMP GUI", "LICENSE"),
        ("Third-party notices", "THIRD_PARTY_NOTICES"),
        ("Trademarks", "TRADEMARK"),
    ]

    var body: some View {
        ChromeRow(title: "Licenses", detail: "AGPL-3.0 with attribution terms, and the notices for what the app builds on.") {
            Button("Show") { isPresented = true }
                .buttonStyle(.glass)
                .controlSize(.small)
                .chromePopover(isPresented: $isPresented, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Self.files, id: \.resource) { file in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(verbatim: Chrome.localized(file.title))
                                        .font(.ui(.body, weight: .semibold))
                                    MarkdownView(text: Self.text(of: file.resource)).equatable()
                                        .environment(\.markdownPointSize, TypeScale.shared.content(12))
                                        .foregroundStyle(Chrome.secondaryText)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 480, height: 440)
                    .presentedChrome()
                }
        }
    }

    /// Read from the bundle once: the popover's body runs on every hover and scroll, and
    /// the markdown it now renders is parsed from this text each time as it is.
    private static let texts: [String: String] = Dictionary(uniqueKeysWithValues: files.map { file in
        let url = Bundle.main.url(forResource: file.resource, withExtension: file.resource == "LICENSE" ? nil : "md")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? String(format: Chrome.localized("The %@ file is missing from this copy of the app."), file.resource)
        return (file.resource, text)
    })

    private static func text(of resource: String) -> String {
        texts[resource] ?? String(format: Chrome.localized("The %@ file is missing from this copy of the app."), resource)
    }
}

/// The upstream project, named and linked: the license keeps the credit for Droppy Code
/// with its author, so the fork's About page carries it.
private struct UpstreamAttributionRow: View {
    let url: URL
    @State private var isHovering = false

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Based on Droppy Code")
                        .font(.ui(.body, weight: .semibold))
                        .foregroundStyle(Chrome.primaryText)
                    Text("Droppy Code by Jordy Spruit (Droppy)")
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                }
                Spacer(minLength: 12)
                HStack(spacing: 4) {
                    Text(verbatim: "getdroppycode.app")
                    Image(systemName: "arrow.up.right")
                        .font(.ui(.footnote, weight: .semibold))
                }
                .font(.ui(.callout, weight: .medium))
                .foregroundStyle(Chrome.accent)
                .opacity(isHovering ? 1 : 0.9)
            }
            .padding(.leading, 16)
            .padding(.trailing, Chrome.rowControlTrailingPadding + 4)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .help("Open getdroppycode.app")
        .accessibilityLabel(Text("Based on Droppy Code by Jordy Spruit. Open getdroppycode.app"))
    }
}

private struct CreditLink: View {
    let title: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 4) {
                Text(verbatim: title)
                Image(systemName: "arrow.up.right")
                    .font(.ui(.footnote, weight: .semibold))
            }
            .font(.ui(.callout, weight: .medium))
            .foregroundStyle(Chrome.accent)
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}

/// The per-project marks behind one button: the Projects card stays two rows long, and the
/// list of projects with their marks opens in a popover off this row.
private struct ProjectMarksRow: View {
    @Environment(AppModel.self) private var model

    @State private var isPresented = false

    var body: some View {
        Button("Edit") { isPresented = true }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(model.projects.isEmpty)
            .help("Choose a mark for each project")
            .chromePopover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.projects.enumerated()), id: \.element.id) { index, project in
                        if index > 0 { ChromeRowDivider() }
                        ChromeRow(title: project.name, detail: project.path) {
                            ProjectIconButton(icon: icon(for: project.id))
                        }
                    }
                }
                .frame(width: 400)
            }
    }

    private func icon(for id: UUID) -> Binding<ProjectIcon?> {
        Binding(
            get: { model.project(id)?.icon },
            set: { newIcon in model.updateProject(id) { $0.icon = newIcon } }
        )
    }
}

/// The theme menu: Breeze (Tivano's own) and System on top, then the dark and the
/// light themes in their own sections, each with a swatch of its surface and accent.
/// Breeze Dark and Breeze Light lead their sections.
private struct ThemePickerButton: View {
    @Binding var selection: AppTheme

    @State private var isPresented = false
    @State private var isHovering = false

    private static let dark = AppTheme.allCases.filter { $0.scheme == .dark }
    private static let light = AppTheme.allCases.filter { $0.scheme == .light }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                selection.swatch
                    .frame(width: 14, height: 14)
                Text(verbatim: Chrome.localized(selection.displayName))
                    .font(.ui(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .foregroundStyle(Chrome.primaryText.opacity(isHovering || isPresented ? 1 : 0.92))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .chromeGlassCapsule()
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
        .chromePopover(isPresented: $isPresented, arrowEdge: .bottom) {
            PopoverMenu {
                item(.breeze)
                item(.system)
                PopoverSectionHeader("Dark")
                ForEach(Self.dark) { item($0) }
                PopoverSectionHeader("Light")
                ForEach(Self.light) { item($0) }
            }
        }
    }

    private func item(_ theme: AppTheme) -> some View {
        PopoverItem(theme.displayName, leading: AnyView(theme.swatch), isChecked: theme == selection) {
            selection = theme
        }
    }
}
