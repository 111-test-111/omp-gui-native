import AppKit
import SwiftUI

struct FilePreviewPane: View {
    @Environment(AppModel.self) private var model
    let store: FilePreviewStore
    var browsesFiles = false
    var isPresented = true
    @State private var diff = FilePreviewDiffState()

    private var showsBrowser: Bool { browsesFiles || store.showsBrowser }
    private var diffRequest: FilePreviewDiffRequest? {
        guard isPresented, store.isVisible, store.isWindowPresented, store.isWorkspacePresented,
              !showsBrowser, store.isFileReaderSelected,
              let tab = store.selectedTab, let snapshot = store.snapshot, snapshot.url == tab.url,
              snapshot.kind == .text || snapshot.kind == .markdown else { return nil }
        return FilePreviewDiffRequest(url: tab.url, context: tab.origin,
                                      revision: snapshot.revision + "#\(store.renderRevision)#\(diff.refreshRevision)",
                                      showsDiff: tab.reader.showsDiff)
    }
    private var canShowDiff: Bool {
        guard let request = diffRequest else { return false }
        return diff.request?.url == request.url && diff.request?.context == request.context && diff.location != nil
    }
    private var showsDiff: Bool { canShowDiff && store.selectedTab?.reader.showsDiff == true }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let threadID = store.context?.threadID,
               let shared = model.runtime(for: threadID).explicitFileContext {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble")
                    Text("Shared with OMP")
                    Text(verbatim: shared.reference).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 0)
                    Button { model.runtime(for: threadID).setExplicitFileContext(nil) } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help(Text("Clear shared file context"))
                    .accessibilityLabel(Text("Clear shared file context"))
                }
                .font(.ui(.caption))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Chrome.overlay(0.035))
                .help(Text(verbatim: shared.promptText))
            }
            if let notice = store.notice {
                HStack(alignment: .top) {
                    Text(verbatim: notice).font(.ui(.caption)).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button { store.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help(Text("Dismiss"))
                }
                .padding(10)
                .background(Chrome.overlay(0.05))
            }
            if showsBrowser, let context = store.context, let browser = store.session?.browser {
                PreviewFileBrowser(store: store, context: context, browser: browser, isPresented: isPresented)
            } else {
                reader
            }
            if let tab = store.selectedTab, !showsBrowser {
                HStack(spacing: 8) {
                    Text(verbatim: tab.url.path)
                        .lineLimit(1).truncationMode(.head)
                        .help(Text(verbatim: tab.url.path))
                    Spacer(minLength: 4)
                    if let snapshot = store.snapshot {
                        Text(verbatim: snapshot.byteCount.formatted(.byteCount(style: .file)))
                    }
                }
                .font(.ui(.caption2))
                .foregroundStyle(Chrome.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Chrome.overlay(0.025))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { NoWindowDragArea() }
        .task(id: diffRequest, priority: .userInitiated) {
            let request = diffRequest
            await diff.update(request)
            if !Task.isCancelled, let request, request.showsDiff, diff.location == nil,
               diff.error == nil, store.selectedTab?.url == request.url {
                store.selectedTab?.reader.showsDiff = false
                store.scheduleSave()
            }
        }
        .onDisappear { diff.suspend() }
    }

    @ViewBuilder private var toolbar: some View {
        if showsBrowser, let context = store.context, let browser = store.session?.browser {
            browserToolbar(context: context, browser: browser)
        } else {
            previewToolbar
        }
    }

    private func browserToolbar(context: FilePreviewContext, browser: PreviewBrowserState) -> some View {
        let root = URL(fileURLWithPath: context.workingDirectory, isDirectory: true)
        let directory = store.browserDirectory ?? root
        return HStack(spacing: 8) {
            ChromeCapsule {
                ChromeIconButton(symbol: "arrow.up", help: "Parent folder") { store.browserDirectory = directory.deletingLastPathComponent() }
                ChromeIconButton(symbol: "house", help: "Workspace root") { store.browserDirectory = root }
                browserDirectoryLabel(directory)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)
            ChromeCapsule {
                ChromeIconButton(symbol: "eye", isActive: browser.showsHidden, help: "Show hidden and ignored files") { browser.showsHidden.toggle() }
            }
            ChromeCapsule {
                ChromeIconButton(symbol: "plus.square.on.square", help: "Open files in preview") { store.chooseFiles(in: store.window) }
                ChromeIconButton(symbol: "arrow.up.right.square", help: "Show in Finder") { NSWorkspace.shared.open(directory) }
                previewActions
            }
        }
        .padding(Chrome.workspaceToolbarInsets)
    }

    private func browserDirectoryLabel(_ directory: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(Chrome.iconFont)
                .fixedSize()
            Text(verbatim: directory.lastPathComponent)
                .font(.ui(.callout, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Chrome.secondaryText)
        .padding(.horizontal, 6)
        .frame(height: Chrome.capsuleContentHeight)
        .help(Text(verbatim: directory.path))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: directory.path))
        .layoutPriority(-1)
    }

    private var previewToolbar: some View {
        HStack(spacing: 8) {
            ChromeCapsule {
                ChromeIconButton(symbol: "folder", isActive: showsBrowser, help: "Browse workspace files") { store.showFiles() }
                    .animation(Chrome.hover, value: showsBrowser)
                ChromeIconButton(symbol: "plus.square.on.square", help: "Open files in preview") { store.chooseFiles(in: store.window) }
            }
            Spacer(minLength: 0)
            if let tab = store.selectedTab, let snapshot = store.snapshot, !showsBrowser {
                if snapshot.kind == .markdown || canShowDiff {
                    ViewThatFits(in: .horizontal) {
                        ChromeCapsule {
                            if snapshot.kind == .markdown {
                                ChromeIconButton(symbol: "doc.richtext", isActive: !showsDiff && !tab.reader.showsSource,
                                                 help: "Show rendered preview") { setMode(tab, source: false) }
                            }
                            ChromeIconButton(symbol: "chevron.left.forwardslash.chevron.right", isActive: !showsDiff && (snapshot.kind == .text || tab.reader.showsSource),
                                             help: "Show source") { setMode(tab, source: true) }
                            if canShowDiff {
                                ChromeIconButton(symbol: "plus.forwardslash.minus", isActive: showsDiff, help: "Show file diff") { setMode(tab, diff: true) }
                            }
                        }
                        .fixedSize()
                        ChromeCapsule {
                            ChromeMenuButton(symbol: showsDiff ? "plus.forwardslash.minus" : "chevron.left.forwardslash.chevron.right", help: "Preview mode") {
                                if snapshot.kind == .markdown {
                                    PopoverItem("Show rendered preview", symbol: "doc.richtext", isChecked: !showsDiff && !tab.reader.showsSource) { setMode(tab, source: false) }
                                }
                                PopoverItem("Show source", symbol: "chevron.left.forwardslash.chevron.right", isChecked: !showsDiff && (snapshot.kind == .text || tab.reader.showsSource)) { setMode(tab, source: true) }
                                if canShowDiff {
                                    PopoverItem("Show file diff", symbol: "plus.forwardslash.minus", isChecked: showsDiff) { setMode(tab, diff: true) }
                                }
                            }
                        }
                        .fixedSize()
                    }
                }
                if !showsDiff {
                    ChromeCapsule {
                        if snapshot.kind == .text || snapshot.kind == .markdown {
                            ChromeIconButton(symbol: "text.word.spacing", isActive: tab.reader.wrapsLines, help: "Wrap source lines") {
                                tab.reader.wrapsLines.toggle(); store.scheduleSave()
                            }
                            .animation(Chrome.hover, value: tab.reader.wrapsLines)
                        }
                        if snapshot.kind == .text || snapshot.kind == .markdown || snapshot.kind == .pdf {
                            ChromeIconButton(symbol: "magnifyingglass", help: "Find in preview") { store.find() }
                        }
                    }
                }
            }
            ChromeCapsule {
                previewActions
            }
        }
        .padding(Chrome.workspaceToolbarInsets)
    }

    private func setMode(_ tab: PreviewTab, source: Bool? = nil, diff: Bool = false) {
        if let source { tab.reader.showsSource = source }
        tab.reader.showsDiff = diff
        store.scheduleSave()
    }

    private var previewActions: some View {
        ChromeMenuButton(symbol: "ellipsis", help: "Preview actions") {
            if let tab = store.selectedTab, !showsBrowser {
                PopoverItem("Add file location to question", symbol: "text.bubble") { addContext(includingSelection: false) }
                if store.snapshot?.text != nil {
                    PopoverItem("Add selected source text to question", symbol: "text.quote") { addContext(includingSelection: true) }
                }
                PopoverDivider()
                PopoverItem("Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([tab.url]) }
                PopoverItem("Open externally", symbol: "arrow.up.right.square") { NSWorkspace.shared.open(tab.url) }
                PopoverItem("Copy file path", symbol: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tab.url.path, forType: .string)
                }
                PopoverDivider()
            }
            if let threadID = store.context?.threadID, model.runtime(for: threadID).explicitFileContext != nil {
                PopoverItem("Clear shared file context", symbol: "text.badge.xmark") {
                    model.runtime(for: threadID).setExplicitFileContext(nil)
                }
                PopoverDivider()
            }
            PopoverItem("Refresh preview", symbol: "arrow.clockwise") { store.refresh() }
            PopoverItem("Close all preview tabs", symbol: "xmark") { store.closeAll() }
        }
    }

    private func addContext(includingSelection: Bool) {
        guard let context = store.questionContext(includingSelection: includingSelection) else { return }
        // The open file may have come from a head in another worktree. Quote it
        // into this pane's conversation while retaining its original owner.
        guard let target = store.context?.threadID else { return }
        model.runtime(for: target).addFileContextToDraft(context)
    }

    @ViewBuilder private var reader: some View {
        if showsDiff {
            FilePreviewDiffView(state: diff)
        } else if let tab = store.selectedTab {
            if let snapshot = store.snapshot,
               let readerTab = snapshot.url == tab.url ? tab : (store.isLoading && snapshot.kind == .markdown
                    ? store.session?.tabs.first { $0.url == snapshot.url } : nil) {
                FilePreviewContent(url: snapshot.url, kind: snapshot.kind, text: snapshot.text, revision: snapshot.revision + "#" + String(store.renderRevision),
                                   location: readerTab.location, state: readerTab.reader) { reference, directory in
                    store.open(reference, context: FilePreviewContext(threadID: readerTab.origin.threadID, workingDirectory: directory.path))
                }
                // A single visible Markdown view keeps its engine across tab changes.
                // The old tab/state stays attached until the next source is ready.
                .id(snapshot.kind == .markdown && !readerTab.reader.showsSource ? "markdown-document" : readerTab.id)
            } else if store.isLoading || store.hasPendingOpen {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 14) {
                    ContentUnavailableView("Cannot preview this file", systemImage: "doc.questionmark", description: Text(verbatim: store.error ?? Chrome.localized("This file has no available preview.")))
                    HStack {
                        Button("Try again") { store.refresh() }
                        Button("Open externally") { NSWorkspace.shared.open(tab.url) }
                    }
                    .buttonStyle(.glass)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if store.hasPendingOpen || store.isLoading {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 14) {
                ContentUnavailableView("File preview", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Open a file link, browse the workspace, or drop a file here."))
                Button("Browse workspace files") { store.showFiles() }.buttonStyle(.glass)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PreviewTabButton: View {
    let tab: PreviewTab
    let isSelected: Bool
    let store: FilePreviewStore

    var body: some View {
        let pointSize = TypeScale.shared.ui(TypeScale.stockPointSize(.body))
        HStack(spacing: 6) {
            Button { store.select(tab.id) } label: {
                HStack(spacing: 6) {
                    Image(nsImage: FileIcons.icon(for: tab.url.path))
                        .resizable().scaledToFit().frame(width: pointSize, height: pointSize)
                    Text(verbatim: tab.url.lastPathComponent)
                        .font(.ui(.body))
                        .lineLimit(1)
                }
                .frame(height: 28).contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button { store.closeSidebarTab(.file(tab.id)) } label: {
                Image(systemName: "xmark").font(.symbol(.caption2, weight: .semibold))
                    .frame(width: 20, height: 20).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text("Close preview tab"))
            .accessibilityLabel(Text("Close preview tab"))
        }
        .padding(.leading, 9)
        .padding(.trailing, 3)
        .frame(height: 28)
        .frame(maxWidth: 230)
        .foregroundStyle(isSelected ? Chrome.primaryText : Chrome.secondaryText)
        .background(Chrome.overlay(isSelected ? 0.09 : 0), in: .rect(cornerRadius: 7))
        .animation(Chrome.hover, value: isSelected)
        .contentShape(.rect)
        .contextMenu {
            Button("Close sidebar tab") { store.closeSidebarTab(.file(tab.id)) }
            Button("Close other sidebar tabs") { store.closeOtherSidebarTabs(.file(tab.id)) }
            Button("Close all sidebar tabs") { store.closeAllSidebarTabs() }
        }
        .help(Text(verbatim: tab.url.path))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PreviewFileBrowser: View {
    let store: FilePreviewStore
    let context: FilePreviewContext
    let browser: PreviewBrowserState
    let isPresented: Bool
    @State private var listing: PreviewDirectoryListing?
    @State private var listingKey: String?
    @State private var error: String?
    @State private var errorKey: String?

    private var showsHidden: Bool { browser.showsHidden }

    private var root: URL { URL(fileURLWithPath: context.workingDirectory, isDirectory: true) }
    private var directory: URL { store.browserDirectory ?? root }
    private var metadataKey: String { directory.path + "\n" + String(showsHidden) + "\n" }
    private var loadKey: String { metadataKey + String(store.renderRevision) }
    private var displayedListing: PreviewDirectoryListing? {
        // A refresh can revalidate these rows without collapsing the retained
        // scroll document; changing the folder or hidden-file policy cannot.
        if listingKey?.hasPrefix(metadataKey) == true { return listing }
        return store.cachedDirectoryListing(at: directory, showHidden: showsHidden, context: context)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let listing = displayedListing {
                if listing.entries.isEmpty {
                    ContentUnavailableView("No files found", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(listing.entries) { entry in
                                PreviewBrowserEntry(entry: entry, depth: 0, showsHidden: showsHidden, store: store, context: context, browser: browser, isPresented: isPresented)
                            }
                            if listing.isTruncated {
                                Text("Some files are omitted")
                                    .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                            }
                        }
                        .padding(.horizontal, 8).padding(.bottom, 8)
                    }
                }
            } else if let error, errorKey == loadKey {
                ContentUnavailableView("Cannot read this folder", systemImage: "folder.badge.questionmark", description: Text(verbatim: error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .task(id: isPresented ? loadKey : nil, priority: .userInitiated) {
            guard isPresented else { return }
            let requestedKey = loadKey
            let requestedDirectory = directory
            let requestedHidden = showsHidden
            error = nil
            do {
                let result = try await PreviewDirectoryBrowser.list(requestedDirectory, showHidden: requestedHidden)
                guard !Task.isCancelled, loadKey == requestedKey, store.context == context else { return }
                listing = result
                listingKey = requestedKey
                store.rememberDirectoryListing(result, at: requestedDirectory, showHidden: requestedHidden, context: context)
            } catch {
                guard !Task.isCancelled, loadKey == requestedKey, store.context == context else { return }
                listing = nil
                listingKey = requestedKey
                self.error = error.localizedDescription
                errorKey = requestedKey
                store.forgetDirectoryListing(at: requestedDirectory)
            }
        }
    }
}

/// One row of the tree: files open in the preview, folders expand in place.
private struct PreviewBrowserEntry: View {
    let entry: PreviewDirectoryEntry
    /// Indentation level; folder children sit one level deeper than their row.
    let depth: Int
    let showsHidden: Bool
    let store: FilePreviewStore
    let context: FilePreviewContext
    let browser: PreviewBrowserState
    let isPresented: Bool

    /// Every depth indents this much; the disclosure chevron and its gap make a
    /// fixed gutter so file rows line up with folder labels at the same depth.
    private static let indent: CGFloat = 14
    static let gutter: CGFloat = 16

    var body: some View {
        if entry.isDirectory {
            PreviewBrowserFolder(entry: entry, depth: depth, showsHidden: showsHidden, store: store, context: context, browser: browser, isPresented: isPresented)
        } else {
            Button {
                store.open(FilePreviewReference(path: entry.url.path), context: context)
            } label: {
                HStack(spacing: 8) {
                    Image(nsImage: FileIcons.icon(for: entry.url.path)).resizable().scaledToFit().frame(width: 18, height: 18)
                    Text(verbatim: entry.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.ui(.callout))
                .padding(.leading, 8 + CGFloat(depth) * Self.indent + Self.gutter)
                .padding(.trailing, 8).padding(.vertical, 6)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            }
        }
    }

    /// The grid a row at `depth` sits on: rows use `leading` for their own
    /// chevron or gutter, children of an expanded folder pass `depth + 1`.
    static func leading(for depth: Int) -> CGFloat { 8 + CGFloat(depth) * indent }
}

/// A folder row with the stock disclosure behavior: expanding lists the folder
/// once, collapsing releases the rows. The listing is read on first expansion
/// and re-read when hidden files or a refresh change what counts as an entry.
private struct PreviewBrowserFolder: View {
    let entry: PreviewDirectoryEntry
    let depth: Int
    let showsHidden: Bool
    let store: FilePreviewStore
    let context: FilePreviewContext
    let browser: PreviewBrowserState
    let isPresented: Bool
    @State private var listing: PreviewDirectoryListing?
    @State private var listingKey: String?
    @State private var failed = false

    private var isExpanded: Bool { browser.expandedFolders.contains(entry.id) }
    private var expansion: Binding<Bool> {
        Binding(get: { isExpanded }, set: { expanded in
            if expanded { browser.expandedFolders.insert(entry.id) }
            else { browser.expandedFolders.remove(entry.id) }
        })
    }

    private var contentKey: String { String(showsHidden) + "\n" + String(store.renderRevision) }
    private var currentListing: PreviewDirectoryListing? {
        listingKey?.hasPrefix(String(showsHidden) + "\n") == true ? listing : nil
    }

    var body: some View {
        DisclosureGroup(isExpanded: expansion) {
            if let listing = currentListing {
                if listing.entries.isEmpty {
                    Text("No files found")
                        .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                        .padding(.leading, PreviewBrowserEntry.leading(for: depth + 1) + PreviewBrowserEntry.gutter)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(listing.entries) { child in
                    PreviewBrowserEntry(entry: child, depth: depth + 1, showsHidden: showsHidden, store: store, context: context, browser: browser, isPresented: isPresented)
                }
                if listing.isTruncated {
                    Text("Some files are omitted")
                        .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                        .padding(.leading, PreviewBrowserEntry.leading(for: depth + 1) + PreviewBrowserEntry.gutter)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if failed {
                Text("Cannot read this folder")
                    .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                    .padding(.leading, PreviewBrowserEntry.leading(for: depth + 1) + PreviewBrowserEntry.gutter)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView().controlSize(.small)
                    .padding(.leading, PreviewBrowserEntry.leading(for: depth + 1) + PreviewBrowserEntry.gutter)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            HStack(spacing: 8) {
                Image(nsImage: FileIcons.icon(for: entry.url.path)).resizable().scaledToFit().frame(width: 18, height: 18)
                Text(verbatim: entry.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .font(.ui(.callout))
        .disclosureGroupStyle(PreviewBrowserDisclosureStyle(depth: depth))
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        }
        .task(id: isPresented ? entry.id + "\n" + contentKey + "\n" + String(isExpanded) : nil) {
            guard isPresented, isExpanded, listingKey != contentKey else { return }
            let requestedKey = contentKey
            failed = false
            do {
                let result = try await PreviewDirectoryBrowser.list(entry.url, showHidden: showsHidden)
                guard !Task.isCancelled else { return }
                listing = result
                listingKey = requestedKey
            } catch {
                guard !Task.isCancelled else { return }
                listing = nil
                listingKey = requestedKey
                failed = true
            }
        }
    }
}

/// The stock disclosure interaction on the pane's row grid: a native-style
/// chevron button whose label is the folder row, children below it. Files and
/// folders share the grid, so rows at one depth line up.
private struct PreviewBrowserDisclosureStyle: DisclosureGroupStyle {
    let depth: Int

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.symbol(.caption2, weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 10)
                    configuration.label
                }
                .padding(.leading, PreviewBrowserEntry.leading(for: depth))
                .padding(.trailing, 8).padding(.vertical, 6)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
