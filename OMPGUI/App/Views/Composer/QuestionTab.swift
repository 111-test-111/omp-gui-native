import SwiftUI

/// Keep the whole form beside the badge, including while its popover is closed.
struct QuestionBadgeRow: View {
    let request: QuestionRequest
    let runtime: ThreadRuntime
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingQuestions = false
    var body: some View {
        let count = request.questions.count
        ChatBadge(
            title: count == 1 ? Chrome.localized("1 question") : String(format: Chrome.localized("%d questions"), count),
            caption: "to answer",
            tint: Chrome.threadStatusColor(.question, isDark: colorScheme == .dark),
            needsAttention: true,
            isPresented: $isShowingQuestions,
            liveDetailWidth: QuestionSheet.width
        ) {
            if let item = runtime.pendingInteraction(for: request.instanceID) {
                OMPQuestionForm(item: item, runtime: runtime)
            }
        }
    }
}

struct OMPQuestionForm: View {
    @Bindable var item: OMPInteraction
    let runtime: ThreadRuntime

    var body: some View {
        if let request = item.question {
            if item.state == .waiting || item.state == .submitting {
                QuestionSheet(request: request, draft: $item.draft) { answers, delivered in
                    runtime.answer(request, answers: answers, delivered: delivered)
                }
                .disabled(!item.canSubmit)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(request.questions) { question in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: question.prompt).font(.ui(.body, weight: .semibold))
                                if let answer = item.draft.values[question.id] {
                                    if answer.skipped { Text("Skipped") }
                                    else if let custom = answer.customInput {
                                        Text(verbatim: question.isSecret ? "••••••" : custom.isEmpty ? Chrome.localized("Empty answer") : custom)
                                    } else if !answer.selectedOptions.isEmpty {
                                        Text(verbatim: answer.selectedOptions.joined(separator: ", "))
                                    } else { Text("No saved answer") }
                                } else { Text("No saved answer") }
                            }
                            .font(.ui(.callout)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(16)
                }.frame(width: 460).frame(maxHeight: 360)
            }
        }
    }
}

/// One native ask request, paged without sending any intermediate answers.
/// Each page gets its own measured height — three choices and the answer field
/// fit exactly, further choices scroll at that height — and the badge popover
/// follows the height of the page on view (see ChatBadge.liveDetailWidth).
struct QuestionSheet: View {
    private static let maxHeight: CGFloat = 360
    /// Choices past this count scroll; the viewport keeps this many choices' height.
    private static let visibleChoices = 3
    static let width: CGFloat = 460

    let request: QuestionRequest
    @Binding var draft: QuestionDraft
    let onSend: ([String: QuestionAnswer], @escaping @MainActor (Bool) -> Void) -> Void
    private let pageHeights: [String: CGFloat]
    @Environment(\.closePopover) private var closePopover

    init(request: QuestionRequest, draft: Binding<QuestionDraft>,
         onSend: @escaping ([String: QuestionAnswer], @escaping @MainActor (Bool) -> Void) -> Void) {
        self.request = request
        _draft = draft
        self.onSend = onSend
        var heights: [String: CGFloat] = [:]
        for question in request.questions {
            var height = Self.measure(question, draft: draft.wrappedValue)
            if question.choices.count > Self.visibleChoices {
                var capped = question
                capped.choices = Array(question.choices.prefix(Self.visibleChoices))
                height = min(height, Self.measure(capped, draft: draft.wrappedValue))
            }
            heights[question.id] = min(max(height, 120), Self.maxHeight)
        }
        pageHeights = heights
    }

    /// A page's height as it will lay out live; the same view measures and renders.
    private static func measure(_ question: QuestionRequest.Question, draft: QuestionDraft) -> CGFloat {
        let probe = QuestionPage(question: question, draft: .constant(draft), onSubmit: {})
            .font(.ui(.body))
            .frame(width: Self.width)
        return NSHostingView(rootView: probe).fittingSize.height
    }

    private var page: Int { min(max(0, draft.page), max(0, request.questions.count - 1)) }

    var body: some View {
        let count = request.questions.count
        let answers = draft.answers(for: request)
        let unanswered = draft.unansweredCount(request)
        VStack(alignment: .leading, spacing: 0) {
            if count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        if count <= 10 {
                            ForEach(Array(request.questions.enumerated()), id: \.element.id) { index, question in
                                let answered = answers[question.id]?.isAnswered == true
                                Button { go(to: index) } label: {
                                    Capsule()
                                        .fill(index == page ? Chrome.accent : answered ? Chrome.accent.opacity(0.35) : Chrome.overlay(0.18))
                                        .frame(width: index == page ? 18 : 6, height: 6)
                                        .frame(minWidth: 16, minHeight: 20)
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("Question %d"), index + 1)))
                            }
                        }
                        Text(verbatim: String(format: Chrome.localized("%d of %d"), page + 1, count))
                            .font(.ui(.subheadline)).monospacedDigit()
                            .foregroundStyle(Chrome.secondaryText)
                        Spacer()
                        Button("Skip question") { skipCurrent() }
                            .buttonStyle(.plain)
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                    }
                    if unanswered > 0 {
                        Text(verbatim: unanswered == 1 ? Chrome.localized("1 question still to answer") : String(format: Chrome.localized("%d questions still to answer"), unanswered))
                            .font(.ui(.caption))
                            .foregroundStyle(Chrome.secondaryText)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)
            }

            if request.questions.indices.contains(page) {
                let question = request.questions[page]
                ScrollView(.vertical) {
                    QuestionPage(question: question, draft: $draft, onSubmit: advance)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: Self.width, height: pageHeights[question.id] ?? Self.maxHeight)
                // Offscreen fields must never retain focus or intercept Return.
                .id(question.id)
            }

            if let deadline = request.deadline {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: String(format: Chrome.localized("Expires in %lld seconds"), Int64(max(0, deadline.timeIntervalSince(context.date)))))
                        .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            Divider()
            HStack(spacing: 8) {
                Button { send([:]) } label: {
                    Text(verbatim: Chrome.localized(count > 1 ? "Skip all" : "Skip"))
                }
                    .buttonStyle(.glass)
                    .help("Sends no answers and lets the agent carry on")
                Spacer()
                if count > 1 {
                    Button { go(to: page - 1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.glass)
                        .disabled(page == 0)
                        .help("Previous question")
                        .accessibilityLabel(Text("Previous question"))
                }
                if page < count - 1 {
                    Button("Next") { go(to: page + 1) }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .help("Goes to the next question")
                } else {
                    Button("Send") { send(answers) }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(unanswered > 0 || count == 0)
                        .help(Text(verbatim: unanswered == 0
                            ? Chrome.localized("Sends your answers")
                            : (count == 1 ? Chrome.localized("Answer the question to send") : String(format: Chrome.localized("Answer all %d questions to send"), count))))
                }
            }
            .controlSize(.regular)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: Self.width)
        .disabled(draft.isSubmitting)
    }

    private func go(to index: Int) {
        guard request.questions.indices.contains(index) else { return }
        draft.page = index
    }

    private func skipCurrent() {
        guard request.questions.indices.contains(page) else { return }
        draft.skip(request.questions[page])
        if page < request.questions.count - 1 { go(to: page + 1) }
        else if let index = request.questions.firstIndex(where: { draft.answers(for: request)[$0.id]?.isAnswered != true }) {
            go(to: index)
        }
    }

    private func advance() {
        if page < request.questions.count - 1 { go(to: page + 1) }
        else if draft.unansweredCount(request) == 0 { send(draft.answers(for: request)) }
    }

    private func send(_ answers: [String: QuestionAnswer]) {
        guard !draft.isSubmitting else { return }
        draft.isSubmitting = true
        onSend(answers) { accepted in
            draft.isSubmitting = false
            if accepted { closePopover?() }
        }
    }
}

/// The same page is used for measurement and live interaction.
private struct QuestionPage: View {
    let question: QuestionRequest.Question
    @Binding var draft: QuestionDraft
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !question.header.isEmpty {
                Text(verbatim: question.header)
                    .font(.ui(.subheadline, weight: .medium))
                    .foregroundStyle(Chrome.secondaryText)
                    .textCase(.uppercase)
            }
            Text(verbatim: question.prompt)
                .font(.ui(.body, weight: .semibold))
                .foregroundStyle(Chrome.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !question.choices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: Chrome.localized(question.allowsMultiple ? "Select one or more options" : "Select one option"))
                        .font(.ui(.caption))
                        .foregroundStyle(Chrome.secondaryText)
                    ForEach(Array(question.choices.enumerated()), id: \.offset) { index, choice in
                        choiceRow(choice, index: index)
                    }
                }
            }
            if question.allowsOther || question.choices.isEmpty {
                let binding = Binding(
                    get: { draft.values[question.id]?.customInput ?? "" },
                    set: { draft.write($0, for: question) }
                )
                Group {
                    if question.isSecret {
                        SecureField("Your answer", text: binding)
                    } else if question.isMultiline {
                        TextEditor(text: binding)
                            .font(.ui(.body, design: .monospaced))
                            .frame(height: 200)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .chromeGlassInputSurface()
                            .accessibilityLabel(Text(verbatim: question.prompt))
                    } else {
                        TextField(question.placeholder ?? Chrome.localized(question.choices.isEmpty ? "Your answer" : "Something else"), text: binding)
                    }
                }
                .textFieldStyle(.chromeGlass)
                .controlSize(.regular)
                .onSubmit(onSubmit)
                .accessibilityLabel(Text(verbatim: Chrome.localized(question.choices.isEmpty ? "Your answer" : "Something else")))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choiceRow(_ choice: QuestionRequest.Choice, index: Int) -> some View {
        let isSelected = draft.values[question.id]?.selectedOptions.contains(choice.label) == true
        let recommended = question.isRecommended(index)
        let suffix = " (Recommended)"
        let label = choice.label.lowercased().hasSuffix(suffix.lowercased()) ? String(choice.label.dropLast(suffix.count)) : choice.label
        return Button { draft.pick(choice.label, for: question) } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(selected: isSelected))
                    .font(.symbol(size: 14))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Chrome.accent) : AnyShapeStyle(Chrome.secondaryText))
                    .frame(width: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: label)
                            .font(.ui(.body, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(Chrome.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if recommended {
                            Text("Recommended")
                                .font(.ui(.footnote, weight: .medium))
                                .foregroundStyle(Chrome.accent)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Chrome.accent.opacity(0.14)))
                                .fixedSize()
                        }
                    }
                    if let detail = choice.detail, !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.ui(.subheadline))
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? Chrome.accent.opacity(0.12) : Chrome.overlay(0.06)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(verbatim: isSelected ? Chrome.localized("Selected") : Chrome.localized("Not selected")))
        .animation(Chrome.hover, value: isSelected)
    }

    private func symbol(selected: Bool) -> String {
        switch (selected, question.allowsMultiple) {
        case (true, true): "checkmark.square.fill"
        case (false, true): "square"
        case (true, false): "checkmark.circle.fill"
        case (false, false): "circle"
        }
    }
}
