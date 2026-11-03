import SwiftUI

struct BrowserHistorySection: View {
    var history: BrowserHistoryStore = .shared
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale
    @State private var list = BrowserHistoryListStore()
    @State private var clearRange: BrowserHistoryRange = .all
    @State private var showsClearConfirmation = false
    @State private var showsImport = false

    private struct Query: Equatable {
        let revision: Int
        let page: Int
        let layout: BrowserHistoryPageLayout
    }

    var body: some View {
        let layout = BrowserHistoryPageLayout()
        ChromeSection(title: "Browsing history", trailing: AnyView(historyControls)) {
            ChromeCard {
                if let key = list.errorKey ?? history.errorKey {
                    HStack(spacing: 12) {
                        Text(verbatim: Chrome.localized(key))
                            .font(.ui(.subheadline)).foregroundStyle(Chrome.danger)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Retry") { Task { await history.loadRecent(); await list.refresh(history: history) } }
                            .buttonStyle(.glass)
                    }.padding(16)
                }
                if list.page.entries.isEmpty {
                    VStack(spacing: 8) {
                        if list.isLoading { ProgressView().controlSize(.small) }
                        else {
                            Image(systemName: "clock.arrow.circlepath").font(.symbol(size: 26))
                                .accessibilityHidden(true)
                            Text(verbatim: Chrome.localized(list.cursors.isEmpty ? "No browsing history" : "No history on this page"))
                                .font(.ui(.callout))
                        }
                    }
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(maxWidth: .infinity).frame(height: 130)
                } else {
                    VStack(alignment: .leading, spacing: layout.groupSpacing) {
                        ForEach(BrowserHistoryDay.groups(list.page.entries, calendar: layout.calendar)) { day in
                            VStack(alignment: .leading, spacing: layout.headingSpacing) {
                                Text(verbatim: dayTitle(day.id))
                                    .font(.ui(.subheadline, weight: .semibold))
                                    .foregroundStyle(Chrome.secondaryText)
                                    .lineLimit(1)
                                    .frame(height: layout.headingHeight)
                                    .padding(.horizontal, 12)
                                    .accessibilityAddTraits(.isHeader)
                                VStack(alignment: .leading, spacing: layout.rowSpacing) {
                                    ForEach(day.entries) { entry in
                                        BrowserHistoryRow(entry: entry, history: history) {
                                            if let url = BrowserAddress.resolve(entry.url) { openURL(url) }
                                        } remove: { history.remove(entry.id) }
                                        .frame(height: layout.rowHeight)
                                    }
                                }
                            }
                        }
                    }
                    .padding(layout.contentPadding)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if list.page.hasMore || !list.cursors.isEmpty {
                    ChromeRowDivider()
                    HStack(spacing: 10) {
                        Text(verbatim: String(format: Chrome.localized("Page %lld"), Int64(list.number)))
                            .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                        Spacer()
                        Button("Newer") { list.newer() }
                            .buttonStyle(.glass).disabled(list.isLoading || list.cursors.isEmpty)
                        Button("Older") { list.older() }
                            .buttonStyle(.glass).disabled(list.isLoading || !list.page.hasMore)
                    }.padding(12)
                }
            }
        }
        .task(id: Query(revision: history.revision, page: list.number, layout: layout)) {
            await list.refresh(history: history, layout: layout)
        }
        .onChange(of: list.canClear) { if !list.canClear { showsClearConfirmation = false } }
    }

    private var historyControls: some View {
        HStack(spacing: 8) {
            Button("Import Chrome history…") { showsImport = true }
                .buttonStyle(.glass)
                .chromePopover(isPresented: $showsImport, arrowEdge: .bottom) {
                    ChromeHistoryImportPopover(history: history) { list.reset() }
                }
            Picker("History time range", selection: $clearRange) {
                ForEach(BrowserHistoryRange.allCases) { range in
                    Text(verbatim: Chrome.localized(range.title)).tag(range)
                }
            }
            .labelsHidden().fixedSize()
            .accessibilityLabel(Text("History time range"))
            Button("Clear…") {
                guard list.canClear else { return }
                showsClearConfirmation = true
            }
                .buttonStyle(.glass)
                .disabled(!list.canClear)
                .allowsHitTesting(list.canClear)
                .accessibilityLabel(Text("Clear browsing history"))
                .accessibilityIdentifier("clearBrowserHistory")
        }
        .fixedSize(horizontal: true, vertical: false)
        .confirmationDialog("Clear browsing history?", isPresented: $showsClearConfirmation, titleVisibility: .visible) {
            Button("Clear browsing history", role: .destructive) {
                guard list.canClear else { return }
                history.clear(clearRange)
                list.reset()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(verbatim: String(format: Chrome.localized("Delete browsing history for %@? Matching recent pages will also be removed. Chrome's original history, cookies and open tabs are kept."),
                                  Chrome.localized(clearRange.title)))
        }
    }

    private func dayTitle(_ date: Date) -> String {
        let formatted = date.formatted(.dateTime.year().month().day().weekday().locale(locale))
        if Calendar.current.isDateInToday(date) { return String(format: Chrome.localized("Today · %@"), formatted) }
        if Calendar.current.isDateInYesterday(date) { return String(format: Chrome.localized("Yesterday · %@"), formatted) }
        return formatted
    }
}
