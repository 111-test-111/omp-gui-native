import SwiftUI

// Droppy Code by Jordy Spruit (Droppy), https://getdroppycode.app. Modified for OMP GUI.
// Adapted from its October 9 activity tree (e7dd8dcb), retaining OMP's
// ordered work groups, native tool identities and independently bounded details.
enum ActivityMetrics {
    static let trunkX: CGFloat = 12.5
    static let gutterWidth: CGFloat = 32
    static let stepPadding: CGFloat = 8
    static let bendRadius: CGFloat = 6
    static let fold = Animation.easeOut(duration: 0.14)
    static let arrival = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.36)

    @MainActor static var branchY: CGFloat {
        stepPadding + max(TimelineMetrics.iconWidth, TypeScale.shared.content(13) * 1.2) / 2
    }
}

private struct ActivityTreeStyleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var activityTreeStyle: Bool {
        get { self[ActivityTreeStyleKey.self] }
        set { self[ActivityTreeStyleKey.self] = newValue }
    }
}

/// Flush-leading summaries share a trailing chevron; only the whole turn carries OMP's mark.
struct ActivityHeaderLabel: View {
    let title: String
    let isOpen: Bool
    var isActive = false
    var canExpand = true
    var showsOMPLogo = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if showsOMPLogo {
                ProviderIcon(provider: .omp, size: 14)
                    .accessibilityHidden(true)
            }
            Text(verbatim: title)
                .lineLimit(1)
                .truncationMode(.tail)
            if canExpand {
                Image(systemName: "chevron.down")
                    .font(.symbol(.caption2, weight: .semibold))
                    .rotationEffect(.degrees(isOpen ? 0 : -90))
                    .accessibilityHidden(true)
            }
        }
        .font(.chat(.callout))
        .foregroundStyle(isHovering || isActive ? Chrome.primaryText : Chrome.secondaryText)
        .frame(minHeight: 26)
        .padding(.trailing, 4)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }
}

private struct ActivityBranch: Shape {
    let branchY: CGFloat
    var continues: Bool

    func path(in rect: CGRect) -> Path {
        let x = ActivityMetrics.trunkX
        let radius = ActivityMetrics.bendRadius
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: branchY - radius))
        path.addQuadCurve(to: CGPoint(x: x + radius, y: branchY), control: CGPoint(x: x, y: branchY))
        path.addLine(to: CGPoint(x: ActivityMetrics.gutterWidth - 4, y: branchY))
        if continues {
            path.move(to: CGPoint(x: x, y: branchY - radius))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        return path
    }
}

/// Decorative connectors never intercept a tool, file link or text selection.
struct ActivityStep<Content: View>: View {
    let id: String
    let continues: Bool
    @ViewBuilder let content: Content
    @Environment(\.timelineLiveAppearance) private var liveAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.revealTimelineEnd) private var revealBox
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    @State private var revealed = false

    var body: some View {
        content
            .padding(.vertical, ActivityMetrics.stepPadding)
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 4)
            .padding(.leading, ActivityMetrics.gutterWidth)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) {
                ActivityBranch(branchY: ActivityMetrics.branchY, continues: continues)
                    .trim(from: 0, to: revealed ? 1 : 0)
                    .stroke(Chrome.primaryText.opacity(0.12), lineWidth: 1)
                    .frame(width: ActivityMetrics.gutterWidth)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onAppear {
                guard !revealed else { return }
                var arrives = false
                if let presentation = revealBox?.presentation {
                    // Reopening a group or remounting a virtualized block keeps its arrival.
                    if presentation.revealedActivity.count >= 4_096 { presentation.revealedActivity.removeAll(keepingCapacity: true) }
                    arrives = presentation.revealedActivity.insert(id).inserted
                }
                if arrives && liveAppearance && !reduceMotion && !performanceMode {
                    withAnimation(ActivityMetrics.arrival) { revealed = true }
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { revealed = true }
                }
            }
    }
}

/// A visual wrapper over one existing OMP work group. It never repartitions entries.
struct ActivityGroup: View {
    let id: String
    let entries: [TimelineEntry]
    let runtime: ThreadRuntime
    var workingDirectory: String?
    var isLive = false
    @Environment(\.revealTimelineEnd) private var revealBox
    @Environment(\.timelineBlockID) private var blockID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    @State private var fallbackPin: Bool?

    private var pin: Bool? {
        get { revealBox?.presentation.working[id] ?? fallbackPin }
        nonmutating set {
            if let revealBox { revealBox.presentation.working[id] = newValue }
            else { fallbackPin = newValue }
        }
    }

    var body: some View {
        let isOpen = pin ?? isLive
        let base = entries.contains { $0.kind == .tool } ? WorkGroupSummary.text(for: entries)
            : Chrome.localized(entries.contains { $0.kind == .reasoning } ? "Thought process" : "Earlier steps")
        let title = entries.count > 1 ? String(format: Chrome.localized("%@ · %lld steps"), base, Int64(entries.count)) : base
        VStack(alignment: .leading, spacing: 0) {
            Button {
                revealBox?.disclosure(blockID)
                withAnimation(reduceMotion || performanceMode ? nil : ActivityMetrics.fold) { pin = !isOpen }
            } label: {
                ActivityHeaderLabel(title: title, isOpen: isOpen, isActive: isLive)
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: Chrome.localized(isOpen ? "Hide these steps" : "Show these steps")))
            .accessibilityValue(Text(isOpen ? "Expanded" : "Collapsed"))
            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    WorkSteps(entries: entries, runtime: runtime, workingDirectory: workingDirectory)
                }
                .environment(\.activityTreeStyle, true)
                .transition(.opacity)
            }
        }
    }
}

/// One status indicator per running turn; the existing Card / Line preference remains.
struct ActivityStatusLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.chatColumnIsShown) private var isColumnShown
    let runtime: ThreadRuntime
    var entries: [TimelineEntry] = []
    @State private var now = Date.now

    var body: some View {
        let startedAt = runtime.turnStartedAt ?? now
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let word = WorkingWords.word(seed: WorkingWords.seed(runtime.threadID.uuidString), elapsedSeconds: Int64(elapsed))
        let title = runtime.quietMinutes.map { String(format: Chrome.localized("No response for %d min…"), $0) } ?? "\(word)…"
        let card = model.settings.showsWorkingCard
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                WorkingSpinner(cellSize: 2.5)
                Text(verbatim: title)
                Text(verbatim: RelativeTime.duration(elapsed))
                    .font(.chat(.subheadline).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if card {
                HydraProgressBar(runtime: runtime, startedAt: startedAt, finishedAt: nil,
                                 status: .running, tint: Chrome.accent, entries: entries)
            }
        }
        .font(.chat(.callout))
        .foregroundStyle(Chrome.secondaryText)
        .padding(card ? 14 : 0)
        .frame(maxWidth: card ? 380 : nil, alignment: .leading)
        .background {
            if card {
                RoundedRectangle(cornerRadius: TimelineMetrics.pillRadius, style: .continuous)
                    .fill(.quaternary.opacity(0.32))
            }
        }
        .accessibilityElement(children: .combine)
        .task(id: isColumnShown && FrontMonitor.shared.isVisible) {
            guard isColumnShown && FrontMonitor.shared.isVisible else { return }
            now = .now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                now = .now
            }
        }
    }
}
