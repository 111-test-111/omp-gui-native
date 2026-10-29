import SwiftUI

/// Controls which OMP models appear in the composer, and their defaults for new chats.
struct ModelsSettingsPage: View {
    @Environment(AppModel.self) private var model
    var query = ""

    /// Kept on the page so searching does not reset provider disclosures.
    @State private var providerExpansion: [String: Bool] = [:]

    private struct ProviderGroup: Identifiable {
        let id: String
        var models: [ModelOption]
    }

    var body: some View {
        let registry = model.providers
        let trimmed = query.trimmed
        let groups = Self.groups(of: registry.models(for: .omp))
        let providers = groups.filter { group in
            let name = providerName(group.id)
            return group.models.contains { Self.matches($0, id: $0.id, providerName: name, query: trimmed) }
        }
        // Keep large catalogues lazy and search updates free of row transitions.
        LazyVStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            if trimmed.isEmpty {
                Text("All chat models are shown by default. Hidden models stay available here but do not appear in the composer picker. Judge and other model kinds use OMP's native model roles.")
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 4)
            }
            if groups.isEmpty && trimmed.isEmpty {
                ProviderModelsSection(title: ProviderKind.omp.displayName, icon: .omp, catalogue: [], query: trimmed, isExpanded: expansion("omp"))
            } else {
                ForEach(providers) { group in
                    ProviderModelsSection(title: providerName(group.id), catalogue: group.models, query: trimmed, isExpanded: expansion(group.id))
                }
            }
            if !trimmed.isEmpty, providers.isEmpty {
                Text(verbatim: String(format: Chrome.localized("No models match “%@”."), trimmed))
                    .font(.ui(size: 13))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 4)
            }
        }
        .task { await registry.loadCatalog(.omp) }
    }

    /// Groups native providers without conflating them with runtime identifiers.
    private static func groups(of catalogue: [ModelOption]) -> [ProviderGroup] {
        var groups: [ProviderGroup] = []
        var positions: [String: Int] = [:]
        for option in catalogue {
            let id = option.provider.isEmpty ? ProviderKind.omp.rawValue : option.provider
            if let position = positions[id] {
                groups[position].models.append(option)
            } else {
                positions[id] = groups.count
                groups.append(ProviderGroup(id: id, models: [option]))
            }
        }
        return groups
    }

    private func providerName(_ id: String) -> String {
        NativeProviderPresentation.displayName(for: id, nativeName: model.omp.loginProviders.first { $0.id == id }?.name)
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { providerExpansion[id] ?? true }, set: { providerExpansion[id] = $0 })
    }

    static func matches(_ option: ModelOption?, id: String, providerName: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let fields = [option?.shortName, option?.name, option?.detail, id, providerName]
        return fields.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

/// Every catalogue row retains access to its existing per-model defaults.
private struct ModelDefaultsButton: View {
    @Environment(AppModel.self) private var model
    let option: ModelOption
    @State private var isPresented = false

    var body: some View {
        let settings = model.settings
        ChromeCircleButton(
            symbol: "slider.horizontal.3",
            help: String(format: Chrome.localized("Default settings for %@"), option.shortName)
        ) {
            isPresented = true
        }
        .chromePopover(isPresented: $isPresented, arrowEdge: .trailing) {
            EffortSliderCard(
                modelName: option.shortName,
                provider: .omp,
                efforts: option.efforts,
                defaultEffort: option.defaultEffort,
                supportsFast: option.supportsFast,
                effort: Binding(
                    get: { settings.preference(for: .omp, model: option.id).effort },
                    set: { effort in
                        var updated = settings.preference(for: .omp, model: option.id)
                        updated.effort = effort
                        settings.setPreference(updated, for: .omp, model: option.id)
                    }
                ),
                fastMode: Binding(
                    get: { settings.preference(for: .omp, model: option.id).fastMode },
                    set: { isOn in
                        var updated = settings.preference(for: .omp, model: option.id)
                        updated.fastMode = isOn
                        settings.setPreference(updated, for: .omp, model: option.id)
                    }
                ),
                onReset: { settings.setPreference(ModelPreference(), for: .omp, model: option.id) }
            )
            .frame(width: 330)
            .presentedChrome()
        }
    }
}

private struct ProviderModelsSection: View {
    @Environment(AppModel.self) private var model
    /// Native provider names are catalogue data, not localized keys.
    let title: String
    var icon: ProviderKind? = nil
    /// The complete provider catalogue, even while a query filters its displayed rows.
    let catalogue: [ModelOption]
    var query = ""
    @Binding var isExpanded: Bool

    @State private var openLineages: Set<String> = []
    @State private var showsTrials = false
    @State private var lineages = LineageCache()
    private static let foldingThreshold = 12

    private enum Row: Identifiable {
        case model(ModelOption, earlier: Int = 0, lineage: String? = nil)
        case trials(count: Int)

        var id: String {
            switch self {
            case .model(let option, _, _): "model/" + option.id
            case .trials: "trials"
            }
        }
    }

    var body: some View {
        let settings = model.settings
        let registry = model.providers
        let rows = rows(catalogue)
        let cardVisible = isExpanded || !query.isEmpty
        let hiddenCount = catalogue.filter { settings.isModelHidden(ModelPin(provider: .omp, modelID: $0.id)) }.count
        VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
            HStack(spacing: 10) {
                CollapsibleProviderHeader(title: title, icon: icon, isExpanded: $isExpanded, subject: "model list")
                if !catalogue.isEmpty {
                    Button("Hide all") { settings.setModelsHidden(true, models: catalogue) }
                        .buttonStyle(.glass)
                        .disabled(hiddenCount == catalogue.count)
                        .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("Hide all models from %@"), title)))
                    Button("Enable all") { settings.setModelsHidden(false, models: catalogue) }
                        .buttonStyle(.glass)
                        .disabled(hiddenCount == 0)
                        .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("Enable all models from %@"), title)))
                }
            }
            LazyVStack(spacing: 0) {
                if catalogue.isEmpty {
                    ChromeRevealLayout(fraction: cardVisible ? 1 : 0) {
                        ChromeRow(title: registry.loadingCatalogs.contains(.omp) ? "Loading models…" : "No models loaded") {
                            Button("Load models") {
                                Task { await registry.loadCatalog(.omp, force: true) }
                            }
                            .buttonStyle(.glass)
                            .disabled(registry.loadingCatalogs.contains(.omp))
                        }
                    }
                    .clipped()
                } else {
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { ChromeRowDivider() }
                        switch row {
                        case .model(let option, let earlier, let lineage):
                            modelRow(option, earlier: earlier, lineage: lineage)
                        case .trials(let count):
                            ChromeRow(title: "Free and preview models", detail: String(format: Chrome.localized("%lld models"), count)) {
                                disclosure(isOpen: showsTrials, label: nil, show: "Show free and preview models", hide: "Hide free and preview models") {
                                    showsTrials.toggle()
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous)
                    .fill(Chrome.overlay(0.03))
            )
            .clipShape(RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous))
            .animation(nil, value: query)
            .allowsHitTesting(cardVisible)
            .accessibilityHidden(!cardVisible)
        }
    }

    /// Visibility in the composer never removes the row's recovery control from Settings.
    private func rows(_ catalogue: [ModelOption]) -> [Row] {
        if !query.isEmpty {
            return catalogue.filter { ModelsSettingsPage.matches($0, id: $0.id, providerName: title, query: query) }.map { .model($0) }
        }
        guard isExpanded else { return [] }
        guard catalogue.count > Self.foldingThreshold else { return catalogue.map { .model($0) } }
        let layout = lineages.layout(of: catalogue)
        var rows: [Row] = []
        for lineage in layout.lineages {
            rows.append(.model(lineage.newest, earlier: lineage.earlier.count, lineage: lineage.key))
            if openLineages.contains(lineage.key) { rows += lineage.earlier.map { .model($0) } }
        }
        if !layout.trials.isEmpty {
            rows.append(.trials(count: layout.trials.count))
            if showsTrials { rows += layout.trials.map { .model($0) } }
        }
        return rows
    }

    private func modelRow(_ option: ModelOption, earlier: Int, lineage: String?) -> some View {
        let settings = model.settings
        let pin = ModelPin(provider: .omp, modelID: option.id)
        let isHidden = settings.isModelHidden(pin)
        return ModelCatalogueRow(option: option) {
            HStack(spacing: 10) {
                if let lineage, earlier > 0 {
                    disclosure(
                        isOpen: openLineages.contains(lineage),
                        label: String(format: Chrome.localized("Earlier versions (%lld)"), earlier),
                        show: "Show earlier versions",
                        hide: "Hide earlier versions"
                    ) {
                        if openLineages.contains(lineage) { openLineages.remove(lineage) } else { openLineages.insert(lineage) }
                    }
                }
                ModelDefaultsButton(option: option)
                ChromeCircleButton(
                    symbol: isHidden ? "eye.slash" : "eye",
                    help: String(format: Chrome.localized(isHidden ? "Enable %@ in the picker" : "Hide %@ from the picker"), option.shortName)
                ) {
                    settings.setModelHidden(!isHidden, pin)
                }
                .accessibilityValue(Text(verbatim: Chrome.localized(isHidden ? "Hidden" : "Shown")))
            }
        }
    }

    private func disclosure(isOpen: Bool, label: String?, show: String, hide: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Chrome.panelSlide) { action() }
        } label: {
            HStack(spacing: 6) {
                if let label {
                    Text(verbatim: label)
                        .font(.ui(size: 11))
                        .foregroundStyle(Chrome.secondaryText)
                }
                Image(systemName: "chevron.right").font(.symbol(size: 11, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(ChromeQuietButtonStyle())
        .help(Text(verbatim: Chrome.localized(isOpen ? hide : show)))
        .accessibilityLabel(Text(verbatim: Chrome.localized(isOpen ? hide : show)))
    }
}

/// The row's main button opens details; its controls are siblings, so hiding a
/// model or editing defaults never also activates the detail popover.
private struct ModelCatalogueRow<Controls: View>: View {
    let option: ModelOption
    @ViewBuilder var controls: Controls
    @State private var isPresented = false

    var body: some View {
        HStack(spacing: 16) {
            Button { isPresented = true } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: option.shortName).font(.ui(.body)).foregroundStyle(Chrome.primaryText)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(verbatim: detail).font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("View model details"))
            .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("Details for %@"), option.shortName)))
            .chromePopover(isPresented: $isPresented, arrowEdge: .leading) {
                ModelDetailsPopover(option: option).presentedChrome()
            }
            controls
        }
        .padding(.leading, 16)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 11)
    }
}

@MainActor
private final class LineageCache {
    private var catalogue: [ModelOption] = []
    private var cached = ModelFamilies.Layout(lineages: [], trials: [])

    func layout(of catalogue: [ModelOption]) -> ModelFamilies.Layout {
        if catalogue != self.catalogue {
            self.catalogue = catalogue
            cached = ModelFamilies.lineages(catalogue)
        }
        return cached
    }
}

/// The disclosure header over one provider's model card.
struct CollapsibleProviderHeader: View {
    /// The provider's display name; catalogue provider names are data, not localized keys.
    let title: String
    /// Set for the runtime's own header; catalogue providers have no asset of their own.
    var icon: ProviderKind? = nil
    @Binding var isExpanded: Bool
    /// What the disclosure shows, named in the help and the accessibility hint.
    let subject: String

    var body: some View {
        Button {
            withAnimation(Chrome.panelSlide) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    ProviderIcon(provider: icon, size: 16)
                        .foregroundStyle(Chrome.primaryText)
                }
                Text(verbatim: title)
                    .font(.ui(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.symbol(size: 11, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(ChromeQuietButtonStyle())
        .frame(height: 22)
        .help(Text(verbatim: String(format: Chrome.localized(isExpanded ? "Hide the %@" : "Show the %@"), Chrome.localized(subject))))
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: Chrome.localized(isExpanded ? "Expanded" : "Collapsed")))
        .accessibilityHint(Text(verbatim: String(format: Chrome.localized("Shows or hides the %@"), Chrome.localized(subject))))
        .accessibilityAddTraits(.isHeader)
    }
}
