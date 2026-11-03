import SwiftUI

/// Navigation rows are ordinary native surfaces; only the compact actions use glass.
struct BrowserHistoryLinkRow: View {
    let entry: BrowserHistoryEntry
    let history: BrowserHistoryStore
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                BrowserHistorySiteIcon(entry: entry, history: history, size: 18)
                    .frame(width: 30, height: 30)
                    .background(Chrome.overlay(0.04), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: entry.displayTitle)
                        .font(.ui(.callout)).foregroundStyle(Chrome.primaryText).lineLimit(1)
                    Text(verbatim: entry.host)
                        .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.symbol(.caption2)).foregroundStyle(Chrome.secondaryText)
                    .opacity(isHovering ? 1 : 0.45).accessibilityHidden(true)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(isHovering ? Chrome.overlay(0.04) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(entry.url)
        .accessibilityElement(children: .combine)
    }
}

struct BrowserHistoryRow: View {
    let entry: BrowserHistoryEntry
    let history: BrowserHistoryStore
    let open: () -> Void
    let remove: () -> Void
    @State private var isHovering = false
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Text(entry.visitedAt, format: .dateTime.hour().minute().locale(locale))
                        .font(.ui(.caption)).monospacedDigit().foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1)
                        .frame(width: 52, alignment: .leading)
                    BrowserHistorySiteIcon(entry: entry, history: history, size: 16)
                        .frame(width: 18)
                    Text(verbatim: entry.displayTitle)
                        .font(.ui(.callout)).foregroundStyle(Chrome.primaryText)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: entry.host)
                        .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 130, alignment: .leading)
                    if entry.source == .chrome {
                        Text("Chrome").font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                            .help(Text(verbatim: entry.sourceName))
                    }
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.url)
            .accessibilityElement(children: .combine)
            ChromeCircleMenuButton(symbol: "ellipsis", help: "History actions") {
                PopoverItem("Copy page address", symbol: "doc.on.doc") { copyAddress() }
                PopoverItem("Delete from history", symbol: "trash", isDestructive: true, action: remove)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 2)
        .background(isHovering ? Chrome.overlay(0.04) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy page address") { copyAddress() }
            Button("Delete from history", role: .destructive, action: remove)
        }
    }

    private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.url, forType: .string)
    }
}

struct BrowserRecentPages: View {
    let history: BrowserHistoryStore
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !history.recent.isEmpty {
                HStack {
                    Text("Recently opened")
                        .font(.ui(.subheadline, weight: .medium)).foregroundStyle(Chrome.secondaryText)
                    Spacer()
                    Button("Clear") { history.clearRecent() }
                        .buttonStyle(.glass).controlSize(.small)
                        .help(Text("Clear recent pages without deleting browsing history"))
                        .accessibilityLabel(Text("Clear recent pages"))
                        .accessibilityIdentifier("clearRecentBrowserPages")
                }
                .padding(.horizontal, 12)
                ForEach(history.recent) { entry in
                    BrowserHistoryLinkRow(entry: entry, history: history) { open(entry.url) }
                }
            }
            if let key = history.errorKey {
                Text(verbatim: BrowserLocalization.localized(key))
                    .font(.ui(.caption)).foregroundStyle(Chrome.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct BrowserHistorySiteIcon: View {
    let entry: BrowserHistoryEntry
    let history: BrowserHistoryStore
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .renderingMode(image.isTemplate ? .template : .original)
                    .resizable().scaledToFit()
            } else { Image(systemName: "globe").font(.symbol(size: size)) }
        }
        .foregroundStyle(Chrome.secondaryText)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: entry) {
            let loaded = await history.icon(for: entry)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
