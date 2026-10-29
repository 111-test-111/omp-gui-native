import SwiftUI

/// Only the timeline is covered: title, composer and navigation remain usable.
/// Opacity preserves the mounted native text views, their layout and scroll state.
struct ChatMathLoading: ViewModifier {
    let runtime: ThreadRuntime
    @Environment(\.chatColumnIsShown) private var isShown
    @State private var preparation = ChatMathPreparation()
    @State private var mountsContent = false

    func body(content: Content) -> some View {
        let needsAssessment = !preparation.hasInitialAssessment
        let loading = runtime.isLoadingHistory || runtime.nativeAgentHistoryLoading
        let dense = preparation.isDenseChat || (isShown && (needsAssessment || loading) && ChatMathPreparation.isDense(runtime.entries.reversed().lazy.compactMap {
            if case .assistant(let message) = $0.item.content, !message.isStreaming { return message.text }
            return nil
        }))
        let entering = isShown && dense && (needsAssessment || (loading && !preparation.isHistoryLoading))
        let hidden = isShown && (preparation.presentation.hidesContent || entering)
        Group {
            if mountsContent || !dense { content }
            else { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
            .environment(\.chatMathPreparation, preparation)
            .opacity(hidden ? 0 : 1)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
            .overlay {
                if isShown && (preparation.presentation.showsSpinner || entering) {
                    VStack(spacing: 14) {
                        WorkingSpinner(cellSize: 5)
                        Text("Waiting for the chat to load")
                            .font(.chat(size: 13))
                            .foregroundStyle(Chrome.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Waiting for the chat to load"))
                    .onAppear { preparation.spinnerDidAppear() }
                }
            }
            .task(id: Request(shown: isShown, loading: loading, dense: dense)) {
                if isShown { preparation.activate(dense: dense, historyLoading: loading) }
                else { preparation.suspend() }
                if !mountsContent {
                    // Commit the small indicator before constructing a dense native
                    // timeline. This delay happens only on its first mount.
                    if isShown && dense { try? await Task.sleep(for: .milliseconds(20)) }
                    guard !Task.isCancelled else { return }
                    mountsContent = true
                }
            }
            .onDisappear { preparation.suspend() }
    }
    private struct Request: Hashable { let shown: Bool, loading: Bool, dense: Bool }
}
