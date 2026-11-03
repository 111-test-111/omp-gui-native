import SwiftUI

extension WorkspacePanel {
    var shortcut: AppShortcut {
        switch self {
        case .git: .openGitPanel
        case .trajectory: .openSessionHistoryPanel
        case .review: .openReviewPanel
        case .context: .openContextPanel
        case .terminal: .openTerminalPanel
        case .debug: .openDebugPanel
        case .browser: .openBrowserPanel
        case .files: .openFilesPanel
        }
    }
}

struct WorkspacePanelPicker: View {
    let store: FilePreviewStore

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                GlassEffectContainer(spacing: 8) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12),
                                             count: geometry.size.width >= 680 ? 2 : 1), spacing: 12) {
                        ForEach(WorkspacePanel.allCases, id: \.self) { panel in
                            WorkspacePanelPickerCard(panel: panel) { store.openPanel(panel) }
                        }
                    }
                    .frame(maxWidth: 720)
                }
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }
}

struct WorkspacePanelPickerCard: View {
    @Environment(\.chromeLocalizationBundle) private var localizationBundle
    let panel: WorkspacePanel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: panel.symbol)
                        .font(.symbol(.body))
                        .foregroundStyle(Chrome.accent)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text(verbatim: Chrome.localized(panel.title, bundle: localizationBundle))
                        .font(.ui(.body, weight: .medium))
                        .foregroundStyle(Chrome.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let label = ShortcutStore.label(for: panel.shortcut) {
                        Text(verbatim: label)
                            .font(.ui(.caption, weight: .medium))
                            .foregroundStyle(Chrome.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Chrome.overlay(0.05), in: .rect(cornerRadius: 5))
                            .fixedSize()
                    }
                }
                Text(verbatim: Chrome.localized(panel.shortcut.detail, bundle: localizationBundle))
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
            .chromeGlassCard()
            .contentShape(.rect(cornerRadius: Chrome.cardCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workspace.open-panel.\(panel.rawValue)")
    }
}
