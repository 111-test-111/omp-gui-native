import AppKit
import SwiftUI

struct OMPSideQuestionButton: View {
    @Environment(\.chatColumnIsShown) private var isColumnShown
    let runtime: ThreadRuntime
    @State private var presented = false

    var body: some View {
        Button { presented.toggle() } label: {
            Image(systemName: "plus.message").font(Chrome.iconFont)
        }
        .buttonStyle(.chip(active: presented))
        .help("Side question")
        .accessibilityLabel(Text("Side question"))
        // The conversation has a fixed viewport. Measure it before showing, rather
        // than resizing and re-showing the panel during its opening animation.
        .badgePopover(isPresented: $presented) { OMPSideQuestionPopover(runtime: runtime) }
        .onChange(of: runtime.threadID) { _, _ in presented = false }
        .onChange(of: runtime.ompSideQuestion.connectionID) { _, _ in presented = false }
        .onChange(of: isColumnShown) { _, shown in if !shown { presented = false } }
    }
}

struct OMPSideQuestionPopover: View {
    /// The popover's fixed width; the composer's text measurement derives from it.
    static let width: CGFloat = 560

    @Environment(\.closePopover) private var closePopover
    let runtime: ThreadRuntime

    var body: some View {
        let unsupported = runtime.ompCapabilities["btw"] == .unsupported
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Side question").font(.ui(.title3, weight: .semibold))
                Spacer()
                ChromeCircleButton(symbol: "xmark", help: "Close") { closePopover?() }
            }
            Divider()
            if unsupported {
                OMPUnsupportedFeatureNotice(feature: .sideQuestion)
            } else {
                SideQuestionConversation(runtime: runtime)
                SideQuestionErrorLine(runtime: runtime)
                SideQuestionComposer(runtime: runtime, onClose: { closePopover?() })
            }
        }
        .padding(14).frame(width: Self.width, height: unsupported ? nil : 600)
        .foregroundStyle(Chrome.primaryText)
    }
}

/// The topic as the conversation's own rows: the question in the chat's user bubble,
/// the answer with the chat's reply rendering. Pins to the end like the timeline: at
/// the end it follows the stream; scrolled up, growth holds what is being read in place.
private struct SideQuestionConversation: View {
    let runtime: ThreadRuntime
    /// The same end-of-content slack the timeline pins with.
    private static let pinSlack: CGFloat = 48
    @State private var pinned = true

    private var state: OMPSideQuestionSnapshot { runtime.ompSideQuestion }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TimelineMetrics.rowSpacing) {
                ForEach(state.turns) { turn in
                    SideQuestionTurn(turn: turn, runtime: runtime)
                        .equatable()
                }
                if showsWorking {
                    ComposerWorkingDots()
                        .frame(height: 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(pinned ? .bottom : .top, for: .sizeChanges)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height
        } action: { _, distance in
            let atEnd = distance < Self.pinSlack
            if atEnd != pinned { pinned = atEnd }
        }
        .frame(maxHeight: .infinity)
        .id(state.recordID)
    }

    /// Dots while an ask or a cancel is pending and no answer text is streaming yet.
    private var showsWorking: Bool {
        guard state.hasLiveWork else { return false }
        guard let last = state.turns.last, last.status == .running else { return true }
        return last.answer.isEmpty
    }
}

/// One exchange. The bubble is the chat's user bubble and the answer the chat's reply
/// rendering, so a side question reads exactly like the conversation beside it.
private struct SideQuestionTurn: View, Equatable {
    let turn: OMPSideQuestionSnapshot.Turn
    let runtime: ThreadRuntime

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.turn == rhs.turn && lhs.runtime === rhs.runtime
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TimelineMetrics.rowSpacing) {
            // Keep the prompt's text exactly as written, like the chat's user row.
            Text(verbatim: turn.question)
                .font(AppFont.swiftUI(size: TypeScale.shared.content(13)))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 14)
                // The tail hangs past the body; the text keeps its inset from the body.
                .padding(.trailing, 14 + UserBubble.tail)
                .padding(.vertical, 9)
                .background(.tint.opacity(0.14), in: UserBubble())
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 96)
            if !turn.answer.isEmpty {
                MarkdownView(text: turn.answer, isStreaming: turn.status == .running).equatable()
                    .messageMenu(text: turn.answer, runtime: runtime)
            }
            if let error = turn.error, !error.isEmpty {
                Text(verbatim: error)
                    .font(.chat(.callout))
                    .foregroundStyle(Chrome.warning)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// What the last ask, save or cancel failed with, between the topic and the box.
private struct SideQuestionErrorLine: View {
    let runtime: ThreadRuntime

    var body: some View {
        let state = runtime.ompSideQuestion
        if let error = state.persistenceError ?? state.error ?? runtime.sideQuestionDraft.error, !error.isEmpty {
            Text(verbatim: error)
                .font(.chat(.callout))
                .foregroundStyle(Chrome.warning)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The chat's own box for the question: the same text view and send button as the
/// conversation's composer, on the shared glass input surface every popover field uses.
/// Return asks, Shift/Option-Return adds a newline, Escape closes; while an answer is
/// on its way the send button is the cancel.
private struct SideQuestionComposer: View {
    let runtime: ThreadRuntime
    let onClose: () -> Void
    @State private var controller = ComposerController()
    @State private var textHeight: CGFloat

    private static var minHeight: CGFloat { ComposerTextMetrics.height(lines: ComposerTextMetrics.restingLines) }
    private static var maxHeight: CGFloat { ComposerTextMetrics.height(lines: 5) }
    /// The field's text width: the popover less its padding and the box's own.
    private static let textWidth: CGFloat = OMPSideQuestionPopover.width - 2 * 14 - 14 - 8
    private var composerHeight: CGFloat { min(max(textHeight, Self.minHeight), Self.maxHeight) }

    init(runtime: ThreadRuntime, onClose: @escaping () -> Void) {
        self.runtime = runtime
        self.onClose = onClose
        // Sized for its draft from the first layout: the text view reports its height a
        // pass later, and a box that opened at the resting height and then grew played
        // that growth over the popover's own appearance (see PromptEditor).
        _textHeight = State(initialValue: Self.measuredHeight(of: runtime.sideQuestionDraft.text))
    }

    /// The text view's height for `text` at the box's width, the way the view measures
    /// itself (`ComposerTextView.Coordinator.updateHeight`): the used rect plus the container inset.
    private static func measuredHeight(of text: String) -> CGFloat {
        let bounds = (text.isEmpty ? " " : text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: ComposerTextMetrics.pointSize)]
        )
        return ceil(max(ComposerTextMetrics.lineHeight, bounds.height) + ComposerTextMetrics.containerInset * 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SideQuestionField(runtime: runtime, controller: controller, textHeight: $textHeight, onKey: handleKey)
                // The chat box's growth: the text view takes its new height at once,
                // so it lays out every line with nothing to scroll; only the clip
                // around it grows and shrinks.
                .frame(height: composerHeight)
                .transaction { $0.animation = nil }
                .frame(height: composerHeight, alignment: .top)
                .clipped()
                .animation(.smooth(duration: 0.28), value: composerHeight)
            SideQuestionControls(runtime: runtime, send: send)
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .chromeGlassInputSurface()
    }

    private func handleKey(_ key: ComposerKey) -> Bool {
        switch key {
        case .submit, .steer:
            send()
            return true
        case .escape:
            onClose()
            return true
        case .up, .down, .tab, .deleteAtStart:
            return false
        }
    }

    private func send() {
        guard !runtime.ompSideQuestion.hasLiveWork else { return }
        runtime.submitOMPSideQuestion(continuing: runtime.ompSideQuestion.canFollowUp)
    }
}

/// The box's text view alone, holding the draft binding: a keystroke re-renders this
/// and the controls' draft reader, never the conversation above.
private struct SideQuestionField: View {
    let runtime: ThreadRuntime
    let controller: ComposerController
    @Binding var textHeight: CGFloat
    let onKey: (ComposerKey) -> Bool

    var body: some View {
        @Bindable var draft = runtime.sideQuestionDraft
        ComposerTextView(
            text: $draft.text,
            height: $textHeight,
            placeholder: Chrome.localized("Your side question"),
            controller: controller,
            onKey: onKey,
            // Side questions carry text only.
            onAttach: { _ in },
            onCursorChange: { _ in }
        )
        .accessibilityLabel(Text("Your side question"))
    }
}

/// The box's controls: a new-topic chip beside the send button while the topic can
/// still grow, and the send button itself, which is the cancel while work is live.
private struct SideQuestionControls: View {
    let runtime: ThreadRuntime
    let send: () -> Void

    private var state: OMPSideQuestionSnapshot { runtime.ompSideQuestion }

    private var canSubmit: Bool {
        runtime.canAskOMPSideQuestion
            && !runtime.sideQuestionDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && runtime.sideQuestionDraft.text.utf8.count <= OMPSideQuestionSnapshot.maximumInputBytes
    }

    var body: some View {
        let stops = state.hasLiveWork
        let enabled = stops
            ? state.pendingCancellationID == nil && !state.draining && runtime.ompCapabilities["btw_cancel"] != .unsupported
            : canSubmit
        let help = stops ? "Cancel side question" : state.canFollowUp ? "Ask follow-up" : state.recordID == nil ? "Ask side question" : "New topic"
        HStack(spacing: 8) {
            if state.canFollowUp {
                Button { runtime.submitOMPSideQuestion(continuing: false) } label: {
                    Image(systemName: "plus.message").font(Chrome.iconFont)
                }
                .buttonStyle(.chip(active: false))
                .focusable(false)
                .disabled(!canSubmit)
                .help("New topic")
                .accessibilityLabel(Text("New topic"))
            }
            Spacer(minLength: 8)
            Button {
                if stops { runtime.cancelOMPSideQuestion() } else { send() }
            } label: {
                Image(systemName: stops ? "stop.fill" : "arrow.up")
                    .font(Chrome.iconFont)
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
                    .background(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .circle)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .disabled(!enabled)
            .help(Text(verbatim: Chrome.localized(help)))
            .accessibilityLabel(Text(verbatim: Chrome.localized(help)))
        }
        .frame(maxWidth: .infinity)
    }
}
