import SwiftUI

struct MemorySettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var selection: MemoryFileSelection?
    @State private var fileRead: (id: UUID, settingsEnabled: Bool)?

    private var isLoading: Bool { model.memoryFiles.isLoading }
    private var canEditSettings: Bool {
        !model.isChangingMemory && (fileRead?.settingsEnabled ?? model.canChangeMemory)
    }

    private func binding<T>(_ key: WritableKeyPath<OMPMemoryConfiguration, T>) -> Binding<T> {
        Binding(get: { model.settings.ompMemory[keyPath: key] }, set: { value in
            guard !isLoading else { return }
            var next = model.settings.ompMemory
            next[keyPath: key] = value
            Task { await model.changeMemory(next) }
        })
    }

    var body: some View {
        ChromeSection(title: "Long-term memory") {
            ChromeCard {
                ChromeRow(title: "Enable memory", detail: "Use OMP Mnemopi to remember project knowledge and shared preferences across conversations. Off by default.") {
                    SettingsSwitch(isOn: binding(\.enabled))
                        .disabled(!canEditSettings)
                }
                ChromeRowDivider()
                ChromeRow(title: "Memory scope", detail: "Project memory + global shared memory. Worktrees of the same Git repository share project memory; separate clones stay separate.") {
                    Text("Mnemopi").foregroundStyle(Chrome.secondaryText)
                }
                ChromeRowDivider()
                ChromeRow(title: "Automatic recall", detail: "OMP recalls relevant memories before the first model response and keeps the native prompt snapshot with the conversation.") {
                    SettingsSwitch(isOn: binding(\.autoRecall)).disabled(!canEditSettings)
                }
                ChromeRowDivider()
                ChromeRow(title: "Automatic retention", detail: "OMP saves completed turns to project memory. Ask the agent to save shared preferences with global scope.") {
                    SettingsSwitch(isOn: binding(\.autoRetain)).disabled(!canEditSettings)
                }
                ChromeRowDivider()
                ChromeRow(title: "Memory language", detail: "The embedding model is managed by OMP. An explicit native embedding model takes precedence.") {
                    Picker("Memory language", selection: binding(\.multilingual)) {
                        Text("Multilingual").tag(true)
                        Text("English").tag(false)
                    }.labelsHidden().disabled(!canEditSettings)
                }
                ChromeRowDivider()
                ChromeRow(title: "Memory context budget", detail: "Approximate token limit for native memory instructions and recalled facts.") {
                    Picker("Memory context budget", selection: binding(\.tokenBudget)) {
                        ForEach([1000, 3000, 5000], id: \.self) { Text(verbatim: String($0)).tag($0) }
                    }.labelsHidden().disabled(!canEditSettings)
                }
            }
            .allowsHitTesting(!isLoading)
            Text("Changes wait for idle conversations, let OMP finish saving, and close existing connections. The next request uses the new configuration. Turning memory off preserves saved memories and conversation history.")
                .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
            if model.isChangingMemory {
                Text("Saving memory and closing OMP connections…").font(.ui(.subheadline))
            }
            if let error = model.memoryError { Text(verbatim: error).foregroundStyle(Chrome.danger) }
        }
        ChromeSection(title: "Memory files", accessory: initialLoadIndicator) {
            if !model.memoryFiles.files.isEmpty {
                ChromeCard {
                    ForEach(Array(model.memoryFiles.files.enumerated()), id: \.element.id) { index, file in
                        if index > 0 { ChromeRowDivider() }
                        ChromeRow(title: file.title, detail: file.path) {
                            Button("Preview") {
                                guard canInspect, !isLoading, let id = model.selectedThreadID else { return }
                                selection = MemoryFileSelection(file: file, threadID: id, configuration: model.settings.ompMemory)
                            }
                            .buttonStyle(.glass).disabled(!canInspect)
                            .chromePopover(isPresented: presented(file), arrowEdge: .bottom) {
                                if let selection, selection.file.id == file.id {
                                    MemoryFilePreview(selection: selection).id(selection.id).presentedChrome()
                                }
                            }
                        }
                    }
                }
            }
            if !model.settings.ompMemory.enabled || model.selectedThreadID == nil {
                Text("Enable memory and select a conversation to inspect it.")
                    .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
            }
            if let error = model.memoryFiles.error { Text(verbatim: error).foregroundStyle(Chrome.danger).textSelection(.enabled) }
            if model.memoryFiles.hasLoaded && model.memoryFiles.files.isEmpty {
                Text("OMP did not report any global memory files.")
                    .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
            }
        }
        .onChange(of: model.memoryFileContext, initial: true) { _, _ in
            selection = nil
            // The cache owns this bounded read beyond the page's lifetime.
            Task { await loadFiles() }
        }
        .onDisappear { selection = nil }
    }

    private var canInspect: Bool {
        model.settings.ompMemory.enabled && !model.isChangingMemory && model.selectedThreadID != nil
    }

    private var initialLoadIndicator: AnyView? {
        guard canInspect, !model.memoryFiles.hasLoaded,
              isLoading || model.memoryFiles.error == nil else { return nil }
        return AnyView(ProgressView().controlSize(.small).accessibilityLabel(Text("Loading memory files")))
    }

    @MainActor private func loadFiles() async {
        guard !isLoading else { return }
        let id = UUID()
        // A read keeps the current controls' appearance. Input remains gated above,
        // and AppModel still checks native requests before changing configuration.
        fileRead = (id, model.canChangeMemory)
        defer { if fileRead?.id == id { fileRead = nil } }
        await model.loadMemoryFiles()
    }

    private func presented(_ file: OMPMemoryFile) -> Binding<Bool> {
        Binding(get: { selection?.file.id == file.id }, set: { shown in
            if !shown, selection?.file.id == file.id { selection = nil }
        })
    }
}

struct MemoryFileSelection: Identifiable {
    let id = UUID()
    let file: OMPMemoryFile
    let threadID: UUID
    let configuration: OMPMemoryConfiguration
}

private struct MemoryFilePreview: View {
    let selection: MemoryFileSelection
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var preview: OMPMemoryPreview?
    @State private var reader = PreviewReaderState(snapshot: .init(wrapsLines: true))
    @State private var error: String?
    @State private var isLoading = false
    @State private var generation = UUID()
    @State private var revision = UUID().uuidString

    private var isCurrentSelection: Bool {
        model.selectedThreadID == selection.threadID && model.settings.ompMemory == selection.configuration
            && model.settings.ompMemory.enabled && !model.isChangingMemory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: Chrome.localized(selection.file.title)).font(.ui(.headline))
                Spacer()
                ChromeCircleButton(symbol: "arrow.clockwise", help: "Refresh memory preview") {
                    Task { await load() }
                }.disabled(!isCurrentSelection || isLoading)
                ChromeCircleButton(symbol: "xmark", help: "Close") { dismiss() }
            }
            Divider()
            if let error { Text(verbatim: error).foregroundStyle(Chrome.danger).textSelection(.enabled) }
            if let preview {
                MemoryFilePreviewDocument(file: selection.file, preview: preview, reader: reader, revision: revision)
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { Spacer() }
        }
        .padding(12)
        .frame(width: 520, height: 380)
        // Let the bounded native read finish even after dismissal. Its pending
        // request keeps memory changes gated; generation discards the late reply.
        .onAppear { Task { await load() } }
        .onDisappear { generation = UUID(); preview = nil }
    }

    @MainActor private func load() async {
        guard isCurrentSelection, !isLoading else { return }
        let expected = UUID()
        generation = expected
        isLoading = true
        defer { if generation == expected { isLoading = false } }
        do {
            let value = try await model.runtime(for: selection.threadID).previewMemory(selection.file)
            guard generation == expected, isCurrentSelection, !Task.isCancelled else { return }
            preview = value
            revision = expected.uuidString
            error = nil
        } catch {
            guard generation == expected, isCurrentSelection, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

struct MemoryFilePreviewDocument: View {
    let file: OMPMemoryFile
    let preview: OMPMemoryPreview
    let reader: PreviewReaderState
    let revision: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if preview.limited {
                Text("Preview limit reached. Some entries may be omitted or shortened.")
                    .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
            }
            if preview.isEmpty {
                Text("No saved memories to preview for this request.")
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FilePreviewContent(url: URL(fileURLWithPath: file.path), kind: .text, text: preview.text,
                                   revision: revision, location: nil, state: reader, onOpen: { _, _ in })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
