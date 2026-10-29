import SwiftUI

/// The composer activates Goal explicitly; native goal state keeps its control
/// visible through an explicitly observed completion. The popover never owns
/// another objective draft.
struct OMPGoalButton: View {
    @Environment(\.chatColumnIsShown) private var isColumnShown
    let runtime: ThreadRuntime
    @State private var isPresented = false
    private var summary: OMPGoal? { runtime.ompGoal.goal ?? (runtime.isOMPGoalComposerMode ? nil : runtime.ompGoal.completedGoal) }

    var body: some View {
        if runtime.showsOMPGoalEntry {
            Button { isPresented.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: summary?.status == .complete ? "checkmark.circle" : "target").font(Chrome.inlineIconFont)
                    if summary?.status == .complete {
                        Text("Goal completed")
                    } else if let goal = runtime.ompGoal.goal {
                        Text(verbatim: goal.objective).lineLimit(1).truncationMode(.tail).frame(maxWidth: 110)
                    } else { Text("Goal") }
                }
                .font(.ui(size: 12.5, weight: .medium)).foregroundStyle(Chrome.primaryText)
                .padding(.horizontal, Chrome.capsuleHorizontalPadding)
                .frame(height: Chrome.capsuleContentHeight).padding(.vertical, Chrome.capsuleVerticalPadding)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain).fixedSize().chromeGlassCapsule()
            .background { NoWindowDragArea() }
            .help("Show native goal").accessibilityLabel(Text("Native goal"))
            .accessibilityValue(Text(verbatim: Chrome.localized(summary?.status.title ?? "Unknown")))
            .badgePopover(isPresented: $isPresented, liveDetailWidth: 460) { OMPGoalPopover(runtime: runtime) }
            .preference(key: ChromePresentationPreference.self, value: isPresented)
            .onChange(of: runtime.threadID) { _, _ in isPresented = false }
            .onChange(of: runtime.ompSideQuestion.connectionID) { _, _ in isPresented = false }
            .onChange(of: isColumnShown) { _, shown in if !shown { isPresented = false } }
        }
    }
}

private struct OMPGoalPopover: View {
    @Environment(\.closePopover) private var closePopover
    @Bindable var runtime: ThreadRuntime
    @State private var working = false
    @State private var error: String?

    private var snapshot: OMPGoalSnapshot { runtime.ompGoal }
    private var busy: Bool { working || runtime.ompGoalComposerWorking || runtime.ompGoalControlWorking || snapshot.pending != nil }
    private var unsupported: Bool { runtime.ompCapabilities["goal"] == .unsupported }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Native goal").font(.ui(.title3, weight: .semibold))
                Spacer(minLength: 8)
                ChromeCircleButton(symbol: "arrow.clockwise", help: "Refresh") {
                    perform { try await runtime.refreshOMPGoal() }
                }.disabled(!runtime.isOMPGoalConnected || busy || unsupported)
                ChromeCircleButton(symbol: "xmark", help: "Close") { closePopover?() }
            }
            Divider()
            if unsupported {
                OMPUnsupportedFeatureNotice(feature: .goal)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if runtime.ompCapabilities.goalIsDisabled {
                            note("Goal mode is disabled in OMP. Enable goal.enabled in OMP, then reconnect this conversation.")
                        }
                        if let goal = snapshot.goal ?? (runtime.isOMPGoalComposerMode ? nil : snapshot.completedGoal) {
                            Text(verbatim: Chrome.localized(goal.status.title)).font(.ui(.headline))
                            if snapshot.hasUnrecognizedState {
                                Text(verbatim: "\(goal.rawStatus) / \(snapshot.modeState?.rawMode ?? "—")").font(.ui(.callout))
                                note("OMP reported an unfamiliar goal state. Update OMP GUI before changing this goal.")
                            }
                            Text(verbatim: goal.objective).font(.ui(.body)).textSelection(.enabled)
                            if goal.objectiveIsTruncated { note("Goal text is limited to 64 KiB in this view.") }
                            metric("Goal tokens used", goal.tokensUsed.formatted())
                            metric("Token budget", goal.tokenBudget?.formatted() ?? Chrome.localized("Not set"))
                            metric("Reported time (seconds)", goal.timeUsedSeconds.formatted(.number.precision(.fractionLength(0...2))))
                            note("Usage reflects OMP's latest report.")
                            if goal.hasReachedTokenBudget && !goal.status.isTerminal {
                                note("This goal has used its token budget. Drop it and create a new goal with a new budget; usage starts at zero.")
                            }
                            if snapshot.observationIsStale { note("Previous observation") }
                        } else {
                            note("Write your goal in the message box.")
                            TextField("Optional token budget", text: $runtime.ompGoalBudgetDraft)
                                .textFieldStyle(.chromeGlass).disabled(busy || runtime.ompCapabilities.goalIsDisabled)
                                .accessibilityLabel(Text("Optional token budget"))
                            note("The token budget is a soft limit.")
                        }
                        if snapshot.pending?.outcomeUnknown == true {
                            note("OMP has not confirmed the goal action. Its outcome is unknown; it will not be sent again automatically.")
                        } else if busy {
                            Text("Waiting for OMP to confirm the goal action…").font(.ui(.callout))
                        }
                        if let message = snapshot.error ?? runtime.ompGoalComposerError ?? error {
                            Text(verbatim: message).font(.ui(.callout)).foregroundStyle(Chrome.danger).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity)
                if let goal = snapshot.goal, !goal.status.isTerminal {
                    Divider()
                    HStack(spacing: 8) {
                        if goal.status == .paused {
                            Button("Resume goal") { perform { try await runtime.changeOMPGoal(.resume, expectedGoalID: goal.id) } }
                                .buttonStyle(.glass).disabled(goal.hasReachedTokenBudget)
                        } else {
                            Button("Pause goal") { perform { try await runtime.changeOMPGoal(.pause, expectedGoalID: goal.id) } }
                                .buttonStyle(.glass)
                        }
                        Spacer(minLength: 8)
                        Button("Drop goal", role: .destructive) { perform { try await runtime.changeOMPGoal(.drop, expectedGoalID: goal.id) } }
                            .buttonStyle(.glass)
                    }.disabled(!runtime.canChangeOMPGoal || busy)
                    note("Pause or drop does not stop the current reply.")
                    note("Stopping the current reply also pauses an active goal.")
                }
            }
        }
        .foregroundStyle(Chrome.primaryText).padding(14).frame(width: 460)
        .frame(height: unsupported ? nil : 360)
        .task(id: runtime.isOMPGoalConnected) {
            guard runtime.isOMPGoalConnected, !unsupported else { return }
            do { try await runtime.refreshOMPGoal(); error = nil }
            catch {
                if snapshot.pending == nil {
                    self.error = TextCleanup.utf8Prefix(error.localizedDescription, maximumBytes: OMPGoalLimits.errorBytes)
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack {
            Text(verbatim: Chrome.localized(title))
            Spacer(minLength: 12)
            Text(verbatim: value).monospacedDigit()
        }.font(.ui(.callout)).foregroundStyle(Chrome.secondaryText)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: Chrome.localized(text)).font(.ui(.caption))
            .foregroundStyle(Chrome.secondaryText).fixedSize(horizontal: false, vertical: true)
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        error = nil
        Task { @MainActor in
            defer { working = false }
            do { try await action() }
            catch {
                if snapshot.pending == nil {
                    self.error = TextCleanup.utf8Prefix(error.localizedDescription, maximumBytes: OMPGoalLimits.errorBytes)
                }
            }
        }
    }
}
