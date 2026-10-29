import SwiftUI

/// Pending approvals share one trigger pill above the composer; details and
/// decisions live in the badge's popover, paged like the ask sheet when more
/// than one request waits. The amber fill and wording set it apart from the
/// purple question badge.
struct ApprovalBadgeRow: View {
    let requests: [ApprovalRequest]
    let runtime: ThreadRuntime
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingApprovals = false
    @State private var page = 0

    private var tint: Color { Chrome.threadStatusColor(.approval, isDark: colorScheme == .dark) }

    private var title: String {
        if requests.count > 1 { return String(format: Chrome.localized("%d approvals"), requests.count) }
        guard let request = requests.first else { return "" }
        if let tool = request.tool { return tool.name }
        return switch request.kind {
        case .command: "Command"
        case .fileChange: "File change"
        case .plan: "Plan"
        case .permissions: "Permissions"
        case .tool, .confirmation: "Approval"
        }
    }

    var body: some View {
        ChatBadge(
            title: title,
            caption: requests.count > 1 ? "need approval" : "needs approval",
            tint: tint,
            needsAttention: true,
            isPresented: $isShowingApprovals,
            liveDetailWidth: requests.count > 1 ? ApprovalSheet.width : nil
        ) {
            if requests.count > 1 {
                ApprovalPagerSheet(runtime: runtime, page: $page)
            } else if let request = requests.first,
                      let item = runtime.pendingInteraction(for: request.instanceID) {
                ApprovalSheet(request: request, state: item.state, canSubmit: item.canSubmit,
                              ownsShortcut: true) {
                    runtime.resolve(request, option: $0)
                }
            }
        }
    }
}

/// Several pending approvals, paged without resolving any of them early. The
/// visible page is the regular approval sheet; the group actions resolve every
/// pending request one by one, each with its single-call option — never a
/// session grant. Requests withdrawn mid-flight are skipped by `resolve`'s
/// own guard, and the page index clamps as resolved requests leave the list.
struct ApprovalPagerSheet: View {
    let runtime: ThreadRuntime
    @Binding var page: Int
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.closePopover) private var closePopover
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    private var tint: Color { Chrome.threadStatusColor(.approval, isDark: colorScheme == .dark) }
    private var requests: [ApprovalRequest] { runtime.approvals }
    private var current: Int { min(max(0, page), max(0, requests.count - 1)) }

    private var canSubmitAny: Bool {
        requests.contains { runtime.pendingInteraction(for: $0.instanceID)?.canSubmit == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if requests.count <= 10 {
                    ForEach(Array(requests.enumerated()), id: \.element.instanceID) { index, _ in
                        Button { go(to: index) } label: {
                            Capsule()
                                .fill(index == current ? tint : Chrome.overlay(0.18))
                                .frame(width: index == current ? 18 : 6, height: 6)
                                .frame(minWidth: 16, minHeight: 20)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("Approval %d"), index + 1)))
                    }
                }
                Text(verbatim: String(format: Chrome.localized("%d of %d"), current + 1, requests.count))
                    .font(.ui(.subheadline)).monospacedDigit()
                    .foregroundStyle(Chrome.secondaryText)
                Spacer()
                Button { go(to: current - 1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .foregroundStyle(current > 0 ? Chrome.secondaryText : Chrome.overlay(0.18))
                    .disabled(current == 0)
                    .help(Text("Previous approval"))
                    .accessibilityLabel(Text("Previous approval"))
                Button { go(to: current + 1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                    .foregroundStyle(current < requests.count - 1 ? Chrome.secondaryText : Chrome.overlay(0.18))
                    .disabled(current >= requests.count - 1)
                    .help(Text("Next approval"))
                    .accessibilityLabel(Text("Next approval"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 2)

            if requests.indices.contains(current), let item = runtime.pendingInteraction(for: requests[current].instanceID) {
                ApprovalSheet(request: requests[current], state: item.state, canSubmit: item.canSubmit,
                              ownsShortcut: true) { option in
                    runtime.resolve(requests[current], option: option)
                }
                // Offscreen pages must never retain the ⌘Return shortcut or stale state.
                .id(requests[current].instanceID)
            }

            Divider().overlay(Chrome.overlay(0.06))
            HStack(spacing: 8) {
                groupButton("Deny all", role: .decline, allows: false)
                    .help(Text("Denies every pending approval"))
                Spacer()
                groupButton("Allow all", role: .approve, allows: true)
                    .help(Text("Allows every pending approval once"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: ApprovalSheet.width)
    }

    @ViewBuilder
    private func groupButton(_ title: String, role: ApprovalRequest.Option.Role, allows: Bool) -> some View {
        let button = Button { resolveAll(role) } label: {
            Text(verbatim: Chrome.localized(title))
                .font(.ui(.callout, weight: .medium))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 4)
                .frame(minWidth: 62)
        }
        .disabled(!canSubmitAny)
        Group {
            if allows {
                if performanceMode { button.buttonStyle(.borderedProminent) }
                else { button.buttonStyle(.glassProminent) }
            } else {
                Group {
                    if performanceMode { button.buttonStyle(.bordered) }
                    else { button.buttonStyle(.glass) }
                }
                .foregroundStyle(Chrome.primaryText)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .tint(allows ? tint : nil)
    }

    private func go(to index: Int) {
        guard requests.indices.contains(index) else { return }
        page = index
    }

    /// Each request keeps its own response: one denial or one single-call
    /// allowance per request, resolved individually like the page's buttons.
    private func resolveAll(_ role: ApprovalRequest.Option.Role) {
        closePopover?()
        for request in runtime.approvals {
            guard let option = request.options.first(where: { $0.role == role }) else { continue }
            runtime.resolve(request, option: option)
        }
    }
}

/// An approval is a direct decision, with no answer editor, paging or Send step.
/// Details stay in a pre-measured bounded scroller while the decision buttons
/// remain outside it; ⌘Return allows while the popover is open.
struct ApprovalSheet: View {
    let request: ApprovalRequest
    let state: OMPInteraction.State
    let canSubmit: Bool
    var ownsShortcut = false
    let onResolve: (ApprovalRequest.Option) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.closePopover) private var closePopover
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    static let width: CGFloat = 460
    private static let detailsMaxHeight: CGFloat = 260

    private var tint: Color { Chrome.threadStatusColor(.approval, isDark: colorScheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The tool name (or the kind's question) is the panel's title.
            Text(verbatim: request.tool?.name ?? Chrome.localized(request.headline))
                .font(.ui(.headline, design: request.tool == nil ? .default : .monospaced))
                .foregroundStyle(Chrome.primaryText)
                .lineLimit(request.tool == nil ? 2 : 1)
                .truncationMode(.middle)
                .help(Text(verbatim: request.title))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, hasDetails ? 10 : 12)

            if hasDetails {
                PopoverScroll(maxHeight: Self.detailsMaxHeight, minHeight: 0, width: Self.width - 32) {
                    details
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            Divider().overlay(Chrome.overlay(0.06))
            HStack(spacing: 8) {
                status
                    .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                ForEach(request.decisions) { option in
                    decision(option)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: Self.width)
    }

    private var hasDetails: Bool {
        !request.title.isEmpty || request.tool != nil || request.detail?.isEmpty == false || request.reason?.isEmpty == false || request.kind == .plan || request.kind == .command
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let tool = request.tool {
                if let origin = tool.origin {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Origin").font(.ui(.caption, weight: .medium)).foregroundStyle(Chrome.secondaryText)
                        Text(verbatim: origin).font(.ui(.callout)).foregroundStyle(Chrome.primaryText)
                    }
                }
                if let reason = tool.reason, !reason.isEmpty { reasonRow(reason) }
                if let command = tool.command {
                    codeSection("Command", source: command, pathExtension: "sh")
                } else if let file = tool.file {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Path")
                            .font(.ui(.caption, weight: .medium)).foregroundStyle(Chrome.secondaryText)
                        Text(verbatim: file.path)
                            .font(.ui(.callout, design: .monospaced)).foregroundStyle(Chrome.primaryText)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        codeSection("Content", source: file.content, pathExtension: (file.path as NSString).pathExtension)
                    }
                } else if !tool.details.isEmpty {
                    codeSection("Tool details", source: tool.details, pathExtension: "txt")
                }
            } else {
                if request.kind == .command {
                    codeSection("Command", source: request.title, pathExtension: "sh")
                } else if !request.title.isEmpty {
                    Text(verbatim: request.title).font(.ui(.callout, weight: .medium)).foregroundStyle(Chrome.primaryText)
                }
                if request.kind == .plan {
                    Text("Approve the plan above to let the agent start building.")
                        .font(.ui(.callout)).foregroundStyle(Chrome.secondaryText)
                }
                if let reason = request.reason, !reason.isEmpty { reasonRow(reason) }
            }
            if let detail = request.detail, !detail.isEmpty {
                Text(verbatim: detail).font(.ui(.callout)).foregroundStyle(Chrome.secondaryText)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reasonRow(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Reason").font(.ui(.caption, weight: .medium)).foregroundStyle(Chrome.secondaryText)
            Text(verbatim: reason)
                .font(.ui(.callout)).foregroundStyle(Chrome.primaryText)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Chrome.overlay(0.04), in: .rect(cornerRadius: 10))
        }
    }

    private func codeSection(_ title: String, source: String, pathExtension: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: Chrome.localized(title))
                .font(.ui(.caption, weight: .medium)).foregroundStyle(Chrome.secondaryText)
            ToolCodeBlockView(source: source, pathExtension: pathExtension)
                .foregroundStyle(Chrome.primaryText)
        }
    }

    @ViewBuilder private var status: some View {
        if state == .submitting { Text("Sending response…") }
        else if state == .deliveryUnknown { Text("Delivery unknown") }
        else if let deadline = request.deadline {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(verbatim: String(format: Chrome.localized("Expires in %lld seconds"), Int64(max(0, deadline.timeIntervalSince(context.date)))))
            }
        }
    }

    @ViewBuilder private func decision(_ option: ApprovalRequest.Option) -> some View {
        let allows = option.role == .approve
        // Close at once like an answered ask sheet; the decision writes in the
        // background and the badge retires itself when the write lands.
        let button = Button { closePopover?(); onResolve(option) } label: {
            Text(verbatim: Chrome.localized(allows ? "Allow" : "Deny"))
                .font(.ui(.callout, weight: .medium))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 4)
                .frame(minWidth: 62)
        }
        .keyboardShortcut(ownsShortcut && allows ? KeyboardShortcut(.return, modifiers: .command) : nil)
        .disabled(!canSubmit)
        Group {
            if allows {
                if performanceMode { button.buttonStyle(.borderedProminent) }
                else { button.buttonStyle(.glassProminent) }
            } else {
                Group {
                    if performanceMode { button.buttonStyle(.bordered) }
                    else { button.buttonStyle(.glass) }
                }
                .foregroundStyle(Chrome.primaryText)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .tint(allows ? tint : nil)
    }
}
