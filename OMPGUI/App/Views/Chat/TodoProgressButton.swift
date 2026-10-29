import SwiftUI

/// The latest native todo snapshot, shared by live updates and saved history.
/// Outside the auto-hiding controls, so progress stays visible while reading.
struct TodoProgressButton: View {
    @Environment(\.chatColumnIsShown) private var isColumnShown
    let runtime: ThreadRuntime
    @State private var isPresented = false

    private var steps: [TodoStep] { runtime.todoSteps }

    var body: some View {
        let steps = steps
        let completed = steps.count { $0.status == .done }
        Group {
            if !steps.isEmpty {
                Button { isPresented.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checklist")
                            .font(Chrome.inlineIconFont)
                        Text("Tasks")
                        Text(verbatim: "\(completed)/\(steps.count)")
                            .monospacedDigit()
                    }
                    .font(.ui(size: 12.5, weight: .medium))
                    .foregroundStyle(steps.contains { $0.status == .blocked } ? Chrome.warning : Chrome.accent)
                    .padding(.horizontal, Chrome.capsuleHorizontalPadding)
                    .frame(height: Chrome.capsuleContentHeight)
                    .padding(.vertical, Chrome.capsuleVerticalPadding)
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .fixedSize()
                .chromeGlassCapsule()
                .background { NoWindowDragArea() }
                .help("Show task list")
                .accessibilityLabel(Text("Task list"))
                .accessibilityValue(Text("\(completed) of \(steps.count) done"))
                .chromePopover(isPresented: $isPresented, arrowEdge: .bottom) {
                    TodoListPopover(runtime: runtime) { isPresented = false }
                }
            }
        }
        .preference(key: ChromePresentationPreference.self, value: isPresented)
        .onChange(of: steps.isEmpty) { _, empty in if empty { isPresented = false } }
        .onChange(of: isColumnShown) { _, shown in if !shown { isPresented = false } }
    }
}

private struct TodoListPopover: View {
    let runtime: ThreadRuntime
    let close: () -> Void

    var body: some View {
        let steps = runtime.todoSteps
        let completed = steps.count { $0.status == .done }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Task list")
                    .font(.ui(.headline))
                Text(verbatim: "\(completed) / \(steps.count)")
                    .font(.ui(.caption).monospacedDigit())
                    .foregroundStyle(Chrome.secondaryText)
                Spacer(minLength: 8)
                ChromeIconButton(symbol: "xmark", help: "Close", action: close)
            }
            PopoverScroll(maxHeight: 360, minHeight: 0, width: 304) {
                TodoStepList(steps: steps)
            }
        }
        .padding(14)
        .frame(width: 332)
        .presentedChrome()
    }
}

private struct TodoStepList: View {
    let steps: [TodoStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if let phase = step.phase, index == 0 || steps[index - 1].phase != phase {
                    Text(verbatim: phase)
                        .font(.ui(.caption))
                        .foregroundStyle(Chrome.secondaryText)
                        .padding(.top, index == 0 ? 0 : 4)
                }
                TodoStepRow(step: step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TodoStepRow: View {
    let step: TodoStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: step.text)
                    .foregroundStyle(step.status == .done || step.status == .abandoned ? Chrome.secondaryText : Chrome.primaryText)
                    .strikethrough(step.status == .done || step.status == .abandoned)
                if step.status == .blocked || step.status == .abandoned {
                    Text(verbatim: Chrome.localized(statusTitle))
                        .font(.ui(.caption))
                        .foregroundStyle(Chrome.secondaryText)
                }
                if step.status == .blocked, let blocker = step.blocker, !blocker.isEmpty {
                    Text(verbatim: blocker)
                        .font(.ui(.caption))
                        .foregroundStyle(Chrome.secondaryText)
                }
            }
        }
        .font(.ui(.callout))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: Chrome.localized(statusTitle)))
    }

    private var symbol: String {
        switch step.status {
        case .pending: "circle"
        case .active: "circle.dotted.circle"
        case .done: "checkmark.circle.fill"
        case .blocked: "exclamationmark.circle"
        case .abandoned: "minus.circle"
        }
    }

    private var color: Color {
        switch step.status {
        case .pending, .abandoned: Chrome.secondaryText
        case .active, .done: Chrome.accent
        case .blocked: Chrome.warning
        }
    }

    private var statusTitle: String {
        switch step.status {
        case .pending: "Not started"
        case .active: "In progress"
        case .done: "Completed"
        case .blocked: "Blocked"
        case .abandoned: "Abandoned"
        }
    }
}
