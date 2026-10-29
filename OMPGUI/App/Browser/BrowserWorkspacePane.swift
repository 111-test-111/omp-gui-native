import AppKit
import SwiftUI

struct BrowserWorkspacePane: View {
    @Bindable var state: BrowserWorkspaceStore
    var searchEngine: BrowserSearchEngine = .google

    var body: some View {
        VStack(spacing: 0) {
            if !state.pages.isEmpty {
                HStack(spacing: 6) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(spacing: 4) {
                                ForEach(state.pages) { page in BrowserPageTab(page: page, state: state).id(page.id) }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: state.selectedID) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
                    }
                    ChromeCircleButton(symbol: "plus", help: "New browser tab") {
                        do { let page = try state.open(); page.addressFocus &+= 1 }
                        catch { state.error = error.localizedDescription }
                    }
                }
                .padding(Chrome.workspaceToolbarInsets)
            }
            if let page = state.selectedPage {
                BrowserPageToolbar(page: page).id(page.id)
                if let error = page.error ?? state.error {
                    browserMessage(error, symbol: "exclamationmark.triangle") {
                        state.error = nil; page.reload()
                    }
                }
                if let notice = page.notice {
                    browserMessage(notice, symbol: "info.circle") { page.notice = nil }
                }
                if page.dialog != nil { BrowserDialogBar(page: page) }
                BrowserPageSurface(page: page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Match CEF's opaque canvas before the native renderer is
                    // attached; replacing a tab must not flash the window below.
                    .background(Color.white)
                    .overlay {
                        if BrowserAddress.isBlankPage(page.url) {
                            BrowserNewTabPage(page: page, searchEngine: searchEngine)
                        }
                    }
                    .transaction { $0.animation = nil }
            } else {
                ContentUnavailableView {
                    Label("Browser", systemImage: "globe")
                } description: {
                    Text(verbatim: state.error ?? BrowserLocalization.localized("Open a browser tab to browse with OMP."))
                } actions: {
                    ChromeTextButton(symbol: "plus", title: "New browser tab", help: "New browser tab") { state.activate() }
                }
            }
        }
        .environment(\.locale, BrowserLocalization.locale)
        .environment(\.chromeLocalizationBundle, BrowserLocalization.bundle)
        .onAppear { state.activate() }
    }

    private func browserMessage(_ text: String, symbol: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Chrome.secondaryText)
            Text(verbatim: text).font(.ui(.caption)).lineLimit(4).textSelection(.enabled)
            Spacer(minLength: 0)
            ChromeCapsule {
                ChromeIconButton(symbol: symbol == "info.circle" ? "xmark" : "arrow.clockwise",
                                 help: symbol == "info.circle" ? "Dismiss" : "Reload browser tab", action: action)
            }
        }
        .padding(8)
    }
}

struct BrowserNewTabPage: View {
    @Bindable var page: BrowserPage
    let searchEngine: BrowserSearchEngine

    private var searchPrompt: String {
        String(format: BrowserLocalization.localized("Search with %@"), BrowserLocalization.localized(searchEngine.title))
    }

    var body: some View {
        VStack(spacing: 24) {
            BrowserMarkImage()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(Chrome.inlineIconFont)
                    .foregroundStyle(Chrome.secondaryText)
                    .accessibilityHidden(true)
                TextField(text: $page.searchText, prompt: Text(verbatim: searchPrompt)) {
                    Text("Search the web")
                }
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .font(.ui(.callout))
                .accessibilityLabel(Text("Search the web"))
                .onSubmit { page.search(page.searchText, using: searchEngine) }
                ChromeIconButton(symbol: "arrow.right", isEnabled: !page.searchText.trimmed.isEmpty, help: "Search the web") {
                    page.search(page.searchText, using: searchEngine)
                }
            }
            .padding(.leading, Chrome.capsuleHorizontalPadding)
            .padding(.trailing, 4)
            .frame(height: Chrome.capsuleHeight + 8)
            .chromeGlassFieldCapsule()
            .frame(maxWidth: 400)
            .background { NoWindowDragArea() }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct BrowserMarkImage: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image("provider-omp", bundle: BrowserLocalization.resources)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .padding(4)
                .foregroundStyle(Chrome.accent)
            Image(systemName: "globe")
                .font(.symbol(size: 14, weight: .medium))
                .foregroundStyle(Chrome.secondaryText)
                .frame(width: 20, height: 20)
                .background(Color(nsColor: .textBackgroundColor), in: Circle())
        }
        .frame(width: 56, height: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("OMP Browser"))
    }
}

private struct BrowserPageTab: View {
    let page: BrowserPage
    let state: BrowserWorkspaceStore
    @State private var isHovering = false
    private var isSelected: Bool { state.selectedID == page.id }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: page.dialog == nil ? "globe" : "bubble.left").font(.symbol(.caption))
            Text(verbatim: page.title).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
            Button { page.requestClose() } label: {
                Image(systemName: "xmark").font(.symbol(.caption2, weight: .bold))
                    .frame(width: 20)
                    .contentShape(Rectangle().inset(by: -6))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Chrome.secondaryText)
            .opacity(isHovering || isSelected ? 1 : 0)
            .allowsHitTesting(isHovering || isSelected)
            .help(Text("Close browser tab"))
            .accessibilityLabel(Text("Close browser tab"))
        }
        .font(.ui(.callout))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background(isSelected ? AnyShapeStyle(.primary.opacity(0.08)) : AnyShapeStyle(Color.clear), in: .capsule)
        .contentShape(.capsule)
        .onTapGesture { state.selectedID = page.id }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: page.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help(page.url)
        .contextMenu {
            Button("Close browser tab") { page.requestClose() }
            Button("Close other browser tabs") {
                for other in state.pages where other.id != page.id { other.requestClose() }
            }
            Button("Copy page address") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(page.url, forType: .string)
            }
        }
    }
}

private struct BrowserPageToolbar: View {
    @Bindable var page: BrowserPage
    @State private var address = ""
    @State private var showsDownloads = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ChromeCapsule {
                    ChromeIconButton(symbol: "chevron.left", isEnabled: page.model.canGoBack, help: "Back") { page.model.goBack() }
                    ChromeIconButton(symbol: "chevron.right", isEnabled: page.model.canGoForward, help: "Forward") { page.model.goForward() }
                    ChromeIconButton(symbol: page.isLoading ? "xmark" : "arrow.clockwise",
                                     help: page.isLoading ? "Stop loading page" : "Reload browser tab") {
                        if page.isLoading { page.model.stopLoading() } else { page.reload() }
                    }
                }
                TextField("Web address", text: $address)
                    .font(.ui(.callout)).textFieldStyle(.chromeGlass(height: Chrome.capsuleHeight))
                    .focused($addressFocused)
                    .onSubmit { page.navigate(address); addressFocused = false }
                    .onChange(of: page.url, initial: true) { _, url in if !addressFocused { address = url == "about:blank" ? "" : url } }
                    .onChange(of: page.addressFocus, initial: true) { _, request in if request > 0 { addressFocused = true } }
                    .accessibilityLabel(Text("Web address"))
                ChromeCircleMenuButton(symbol: "ellipsis", help: "Browser actions") {
                    PopoverItem("Find in page", symbol: "magnifyingglass") { page.showsFind.toggle() }
                    PopoverItem("Browser downloads", symbol: "arrow.down.circle") { showsDownloads = true }
                    PopoverDivider()
                    PopoverItem("Zoom in", symbol: "plus.magnifyingglass") { if let browser = page.model.browser { browser.zoomLevel = min(5, browser.zoomLevel + 0.5) } }
                    PopoverItem("Zoom out", symbol: "minus.magnifyingglass") { if let browser = page.model.browser { browser.zoomLevel = max(-3, browser.zoomLevel - 0.5) } }
                    PopoverItem("Reset zoom", symbol: "arrow.counterclockwise") { page.model.browser?.zoomLevel = 0 }
                    PopoverDivider()
                    PopoverItem("Copy page address", symbol: "doc.on.doc") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(page.url, forType: .string)
                    }
                    PopoverItem("Open in default browser", symbol: "arrow.up.forward.app") {
                        if let url = BrowserAddress.resolve(page.url), url.scheme != "about" { NSWorkspace.shared.open(url) }
                    }
                    PopoverItem("Developer tools", symbol: "curlybraces") { page.model.browser?.toggleDevTools() }
                }
                .popover(isPresented: $showsDownloads) { BrowserDownloads(page: page).padding(12).frame(width: 330) }
            }
            if page.showsFind {
                HStack(spacing: 6) {
                    TextField("Find in page", text: $page.findText).textFieldStyle(.chromeGlass)
                        .onSubmit { find(forward: true) }
                        .onChange(of: page.findText) { find(forward: true) }
                    ChromeCapsule {
                        ChromeIconButton(symbol: "chevron.up", help: "Previous match") { find(forward: false) }
                        ChromeIconButton(symbol: "chevron.down", help: "Next match") { find(forward: true) }
                        ChromeIconButton(symbol: "xmark", help: "Close find") {
                            page.showsFind = false; page.findText = ""; find(forward: true)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Chrome.workspaceToolbarInsets.leading)
        .padding(.bottom, Chrome.workspaceToolbarInsets.bottom)
        .overlay(alignment: .bottomLeading) {
            if page.isLoading {
                GeometryReader { geometry in
                    Rectangle().fill(Color.accentColor)
                        .frame(width: geometry.size.width * max(0.04, page.model.estimatedProgress), height: 2)
                }.frame(height: 2).accessibilityHidden(true)
            }
        }
    }

    private func find(forward: Bool) { page.model.browser?.find(page.findText, forward: forward, matchCase: false) }
}

private struct BrowserDialogBar: View {
    @Bindable var page: BrowserPage

    var body: some View {
        if let dialog = page.dialog {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: BrowserLocalization.localized(page.isBeforeUnload ? "Leave this page?" : "Message from this page")).font(.ui(.headline))
                Text(verbatim: URL(string: dialog.origin)?.host ?? dialog.origin).font(.ui(.caption)).lineLimit(1)
                ScrollView { Text(verbatim: dialog.message).font(.ui(.callout)).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 100)
                if dialog.kind == .prompt { TextField("Page response", text: $page.promptText).textFieldStyle(.chromeGlass) }
                HStack {
                    Spacer()
                    ChromeCapsule {
                        if dialog.kind != .alert {
                            ChromeTextButton(symbol: "xmark", title: page.isBeforeUnload ? "Stay" : "Cancel", help: "Dismiss page dialog") { page.answerDialog(false) }
                        }
                        ChromeTextButton(symbol: "checkmark", title: page.isBeforeUnload ? "Leave" : "OK", help: "Accept page dialog") { page.answerDialog(true) }
                    }
                }
            }
            .padding(12).background(Chrome.overlay(0.04))
        }
    }
}

private struct BrowserDownloads: View {
    let page: BrowserPage
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Browser downloads").font(.ui(.headline))
            if page.downloads.isEmpty { Text("No downloads in this tab.").font(.ui(.callout)).foregroundStyle(Chrome.secondaryText) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(page.downloads.reversed(), id: \.id) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: item.fullPath?.lastPathComponent ?? item.url?.lastPathComponent ?? "").lineLimit(1)
                                Text(verbatim: ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file))
                                    .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                                if let error = page.downloadErrors[item.id] {
                                    Text(verbatim: error).font(.ui(.caption)).foregroundStyle(Chrome.danger)
                                } else if item.isCanceled { Text("Download interrupted").font(.ui(.caption)) }
                                else if !item.isComplete { ProgressView(value: Double(item.receivedBytes), total: Double(max(item.totalBytes, item.receivedBytes + 1))) }
                            }
                            Spacer()
                            if item.isComplete, page.downloadErrors[item.id] == nil, let url = item.fullPath {
                                ChromeCapsule { ChromeIconButton(symbol: "folder", help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                            }
                        }
                    }
                }
            }.frame(maxHeight: 280)
        }
    }
}

private struct BrowserPageSurface: NSViewRepresentable {
    let page: BrowserPage
    func makeNSView(context: Context) -> BrowserSurfaceView { BrowserSurfaceView() }
    func updateNSView(_ view: BrowserSurfaceView, context: Context) {
        if view.page !== page { view.page?.isPresented = false }
        for host in view.subviews where host !== page.host { EmbeddedBrowserRuntime.shared.park(host) }
        do { try page.materialize() }
        catch { Task { @MainActor in page.error = error.localizedDescription }; return }
        view.page = page
        view.presentPage()
    }
    static func dismantleNSView(_ view: BrowserSurfaceView, coordinator: ()) {
        if view.page?.host?.superview === view { view.page?.isPresented = false }
        for host in view.subviews { EmbeddedBrowserRuntime.shared.park(host) }
        view.stopObserving()
    }
}

private final class BrowserSurfaceView: NSView {
    weak var page: BrowserPage?
    private var focusObserver: NSObjectProtocol?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentPage() }
        }
        presentPage()
    }
    func presentPage() {
        guard let window, let page, let host = page.host else { return }
        // A background window's observable updates must not steal a native
        // browser from the foreground presentation of the same conversation.
        if let previous = host.superview as? BrowserSurfaceView, previous !== self {
            guard window.isKeyWindow else { return }
            previous.page?.isPresented = false
        }
        if host.superview !== self {
            host.removeFromSuperview()
            host.frame = bounds; host.autoresizingMask = [.width, .height]
            addSubview(host)
        }
        host.frame = bounds; host.isHidden = false
        page.isPresented = true
    }
    func stopObserving() {
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
    }
    isolated deinit { stopObserving() }
    override func layout() { super.layout(); for view in subviews { view.frame = bounds } }
}
