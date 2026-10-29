import SwiftUI

enum ModelPickerProjection {
    struct Provider: Identifiable, Equatable {
        let id: String
        let models: [ModelOption]
    }

    static func providers(_ catalogue: [ModelOption]) -> [Provider] {
        var order: [String] = []
        var groups: [String: [ModelOption]] = [:]
        for option in catalogue {
            let id = option.provider.isEmpty ? "omp" : option.provider
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(option)
        }
        return order.map { Provider(id: $0, models: groups[$0] ?? []) }
    }

    static func matches(_ option: ModelOption, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return terms.allSatisfy { term in
            [option.name, option.id, option.provider, NativeProviderPresentation.displayName(for: option.provider)]
                .contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }
}

/// Native model providers are presentation groups. Every selection still runs through OMP.
struct ModelList: View {
    @Environment(AppModel.self) private var model
    let thread: ChatThread
    let hasHistory: Bool
    let onChoose: (ModelCatalog.Entry) -> Void
    var onEnterPair: (HydraPair) -> Void = { _ in }
    let onBack: () -> Void

    var body: some View {
        let pairs = model.hydraIsOn(thread) ? model.hydraPickerPairs : []
        NativeModelPicker(selectedModelID: thread.provider == .omp ? thread.model : nil,
                          isEnabled: !hasHistory || thread.provider == .omp,
                          onChoose: onChoose, onBack: onBack,
                          pairChoices: .init(options: pairs,
                                             selectedID: pairs.first { model.leadsWithHydraPair($0, thread: thread) }?.id,
                                             lockedProvider: hasHistory ? thread.provider : nil,
                                             onChoose: onEnterPair))
    }
}

/// The bounded provider rail, search and model rows inside the chat model popover.
struct NativeModelPicker: View {
    struct PairChoices {
        let options: [HydraPair]
        let selectedID: UUID?
        let lockedProvider: ProviderKind?
        let onChoose: (HydraPair) -> Void
    }

    @Environment(AppModel.self) private var model
    let selectedModelID: String?
    var isEnabled = true
    let onChoose: (ModelCatalog.Entry) -> Void
    var onBack: (() -> Void)? = nil
    var pairChoices: PairChoices? = nil
    @State private var selectedProvider: String?
    @State private var showsPairs = false
    @State private var query = ""
    @State private var isPreparingCatalog = true
    private var groups: [ModelPickerProjection.Provider] { ModelPickerProjection.providers(model.providers.models(for: .omp)) }
    private var pairs: [HydraPair] { pairChoices?.options ?? [] }
    private var currentProvider: ModelPickerProjection.Provider? {
        groups.first { $0.id == selectedProvider }
            ?? groups.first { $0.models.contains { $0.id == selectedModelID } }
            ?? groups.first
    }

    var body: some View {
        HStack(spacing: 0) {
            providerRail
                .frame(width: 52)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if let onBack {
                        ChromeCircleButton(symbol: "chevron.left", help: "Back", action: onBack)
                    }
                    ChromeSearchField(query: $query, prompt: "Search models", width: nil)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 12).padding(.top, 12)
                GeometryReader { viewport in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            if showsPairs && !pairs.isEmpty { pairRows }
                            else if let provider = currentProvider { providerRows(provider) }
                            else {
                                Text(verbatim: Chrome.localized(isPreparingCatalog || model.providers.loadingCatalogs.contains(.omp) ? "Loading models…" : "No available model providers."))
                                    .font(.ui(.body)).foregroundStyle(Chrome.secondaryText).padding(12)
                            }
                            if let error = model.providers.catalogErrors[.omp] {
                                Text(verbatim: error).font(.ui(.body)).foregroundStyle(Chrome.danger).padding(8)
                                Button("Retry") { Task { await model.providers.loadCatalog(.omp, force: true) } }
                                    .buttonStyle(.glass)
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 12)
                        .frame(width: viewport.size.width, alignment: .leading)
                        .background { VerticalScrollLock() }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .padding(.bottom, ModelPickerLayout.modelListBottomInset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: ModelPickerLayout.modelSize.width, height: ModelPickerLayout.modelSize.height)
        .onChange(of: pairs.isEmpty) { _, empty in if empty { showsPairs = false } }
        .task {
            isPreparingCatalog = true
            defer { isPreparingCatalog = false }
            // The picker may open before app startup finishes discovering the login
            // PATH. Own this read as well as the chip's opportunistic warm-up.
            await LoginEnvironment.load()
            guard !Task.isCancelled else { return }
            await model.providers.loadCatalog(.omp)
        }
    }

    private var providerRail: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(groups) { provider in
                    ProviderRailButton(provider: provider.id, title: providerName(provider.id),
                                       selected: !showsPairs && currentProvider?.id == provider.id) {
                        selectedProvider = provider.id
                        showsPairs = false
                    }
                }
                if !pairs.isEmpty {
                    Divider().padding(.vertical, 4)
                    Button { showsPairs = true } label: {
                        HydraMarkImage().frame(width: 20, height: 20)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Chrome.overlay(showsPairs ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain).help("Pairs").accessibilityLabel(Text("Pairs"))
                    .accessibilityAddTraits(showsPairs ? .isSelected : [])
                }
            }
            .padding(6)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder private func providerRows(_ provider: ModelPickerProjection.Provider) -> some View {
        Text(verbatim: providerName(provider.id)).font(.ui(.body))
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 11)
            .accessibilityAddTraits(.isHeader)
        let visible = provider.models.filter { !model.settings.isModelHidden(ModelPin(provider: .omp, modelID: $0.id)) }
        let filtered = visible.filter { ModelPickerProjection.matches($0, query: query) }
        ForEach(filtered) { option in
            NativeModelPickerRow(option: option, selected: pairChoices?.selectedID == nil && option.id == selectedModelID,
                                 isEnabled: isEnabled) {
                onChoose(ModelCatalog.Entry(provider: .omp, option: option))
            }
        }
        if filtered.isEmpty {
            Text(verbatim: Chrome.localized(visible.isEmpty ? "All models are hidden. Enable models in Settings → Models." : "No matching models."))
                .font(.ui(.body)).foregroundStyle(Chrome.secondaryText).padding(12)
        }
    }

    private var pairRows: some View {
        ForEach(pairs.filter { query.trimmed.isEmpty || HydraPairSummary.title($0, registry: model.providers).localizedCaseInsensitiveContains(query.trimmed) }) { pair in
            let locked = pairChoices?.lockedProvider.map { $0 != pair.provider } ?? false
            let models = pair.customName == nil ? nil : HydraPairSummary.modelsTitle(pair, registry: model.providers)
            HydraPairListRow(pair: pair, title: HydraPairSummary.title(pair, registry: model.providers),
                             detail: locked ? "New chats only" : [models, HydraPairSummary.providers(pair), HydraPairSummary.efforts(pair)].compactMap { $0 }.joined(separator: " · "),
                             rowHeight: 58, isSelected: pair.id == pairChoices?.selectedID, isEnabled: !locked) { pairChoices?.onChoose(pair) }
        }
    }

    private func providerName(_ id: String) -> String {
        NativeProviderPresentation.displayName(for: id, nativeName: model.omp.loginProviders.first { $0.id == id }?.name)
    }
}

struct NativeModelProviderMark: View {
    let provider: String
    var name: String? = nil
    var body: some View {
        NativeProviderIcon(providerID: provider, name: name)
    }

    static func title(_ id: String) -> String {
        NativeProviderPresentation.displayName(for: id)
    }
}

private struct ProviderRailButton: View {
    let provider: String
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            NativeModelProviderMark(provider: provider, name: title)
            .foregroundStyle(selected ? Chrome.primaryText : Chrome.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Chrome.overlay(selected ? 0.1 : hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain).onHover { hovering = $0 }.help(title)
        .accessibilityLabel(Text(verbatim: title)).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct NativeModelPickerRow: View {
    let option: ModelOption
    let selected: Bool
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: option.name).font(.ui(.body)).foregroundStyle(Chrome.primaryText).lineLimit(1)
                    Text(verbatim: option.id).font(.ui(.callout)).foregroundStyle(Chrome.secondaryText).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if option.supportsFast {
                    Image(systemName: "bolt").font(.symbol(.footnote)).foregroundStyle(Chrome.secondaryText)
                }
                if selected {
                    Image(systemName: "checkmark").font(Chrome.iconFont).foregroundStyle(Chrome.secondaryText)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(Chrome.overlay(hovering && isEnabled && !selected ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(!isEnabled).opacity(isEnabled ? 1 : 0.45).onHover { hovering = $0 }
        .help(isEnabled ? option.id : Chrome.localized("New chats only"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
