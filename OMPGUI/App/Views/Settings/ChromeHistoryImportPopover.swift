import SwiftUI

struct ChromeHistoryImportPopover: View {
    @Environment(\.dismiss) private var dismiss
    @State private var importer: ChromeHistoryImportStore
    let onComplete: @MainActor () -> Void

    init(history: BrowserHistoryStore, onComplete: @escaping @MainActor () -> Void) {
        _importer = State(initialValue: ChromeHistoryImportStore(history: history))
        self.onComplete = onComplete
    }

    var body: some View {
        ChromeHistoryImportForm(importer: importer, onComplete: onComplete, onClose: { dismiss() },
                                availableWidth: max(240, ((NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.width ?? 1_200) - 64))
            .onAppear { importer.discover() }
            .onDisappear { importer.cancel() }
            .interactiveDismissDisabled(importer.isCommitting)
    }
}

/// The same native form can be rendered with isolated source data in checks.
struct ChromeHistoryImportForm: View {
    @Bindable var importer: ChromeHistoryImportStore
    let onComplete: @MainActor () -> Void
    let onClose: () -> Void
    var availableWidth: CGFloat = 520
    @State private var confirmsReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Chrome history").font(.ui(.body, weight: .semibold))
            Text("Import saved visits and website icons. Your OMP GUI history and recently opened pages are kept. Chrome data is never changed.")
                .foregroundStyle(Chrome.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !importer.profiles.isEmpty {
                Picker("Chrome profile", selection: $importer.selectedID) {
                    ForEach(importer.profiles) { profile in
                        Text(verbatim: profile.name + " · " + profile.directoryName).tag(Optional(profile.id))
                    }
                }.disabled(importer.isBusy)
                Picker("History time range", selection: $importer.range) {
                    ForEach(BrowserHistoryRange.allCases) { range in
                        Text(verbatim: Chrome.localized(range.title)).tag(range)
                    }
                }.disabled(importer.isBusy)
            }
            if importer.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: Chrome.localized(importer.isCommitting ? "Importing history…" : "Reading Chrome history…"))
                        .foregroundStyle(Chrome.secondaryText)
                }
            }
            if let summary = importer.result ?? importer.preview?.summary {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: Chrome.localized(importer.result == nil ? "Import preview" : "History import complete"))
                        .font(.ui(.body, weight: .medium))
                    Text(verbatim: String(format: Chrome.localized("New: %ld · Already imported: %ld · Previously deleted: %ld · Skipped: %ld"),
                                          summary.added, summary.existing, summary.deleted, summary.skipped))
                        .fixedSize(horizontal: false, vertical: true)
                    if summary.added == 0 {
                        Text("No new visits to import. Previously deleted records stay deleted.")
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Chrome.overlay(0.03), in: RoundedRectangle(cornerRadius: 10))
            }
            if let key = importer.errorKey {
                Text(verbatim: Chrome.localized(key)).foregroundStyle(Chrome.danger)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if importer.permissionDenied {
                    Button("Open Privacy Settings", action: openChromeImportPrivacySettings).buttonStyle(.glass)
                }
            }
            if (importer.preview?.summary.deleted ?? 0) > 0 {
                Button("Reset import exclusions…") { confirmsReset = true }
                    .buttonStyle(.glass).disabled(importer.isBusy)
                    .confirmationDialog("Reset Chrome history exclusions?", isPresented: $confirmsReset, titleVisibility: .visible) {
                        Button("Reset exclusions", role: .destructive) { importer.resetExclusions() }
                    } message: {
                        Text("Only this Chrome profile's deletion markers will be reset. Deleted visits can return the next time you preview and import. Existing history is kept.")
                    }
            }
            HStack(spacing: 10) {
                Spacer()
                Button(action: onClose) {
                    Text(verbatim: Chrome.localized(importer.result == nil ? "Cancel" : "Done"))
                }
                    .buttonStyle(.glass).disabled(importer.isCommitting)
                if importer.result == nil {
                    if let preview = importer.preview {
                        Button("Import history") { importer.commit(onComplete: onComplete) }
                            .buttonStyle(.glassProminent).disabled(importer.isBusy || preview.summary.added == 0)
                    } else {
                        Button {
                            if importer.profiles.isEmpty { importer.discover() } else { importer.prepare() }
                        } label: {
                            Text(verbatim: Chrome.localized(importer.profiles.isEmpty ? "Retry" : "Preview import"))
                        }.buttonStyle(.glassProminent).disabled(importer.isBusy)
                    }
                }
            }
        }
        .font(.ui(.body)).padding(16)
        .frame(width: min(520, max(240, availableWidth))).fixedSize(horizontal: false, vertical: true)
        .presentedChrome()
    }
}
