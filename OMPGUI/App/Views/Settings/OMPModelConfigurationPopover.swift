import AppKit
import SwiftUI

struct OMPModelConfigurationPopover: View {
    let registry: ProviderRegistry
    var initialProvider: String? = nil
    let completed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var snapshot: OMPModelConfigurationSnapshot?
    @State private var fields: [String: String] = [:]
    @State private var revealed: Set<String> = []
    @State private var search = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    private var fieldTint: Color {
        Chrome.primaryText.opacity(colorScheme == .dark ? 0.16 : 0.06)
    }

    private var providers: [OMPAPIKeyProvider] {
        (snapshot?.providers ?? []).filter { provider in
            NativeProviderPresentation.matches(provider: provider.id, nativeName: provider.name,
                                               environmentKeys: provider.environmentKeys, query: search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Provider API keys").font(.ui(.title3, weight: .semibold))
                Spacer()
                ChromeCircleButton(symbol: "doc.text", help: "Open configuration file") {
                    guard let snapshot else { return }
                    NSWorkspace.shared.open(URL(fileURLWithPath: snapshot.file))
                }.disabled(saving || snapshot == nil)
            }
            TextField("Search providers", text: $search).textFieldStyle(.chromeGlass(tint: fieldTint))
                .disabled(saving || snapshot == nil)
            Group {
                if snapshot != nil {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                                if index > 0 { Divider().padding(.vertical, 8) }
                                providerRow(provider)
                            }
                        }
                    }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(height: 320)
            if let error { Text(verbatim: error).font(.ui(.subheadline)).foregroundStyle(Chrome.danger).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save") { Task { await save() } }.buttonStyle(.glass).keyboardShortcut(.defaultAction)
                    .disabled(saving || loading || snapshot == nil || snapshot?.changes(from: fields).isEmpty == true)
            }
        }
        .padding(16)
        .frame(width: 560)
        .interactiveDismissDisabled(saving)
        .task { search = initialProvider ?? ""; await load() }
        .onDisappear { fields.removeAll(); revealed.removeAll(); snapshot = nil }
    }

    private func providerRow(_ provider: OMPAPIKeyProvider) -> some View {
        let name = NativeProviderPresentation.displayName(for: provider.id, nativeName: provider.name)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 8) {
                NativeProviderIcon(providerID: provider.id, name: name, size: 18)
                Text(verbatim: name).font(.ui(.subheadline)).lineLimit(2)
            }.frame(width: 180, alignment: .leading)
            Group {
                let value = Binding(get: { fields[provider.id] ?? "" }, set: { fields[provider.id] = $0 })
                if revealed.contains(provider.id) { TextField("", text: value) }
                else { SecureField("", text: value) }
            }
                .textFieldStyle(.chromeGlass(tint: fieldTint)).font(.ui(.subheadline, design: .monospaced))
                .privacySensitive()
                .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("API key for %@"), name)))
            ChromeCircleButton(symbol: revealed.contains(provider.id) ? "eye.slash" : "eye",
                               help: revealed.contains(provider.id) ? "Hide the API key" : "Show the API key") {
                if !revealed.insert(provider.id).inserted { revealed.remove(provider.id) }
            }
        }.disabled(saving)
    }

    @MainActor private func load() async {
        do {
            guard let executable = registry.executable(for: .omp) else { throw ProviderError.notInstalled(.omp) }
            let environment = registry.environment(for: .omp)
            let loaded = try await OMPModelConfiguration.read(executable: executable, environment: environment)
            try Task.checkCancellation()
            guard registry.executable(for: .omp) == executable, registry.environment(for: .omp) == environment else {
                throw OMPModelConfiguration.failure("profile_changed")
            }
            fields = Dictionary(uniqueKeysWithValues: loaded.providers.map { ($0.id, $0.value) })
            snapshot = loaded
        } catch { self.error = error.localizedDescription }
        loading = false
    }

    @MainActor private func save() async {
        guard !saving, let snapshot, let executable = registry.executable(for: .omp) else { return }
        saving = true
        error = nil
        do {
            try await OMPModelConfiguration.save(snapshot, fields: fields, executable: executable, environment: registry.environment(for: .omp))
            fields.removeAll()
            self.snapshot = nil
            completed()
            dismiss()
        } catch { self.error = error.localizedDescription }
        saving = false
    }
}
