import SwiftUI

/// Chooses the models the composer's picker offers, and each one's effort and fast mode for new chats.
struct ModelsSettingsPage: View {
    @Environment(AppModel.self) private var model
    var query = ""

    /// The live grip reorder of a chosen model (see `RowDrag`).
    @State private var drag = RowDrag<ModelPin>()
    /// Each row's height including its divider: one row's slot in the card.
    @State private var rowHeights: [ModelPin: CGFloat] = [:]
    /// Each provider section's expansion, keyed on the page so typing in the search
    /// field — which rebuilds the sections — doesn't reset it. Absent means expanded.
    @State private var providerExpansion: [ProviderKind: Bool] = [:]

    /// Neighbours sliding out of the grabbed row's way.
    private static let slide = Animation.spring(response: 0.28, dampingFraction: 0.82)

    var body: some View {
        let settings = model.settings
        let registry = model.providers
        let pins = settings.modelList
        let trimmed = query.trimmed
        let visiblePins = self.visiblePins(query: trimmed)
        let providers = registry.availableProviders.filter { provider in
            trimmed.isEmpty || registry.models(for: provider).contains { Self.matches($0, id: $0.id, provider: provider, query: trimmed) }
        }
        // Filtering is instant with no transitions: animating dozens of rows with blur on every
        // keystroke (and all of them again when clearing) is what made entries overlap and jump.
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            if trimmed.isEmpty || !visiblePins.isEmpty {
                ChromeSection(title: "Your models") {
                    ChromeCard {
                        if pins.isEmpty {
                            ChromeRow(
                                title: "No models chosen yet",
                                detail: "Until you add some below, the picker shows every model from your providers."
                            ) {
                                EmptyView()
                            }
                        } else {
                            // A plain stack, not the card's lazy one: a lazy stack
                            // rebuilds a row that changes slot and animates it in
                            // from the container's origin, so a reorder sent the
                            // grabbed row flying to the top; it also ignores
                            // zIndex, which the lifted row needs to draw on top.
                            VStack(spacing: 0) {
                                ForEach(visiblePins, id: \.self) { pin in
                                    let isDragged = drag.id == pin
                                    VStack(spacing: 0) {
                                        ChromeRowDivider().opacity(pin == visiblePins.first || isDragged ? 0 : 1)
                                        PinnedModelRow(
                                            pin: pin,
                                            isDragged: isDragged,
                                            onDragChanged: { translation in dragChanged(pin, translation: translation) },
                                            onDragEnded: { dragEnded() }
                                        )
                                    }
                                    .modifier(PinnedRowHeightReporter(pin: pin, heights: $rowHeights))
                                    .offset(y: isDragged ? drag.visualOffset : 0)
                                    .zIndex(isDragged ? 1 : 0)
                                }
                            }
                        }
                    }
                    if trimmed.isEmpty {
                        Text(verbatim: String(format: Chrome.localized("%lld of %lld. Click a model to set its reasoning effort and fast mode for every new chat."), pins.count, AppSettings.modelListLimit))
                            .font(.system(size: 11))
                            .foregroundStyle(Chrome.secondaryText)
                            .padding(.horizontal, 4)
                    }
                }
            }

            ForEach(providers) { provider in
                ProviderModelsSection(
                    provider: provider,
                    query: trimmed,
                    isExpanded: Binding(
                        get: { providerExpansion[provider] ?? true },
                        set: { providerExpansion[provider] = $0 }
                    )
                )
            }

            if !trimmed.isEmpty, visiblePins.isEmpty, providers.isEmpty {
                Text(verbatim: String(format: Chrome.localized("No models match “%@”."), trimmed))
                    .font(.system(size: 13))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 4)
            }
        }
        .onChange(of: pins) { _, pins in
            // An unpinned model takes its measured height with it.
            if rowHeights.count > pins.count {
                let kept = Set(pins)
                rowHeights = rowHeights.filter { kept.contains($0.key) }
            }
        }
    }

    // MARK: - Reorder

    /// The chosen models that match the search, in list order.
    private func visiblePins(query: String) -> [ModelPin] {
        let registry = model.providers
        return model.settings.modelList.filter { pin in
            Self.matches(registry.model(pin.modelID, for: pin.provider), id: pin.modelID, provider: pin.provider, query: query)
        }
    }

    /// The grabbed row follows the pointer and swaps past every visible
    /// neighbour whose centre it has crossed. While a search filters the list
    /// the swaps still happen against the visible neighbour, so hidden models
    /// keep their place relative to it. The order is read fresh on every move
    /// rather than captured by the row's gesture.
    private func dragChanged(_ pin: ModelPin, translation: CGFloat) {
        if drag.id != pin {
            drag = RowDrag(id: pin)
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { drag.translation = translation }

        let order = visiblePins(query: query.trimmed)
        let moved = withAnimation(Self.slide) {
            drag.settle(order: order, heights: rowHeights, fallbackHeight: 54) { neighbour, placeAfter in
                model.settings.moveModel(pin, to: neighbour, placeAfter: placeAfter)
            }
        }
        if moved {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func dragEnded() {
        guard drag.id != nil else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { drag = RowDrag() }
    }

    private struct PinnedRowHeightReporter: ViewModifier {
        let pin: ModelPin
        @Binding var heights: [ModelPin: CGFloat]

        func body(content: Content) -> some View {
            content.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                if heights[pin] != height { heights[pin] = height }
            }
        }
    }

    /// Whether a model matches the search by name, description or provider.
    static func matches(_ option: ModelOption?, id: String, provider: ProviderKind, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let fields = [option?.shortName, option?.name, option?.detail, id, provider.displayName]
        return fields.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

private struct PinnedModelRow: View {
    @Environment(AppModel.self) private var model
    let pin: ModelPin
    /// Lifted and following the pointer.
    let isDragged: Bool
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var isPresented = false
    @State private var isHovering = false
    /// Whether the pointer is over the reorder grip, which brightens its icon.
    @State private var isHoveringGrip = false

    var body: some View {
        let settings = model.settings
        let option = model.providers.model(pin.modelID, for: pin.provider)
        let preference = settings.preference(for: pin.provider, model: pin.modelID)
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Chrome.secondaryText.opacity(isHoveringGrip ? 1 : 0.7))
                .frame(width: 24, height: 24)
                .contentShape(.rect)
                .onHover { hovering in isHoveringGrip = hovering }
                .pointerStyle(isDragged ? .grabActive : .grabIdle)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in onDragChanged(value.translation.height) }
                        .onEnded { _ in onDragEnded() }
                )
                .help("Drag to reorder")
                .accessibilityLabel(Text("Drag to reorder"))
            Button {
                isPresented = true
            } label: {
                HStack(spacing: 12) {
                    ProviderIcon(provider: pin.provider, size: 16)
                        .foregroundStyle(Chrome.primaryText)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: option?.shortName ?? pin.modelID)
                            .font(.system(size: 13))
                            .foregroundStyle(Chrome.primaryText)
                        Text(verbatim: summary(option: option, preference: preference))
                            .font(.system(size: 11))
                            .foregroundStyle(Chrome.secondaryText)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                        .foregroundStyle(Chrome.secondaryText)
                        .opacity(isHovering ? 1 : 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                EffortSliderCard(
                    modelName: option?.shortName ?? pin.modelID,
                    provider: pin.provider,
                    efforts: option?.efforts ?? [],
                    defaultEffort: option?.defaultEffort,
                    supportsFast: option?.supportsFast ?? false,
                    effort: Binding(
                        get: { settings.preference(for: pin.provider, model: pin.modelID).effort },
                        set: { effort in
                            var updated = settings.preference(for: pin.provider, model: pin.modelID)
                            updated.effort = effort
                            settings.setPreference(updated, for: pin.provider, model: pin.modelID)
                        }
                    ),
                    fastMode: Binding(
                        get: { settings.preference(for: pin.provider, model: pin.modelID).fastMode },
                        set: { isOn in
                            var updated = settings.preference(for: pin.provider, model: pin.modelID)
                            updated.fastMode = isOn
                            settings.setPreference(updated, for: pin.provider, model: pin.modelID)
                        }
                    ),
                    onReset: { settings.setPreference(ModelPreference(), for: pin.provider, model: pin.modelID) }
                )
                .frame(width: 330)
                .presentedChrome()
            }

            RowControl(symbol: "minus.circle", help: "Remove from the picker", isEnabled: true) {
                withAnimation(Chrome.panelSlide) { settings.removeFromModelList(pin) }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 9)
        // Lifted: a touch larger with a shadow over an opaque fill, so the rows
        // sliding underneath never show through.
        .background {
            if isDragged {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Chrome.overlay(0.12))
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
            }
        }
        .scaleEffect(isDragged ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isDragged)
    }

    private func summary(option: ModelOption?, preference: ModelPreference) -> String {
        var parts = [pin.provider.displayName]
        if let option, !option.efforts.isEmpty {
            parts.append(String(format: Chrome.localized("%@ effort"), Chrome.localized(ModelOption.effortTitle(preference.effort ?? option.defaultEffort ?? ""))))
        }
        if preference.fastMode, option?.supportsFast == true { parts.append(Chrome.localized("Fast")) }
        return parts.joined(separator: " · ")
    }
}

private struct RowControl: View {
    let symbol: String
    let help: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Chrome.secondaryText)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help(Text(verbatim: Chrome.localized(help)))
        .accessibilityLabel(Text(verbatim: Chrome.localized(help)))
    }
}

private struct ProviderModelsSection: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderKind
    var query = ""

    /// Lives on the page (`providerExpansion`), so typing in the search field — which
    /// rebuilds this section — doesn't reset it. Absent there means expanded.
    @Binding var isExpanded: Bool

    var body: some View {
        let settings = model.settings
        let registry = model.providers
        // The catalogue is the stable row set: the ForEach below always walks it in
        // catalogue order, and visibility only opens or closes each row's reveal.
        let catalogue = registry.models(for: provider)
        let isFull = settings.modelList.count >= AppSettings.modelListLimit
        let isFiltering = !query.isEmpty
        // Search shows only matches; otherwise expanded shows everything and collapsed
        // shows just the chosen models, all in catalogue order.
        let visibleIDs = Set(catalogue.filter { option in
            isFiltering
                ? ModelsSettingsPage.matches(option, id: option.id, provider: provider, query: query)
                : isExpanded || settings.isInModelList(ModelPin(provider: provider, modelID: option.id))
        }.map(\.id))
        let firstVisibleID = catalogue.first { visibleIDs.contains($0.id) }?.id
        // Collapsed with nothing chosen closes the card outright.
        let cardVisible = isExpanded || isFiltering || !visibleIDs.isEmpty
        VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
            CollapsibleProviderHeader(provider: provider, isExpanded: $isExpanded, subject: "model list")
            // An eager surface instead of ChromeCard: its LazyVStack rebuilds rows
            // that stay mounted while their reveal animates. Same fill and shape.
            VStack(spacing: 0) {
                if catalogue.isEmpty {
                    // The loading/empty row is the expanded state; collapsed closes it.
                    ChromeRevealLayout(fraction: cardVisible ? 1 : 0) {
                        ChromeRow(title: registry.loadingCatalogs.contains(provider) ? "Loading models…" : "No models loaded") {
                            Button("Load models") {
                                Task { await registry.loadCatalog(provider, force: true) }
                            }
                            .buttonStyle(.glass)
                            .disabled(registry.loadingCatalogs.contains(provider))
                        }
                    }
                    .clipped()
                    .disabled(!cardVisible)
                    .allowsHitTesting(cardVisible)
                    .accessibilityHidden(!cardVisible)
                } else {
                    ForEach(catalogue, id: \.id) { option in
                        let pin = ModelPin(provider: provider, modelID: option.id)
                        let isAdded = settings.isInModelList(pin)
                        let isVisible = visibleIDs.contains(option.id)
                        // Divider and row reveal independently: a row's divider exists
                        // only when a visible row sits above it (never one on top).
                        ChromeRevealLayout(fraction: isVisible && option.id != firstVisibleID ? 1 : 0) {
                            ChromeRowDivider()
                        }
                        .clipped()
                        ChromeRevealLayout(fraction: isVisible ? 1 : 0) {
                            ChromeRow(title: option.shortName, detail: option.detail) {
                                HStack(spacing: 10) {
                                    if option.supportsFast {
                                        Image(systemName: "bolt")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Chrome.secondaryText)
                                            .help("Supports fast mode")
                                    }
                                    Button {
                                        // Re-filtering mid-search is instant, like the
                                        // rest of the page; otherwise rows slide.
                                        if isFiltering {
                                            if isAdded { settings.removeFromModelList(pin) } else { settings.addToModelList(pin) }
                                        } else {
                                            withAnimation(Chrome.panelSlide) {
                                                if isAdded { settings.removeFromModelList(pin) } else { settings.addToModelList(pin) }
                                            }
                                        }
                                    } label: {
                                        Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                                            .font(.system(size: 17))
                                            .foregroundStyle(isAdded ? Chrome.accent : Chrome.secondaryText)
                                            .contentTransition(.symbolEffect(.replace))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!isAdded && isFull)
                                    // A plain button does not dim itself; the same 0.35 as
                                    // every other disabled control on this page.
                                    .opacity(!isAdded && isFull ? 0.35 : 1)
                                    .help(Text(verbatim: isAdded ? Chrome.localized("Remove from the picker") : (isFull ? String(format: Chrome.localized("The picker holds up to %lld models"), AppSettings.modelListLimit) : Chrome.localized("Add to the picker"))))
                                    .accessibilityLabel(Text(verbatim: String(format: Chrome.localized(isAdded ? "Remove %@ from the picker" : "Add %@ to the picker"), option.shortName)))
                                }
                            }
                        }
                        .clipped()
                        .disabled(!isVisible)
                        .allowsHitTesting(isVisible)
                        .accessibilityHidden(!isVisible)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous)
                    .fill(Chrome.overlay(0.03))
            )
            .clipShape(RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous))
            // Search re-filters instantly, typing and clearing alike; header toggles
            // still animate (their transaction never touches `query`).
            .animation(nil, value: query)
            // Collapsed rows are neither tappable nor in the accessibility tree.
            .allowsHitTesting(cardVisible)
            .accessibilityHidden(!cardVisible)
        }
        .task { await registry.loadCatalog(provider) }
    }
}

/// The disclosure header over one provider's settings or model card.
struct CollapsibleProviderHeader: View {
    let provider: ProviderKind
    @Binding var isExpanded: Bool
    /// What the disclosure shows, named in the help and the accessibility hint.
    let subject: String

    var body: some View {
        Button {
            withAnimation(Chrome.panelSlide) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                ProviderIcon(provider: provider, size: 16)
                    .foregroundStyle(Chrome.primaryText)
                Text(verbatim: provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(ChromeQuietButtonStyle())
        .frame(height: 22)
        .help(Text(verbatim: String(format: Chrome.localized(isExpanded ? "Hide the %@" : "Show the %@"), Chrome.localized(subject))))
        .accessibilityLabel(Text(verbatim: provider.displayName))
        .accessibilityValue(Text(verbatim: Chrome.localized(isExpanded ? "Expanded" : "Collapsed")))
        .accessibilityHint(Text(verbatim: String(format: Chrome.localized("Shows or hides the %@"), Chrome.localized(subject))))
        .accessibilityAddTraits(.isHeader)
    }
}
