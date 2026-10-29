import AppKit
import SwiftUI

struct SkillsSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var native = OMPNativeSkills()
    @State private var selection: OMPGlobalSkill?

    private var context: OMPDiscoveryContext? {
        guard let executable = model.providers.executable(for: .omp) else { return nil }
        return OMPDiscoveryContext(executable: executable,
            environment: OMPCLI.profileConfigurationEnvironment(model.providers.environment(for: .omp)))
    }

    var body: some View {
        ChromeSection(title: "Global skills", accessory: loadingIndicator, trailing: refreshButton) {
            Text("Global skills discovered by OMP. Project skills are excluded.")
                .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
            if let error = native.error {
                Text(verbatim: error).font(.ui(.subheadline)).foregroundStyle(Chrome.danger).textSelection(.enabled)
            }
            if native.hasLoaded && native.skills.isEmpty {
                Text("OMP did not report any global skills.")
                    .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
            }
            ChromeCard {
                ForEach(Array(native.skills.enumerated()), id: \.element.id) { index, skill in
                    if index > 0 { ChromeRowDivider() }
                    Button { selection = skill } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: skill.name).font(.ui(.body, weight: .medium))
                                .foregroundStyle(Chrome.primaryText)
                            if !skill.description.isEmpty {
                                Text(verbatim: skill.description).font(.ui(.subheadline))
                                    .foregroundStyle(Chrome.secondaryText).lineLimit(2)
                            }
                            Text(verbatim: skill.filePath).font(.code(.caption))
                                .foregroundStyle(Chrome.secondaryText).lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("Preview SKILL.md"))
                    .chromePopover(isPresented: presented(skill), arrowEdge: .leading) {
                        SkillFilePreview(skill: skill).id(skill.id).presentedChrome()
                    }
                }
            }
        }
        .task(id: context) { await native.refresh(context) }
        .onChange(of: context) { _, _ in selection = nil }
        .onDisappear { selection = nil }
    }

    private var loadingIndicator: AnyView? {
        guard native.isLoading else { return nil }
        return AnyView(ProgressView().controlSize(.small).accessibilityLabel(Text("Loading global skills")))
    }

    private var refreshButton: AnyView {
        AnyView(
            ChromeCircleButton(symbol: "arrow.clockwise", help: "Refresh global skills") {
                selection = nil
                Task { await native.refresh(context) }
            }.disabled(native.isLoading)
        )
    }

    private func presented(_ skill: OMPGlobalSkill) -> Binding<Bool> {
        Binding(get: { selection?.id == skill.id }, set: { shown in
            if !shown, selection?.id == skill.id { selection = nil }
        })
    }
}

struct SkillFilePreview: View {
    let skill: OMPGlobalSkill
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: PreviewFileSnapshot?
    @State private var reader: PreviewReaderState
    @State private var error: String?
    @State private var revision = 0

    init(skill: OMPGlobalSkill, reader: PreviewReaderState = .init()) {
        self.skill = skill
        _reader = State(initialValue: reader)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(verbatim: skill.name).font(.ui(.headline)).lineLimit(1)
                    Spacer(minLength: 0)
                    ChromeCapsule {
                        ChromeIconButton(symbol: "chevron.left.forwardslash.chevron.right", isActive: reader.showsSource,
                                         help: reader.showsSource ? "Show rendered preview" : "Show source") {
                            reader.showsSource.toggle()
                        }
                        .animation(Chrome.hover, value: reader.showsSource)
                        .accessibilityValue(Text(verbatim: Chrome.localized(reader.showsSource ? "Source" : "Preview")))
                        .accessibilityAddTraits(reader.showsSource ? .isSelected : [])
                        ChromeIconButton(symbol: "arrow.clockwise", help: "Refresh preview") { revision += 1 }
                        ChromeIconButton(symbol: "folder", help: "Open containing folder") {
                            NSWorkspace.shared.open(skill.url.deletingLastPathComponent())
                        }
                    }
                    ChromeCircleButton(symbol: "xmark", help: "Close") { dismiss() }
                }
                Text(verbatim: skill.filePath).font(.code(.caption)).foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1).truncationMode(.middle).help(Text(verbatim: skill.filePath))
                Divider()
            }
            .padding(.top, 12)
            VStack(alignment: .leading, spacing: 10) {
                if let error {
                    Text(verbatim: error).font(.ui(.subheadline)).foregroundStyle(Chrome.danger).textSelection(.enabled)
                }
                if let snapshot {
                    FilePreviewContent(url: snapshot.url, kind: .markdown, text: snapshot.text, revision: snapshot.revision,
                                       location: nil, state: reader, onOpen: { _, _ in })
                        .id(reader.showsSource)
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { Spacer() }
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 580, height: 540)
        .task(id: revision) { await load() }
        .onDisappear { snapshot = nil }
    }

    @MainActor private func load() async {
        do {
            let opening = try await PreviewFileLoader.open(.init(path: skill.filePath), relativeTo: skill.url.deletingLastPathComponent().path)
            guard let content = opening.content else { throw FilePreviewError.directory }
            let value = try content.get()
            try Task.checkCancellation()
            snapshot = value
            error = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
