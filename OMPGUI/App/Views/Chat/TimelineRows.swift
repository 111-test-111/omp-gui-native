import AppKit
import SwiftUI

/// A Hydra merge stage's words in the app language. With several projects the stage reads
/// "Project: words", and only the words after the last colon are translated.
enum MergeStageText {
    static func localized(_ stage: String) -> String {
        let whole = Chrome.localized(stage)
        if whole != stage { return whole }
        guard let colon = stage.range(of: ": ", options: .backwards) else { return stage }
        return String(stage[..<colon.upperBound]) + Chrome.localized(String(stage[colon.upperBound...]))
    }
}

/// The timeline's shared geometry. One vertical rhythm governs every pair of rows —
/// reply to reply, reply to work line, work line to row — so the distance between
/// text and the steps never varies. A message's hover controls sit inside that gap
/// rather than widening it.
enum TimelineMetrics {
    /// The gap between any two consecutive rows in the timeline.
    static let rowSpacing: CGFloat = 20
    /// The room a message keeps for its hover line (copy, revert). Reserved inside
    /// the row so showing the controls never moves text, then subtracted from the
    /// row's own height so they fill the gap below instead of adding to it.
    static let hoverLineHeight: CGFloat = 22
    /// The icon column every transcript row starts with. Rows carry no leading inset,
    /// so the column sits on the reply text's own x and all labels line up after it.
    static let iconWidth: CGFloat = TimelineIconMetrics.size
    static let iconSpacing: CGFloat = 8
    static let headGlyphSpacing: CGFloat = 6
    /// One pill for everything that sits in the conversation as a badge or a card: the
    /// head pills, the question badge, the merge pill, a notice, the lead's delegation
    /// card, the working line. Same corner, same insets, so they line up in the column
    /// and read as one family. Trailing is wider than leading because most end in a
    /// chevron or a time, which sits lighter than the glyph that opens them.
    static let pillLeading: CGFloat = 12
    static let pillTrailing: CGFloat = 14
    static let pillVertical: CGFloat = 8
    static let pillRadius: CGFloat = 18
}

/// The pasteboard half of `CopyButton` (see MarkdownView.swift), for the message menus.
private func copyMessageText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(ProseReflow.reflowed(text), forType: .string)
}

/// The last whole fenced code block's code, if the text holds one: a simple scan for
/// lines starting with three backticks.
private func lastCodeBlock(in text: String) -> String? {
    var last: String?
    var open: [String]?
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("```") {
            if let done = open {
                last = done.joined(separator: "\n")
                open = nil
            } else {
                open = []
            }
        } else {
            open?.append(line)
        }
    }
    return last
}

/// Carries a message row's context-menu intents outside its @State, the way the sidebar's
/// menuRequests does: the AppKit menu outlives the right-click, so its callbacks must not
/// retain the row. The row takes the request up below.
@Observable
private final class MessageMenuRequests {
    var confirmRevert = false
}

@MainActor
private func copyActions(text: String, selection: SelectionCopy) -> [RowAction] {
    [
        RowAction(title: "Copy", symbol: "doc.on.doc", confirms: "Copied") {
            if !selection.copy() { copyMessageText(MessageText.plain(text)) }
        },
        RowAction(title: "Copy message as markdown", symbol: "number", confirms: "Copied") { copyMessageText(text) },
    ]
}

struct UserMessageRow: View {
    let entry: TimelineEntry
    let runtime: ThreadRuntime
    /// Whether the message can be edited right now, which rewinds its turn. Decided by the
    /// timeline, which reads the provider and the turn list once for every row.
    let canRevert: Bool

    @Environment(\.revealTimelineEnd) private var revealBox
    @Environment(\.timelineBlockID) private var blockID
    @State private var fallbackExpanded = false
    private var promptExpanded: Bool {
        get { revealBox?.presentation.prompts[entry.id] ?? fallbackExpanded }
        nonmutating set {
            if let revealBox { revealBox.presentation.prompts[entry.id] = newValue }
            else { fallbackExpanded = newValue }
        }
    }

    private func promptPreview(_ text: String) -> String {
        if let cached = revealBox?.presentation.previews[entry.id] { return cached }
        let lines = text.split(separator: "\n", maxSplits: 8, omittingEmptySubsequences: false)
        let firstLines = lines.prefix(8).joined(separator: "\n")
        var preview = String(firstLines.prefix(600))
        if preview.count < firstLines.count, let boundary = preview.lastIndex(where: { $0.isWhitespace }) {
            preview = String(preview[..<boundary])
        }
        if preview != text { preview = preview.trimmingCharacters(in: .whitespacesAndNewlines) + "…" }
        revealBox?.presentation.previews[entry.id] = preview
        return preview
    }

    @State private var isHovering = false
    @State private var isConfirmingRevert = false
    /// Carries the edit-from-here intent out of the context menu without retaining the row.
    @State private var menuRequests = MessageMenuRequests()
    /// The editor popover, anchored to the pencil.
    @State private var editor = PromptEditorPopover<MessageEditor>()

    var body: some View {
        if case .user(let message) = entry.item.content, message.isFromHydra {
            HydraReportRow(message: message)
        } else if case .user(let message) = entry.item.content, message.isHydraBrief {
            HydraBriefRow(message: message, entry: entry, runtime: runtime)
        } else if case .user(let message) = entry.item.content {
            // Which message is open for editing is the thread's, so the editor survives
            // the row: leaving the thread closes the popover only, and the row coming
            // back reopens it on the edit as it was left.
            let isEditing = entry.turnID != nil && runtime.messageEdit?.id == entry.turnID
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    AttachmentStrip(attachments: message.attachments)
                }
                let preview = promptPreview(message.text)
                if !message.text.isEmpty {
                    // Keep the prompt's Markdown markers and newlines exactly as written.
                    Group {
                        if (promptExpanded ? message.text : preview).contains("\n") {
                            LinkParagraphView(source: promptExpanded ? message.text : preview, pointSize: TypeScale.shared.content(13), literal: true)
                        } else {
                            Text(verbatim: promptExpanded ? message.text : preview)
                        }
                    }
                    .font(AppFont.swiftUI(size: TypeScale.shared.content(13)))
                    .lineSpacing(MarkdownParagraphLayout.lineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14)
                    // The tail hangs past the body; the text keeps its inset from the body.
                    .padding(.trailing, 14 + UserBubble.tail)
                    .padding(.vertical, 9)
                    .background(.tint.opacity(0.14), in: UserBubble())
                }
                if preview != message.text {
                    Button(Chrome.localized(promptExpanded ? "Show less" : "Show more")) {
                        revealBox?.disclosure(blockID)
                        promptExpanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.chat(.callout))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, UserBubble.tail)
                }
                HStack(spacing: 2) {
                    if canRevert, let turnID = entry.turnID {
                        Button {
                            // The pencil toggles: a second tap while open closes the editor.
                            runtime.messageEdit = isEditing ? nil : PromptEdit(id: turnID, text: message.text, attachments: message.attachments)
                        } label: {
                            Image(systemName: "pencil")
                                .frame(width: 22, height: 22)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(isEditing ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .help("Edit message")
                        // The pointer settling on the pencil is the editor about to open: its
                        // file preview starts now, so the click finds it done or nearly so.
                        .onHover { hovering in
                            if hovering { _ = runtime.revertPreview(for: turnID) }
                        }
                        .background {
                            AttachmentAnchorCapture { anchor in
                                editor.setAnchor(anchor)
                                // The anchor lands in its window after the row appears: the
                                // moment a reopened thread can show the editor again.
                                syncEditor(isEditing)
                            }
                        }
                    }
                }
                // Pinned to the hover line's room, so the row keeps it (and the gap
                // math below holds) with no copy button left to size it.
                .frame(height: TimelineMetrics.hoverLineHeight)
                .opacity(isHovering || isEditing ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 96)
            // The binding alone, so the hover responder never keeps this row (and its
            // message) alive after it scrolls away.
            .onHover { [hovering = $isHovering] in hovering.wrappedValue = $0 }
            // Snapshots only: the popover opens at the pointer and its builder must not
            // capture the row, so the popover cannot pin the row's state storage
            // after dismiss. The revert intent goes through the binding alone, the
            // way the hover responder does below.
            .rightClickPopover { [message, canRevert, confirming = $menuRequests.confirmRevert] selection in
                Self.messageActions(
                    text: message.text,
                    canRevert: canRevert,
                    confirmRevert: confirming,
                    selection: selection
                )
            }
            // The room for the hover line lives inside the row but is taken back out
            // of its height, so the controls show up in the gap to the next row and
            // that gap stays the same whether or not they are showing. (6 = the
            // VStack's spacing above them.)
            .padding(.bottom, -(TimelineMetrics.hoverLineHeight + 6))
            .onChange(of: menuRequests.confirmRevert) { _, asked in
                guard asked else { return }
                // The menu posts the intent, the row takes it up, like the sidebar's
                // menuRequests: the confirmation dialog then opens on the row itself.
                menuRequests.confirmRevert = false
                isConfirmingRevert = true
            }
            .confirmationDialog("Edit from this message?", isPresented: $isConfirmingRevert) {
                Button("Branch and keep file changes") { revert(restoreFiles: false) }
                Button("Branch and restore files", role: .destructive) { revert(restoreFiles: true) }
            } message: {
                Text("OMP creates a branch before this message and restores its prompt. The original conversation remains available. File restoration is a separate operation.")
            }
            .onChange(of: isEditing) { _, editing in syncEditor(editing) }
            .onDisappear { editor.close() }
        }
    }

    private func revert(restoreFiles: Bool) {
        guard let turnID = entry.turnID else { return }
        // A revert that cannot start (a turn still running) says so in the thread itself.
        Task {
            do { _ = try await runtime.revert(to: turnID, restoreFiles: restoreFiles) }
            catch { runtime.reportNativeError(error) }
        }
    }

    private func syncEditor(_ isEditing: Bool) {
        editor.sync(isEditing ? runtime.messageEdit : nil, dismiss: { runtime.messageEdit = nil }) { edit in
            MessageEditor(edit: edit, runtime: runtime)
        }
    }

    /// The context menu's items, from value snapshots with weak captures: the AppKit menu
    /// outlives the right-click, so its callbacks must not retain the row.
    private static func messageActions(text: String, canRevert: Bool, confirmRevert: Binding<Bool>, selection: SelectionCopy) -> [RowAction] {
        let textSnapshot = text
        var items = copyActions(text: textSnapshot, selection: selection)
        if canRevert {
            items.append(RowAction(title: "Edit from here", symbol: "arrow.uturn.backward", startsGroup: true) { [confirm = confirmRevert] in
                confirm.wrappedValue = true
            })
        }
        return items
    }
}

/// Heads reporting back to their lead: their glyphs and names on a line, and their reports
/// in a popover off it. It sits on the user's side, since that is where the lead reads it from,
/// but reads as the team's, not the user's. A note from Hydra itself (heads held back, the
/// team's work merged) takes the same row with the Hydra mark in the glyphs' place; a note
/// that leads with the merge request's address links to it from the pill.
struct HydraReportRow: View {
    let message: UserMessage

    @State private var isShowingReport = false

    var body: some View {
        let personas = (message.hydraHeads ?? []).map(HydraRoster.persona(at:))
        let names = personas.map(\.name)
        // A note from Hydra itself says what it is on its first line; the rest is the message.
        // That line ends like a sentence, and the pill reads it as a label.
        // A heads' report keeps its full text for the popover, but the pill reads a
        // short human summary with the heads first, never the file-heavy detail.
        let parts = message.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        let title = personas.isEmpty ? Self.withoutTrailingStop(String(parts.first ?? "Hydra")) : Self.reportSummary(names: names, text: message.text)
        let body = personas.isEmpty ? String(parts.count > 1 ? parts[1] : "").trimmed : message.text
        // A merge note puts the merge request's address on the body's first line: that becomes
        // a link on the pill, and the chevron stays only for what the note says after it.
        let link = personas.isEmpty ? Self.leadingURL(in: body) : nil
        let details = link == nil ? body : Self.withoutFirstLine(body)
        // The link is a control of its own beside the button, never inside its label: a
        // link nested in a button takes the button's clicks on macOS, and the text
        // stopped opening the popover.
        HStack(spacing: 8) {
            Button {
                guard !details.isEmpty else { return }
                isShowingReport.toggle()
            } label: {
                HStack(spacing: 8) {
                    // The mark takes a glyph's slot, so both rows sit the same in the pill.
                    // (Only one or the other: an empty stack would still keep its spacing.)
                    if personas.isEmpty {
                        HydraMarkImage()
                            .foregroundStyle(Chrome.secondaryText)
                            .frame(width: 18, height: 18)
                    } else {
                        HStack(spacing: TimelineMetrics.headGlyphSpacing) {
                            ForEach(Array(personas.prefix(4).enumerated()), id: \.offset) { _, persona in
                                HydraGlyph(persona: persona, size: 18)
                            }
                            if personas.count > 4 {
                                Text(verbatim: "+\(personas.count - 4)").font(.chat(.caption))
                            }
                        }
                    }
                    Text(verbatim: title)
                        .foregroundColor(Chrome.primaryText.opacity(0.9))
                        .font(.chat(.callout, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !details.isEmpty {
                        Image(systemName: "chevron.right").font(.system(size: TypeScale.shared.content(TypeScale.stockPointSize(.caption2)), weight: .semibold))
                            .foregroundStyle(Chrome.secondaryText)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(details.isEmpty)
            .help(Text(verbatim: details.isEmpty ? "" : Chrome.localized("Show the message")))
            .badgePopover(isPresented: $isShowingReport) {
                // Reports from heads draw the digest; a merge note draws its own card;
                // every other note keeps the markdown view.
                if let link, let request = MergeRequestLink(url: link), let note = HydraMergeNote.parse(details, link: request) {
                    HydraMergePopover(note: note)
                } else if !personas.isEmpty {
                    HydraReportsPopover(title: title, text: body, personas: personas)
                } else {
                    HydraReportPopover(text: body)
                }
            }
            if let link {
                Link(destination: link) {
                    Text("Open")
                        .font(.chat(.caption, weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                }
                .help("Open in the browser")
            }
        }
        .padding(.leading, TimelineMetrics.pillLeading)
        .padding(.trailing, TimelineMetrics.pillTrailing)
        .padding(.vertical, TimelineMetrics.pillVertical)
        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: TimelineMetrics.pillRadius, style: .continuous))
        // The report parses off the main thread as the pill appears, so the tap that
        // opens it finds the blocks ready rather than parsing the whole batch first. A
        // heads' report is read one head at a time, so it is each head's body that warms.
        .task(id: body) {
            guard !details.isEmpty else { return }
            let texts = personas.isEmpty ? [body] : HydraReportDigest.parse(body).heads.map(\.body)
            try? await MarkdownView.warm(texts)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 96)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    /// The title without the one full stop a note's first line ends on.
    nonisolated static func withoutTrailingStop(_ title: String) -> String {
        title.hasSuffix(".") ? String(title.dropLast()) : title
    }

    /// The pill for heads reporting back: just who is done, since the report itself is
    /// one tap away in the popover. "Hank is done", "Hank and Walter are done"; a head
    /// whose `## Name: task (failed)` section says otherwise is named with its outcome
    /// instead, so a failure never hides behind "done".
    private static func reportSummary(names: [String], text: String) -> String {
        let outcomes = reportOutcomes(in: text)
        let done = names.filter { outcomes[$0] == nil }
        let others = names.filter { outcomes[$0] != nil }
        var parts: [String] = []
        if !done.isEmpty {
            parts.append(String(format: Chrome.localized(done.count == 1 ? "%@ is done" : "%@ are done"), list(done)))
        }
        for name in others {
            parts.append(String(format: Chrome.localized(outcomes[name] == "stopped" ? "%@ stopped" : "%@ failed"), name))
        }
        let joined = parts.dropFirst().reduce(parts.first ?? "") { String(format: Chrome.localized("%@, %@"), $0, $1) }
        return TextCleanup.singleLine(joined, limit: 140)
    }

    /// "Hank", "Hank and Walter", "Hank, Walter and Ada".
    private static func list(_ names: [String]) -> String {
        if names.count <= 1 { return names.first ?? "" }
        return names.dropLast().joined(separator: Chrome.localized(", ")) + Chrome.localized(" and ") + (names.last ?? "")
    }

    /// Each head's outcome off its `## Name: task (failed)` / `(stopped)` section, by
    /// name; a head that finished has no entry.
    private static func reportOutcomes(in text: String) -> [String: String] {
        var outcomes: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("## "), let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<colon]).trimmingCharacters(in: .whitespaces)
            let lower = line[colon...].lowercased()
            if lower.contains("(failed") { outcomes[name] = "failed" }
            else if lower.contains("(stopped") { outcomes[name] = "stopped" }
        }
        return outcomes
    }

    /// The address on the body's first line, when that line is an address and nothing else.
    nonisolated static func leadingURL(in body: String) -> URL? {
        guard let line = body.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces),
              line.lowercased().hasPrefix("http://") || line.lowercased().hasPrefix("https://"),
              !line.contains(where: \.isWhitespace) else { return nil }
        return URL(string: line)
    }

    /// The body past its first line: what a note says after the address it leads with.
    nonisolated static func withoutFirstLine(_ body: String) -> String {
        guard let newline = body.firstIndex(where: \.isNewline) else { return "" }
        return String(body[newline...]).trimmed
    }
}

struct BackgroundTasksWorkingRow: View {
    let descriptions: [String]

    private var label: String {
        let first = descriptions.first ?? Chrome.localized("a background command")
        return descriptions.count > 1
            ? String(format: Chrome.localized("Waiting on a background task: %@ and %lld more"), first, descriptions.count - 1)
            : String(format: Chrome.localized("Waiting on a background task: %@"), first)
    }

    var body: some View {
        HStack(spacing: 8) {
            MiniSpinner(cellSize: 2.4)
            Text(verbatim: label)
                .font(.chat(.callout))
                .foregroundStyle(Chrome.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HydraHeadsWorkingRow: View {
    @Environment(AppModel.self) private var model
    let heads: [Int]
    let runtime: ThreadRuntime

    var body: some View {
        // Read through this thread's own cells (`helpers(of:)` holds every unarchived head,
        // in the panel or not), the same list as `hydraTeam(of:)` without its scan of
        // `model.threads`: a write to some other chat never re-renders these pills.
        let team = model.children(of: runtime.threadID)
            .filter(\.isHydraHead)
        let infos = Dictionary(team.compactMap(\.hydra).map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        let finished = heads.compactMap { infos[$0] }
        // Adjacent successful completions share a pill. Failures and stopped heads
        // keep their own outcome and position in the finish order.
        VStack(alignment: .leading, spacing: 6) {
            ForEach(FinishedHeadsGroup.build(finished)) { group in
                FinishedHeadsPill(heads: group.heads)
                    .transition(.settleGlide)
            }
        }
        .animation(.smooth(duration: 0.3), value: finished.map(\.index))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 96)
    }

    /// The finished heads whose report has not reached the lead yet: a finished head whose
    /// batch still has a head at work, or — with no batch — a head that finished since the
    /// earliest running head set out, so heads done in an earlier turn stay out. Order is the caller's.
    static func finishedHeads(in threads: [ChatThread]) -> [HydraHeadInfo] {
        let infos = threads.compactMap(\.hydra)
        let running = infos.filter { $0.status == .running }
        guard !running.isEmpty else { return [] }
        let since = running.map(\.startedAt).min() ?? .distantPast
        return infos.filter { info in
            guard info.isFinished else { return false }
            guard let batch = info.batchID else { return (info.finishedAt ?? .distantPast) >= since }
            return running.contains { $0.batchID == batch }
        }
    }
}

/// Preserve finish order and keep unsuccessful outcomes out of a successful count.
struct FinishedHeadsGroup: Identifiable {
    let id: Int
    var heads: [HydraHeadInfo]

    static func build(_ heads: [HydraHeadInfo]) -> [Self] {
        var groups: [Self] = []
        for head in heads {
            if head.status == .completed, groups.last?.heads.last?.status == .completed {
                groups[groups.count - 1].heads.append(head)
            } else {
                groups.append(Self(id: head.index, heads: [head]))
            }
        }
        return groups
    }
}

/// Bounded avatar strip shared by departure and completion pills.
private struct HydraHeadGlyphs: View {
    let heads: [HydraHeadInfo]

    var body: some View {
        HStack(spacing: TimelineMetrics.headGlyphSpacing) {
            ForEach(Array(heads.prefix(4)), id: \.index) { head in
                HydraGlyph(persona: head.persona, size: 18, isRunning: head.status == .running, status: head.status)
            }
            if heads.count > 4 {
                Text(verbatim: "+\(heads.count - 4)").font(.chat(.caption))
            }
        }
    }
}

/// Heads finished while their batch still works: outcomes now, reports one tap away.
private struct FinishedHeadsPill: View {
    let heads: [HydraHeadInfo]

    @State private var isShowingReport = false

    var body: some View {
        if let head = heads.first {
            let title = heads.count > 1
                ? String(format: Chrome.localized("%lld heads finished working"), Int64(heads.count))
                : String(format: Chrome.localized(head.status == .failed ? "%@ failed" : (head.status == .stopped ? "%@ was stopped" : "%@ finished working")), head.persona.name)
            Button {
                isShowingReport.toggle()
            } label: {
                HStack(spacing: 8) {
                    HydraHeadGlyphs(heads: heads)
                    Text(verbatim: title)
                        .foregroundStyle(Chrome.primaryText.opacity(0.75))
                        .font(.chat(.callout, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.system(size: TypeScale.shared.content(TypeScale.stockPointSize(.caption2)), weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                }
                .padding(.leading, TimelineMetrics.pillLeading)
                .padding(.trailing, TimelineMetrics.pillTrailing)
                .padding(.vertical, TimelineMetrics.pillVertical)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: TimelineMetrics.pillRadius, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Show the report")
            // Both report variants premeasure a fixed scrolling viewport. Following its
            // opening geometry again can reposition a side-opening panel mid-animation.
            .badgePopover(isPresented: $isShowingReport) {
                if heads.count == 1 {
                    HydraHeadReportPopover(head: head)
                } else {
                    HydraReportsPopover(heads: heads)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: title))
        }
    }
}

/// A shimmer sweeping across the content on a loop: a narrow bright band sliding
/// left to right, masked to the content itself. Still when reduced motion is on.
private struct HydraShimmer: ViewModifier {
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    @State private var width: CGFloat = 0

    /// One pass of the band, from off the left edge to off the right.
    private static let sweep: TimeInterval = 1.8

    func body(content: Content) -> some View {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || performanceMode {
            content
        } else {
            // The band lives in a layer the size of the text and is masked to the text
            // there: masking the band alone would cut the text to the band's own width.
            let band = max(24, width / 3)
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .overlay {
                    // Thirty frames a second is enough for a band this soft, a quarter of the
                    // display's rate; and it holds still while the reader scrolls anywhere, so
                    // the mask pass below never lands on a scrolled frame.
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: ScrollActivity.shared.isScrolling)) { context in
                        let phase = CGFloat(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.sweep) / Self.sweep)
                        Color.clear
                            .overlay(alignment: .leading) {
                                LinearGradient(
                                    stops: [
                                        .init(color: Chrome.primaryText.opacity(0), location: 0),
                                        .init(color: Chrome.primaryText.opacity(0.9), location: 0.5),
                                        .init(color: Chrome.primaryText.opacity(0), location: 1),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: band)
                                .offset(x: -band + phase * (width + band))
                            }
                            .mask { content }
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

/// The lead's brief to a head, as the report pill's twin: a small pill where the user's
/// message would sit, with the full brief one tap away in a popover. While the brief's
/// turn has no assistant output yet the head is still cooking, so the pill reads so with
/// the thinking shimmer; once the head has answered it reads as the brief.
struct HydraBriefRow: View {
    let message: UserMessage
    let entry: TimelineEntry
    let runtime: ThreadRuntime

    @State private var isShowingBrief = false
    /// Whether the brief's turn has output, as of an entry count: the row re-evaluates far
    /// more often than the timeline grows, so the scan runs once per count and is replayed.
    @State private var scanned: (count: Int, value: Bool)?

    var body: some View {
        let persona = runtime.thread?.hydra?.persona ?? HydraRoster.persona(at: 0)
        // The brief's turn has produced nothing of its own yet: no entry past the brief
        // itself on the same turn means the head is still cooking.
        let count = runtime.entries.count
        let hasOutput: Bool = if let scanned, scanned.count == count {
            scanned.value
        } else {
            entry.turnID != nil && runtime.entries.contains { $0.turnID == entry.turnID && $0.id != entry.id }
        }
        let cooking = !hasOutput && runtime.isRunning
        let title = cooking ? "\(persona.name) is starting to cook…" : "\(persona.name)'s brief"
        VStack(alignment: .trailing, spacing: 6) {
            if !message.attachments.isEmpty {
                AttachmentStrip(attachments: message.attachments)
            }
            Button {
                isShowingBrief.toggle()
            } label: {
                HStack(spacing: 8) {
                    HydraGlyph(persona: persona, size: 18, isRunning: cooking)
                    Group {
                        if cooking {
                            Text(verbatim: title)
                                .modifier(HydraShimmer())
                        } else {
                            Text(verbatim: title)
                        }
                    }
                    .font(.chat(.callout, weight: .medium))
                    .foregroundStyle(Chrome.primaryText.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Image(systemName: "chevron.right").font(.system(size: TypeScale.shared.content(TypeScale.stockPointSize(.caption2)), weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                }
                .padding(.leading, TimelineMetrics.pillLeading)
                .padding(.trailing, TimelineMetrics.pillTrailing)
                .padding(.vertical, TimelineMetrics.pillVertical)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: TimelineMetrics.pillRadius, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Show the brief")
            .badgePopover(isPresented: $isShowingBrief) {
                HydraBriefPopover(persona: persona, task: runtime.thread?.hydra?.task, text: message.text)
            }
            .accessibilityLabel(Text(title))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 96)
        .accessibilityElement(children: .contain)
        // The scan the body just made, kept for the evaluations until the count moves.
        .onChange(of: count, initial: true) { _, _ in
            if scanned?.count != count { scanned = (count, hasOutput) }
        }
    }
}

/// A head's report in the popover its pill opens: the markdown at reading width, scrolling
/// past the panel's height rather than pushing the timeline apart.
///
/// A batch of reports runs to tens of thousands of characters. The blocks are in place
/// before the popover's first layout (the pill parses them off the main thread as it
/// appears, so a tap finds them cached; a cold tap parses now), and `PopoverScroll`
/// lays them out once at the popover's width, so it opens at its final size instead of
/// growing after it is shown. They are built lazily, so opening costs the blocks on
/// screen rather than the whole report.
private struct HydraReportPopover: View {
    let text: String
    var width: CGFloat = 460
    private let blocks: [MarkdownBlock]

    @MainActor
    init(text: String, width: CGFloat = 460) {
        self.text = text
        self.width = width
        blocks = MarkdownView.blocks(for: text)
    }

    var body: some View {
        PopoverScroll(maxHeight: 460, width: width) {
            // Every block at once: the body is laid out whole to size the panel before it
            // opens, and a lazy stack measured differently once shown (see `PopoverScroll`).
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block)
                        .equatable()
                }
            }
            // The note reads at the popover's own compact size.
            .font(.chat(.callout))
            .environment(\.markdownPointSize, TypeScale.shared.content(12))
            .environment(\.markdownDimmed, false)
            .lineSpacing(MarkdownParagraphLayout.lineSpacing)
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width)
    }
}

/// The lead's delegation block, the fenced `hydra` JSON at the end of its reply, as the
/// card it stands for: the mark, "Summoning heads", and under them one row per head with
/// the glyph of the head being summoned, its task, and the project it goes to when that
/// is not the chat's own. Never the JSON itself. The card reads the block as it streams
/// and adds each head as its brief closes; while nothing has closed yet, or when the
/// block cannot be read, it says the heads are being summoned and nothing more.
struct HydraDelegationBlock: View {
    let json: String
    var sent = false
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false

    var body: some View {
        let reading = Self.reading(of: json)
        let delegations = reading.delegations
        let streaming = !reading.isComplete && !sent
        // The mark and the title share a line; the heads run under both, each glyph in
        // the mark's column, so the list reads from the card's own left edge.
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: TimelineMetrics.iconSpacing) {
                HydraMarkImage()
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(verbatim: Self.title(for: delegations, streaming: streaming, sent: sent))
                    .font(.chat(.callout, weight: .medium))
                    .contentTransition(.opacity)
                if sent {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: TypeScale.shared.content(TypeScale.stockPointSize(.callout)), weight: .medium))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("sent")
                }
            }
            if !delegations.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(delegations.enumerated()), id: \.offset) { _, delegation in
                        headRow(delegation)
                    }
                    if streaming {
                        HStack(alignment: .center, spacing: TimelineMetrics.iconSpacing) {
                            Color.clear.frame(width: 16, height: 16)
                            Text("Writing the next brief…")
                                .font(.chat(.caption))
                                .foregroundStyle(Chrome.secondaryText)
                        }
                    }
                }
            }
        }
        .padding(.leading, TimelineMetrics.pillLeading)
        .padding(.trailing, TimelineMetrics.pillTrailing)
        .padding(.vertical, TimelineMetrics.pillVertical)
        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: TimelineMetrics.pillRadius, style: .continuous))
        .overlay {
            // Out: one wave of the accent flows through the card, as through the heads panel.
            if !performanceMode, sent {
                DotFieldSweep(tint: Chrome.accentNSColor)
                    .clipShape(RoundedRectangle(cornerRadius: TimelineMetrics.pillRadius, style: .continuous))
                    .transition(.opacity)
            }
        }
        .animation(Chrome.panelSlide, value: sent)
        .animation(Chrome.panelSlide, value: delegations.count)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    /// One head on its way: the glyph of the head the lead named (the mark when it named
    /// none), its task, and the project it goes to when the brief sends it elsewhere.
    private func headRow(_ delegation: HydraDelegation) -> some View {
        HStack(alignment: .center, spacing: TimelineMetrics.iconSpacing) {
            if let persona = Self.persona(named: delegation.name) {
                HydraGlyph(persona: persona, size: 16)
                    .accessibilityLabel(Text(persona.name))
            } else {
                HydraMarkImage()
                    .foregroundStyle(Chrome.secondaryText)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }
            Text(verbatim: delegation.task)
                .font(.chat(.caption))
                .foregroundStyle(Chrome.primaryText.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.tail)
            if let project = Self.projectName(delegation.project) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.right")
                        .accessibilityHidden(true)
                    Text(verbatim: project)
                }
                .font(.chat(.caption2, weight: .medium))
                .foregroundStyle(Chrome.secondaryText)
                .lineLimit(1)
                .padding(.leading, 2)
                .accessibilityLabel(Text("in \(project)"))
            }
        }
        .transition(.opacity)
    }

    /// "Summoning heads" while the briefs still stream; once the block has closed, how many
    /// are going (or went) out, the one head by name when the lead named it.
    private static func title(for delegations: [HydraDelegation], streaming: Bool, sent: Bool) -> String {
        if streaming || delegations.isEmpty { return Chrome.localized("Summoning heads") }
        if delegations.count == 1 {
            if let persona = persona(named: delegations[0].name) { return String(format: Chrome.localized(sent ? "Summoned %@" : "Summoning %@"), persona.name) }
            return Chrome.localized(sent ? "Summoned a head" : "Summoning a head")
        }
        return String(format: Chrome.localized(sent ? "Summoned %d heads" : "Summoning %d heads"), delegations.count)
    }

    /// The roster persona the lead announced for an entry, when it is a roster name.
    private static func persona(named name: String?) -> HydraPersona? {
        guard let name, !name.trimmed.isEmpty else { return nil }
        return HydraRoster.persona(named: name)
    }

    /// A project the brief names, as its name: a path reads as its last folder.
    private static func projectName(_ project: String?) -> String? {
        guard let project = project?.trimmed, !project.isEmpty else { return nil }
        let name = project.contains("/") ? (project as NSString).lastPathComponent : project
        return name.isEmpty ? project : name
    }

    /// The block read as far as it has streamed, by source: the reader is a single linear
    /// pass over the body and reads partial blocks on purpose, so every flush is cached
    /// and a finished block is the same card on every evaluation.
    @MainActor private static var readingCache = RecentCache<String, HydraPrompts.StreamedDelegations>(limit: 200)

    /// The entries whose briefs have closed so far, in the block's order, and whether the
    /// block itself has closed. The card reads the block as it streams and lists each
    /// head as its brief closes; nothing until the first entry's brace has closed.
    @MainActor
    private static func reading(of json: String) -> HydraPrompts.StreamedDelegations {
        if let cached = readingCache.value(for: json) { return cached }
        let reading = HydraPrompts.streamedDelegations(inBody: json[...])
        readingCache.insert(reading, for: json)
        return reading
    }
}

/// What the merge pill shows: the merge under way, or the note about how it went.
enum HydraMergePhase: Equatable {
    case merging
    case outcome(UserMessage)
}

/// A merge outcome note read for the pill: the title it leads with, the merge request's
/// address when the body leads with one, and what the note says past that.
private struct HydraMergeOutcome {
    let title: String
    /// The note past its title, for the popover.
    let body: String
    /// The merge request's address, when the body leads with one: a link beside the pill.
    let link: URL?
    /// What the note says after the address, if any: with none, the pill has no popover.
    let details: String

    init(_ message: UserMessage) {
        let parts = message.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        title = HydraReportRow.withoutTrailingStop(String(parts.first ?? "Hydra"))
        body = String(parts.count > 1 ? parts[1] : "").trimmed
        link = HydraReportRow.leadingURL(in: body)
        details = link == nil ? body : HydraReportRow.withoutFirstLine(body)
    }
}

/// The merge's progress: a track of one dot per stage with the head above it, hopping to
/// the dot of the stage under way. Done, every dot lights and the head gives one small
/// bounce before the track fades and the head settles back to its resting size.
///
/// The whole track is one animatable drawing (`HydraMergeTrackBody`): the head's place on
/// the track, how far the outcome has lit the dots, and how far the head has settled are
/// three continuous values, and every frame is drawn from them. So a stage that changes
/// while the head is still in the air retargets the same motion instead of restarting it
/// from the ground, a jump over several dots arcs over each one, and the lift, the glide
/// and the size change can never fall out of step with each other.
struct HydraMergeTrack: View {
    enum Mode { case running, done, resting }

    let step: Int
    let count: Int
    let mode: Mode

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HydraMergeTrackBody(
            position: CGFloat(step),
            done: mode == .running ? 0 : 1,
            rest: mode == .resting ? 1 : 0,
            count: count,
            hops: !reduceMotion
        )
        .animation(.smooth(duration: 0.5), value: step)
        .animation(.smooth(duration: 0.45), value: mode)
    }
}

/// The track as drawn from its three continuous values; SwiftUI interpolates them.
private struct HydraMergeTrackBody: View, Animatable {
    /// The head's place along the track in dots: whole at rest on a dot, fractional in
    /// flight between two.
    var position: CGFloat
    /// 0 while the merge runs, 1 once it is over: lights the dots left to right and pops
    /// the head on the way.
    var done: CGFloat
    /// 0 on the track, 1 settled: the track fades and the head grows to its resting size.
    var rest: CGFloat
    let count: Int
    let hops: Bool

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(position, AnimatablePair(done, rest)) }
        set { position = newValue.first; done = newValue.second.first; rest = newValue.second.second }
    }

    private static let dot: CGFloat = 4
    private static let gap: CGFloat = 3
    private static let headSize: CGFloat = 12
    private static let restingSize: CGFloat = 18
    private static let height: CGFloat = 20
    private static let lift: CGFloat = 4

    private var trackWidth: CGFloat {
        CGFloat(count) * Self.dot + CGFloat(count - 1) * Self.gap
    }

    private static func dotCentre(_ i: CGFloat) -> CGFloat {
        i * (dot + gap) + dot / 2
    }

    /// How lit dot `i` is: fully once the head has reached it, and otherwise as far as
    /// the outcome's wave has come, sweeping the track left to right as `done` rises.
    private func lit(_ i: Int) -> CGFloat {
        let reached: CGFloat = position + 0.35 >= CGFloat(i) ? 1 : 0
        let wave = min(max(done * CGFloat(count + 1) - CGFloat(i), 0), 1)
        return max(reached, wave)
    }

    var body: some View {
        // The head in flight arcs over every dot it crosses: the arc is zero at each whole
        // dot and highest half way, so a jump over several dots hops each one in turn.
        let arc = hops ? Self.lift * abs(sin(.pi * position)) : 0
        let side = Self.headSize + (Self.restingSize - Self.headSize) * rest
        let x = (Self.dotCentre(position) - Self.headSize / 2) * (1 - rest)
        let y = -arc * (1 - rest) + (Self.height - Self.restingSize) / 2 * rest
        // One pop as the outcome lands, up and back within the same rise of `done`.
        let pop = hops ? 1 + 0.18 * sin(.pi * min(done, 1)) : 1
        ZStack(alignment: .topLeading) {
            HStack(spacing: Self.gap) {
                ForEach(0..<count, id: \.self) { i in
                    Circle()
                        .fill(Chrome.overlay(0.28))
                        .overlay(Circle().fill(Chrome.accent).opacity(lit(i)))
                        .frame(width: Self.dot, height: Self.dot)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .opacity(1 - rest)
            HydraMarkImage()
                .foregroundStyle(Chrome.secondaryText)
                .frame(width: side, height: side)
                .scaleEffect(pop)
                .offset(x: x, y: y)
        }
        // Pinned to the leading edge: the dots keep their full width under the head even
        // once they have faded, so the stack stays as wide as the track while the frame
        // has shrunk to the resting head. Centred in it, the stack overhung the frame on
        // both sides and the settled head sat half outside the pill, a gap before the words.
        .frame(width: trackWidth + (Self.restingSize - trackWidth) * rest, height: Self.height, alignment: .topLeading)
    }
}

/// The team's work on its way to the remote once the lead has finished, and then the word
/// on how it went, in one pill in the report pill's frame. While the merge runs: the head on
/// its track of dots (see `HydraMergeTrack`) and the stage the merge is at right now (the
/// same words the sidebar shows). Merged, the track lights and the head settles. Once the outcome note lands: the note's title with its report
/// a tap away, and the merge request's link beside it. The timeline draws the pill under the
/// outcome note's own id from the first stage on (see `ThreadRuntime.hydraMergeNoteID`), so
/// this one row keeps its identity across the change and morphs: the contents crossfade
/// while the capsule glides to the new width. It holds no condition of its own.
struct HydraMergeRow: View {
    let runtime: ThreadRuntime
    let phase: HydraMergePhase

    @State private var isShowingReport = false
    @State private var flourish = false

    /// The one motion for anything in the pill changing: the stage's words, the time's
    /// digits, and the merging state giving way to the outcome.
    private static let change = Animation.smooth(duration: 0.3)

    var body: some View {
        let outcome: HydraMergeOutcome? = if case .outcome(let message) = phase { HydraMergeOutcome(message) } else { nil }
        let isMerging = outcome == nil
        // A merging pill for a merge that is over (the flag is down and no outcome note
        // has taken the pill's place) has nothing to say: it goes, rather than reading
        // "Merging…" for good. Observed here, so the flag going down takes it away.
        ZStack(alignment: .leading) {
            if isMerging, !runtime.isHydraMerging {
                EmptyView()
            } else {
                pill(outcome: outcome, isMerging: isMerging)
                    .transition(.settleGlide)
            }
        }
        .animation(.spring(Chrome.glideSpring), value: runtime.isHydraMerging)
    }

    private func pill(outcome: HydraMergeOutcome?, isMerging: Bool) -> some View {
        // The same stage words the sidebar shows beside its own spinner.
        let stage = MergeStageText.localized(runtime.hydraMergeStage ?? "Merging") + "…"
        // The stage alone, no clock: the merge's stages say what it is doing, and a
        // count of seconds beside them read as a stall.
        return HStack(spacing: 8) {
            // The track stays put through the change; the head opens the report like the title does.
            // Done, the head stands on the last dot: the merge clears its step as the
            // outcome note lands, so the runtime's own would send it back to the first.
            let mode = trackMode(outcome: outcome)
            let count = HydraMergeStage.allCases.count
            HydraMergeTrack(step: mode == .running ? (runtime.hydraMergeStep?.rawValue ?? 0) : count - 1, count: count, mode: mode)
                .contentShape(.rect)
                .onTapGesture {
                    guard let outcome, !outcome.details.isEmpty else { return }
                    isShowingReport.toggle()
                }
                .accessibilityHidden(true)
            // Only the contents of the current state take part in layout: a still copy of
            // them sizes the slot, and it changes over at once (an identity transition), so
            // the pill glides straight from the one width to the other. The contents on
            // show are drawn over that slot at their own size and clipped to it, the old
            // ones fading out as the new ones fade in; laid out side by side instead, the
            // two would hold the pill wide for the length of the fade.
            ZStack(alignment: .leading) {
                if let outcome {
                    outcomeLabel(outcome)
                        .transition(.identity)
                } else {
                    mergingLabel(stage: stage)
                        .transition(.identity)
                }
            }
            .hidden()
            .overlay(alignment: .leading) {
                ZStack(alignment: .leading) {
                    if let outcome {
                        outcomeControls(outcome)
                            .fixedSize()
                            .transition(.opacity)
                    } else {
                        mergingContent(stage: stage)
                            .fixedSize()
                            .transition(.opacity)
                    }
                }
            }
            // Room above and below for the stage words' lift, and a hair either side for
            // the controls' own edges, given back after the clip.
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .clipped()
            .padding(.horizontal, -2)
            .padding(.vertical, -6)
            // Scoped to the slot, so the shimmer's own frames beside it are never caught in
            // the transaction; the pill around it follows the slot's animated width.
            .animation(Self.change, value: isMerging)
        }
        .padding(.leading, TimelineMetrics.pillLeading)
        .padding(.trailing, TimelineMetrics.pillTrailing)
        .padding(.vertical, TimelineMetrics.pillVertical)
        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: TimelineMetrics.pillRadius, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 96)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: outcome?.title ?? String(format: Chrome.localized("Merging the team's work: %@"), stage)))
        .onChange(of: isMerging) { wasMerging, merging in
            guard wasMerging, !merging, let outcome, outcome.title.contains("Hydra merged") else { return }
            flourish = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1100))
                flourish = false
            }
        }
        // The report parses off the main thread as the pill appears, so the tap that
        // opens it finds the blocks ready rather than parsing the whole batch first.
        .task(id: outcome?.body) {
            guard let outcome, !outcome.details.isEmpty else { return }
            try? await MarkdownView.warm([outcome.body])
        }
    }

    private func trackMode(outcome: HydraMergeOutcome?) -> HydraMergeTrack.Mode {
        guard outcome != nil else { return .running }
        return flourish ? .done : .resting
    }

    // MARK: Merging

    /// The merging state as shown: the spinner, the stage with its shimmer, the time.
    private func mergingContent(stage: String) -> some View {
        HStack(spacing: 8) {
            // A new stage is a new text: the old one fades up and out as the new one fades in
            // from below, each with its own shimmer at its own width. A content transition
            // over the shimmer crossfaded the band's mask between the two lengths, so the
            // words tore mid-fade.
            //
            // Only the new words take part in layout: a hidden copy of them sizes the slot,
            // so the pill glides straight from the old width to the new one. The words on
            // show are drawn over that slot at their own size and clipped to it, so the
            // outgoing text neither holds the pill wide until its fade ends (it snapped
            // narrower afterwards) nor runs past the slot over the time beside it.
            Text(verbatim: stage)
                .font(.chat(.callout, weight: .medium))
                .hidden()
                .overlay(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        Text(verbatim: stage)
                            .font(.chat(.callout, weight: .medium))
                            .foregroundStyle(Chrome.primaryText.opacity(0.9))
                            .modifier(HydraShimmer())
                            .fixedSize()
                            .id(stage)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 5)),
                                removal: .opacity.combined(with: .offset(y: -5))
                            ))
                    }
                }
                // Room above and below for the words' lift, given back after the clip.
                .padding(.vertical, 6)
                .clipped()
                .padding(.vertical, -6)
                // On the slot alone: the whole row's transaction would catch the shimmer's
                // next frame too and ease it, so the band hitched at every new stage.
                .animation(Self.change, value: stage)
        }
    }

    /// The merging state's still copy, for its size only: the spinner's slot and the
    /// words, in the font they show in.
    private func mergingLabel(stage: String) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: stage)
                .font(.chat(.callout, weight: .medium))
                .animation(Self.change, value: stage)
        }
    }

    // MARK: Outcome

    /// The outcome as shown: the title opens the report, the link opens the merge request.
    /// The link is a control of its own beside the button, never inside its label: a link
    /// nested in a button takes the button's clicks on macOS, and the text stopped opening
    /// the popover.
    private func outcomeControls(_ outcome: HydraMergeOutcome) -> some View {
        HStack(spacing: 8) {
            Button {
                guard !outcome.details.isEmpty else { return }
                isShowingReport.toggle()
            } label: {
                outcomeTitle(outcome)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(outcome.details.isEmpty)
            .help(Text(verbatim: outcome.details.isEmpty ? "" : Chrome.localized("Show the message")))
            .chromePopover(isPresented: $isShowingReport, arrowEdge: .bottom) {
                // A merge note draws its own card; every other outcome keeps the markdown view.
                if let link = outcome.link, let request = MergeRequestLink(url: link), let note = HydraMergeNote.parse(outcome.details, link: request) {
                    HydraMergePopover(note: note)
                        .presentedChrome()
                } else {
                    HydraReportPopover(text: outcome.body)
                        .presentedChrome()
                }
            }
            if let link = outcome.link {
                Link(destination: link) {
                    openLabel
                }
                .help("Open in the browser")
            }
        }
    }

    /// The outcome's still copy, for its size only: the same title and link text without
    /// the controls around them, which add nothing to their size.
    private func outcomeLabel(_ outcome: HydraMergeOutcome) -> some View {
        HStack(spacing: 8) {
            outcomeTitle(outcome)
            if outcome.link != nil {
                openLabel
            }
        }
    }

    /// The title, and the chevron when there is a report behind it.
    private func outcomeTitle(_ outcome: HydraMergeOutcome) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: outcome.title)
                .font(.chat(.callout, weight: .medium))
                .foregroundStyle(Chrome.primaryText.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            if !outcome.details.isEmpty {
                Image(systemName: "chevron.right").font(.system(size: TypeScale.shared.content(TypeScale.stockPointSize(.caption2)), weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
            }
        }
    }

    private var openLabel: some View {
        Text("Open")
            .font(.chat(.caption, weight: .semibold))
            .foregroundStyle(Chrome.secondaryText)
    }
}

/// iMessage's outgoing bubble: rounded on three corners, the bottom-right one drawn out into
/// the little tail that curls back under the bubble. The shape only; the fill is the row's.
/// The tail's tip sits `tail` points past the body's trailing edge, at the very bottom.
struct UserBubble: Shape {
    static let cornerRadius: CGFloat = 18
    static let tail: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        let r = Self.cornerRadius
        let left = rect.minX
        let top = rect.minY
        let bottom = rect.maxY
        // The body's trailing edge; the tail reaches past it.
        let edge = rect.maxX - Self.tail
        var path = Path()
        path.move(to: CGPoint(x: left + r, y: top))
        path.addLine(to: CGPoint(x: edge - r, y: top))
        path.addArc(center: CGPoint(x: edge - r, y: top + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: edge, y: bottom - 11))
        // Out to the tip at the bottom corner, then curling back in under the body and
        // easing into the bottom edge.
        path.addCurve(
            to: CGPoint(x: edge + Self.tail, y: bottom),
            control1: CGPoint(x: edge, y: bottom - 1),
            control2: CGPoint(x: edge + Self.tail, y: bottom)
        )
        path.addCurve(
            to: CGPoint(x: edge - 7, y: bottom - 4),
            control1: CGPoint(x: edge, y: bottom + 0.5),
            control2: CGPoint(x: edge - 4, y: bottom - 1)
        )
        path.addCurve(
            to: CGPoint(x: edge - 21, y: bottom),
            control1: CGPoint(x: edge - 12, y: bottom),
            control2: CGPoint(x: edge - 16, y: bottom)
        )
        path.addLine(to: CGPoint(x: left + r, y: bottom))
        path.addArc(center: CGPoint(x: left + r, y: bottom - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: left, y: top + r))
        path.addArc(center: CGPoint(x: left + r, y: top + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct AttachmentStrip: View {
    let attachments: [Attachment]

    /// One preview panel for the strip, so every photo opens in a single tap no matter
    /// how many are attached, and made on the first tap rather than with the row.
    @State private var preview = AttachmentPreviewSlot()

    var body: some View {
        // Weak/box captures only: hover responders and anchor views must not keep this
        // strip (and its panel) alive after it scrolls away.
        let slot = preview
        // A plain stack hugs the thumbnails, so a trailing-aligned row keeps the
        // photos over the bubble — and the anchor view fills just the photos.
        HStack(spacing: 6) {
            ForEach(attachments) { attachment in
                AttachmentThumbnail(attachment: attachment, preview: preview)
                    .help(attachment.name)
            }
        }
        .background {
            AttachmentAnchorCapture { [weak slot] in slot?.setAnchor($0) }
        }
        .onDisappear { [weak slot] in slot?.close() }
    }
}

struct AttachmentThumbnail: View {
    @Environment(\.filePreviewAction) private var filePreviewAction
    @Environment(\.filePreviewContext) private var filePreviewContext
    let attachment: Attachment
    var size: CGFloat = 56
    /// The panel the photo opens in: either a slot, which makes its panel on the first
    /// tap, or one the caller already holds. A strip that scrolls with the conversation
    /// wants the slot; the composer's own strips, which are made once, take either.
    private let slot: AttachmentPreviewSlot?
    private let panel: AttachmentPreviewCoordinator?

    @State private var image: CGImage?
    /// The thumbnail's own NSView, handed to the panel on tap so the arrow
    /// lands on the tapped photo rather than the strip's middle. Mounted once the
    /// pointer has been on the photo: a tap always follows a hover, and a strip
    /// scrolling past should not be building views for a tap that never comes.
    @State private var ownAnchor = WeakView()
    @State private var needsAnchor = false
    /// Never mounts an anchor view of its own: for a strip that keeps every AppKit view
    /// out of SwiftUI's key-view-loop walk (see `WindowRectAnchor`). The panel then aims
    /// at the tap inside the strip's own anchor, which is where the pointer is anyway.
    private let anchorless: Bool

    init(attachment: Attachment, size: CGFloat = 56, preview: AttachmentPreviewSlot, anchorless: Bool = false) {
        self.init(attachment: attachment, size: size, slot: preview, panel: nil, anchorless: anchorless)
    }

    init(attachment: Attachment, size: CGFloat = 56, preview: AttachmentPreviewCoordinator) {
        self.init(attachment: attachment, size: size, slot: nil, panel: preview, anchorless: false)
    }

    private init(attachment: Attachment, size: CGFloat, slot: AttachmentPreviewSlot?, panel: AttachmentPreviewCoordinator?, anchorless: Bool) {
        self.attachment = attachment
        self.size = size
        self.slot = slot
        self.panel = panel
        self.anchorless = anchorless
        // A photo shown before starts out drawn, so scrolling back to it never fades it in again.
        _image = State(initialValue: PreviewImages.isImageAttachment(attachment) ? ThumbnailMemory.image(for: attachment.path, pointSize: size) : nil)
    }

    /// Opens (or closes) the panel for this photo, making one only now if the caller
    /// handed over a slot.
    private func togglePanel() {
        // Photos open at the click, in the large preview panel. Non-images keep the
        // file pane, whose readers handle text, documents and folders the panel cannot;
        // without one, the panel's fallback still shows them.
        if !PreviewImages.isImageAttachment(attachment),
           filePreviewAction(FilePreviewReference(path: attachment.path), context: filePreviewContext) { return }
        if let slot {
            slot.panel.toggle(attachment, over: ownAnchor.value, filePreviewAction: filePreviewAction, context: filePreviewContext)
        } else {
            panel?.toggle(attachment, over: ownAnchor.value, filePreviewAction: filePreviewAction, context: filePreviewContext)
        }
    }

    var body: some View {
        // The anchor box alone: the hover responder and the anchor view must not keep
        // this row (and its attachment) alive after it scrolls away.
        let anchorBox = ownAnchor
        Button {
            togglePanel()
        } label: {
            if PreviewImages.isImageAttachment(attachment) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.quaternary.opacity(0.6))
                    if let image {
                        Image(decorative: image, scale: 2)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
            } else if attachment.isVideo {
                AttachmentVideoThumbnail(attachment: attachment, size: size)
            } else {
                // A file fills its chip the way a photo does: the Finder icon at the
                // chip's full size on the same plate, so a text file, a PDF and a
                // folder all read at a glance. The name is the tooltip and the preview
                // panel; at 48pt it never fit under a 16pt icon anyway.
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.quaternary.opacity(0.6))
                    Image(nsImage: FileIcons.icon(for: attachment.path))
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(size * 0.08)
                }
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(Text(attachment.name))
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .rightClickPopover { [attachment, filePreviewAction, filePreviewContext] in
            [
                RowAction(title: "Open in preview", symbol: "sidebar.right") {
                    _ = filePreviewAction(FilePreviewReference(path: attachment.path), context: filePreviewContext, pinned: true)
                },
                RowAction(title: "Open", symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(attachment.url) },
                RowAction(title: "Show in Finder", symbol: "folder") { NSWorkspace.shared.activateFileViewerSelecting([attachment.url]) },
            ]
        }
        // The .fill image is drawn wider than the cell before it is clipped;
        // pinning the hit shape to the cell keeps the neighbour's remove badge
        // reachable no matter how hit-testing treats the overflow.
        .contentShape(.rect(cornerRadius: 12, style: .continuous))
        .onHover { [needed = $needsAnchor, anchorless] hovering in
            if hovering, !anchorless, !needed.wrappedValue { needed.wrappedValue = true }
        }
        .background {
            if needsAnchor, !anchorless {
                AttachmentAnchorCapture { [weak anchorBox] in anchorBox?.value = $0 }
            }
        }
        .task(id: attachment.path) {
            guard PreviewImages.isImageAttachment(attachment) else { return }
            if let known = ThumbnailMemory.image(for: attachment.path, pointSize: size) {
                if image !== known { image = known }
                return
            }
            guard let thumbnail = await ThumbnailCache.shared.thumbnail(for: attachment.path, pointSize: size, fillingSquare: true) else { return }
            ThumbnailMemory.store(thumbnail.image, for: attachment.path, pointSize: size)
            withAnimation(.easeOut(duration: 0.15)) { image = thumbnail.image }
        }
    }
}

struct AssistantMessageRow: View {
    let entry: TimelineEntry
    /// The turn's summary, set only on the turn's last reply. Precomputed by the
    /// timeline, so rows never scan the thread.
    let summary: TurnSummary?
    let runtime: ThreadRuntime
    @State private var isHovering = false

    var body: some View {
        if case .assistant(let message) = entry.item.content {
            VStack(alignment: .leading, spacing: 2) {
                MarkdownView(text: message.text, isStreaming: message.isStreaming).equatable()
                // One side for both kinds of message: the summary sits on the trailing
                // edge, where the copy control used to be.
                HStack(spacing: 8) {
                    if let summary {
                        Text(TurnEndRow.label(for: summary))
                            .font(.chat(.caption))
                            .foregroundStyle(Chrome.secondaryText)
                    }
                    Spacer(minLength: 8)
                }
                // Pinned to the hover line's room, so the row keeps it (and the gap math
                // below holds) with no copy button left to size it.
                .frame(height: TimelineMetrics.hoverLineHeight)
                .opacity(isHovering && !message.isStreaming ? 1 : 0)
            }
            .onHover { [hovering = $isHovering] isOver in
                withAnimation(.easeOut(duration: 0.12)) { hovering.wrappedValue = isOver }
            }
            .messageMenu(text: message.text, runtime: runtime)
            // Same trade as the user row: the hover line's room stays inside the row
            // (so hovering it works and text never moves), but not in its height, so
            // the controls fill the gap below instead of adding to it. (2 = the
            // VStack's spacing above them.)
            .padding(.bottom, -(TimelineMetrics.hoverLineHeight + 2))
        }
    }

    /// The context menu's items, from value snapshots with weak captures: the AppKit menu
    /// outlives the right-click, so its callbacks must not retain the row.
    static func messageActions(text: String, code: String?, runtime: ThreadRuntime, selection: SelectionCopy) -> [RowAction] {
        let textSnapshot = text
        let quoteSnapshot = selection.text ?? text
        let codeSnapshot = code
        var items = copyActions(text: textSnapshot, selection: selection)
        if let codeSnapshot {
            items.append(RowAction(title: "Copy last code block", symbol: "chevron.left.forwardslash.chevron.right", confirms: "Copied") { [code = codeSnapshot] in
                copyMessageText(code)
            })
        }
        items.append(RowAction(title: "Add to reply", symbol: "arrow.turn.down.left", startsGroup: true, confirms: "Added") { [weak runtime] in
            guard let runtime else { return }
            guard !runtime.draft.quotes.contains(where: { $0.text == quoteSnapshot }) else { return }
            runtime.draft.quotes.append(ReplyQuote(text: quoteSnapshot))
        })
        return items
    }
}

extension View {
    /// The right-click popover of a reply, opened at the pointer, wherever its text
    /// is shown: copy, the last code block, quoting it into the chat box.
    /// Snapshots only: the popover builder must not capture the
    /// row, so the popover cannot pin the row's state storage after dismiss.
    func messageMenu(text: String, runtime: ThreadRuntime) -> some View {
        rightClickPopover { [text, runtime] selection in
            AssistantMessageRow.messageActions(
                text: text,
                code: lastCodeBlock(in: text),
                runtime: runtime,
                selection: selection
            )
        }
    }
}

private struct FoldedAnswerView: View {
    let text: String
    let runtime: ThreadRuntime

    var body: some View {
        MarkdownView(text: text).equatable()
            .messageMenu(text: text, runtime: runtime)
    }
}

/// Every entry in an expanded step group, in arrival order. Tool payloads and
/// individual thinking blocks retain their bounded detail viewports.
struct WorkSteps: View {
    let entries: [TimelineEntry]
    let runtime: ThreadRuntime
    var workingDirectory: String?

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            ActivityStep(id: entry.id, continues: index < entries.count - 1) {
                switch entry.item.content {
                case .reasoning:
                    ThinkingRow(entry: entry)
                case .notice:
                    NoticeRow(entry: entry)
                case .tool:
                    ToolRow(entry: entry, runtime: runtime, workingDirectory: workingDirectory)
                default:
                    EmptyView()
                }
            }
        }
    }
}

/// A thinking step uses the same plain icon/text/chevron row as a tool. The preview
/// reads the actual first line; opening the full native text is always the reader's choice.
struct ThinkingRow: View {
    let entry: TimelineEntry
    @Environment(\.revealTimelineEnd) private var revealBox
    @Environment(\.timelineBlockID) private var blockID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    @State private var fallbackExpanded = false

    private var isExpanded: Bool {
        get { revealBox?.presentation.thoughts[entry.id] ?? fallbackExpanded }
        nonmutating set {
            if let revealBox { revealBox.presentation.thoughts[entry.id] = newValue }
            else { fallbackExpanded = newValue }
        }
    }

    var body: some View {
        if case .reasoning(let block) = entry.item.content {
            let preview = String(block.text.prefix { !$0.isNewline })
            VStack(alignment: .leading, spacing: TimelineMetrics.rowSpacing) {
                Button {
                    revealBox?.disclosure(blockID)
                    withAnimation(reduceMotion || performanceMode ? nil : .snappy(duration: 0.24)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: TimelineMetrics.iconSpacing) {
                        TimelineSymbolIcon(OMPToolSymbols.symbol(for: OMPTool.think))
                            .foregroundStyle(Chrome.secondaryText)
                            .accessibilityHidden(true)
                        Text("Thought process")
                            .lineLimit(1)
                            .layoutPriority(1)
                        if !preview.isEmpty {
                            Text(verbatim: preview)
                                .foregroundStyle(Chrome.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(-1)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: TypeScale.shared.content(TypeScale.stockPointSize(.caption2)), weight: .semibold))
                            .foregroundStyle(Chrome.secondaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .fixedSize()
                            .layoutPriority(2)
                            .accessibilityHidden(true)
                    }
                    .font(.chat(.callout))
                    .foregroundStyle(Chrome.primaryText)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: Chrome.localized(isExpanded ? "Hide the thinking" : "Show the thinking")))
                .accessibilityValue(Text(isExpanded ? "Expanded" : "Collapsed"))

                if isExpanded {
                    ThinkingScroll(steps: [ThinkingStep(text: block.text, isStreaming: block.isStreaming)])
                        .foregroundStyle(.secondary)
                        .environment(\.markdownPointSize, TypeScale.shared.content(12))
                        .environment(\.markdownDimmed, true)
                        .padding(.leading, TimelineMetrics.iconWidth + TimelineMetrics.iconSpacing)
                        .padding(.trailing, 12)
                        .transition(.opacity)
                }
            }
        }
    }
}

/// The heads a turn sent out, one tool row each, as a plain list: no header, no
/// chevron. It stays at its arrival position during a turn and inside the overall
/// process disclosure after completion.
struct HydraHeadsList: View {
    let entries: [TimelineEntry]
    let runtime: ThreadRuntime
    var workingDirectory: String?

    var body: some View {
        // Badges, not lines of text: they stack closer than rows of text do.
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entries) { entry in
                ToolRow(entry: entry, runtime: runtime, workingDirectory: workingDirectory)
            }
        }
    }
}

/// The "Edited files, ran commands" line above a tool group, derived from the
/// calls' kinds and native write identity rather than their localized titles.
/// First part capitalized, the rest lowered, in a fixed kind order. A kind with a call still running reads
/// in the present tense ("Editing files, ran commands").
///
/// Main-actor isolated like the entries it reads: `TimelineEntry.item` lives on
/// the main actor, so this can only run where view bodies run.
@MainActor
enum WorkGroupSummary {
    private static let order: [ToolCall.Kind] = [.edit, .read, .command, .search, .web, .mcp, .agent, .other]

    static func text(for entries: [TimelineEntry]) -> String {
        // Kind → whether a call of it is still running, in one pass; this runs once a
        // second under the working indicator.
        var running: [ToolCall.Kind: Bool] = [:]
        var writing: Bool?
        for entry in entries {
            guard case .tool(let call) = entry.item.content else { continue }
            if call.kind == .edit, call.ompTool == .write {
                writing = (writing ?? false) || call.status == .running
                continue
            }
            running[call.kind, default: false] = running[call.kind, default: false] || call.status == .running
        }
        var parts: [String] = []
        for kind in order {
            if let isRunning = running[kind] {
                parts.append(label(for: kind, running: isRunning))
            }
            if kind == .edit, let writing {
                parts.append(Chrome.localized(writing ? "Writing files" : "Wrote files"))
            }
        }
        if parts.isEmpty { return Chrome.localized("Worked") }
        guard parts.count > 1 else { return parts[0] }
        let rest = parts.dropFirst().map { part -> String in
            guard let head = part.first else { return part }
            return String(head).lowercased() + String(part.dropFirst())
        }
        return ([parts[0]] + rest).joined(separator: Chrome.localized(", "))
    }

    static func symbol(for entries: [TimelineEntry]) -> SFSymbolResource {
        let calls = entries.compactMap { entry -> ToolCall? in
            guard case .tool(let call) = entry.item.content else { return nil }
            return call
        }
        if let first = calls.first, calls.allSatisfy({
            $0.toolName == first.toolName && $0.toolDevice == first.toolDevice && $0.kind == first.kind
        }) {
            return ToolPresentation.symbol(for: first)
        }
        let kinds = Set(entries.compactMap { entry -> ToolCall.Kind? in
            guard case .tool(let call) = entry.item.content else { return nil }
            return call.kind
        })
        let order: [ToolCall.Kind] = [.edit, .read, .command, .search, .web, .mcp, .agent, .other]
        guard let first = order.first(where: { kinds.contains($0) }) else { return "wrench.and.screwdriver" }
        return ToolPresentation.symbol(for: first)
    }

    private static func label(for kind: ToolCall.Kind, running: Bool) -> String {
        switch kind {
        case .edit: Chrome.localized(running ? "Editing files" : "Edited files")
        case .read: Chrome.localized(running ? "Reading files" : "Read files")
        case .command: Chrome.localized(running ? "Running commands" : "Ran commands")
        case .search: Chrome.localized(running ? "Searching" : "Searched")
        case .web: Chrome.localized(running ? "Browsing" : "Browsed")
        case .mcp: Chrome.localized(running ? "Calling tools" : "Called tools")
        case .agent: Chrome.localized(running ? "Delegating tasks" : "Delegated tasks")
        case .other: Chrome.localized(running ? "Using tools" : "Used tools")
        }
    }
}

struct ToolRow: View {
    @Environment(\.activityTreeStyle) private var activityTreeStyle
    @Environment(AppModel.self) private var model
    @Environment(\.filePreviewAction) private var filePreviewAction
    @Environment(\.filePreviewContext) private var filePreviewContext
    let entry: TimelineEntry
    let runtime: ThreadRuntime
    var workingDirectory: String?
    @State private var isExpanded = false
    /// The image preview and its label anchor are made on first use, so scrolling
    /// past hundreds of tool rows never builds panels the reader has not opened.
    @State private var preview = AttachmentPreviewSlot()
    /// Whether the pointer has been on the row's label, which is when its anchor view is
    /// mounted. A click always follows a hover, and hovering is off while the timeline
    /// scrolls, so a row scrolling past never mounts one. Once mounted it stays: a popover
    /// is positioned against this view, and taking it away under an open one closes it.
    @State private var needsAnchor = false
    /// Whether the steps popover of the head this row sent out is open.
    @State private var isShowingHead = false
    @Environment(\.revealTimelineEnd) private var revealBox
    @Environment(\.timelineBlockID) private var blockID

    var body: some View {
        if case .tool(let call) = entry.item.content {
            // File changes expand below their own tool row using only this call's
            // edits. Reading an image still opens the image preview.
            let edits = call.edits.filter { !$0.path.isEmpty }
            let showsDiff = !edits.isEmpty
            let imagePath = showsDiff ? nil : PreviewImages.resolveToolImagePath(for: call, workingDirectory: workingDirectory)
            let showsOutput = !call.output.isEmpty || !(call.detail ?? "").isEmpty
            let showsDetails = showsDiff || showsOutput
            let opensImage = imagePath != nil && (call.kind == .read || !showsOutput)
            // A row that sent out a head opens the head's steps in a popover of its own,
            // never its raw tool output.
            let headIDs = call.kind == .agent ? runtime.hydraHeads(forTool: entry.id) : []
            let opensHead = !headIDs.isEmpty
            let references = Self.previewReferences(for: call)
            // A call with no change to show, no image and no output of its own has
            // nothing to open. Rendered as a line of text rather than a control, so the
            // pointer and VoiceOver both treat it as what it is.
            let isTappable = opensImage || opensHead || showsDetails
            // Values and weak boxes only below: the button action must not keep this
            // row's entry (and its text) alive through menus and hovers.
            let slot = preview
            VStack(alignment: .leading, spacing: TimelineMetrics.rowSpacing) {
                HStack(spacing: 4) {
                    if isTappable {
                        Button {
                            [weak slot, revealBox, blockID, filePreviewAction, filePreviewContext,
                             presented = $isShowingHead, expanded = $isExpanded] in
                            if opensHead {
                                presented.wrappedValue.toggle()
                            } else if opensImage, let imagePath {
                                slot?.panel.toggle(PreviewImages.attachment(for: imagePath), over: slot?.anchor.value, edge: .minY,
                                                   filePreviewAction: filePreviewAction, context: filePreviewContext)
                            } else {
                                revealBox?.disclosure(blockID)
                                withAnimation(.snappy(duration: 0.24)) {
                                    expanded.wrappedValue.toggle()
                                }
                            }
                        } label: {
                            line(call: call, imagePath: imagePath, opensImage: opensImage, opensHead: opensHead, showsDetails: showsDetails)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help(Text(verbatim: helpText(showsDiff: showsDiff, opensImage: opensImage, opensHead: opensHead, showsOutput: showsOutput)))
                    } else {
                        line(call: call, imagePath: imagePath, opensImage: opensImage, opensHead: opensHead, showsDetails: showsDetails)
                    }
                    // Keep the delegation row's spare width outside its button.
                    if call.kind == .agent {
                        Spacer(minLength: 8)
                        if call.status == .declined {
                            Text("Declined")
                                .font(.chat(.caption))
                                .foregroundStyle(Chrome.warning)
                        }
                    }
                }
                .padding(.trailing, call.kind == .agent ? 12 : 0)
                .modifier(ToolFilePreviewMenu(references: references))
                if isExpanded, showsDetails, !opensImage, !opensHead {
                    ToolDetailView(call: call, workingDirectory: workingDirectory)
                        .padding(.trailing, 12)
                }
            }
            .onDisappear { [weak slot] in slot?.close() }
        }
    }

    /// Structured OMP references take precedence. Imported read rows from older
    /// versions can expose their path only when their title is plainly a path;
    /// arbitrary command titles and device documentation never become file links.
    private static func previewReferences(for call: ToolCall) -> [FilePreviewReference] {
        if let references = call.fileReferences { return references }
        if let reference = call.fileReference { return [reference] }
        guard call.kind == .read, call.toolDevice == nil,
              call.toolName == nil || call.toolName == "read" else { return [] }
        let title = call.title.trimmed
        guard !title.isEmpty, title.rangeOfCharacter(from: .newlines) == nil,
              !title.contains("\0"), !title.contains("://") || title.lowercased().hasPrefix("file://") else { return [] }
        let lower = title.lowercased()
        guard !["read ", "reading ", "view ", "open ", "cat "].contains(where: lower.hasPrefix) else { return [] }
        let looksLikePath = title.hasPrefix("/") || title.hasPrefix("./") || title.hasPrefix("../")
            || title.hasPrefix("~/") || title.lowercased().hasPrefix("file://")
            || title.contains("/") || !(title as NSString).pathExtension.isEmpty
        return looksLikePath ? [FilePreviewReference(path: title)] : []
    }

    /// The head a delegation call is sending out, read from the call itself before its
    /// thread is linked: a roster name leading the title ("Pip: the merge popover") names
    /// the face; unresolved workers use a neutral icon until native metadata arrives.
    /// The task is the title past the name.
    private static func departingHead(for call: ToolCall) -> (persona: HydraPersona?, name: String?, task: String) {
        let title = call.title.trimmed
        // "Subagent" and the like are the tool's own word for itself, not a task.
        let generic: Set<String> = ["subagent", "agent", "task", ""]
        if let colon = title.firstIndex(of: ":") {
            let name = String(title[..<colon]).trimmed
            if let persona = HydraRoster.persona(named: name) {
                let task = String(title[title.index(after: colon)...]).trimmed
                return (persona, persona.name, task)
            }
        }
        return (nil, nil, generic.contains(title.lowercased()) ? "" : title)
    }

    /// What the departing row says: on its way, out, or never sent.
    private static func departureLabel(for call: ToolCall, name: String?, task: String) -> String {
        let who = name ?? Chrome.localized("a head")
        let template = switch call.status {
        case .running: "Sending out %@"
        case .failed: "Could not send out %@"
        default: "Sent out %@"
        }
        if task.isEmpty { return String(format: Chrome.localized(template), who) }
        return String(format: Chrome.localized(template + ": %@"), who, task)
    }

    private static func departureStatus(for call: ToolCall) -> HydraHeadInfo.Status? {
        switch call.status {
        case .running: nil
        case .failed: .failed
        default: .completed
        }
    }

    /// The row itself: icon, text, stats and chevron, laid out the same whether or not
    /// the line can be tapped.
    @ViewBuilder
    private func line(call: ToolCall, imagePath: String?, opensImage: Bool, opensHead: Bool, showsDetails: Bool) -> some View {
        // The slot alone: the hover responder and the anchor view must not keep this
        // row's entry (and its text) alive after it scrolls away.
        let previewSlot = preview
        // A row that sent out a head wears the head's glyph and name, in the badge the
        // finished turn's card and the working line wear, rather than as a line of text.
        let heads = call.kind == .agent ? runtime.hydraHeads(forTool: entry.id).compactMap { model.thread($0)?.hydra } : []
        let head = heads.first
        // Before the head's thread is linked to the call (the moment it goes out, or a
        // call that failed to send one), use the name from the call's own title when
        // it leads with a roster name. Otherwise keep the icon neutral.
        let departing = call.kind == .agent && head == nil ? Self.departingHead(for: call) : nil
        let mcp = ToolPresentation.mcpParts(call)
        let isBadge = head != nil || departing != nil || (mcp != nil && !activityTreeStyle)
        HStack(spacing: TimelineMetrics.iconSpacing) {
            HStack(spacing: isBadge ? 8 : TimelineMetrics.iconSpacing) {
                if !heads.isEmpty {
                    HydraHeadGlyphs(heads: heads)
                } else if let departing {
                    if let persona = departing.persona {
                        HydraGlyph(persona: persona, size: 18, isRunning: call.status == .running, status: Self.departureStatus(for: call))
                    } else {
                        ToolStatusIcon(call: call, symbol: OMPToolSymbols.symbol(for: OMPTool.task))
                    }
                } else if let mcp {
                    ToolStatusIcon(call: call, asset: mcp.entry.asset, size: 18,
                                   tint: mcp.entry.isMonochrome ? Chrome.primaryText : mcp.entry.color)
                } else {
                    ToolStatusIcon(call: call, symbol: imagePath != nil && call.kind == .read ? "photo" : nil)
                }
                // One text run after the icon, so the row reads as
                // icon + space + text instead of three spaced items.
                Text(verbatim: heads.count > 1
                    ? String(format: Chrome.localized(call.status == .running ? "Sending out %lld heads" : "Sent out %lld heads"), Int64(heads.count))
                    : head.map { String(format: Chrome.localized(call.status == .running ? "Sending out %@: %@" : "Sent out %@: %@"), $0.persona.name, call.title) }
                    ?? departing.map { Self.departureLabel(for: call, name: $0.name, task: $0.task) }
                    ?? mcp.map { ToolPresentation.mcpLabel(entry: $0.entry, tool: $0.tool, running: call.status == .running) }
                    ?? ToolPresentation.label(for: call))
                    .font(isBadge ? .chat(.callout, weight: .medium) : .chat(.callout))
                    .foregroundStyle(isBadge ? AnyShapeStyle(Chrome.primaryText.opacity(0.9)) : (activityTreeStyle ? AnyShapeStyle(Chrome.primaryText) : AnyShapeStyle(.secondary)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let stats = ToolPresentation.stats(for: call) {
                    DiffStatLabel(additions: stats.additions, deletions: stats.deletions)
                }
                // Beside the subject, not out at the trailing edge: the chevron
                // belongs to the row's own text.
                if opensImage || opensHead {
                    Image(systemName: "chevron.down").font(.system(size: TypeScale.shared.content(TypeScale.stockPointSize(.caption2)), weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                } else if showsDetails {
                    Image(systemName: "chevron.right").font(.system(size: TypeScale.shared.content(TypeScale.stockPointSize(.caption2)), weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(.leading, isBadge ? TimelineMetrics.pillLeading : 0)
            .padding(.trailing, isBadge ? TimelineMetrics.pillTrailing : 0)
            .padding(.vertical, isBadge ? TimelineMetrics.pillVertical : 0)
            .background {
                if isBadge {
                    RoundedRectangle(cornerRadius: TimelineMetrics.pillRadius, style: .continuous)
                        .fill(.quaternary.opacity(0.32))
                }
            }
            .onHover { [needed = $needsAnchor] hovering in
                if opensImage, hovering, !needed.wrappedValue { needed.wrappedValue = true }
            }
            .background {
                if opensImage, needsAnchor {
                    AttachmentAnchorCapture { [weak previewSlot] in previewSlot?.setAnchor($0) }
                }
            }
            // On the text run (the badge), not the full-width row: hung from the row, the
            // popover's arrow pointed at the row's middle, well to the right of the words.
            .modifier(HeadStepsPopoverModifier(headIDs: opensHead ? runtime.hydraHeads(forTool: entry.id) : [], isPresented: $isShowingHead))
            if call.kind != .agent {
                Spacer(minLength: 8)
                if call.status == .declined {
                    Text("Declined")
                        .font(.chat(.caption))
                        .foregroundStyle(Chrome.warning)
                }
            }
        }
        .font(.chat(.callout))
        .padding(.trailing, call.kind == .agent ? 0 : 12)
    }

    private func helpText(showsDiff: Bool, opensImage: Bool, opensHead: Bool, showsOutput: Bool) -> String {
        if opensHead { return Chrome.localized("Show the head's steps") }
        if showsDiff { return Chrome.localized(isExpanded ? "Hide this change" : "Show this change") }
        if opensImage { return Chrome.localized("Show the image") }
        guard showsOutput else { return "" }
        return Chrome.localized(isExpanded ? "Hide the output" : "Show the output")
    }
}

/// Non-file tools mount no additional AppKit menu catcher in a long timeline.
private struct ToolFilePreviewMenu: ViewModifier {
    let references: [FilePreviewReference]
    @Environment(\.filePreviewAction) private var filePreviewAction
    @Environment(\.filePreviewContext) private var filePreviewContext

    @ViewBuilder
    func body(content: Content) -> some View {
        if !references.isEmpty {
            content.rightClickPopover { [references, filePreviewAction, filePreviewContext] in
                references.map { reference in
                    let title = references.count == 1 ? "Open in preview"
                        : String(format: Chrome.localized("Open in preview: %@"), reference.path)
                    return RowAction(title: title, symbol: "sidebar.right") {
                        _ = filePreviewAction(reference, context: filePreviewContext, pinned: true)
                    }
                }
            }
        } else {
            content
        }
    }
}

/// Hangs the head's steps popover from a row that sent out a head. A row that did not
/// mounts nothing: the popover, its state and its anchor exist only where they can open.
private struct HeadStepsPopoverModifier: ViewModifier {
    let headIDs: [UUID]
    @Binding var isPresented: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.chatColumnIsShown) private var isColumnShown
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if let headID = headIDs.first {
            // Measure once and resolve a fitting edge before the card's native
            // presentation starts, including after scrolling or changing windows.
            content.badgePopover(isPresented: $isPresented, usesViewAnchor: true) {
                Group {
                    if headIDs.count == 1 {
                        HydraHeadStepsPopover(headID: headID)
                    } else {
                        DelegatedHeadsPopover(headIDs: headIDs)
                    }
                }
                .environment(model)
                .environment(\.chatColumnIsShown, isColumnShown)
                .environment(\.locale, locale)
                .environment(\.colorScheme, colorScheme)
            }
            .onChange(of: isColumnShown) { _, shown in
                if !shown { isPresented = false }
            }
        } else {
            content
        }
    }
}

/// A batch keeps every worker reachable, with only the selected journal leased.
private struct DelegatedHeadsPopover: View {
    let headIDs: [UUID]
    @Environment(AppModel.self) private var model
    @State private var selected: UUID?

    var body: some View {
        let id = selected.flatMap { headIDs.contains($0) ? $0 : nil } ?? headIDs.first
        VStack(spacing: 0) {
            Picker("Delegated heads", selection: Binding(get: { id }, set: { selected = $0 })) {
                ForEach(headIDs, id: \.self) { headID in
                    Text(verbatim: model.thread(headID)?.title ?? "").tag(Optional(headID))
                }
            }
            .pickerStyle(.menu)
            .padding(12)
            Divider()
            // Keep every selected worker's journal inside the same native viewport.
            if let id { HydraHeadStepsPopover(headID: id, reservesFullHeight: true).id(id) }
        }
        .frame(width: 440)
    }
}

/// What a head did, in plain text: its brief, then every step it took, then its report.
/// Reads the head's own runtime straight from the model, so the list grows while the
/// head still works.
struct HydraHeadStepsPopover: View {
    let headID: UUID
    var reservesFullHeight = false
    @Environment(AppModel.self) private var model

    @Environment(\.chatColumnIsShown) private var isColumnShown
    @State private var detailConsumerID = UUID()
    private var detailConsumer: String { "hydra-steps-" + detailConsumerID.uuidString }

    private static let width: CGFloat = 440
    private static let maxHeight: CGFloat = 520

    var body: some View {
        let hydra = model.thread(headID)?.hydra
        let runtime = model.runtime(for: headID)
        let steps = Self.steps(in: runtime.entries)
        let report = hydra.flatMap { head -> String? in
            guard head.isFinished else { return nil }
            let text = (head.summary ?? "").trimmed
            return text.isEmpty ? nil : text
        }
        PopoverScroll(maxHeight: Self.maxHeight, minHeight: reservesFullHeight ? Self.maxHeight : 80, width: Self.width) {
            VStack(alignment: .leading, spacing: 16) {
                if let issue = runtime.nativeAgentHistoryIssue {
                    Text(verbatim: issue).font(.chat(.callout)).foregroundStyle(Chrome.warning)
                        .lineSpacing(MarkdownParagraphLayout.lineSpacing).textSelection(.enabled)
                } else if runtime.nativeAgentHistoryLoading {
                    Text("Loading OMP worker history…").font(.chat(.callout)).foregroundStyle(Chrome.secondaryText)
                }
                if let hydra {
                    header(hydra)
                    if !hydra.task.isEmpty {
                        Text(verbatim: hydra.task)
                            .font(.chat(.callout))
                            .foregroundStyle(Chrome.primaryText)
                            .lineSpacing(MarkdownParagraphLayout.lineSpacing)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: TimelineMetrics.rowSpacing) {
                    sectionTitle("Steps")
                    if steps.isEmpty {
                        Text("No steps yet.")
                            .font(.chat(.callout))
                            .foregroundStyle(Chrome.secondaryText)
                    } else {
                        ForEach(steps) { entry in
                            step(entry)
                        }
                    }
                }
                if let report {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("Report")
                        Text(verbatim: report)
                            .font(.chat(.callout))
                            .foregroundStyle(Chrome.primaryText)
                            .lineSpacing(MarkdownParagraphLayout.lineSpacing)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(width: Self.width, alignment: .leading)
        }
        .scrollIndicators(.never)
        .frame(width: Self.width)
        .task(id: isColumnShown) {
            await model.setOMPAgentDetailsVisible(headID: headID, visible: isColumnShown, consumer: detailConsumer)
        }
        .onDisappear {
            Task { await model.setOMPAgentDetailsVisible(headID: headID, visible: false, consumer: detailConsumer) }
        }
    }

    /// The head's glyph and name, with where it stands on the trailing side.
    private func header(_ hydra: HydraHeadInfo) -> some View {
        HStack(alignment: .center, spacing: TimelineMetrics.iconSpacing) {
            HydraGlyph(persona: hydra.persona, size: 22, isRunning: hydra.status == .running, status: hydra.status)
            Text(verbatim: hydra.persona.name)
                .font(.chat(.headline))
                .foregroundStyle(Chrome.primaryText)
            Spacer(minLength: 12)
            Text(verbatim: Self.statusLine(for: hydra))
                .font(.chat(.caption))
                .foregroundStyle(Chrome.secondaryText)
                .lineLimit(1)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(verbatim: Chrome.localized(title))
            .font(.chat(.caption, weight: .semibold))
            .foregroundStyle(Chrome.secondaryText)
    }

    /// One step, laid out like the timeline's own rows: the icon column, then the text.
    @ViewBuilder
    private func step(_ entry: TimelineEntry) -> some View {
        switch entry.item.content {
        case .tool(let call):
            let mcp = ToolPresentation.mcpParts(call)
            let textCapHeight = NSFont.systemFont(ofSize: TypeScale.shared.content(TypeScale.stockPointSize(.callout))).capHeight
            HStack(alignment: .firstTextBaseline, spacing: TimelineMetrics.iconSpacing) {
                Group {
                    if let mcp {
                        ToolStatusIcon(call: call, asset: mcp.entry.asset, size: 14,
                                       tint: mcp.entry.isMonochrome ? Chrome.primaryText : mcp.entry.color)
                    } else {
                        ToolStatusIcon(call: call)
                    }
                }
                .frame(width: TimelineMetrics.iconWidth)
                .alignmentGuide(.firstTextBaseline) { [textCapHeight] dimensions in
                    dimensions[VerticalAlignment.center] + textCapHeight / 2
                }
                Text(verbatim: mcp.map { ToolPresentation.mcpLabel(entry: $0.entry, tool: $0.tool, running: call.status == .running) } ?? ToolPresentation.label(for: call))
                    .font(.chat(.callout))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let stats = ToolPresentation.stats(for: call) {
                    DiffStatLabel(additions: stats.additions, deletions: stats.deletions)
                }
            }
        case .assistant(let message):
            Text(verbatim: message.text)
                .font(.chat(.callout))
                .foregroundStyle(Chrome.primaryText)
                .lineSpacing(MarkdownParagraphLayout.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .user(let message):
            // A later brief: the lead steering the head on.
            Text(verbatim: message.text)
                .font(.chat(.callout))
                .foregroundStyle(Chrome.secondaryText)
                .lineSpacing(MarkdownParagraphLayout.lineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .notice:
            NoticeRow(entry: entry)
                .environment(\.revealTimelineEnd, nil)
        default:
            EmptyView()
        }
    }

    /// "Working…" or the outcome, then the tool count and, once the head is done, how
    /// long it took.
    private static func statusLine(for hydra: HydraHeadInfo) -> String {
        let outcome: String = switch hydra.status {
        case .running: Chrome.localized("Working…")
        case .completed: Chrome.localized("Done")
        case .failed: Chrome.localized("Failed")
        case .stopped: Chrome.localized("Stopped")
        }
        var parts = [outcome]
        if hydra.toolCalls > 0 {
            parts.append(hydra.toolCalls == 1 ? Chrome.localized("1 tool") : String(format: Chrome.localized("%d tools"), hydra.toolCalls))
        }
        if let finishedAt = hydra.finishedAt {
            parts.append(RelativeTime.duration(finishedAt.timeIntervalSince(hydra.startedAt)))
        }
        return parts.joined(separator: " · ")
    }

    /// The entries worth a line: every tool call, reply and notice, and any brief after
    /// the first. The first user entry is the task itself, shown above; thinking, plans,
    /// todo lists and turn ends are the head's own bookkeeping.
    private static func steps(in entries: [TimelineEntry]) -> [TimelineEntry] {
        var sawBrief = false
        return entries.filter { entry in
            switch entry.item.content {
            case .user(let message):
                if !sawBrief {
                    sawBrief = true
                    return false
                }
                return !message.text.trimmed.isEmpty
            case .assistant(let message):
                return !message.text.trimmed.isEmpty
            case .tool:
                return true
            case .notice(let notice):
                return !notice.isRuntimeSetupNoise
            case .reasoning, .turnEnd, .plan, .todos:
                return false
            }
        }
    }
}

private struct ToolStatusIcon: View {
    let call: ToolCall
    /// Image reads and existing MCP artwork can override the exact tool symbol.
    var symbol: SFSymbolResource?
    var asset: String?
    var size: CGFloat = TimelineMetrics.iconWidth
    var tint: Color = Chrome.secondaryText
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let asset {
                Image(asset)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
            } else {
                TimelineSymbolIcon(symbol ?? OMPToolSymbols.symbol(for: call))
            }
        }
            .foregroundStyle(call.status == .failed ? Chrome.danger : tint)
            .frame(width: size, height: size)
            .accessibilityLabel(Text(verbatim: ""))
            .accessibilityValue(Text(verbatim: call.status == .failed ? Chrome.localized("Failed") : ""))
            .overlay(alignment: .bottomTrailing) {
                if let badge = statusBadge {
                    Image(systemName: badge.symbol)
                        .font(.system(size: 5, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 8, height: 8)
                        .background(badge.color, in: Circle())
                        .overlay {
                            Circle().strokeBorder(colorScheme == .dark ? Color.black.opacity(0.55) : Color.white.opacity(0.95), lineWidth: 1)
                        }
                        .offset(x: 2, y: 2)
                }
            }
    }

    private var statusBadge: (symbol: String, color: Color)? {
        switch call.status {
        case .declined: ("hand.raised.slash", Chrome.warning)
        default: nil
        }
    }
}

private struct ToolDetailView: View {
    let call: ToolCall
    var workingDirectory: String?

    /// One viewport for every block a call returns, including multi-file edits.
    /// Short results keep their natural height; long results scroll inside the row.
    private static let maximumHeight: CGFloat = 360

    var body: some View {
        let edits = call.edits.filter { !$0.path.isEmpty }
        // Completed file-edit tools show their rendered patch; failed edits and
        // commands keep their output too, so errors and command results stay readable.
        let showsOutput = call.kind != .edit || edits.isEmpty || call.status != .completed
        PopoverScroll(maxHeight: Self.maximumHeight, minHeight: 1) {
            VStack(alignment: .leading, spacing: TimelineMetrics.rowSpacing) {
                if showsOutput, let imagePath = PreviewImages.resolveToolImagePath(for: call, workingDirectory: workingDirectory) {
                    ToolImagePreview(path: imagePath)
                }
                if showsOutput, let detail = call.detail, !detail.isEmpty {
                    // Keep arguments selectable and framed like output, in one quiet color.
                    Text(verbatim: detail)
                        .font(.code(.caption))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineSpacing(MarkdownParagraphLayout.lineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 10, style: .continuous))
                }
                ForEach(Array(edits.enumerated()), id: \.offset) { _, edit in
                    ToolEditDiffView(edit: edit, reference: previewReference(for: edit))
                }
                if showsOutput, !call.output.isEmpty {
                    if call.kind == .read, let ext = readOutputExtension {
                        ToolCodeBlockView(source: call.output.trimmingCharacters(in: .newlines), pathExtension: ext)
                    } else {
                        Text(verbatim: call.output.trimmingCharacters(in: .newlines))
                            .font(.code(.caption))
                            .foregroundStyle(Chrome.secondaryText)
                            .lineSpacing(MarkdownParagraphLayout.lineSpacing)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(.top)
        .clipped()
    }

    private func previewReference(for edit: FileEdit) -> FilePreviewReference {
        if let reference = call.fileReference {
            if edit.path == reference.path || edit.path == call.title { return reference }
            if let workingDirectory,
               URL(fileURLWithPath: workingDirectory).appendingPathComponent(edit.path).standardizedFileURL.path == reference.path {
                return reference
            }
        }
        return FilePreviewReference(path: edit.path)
    }

    /// Use the same filename/extension recognition as source previews and fences.
    private var readOutputExtension: String? {
        let path = call.fileReferences?.first?.path ?? call.fileReference?.path ?? call.title
        return PreviewSyntaxHighlighter.languageExtension(forFilePath: path)
    }
}

/// An expanded row's monospaced read output in the preview reader's syntax colors.
/// Call arguments and system notices use plain text in their own blocks.
/// Highlighting runs off the main actor; until the colored string arrives the
/// block shows the same plain text it always did, and a source that outgrew its
/// colors (a streaming update) falls back to plain text for that update.
struct ToolCodeBlockView: View {
    let source: String
    let pathExtension: String
    @State private var result: Highlighted?

    private struct Request: Hashable {
        let source: String
        let pathExtension: String
        let theme: CodeHighlightTheme
    }

    private struct Highlighted {
        let request: Request
        let spans: [PreviewSyntaxHighlighter.Span]
        let text: AttributedString
    }

    var body: some View {
        let theme = CodeHighlighting.shared.theme
        let request = Request(source: source, pathExtension: pathExtension, theme: theme)
        // Keep one selectable Text identity while its foreground attributes change.
        Text(result.flatMap { $0.request == request ? $0.text : nil } ?? AttributedString(source))
        .font(.code(.caption))
        .foregroundStyle(Color(nsColor: CodeSyntaxStyle.foregroundColor(theme: theme)))
        .lineSpacing(MarkdownParagraphLayout.lineSpacing)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 10, style: .continuous))
        .task(id: request) {
            let spans: [PreviewSyntaxHighlighter.Span]
            if let result, result.request.source == request.source, result.request.pathExtension == request.pathExtension {
                spans = result.spans
            } else {
                let highlight = Task.detached(priority: .utility) {
                    PreviewSyntaxHighlighter.spans(in: request.source, extension: request.pathExtension)
                }
                spans = await withTaskCancellationHandler(operation: { await highlight.value }, onCancel: { highlight.cancel() })
            }
            guard !Task.isCancelled else { return }
            result = Highlighted(request: request, spans: spans,
                text: CodeSyntaxStyle.attributedString(source: request.source, spans: spans, theme: request.theme))
        }
    }

}

/// A single call's file change. Never reads the turn's aggregate diff: two edits
/// to the same path keep their own patches even after later tools rewrite the file.
private struct ToolEditDiffView: View {
    let edit: FileEdit
    let reference: FilePreviewReference

    var body: some View {
        let file = edit.diff.flatMap { diff in
            diff.isEmpty ? nil : DiffDetailCache.file(diff: diff, path: edit.path)
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: edit.path)
                    .font(.chat(.caption))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(edit.path)
                Spacer(minLength: 8)
                if edit.additions + edit.deletions > 0 {
                    DiffStatLabel(additions: edit.additions, deletions: edit.deletions)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .modifier(ToolFilePreviewMenu(references: [reference]))

            if let file, file.isDeferred {
                DeferredDiffLinesView(file: file, showsLineNumbers: false, collapsesLongDiff: false)
                    .id("\(file.id)|\(file.revision)")
            } else if let file, !file.hunks.isEmpty {
                DiffLinesView(file: file, showsLineNumbers: false, collapsesLongDiff: false)
                    .equatable()
            } else if let diff = edit.diff, !diff.isEmpty, file?.isBinary != true {
                // Preserve a provider's patch even if a newer format is not yet
                // understood by the structured renderer.
                Text(verbatim: diff)
                    .font(.code(size: 11.5))
                    .foregroundStyle(Chrome.secondaryText)
                    .lineSpacing(MarkdownParagraphLayout.lineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                // Count-only and binary changes still identify the file and explain
                // why no patch is available, without substituting the turn's diff.
                Text(verbatim: Chrome.localized(file?.isBinary == true ? "Binary file" : "Diff details unavailable"))
                    .font(.chat(.caption))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 10, style: .continuous))
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
    }
}

/// Parsed per-file diffs for expanded tool rows. Parsing runs once per distinct diff,
/// so opening and closing a row is instant no matter how large the patch is.
private enum DiffDetailCache {
    @MainActor private static var cache = RecentCache<String, DiffFile>(limit: 60)

    @MainActor
    static func file(diff: String, path: String) -> DiffFile {
        let key = path + "\n" + diff
        if let hit = cache.value(for: key) { return hit }
        let parsed = DiffParser.parseHunks(diff, path: path)
        cache.insert(parsed, for: key)
        return parsed
    }
}

enum ToolPresentation {
    /// The row's text run: verb plus subject. Agents that title a call with the
    /// tool's own name ("Edit file", "Write file") would read "Edited Edit file" or
    /// "Editing Write file" — a leading word that only restates the kind goes, so it
    /// reads "Edited file".
    static func label(for call: ToolCall) -> String {
        // Some native edit modes pass only a patch, leaving the title as "edit".
        // Use the call's own result paths for both edits and writes, including
        // saved calls, without changing command titles that also have file edits.
        var seen: Set<String> = []
        let paths = call.kind == .edit ? call.edits.compactMap { edit -> String? in
            guard !edit.path.isEmpty, seen.insert(edit.path).inserted else { return nil }
            return edit.path
        } : []
        let title = paths.isEmpty ? call.title : paths.joined(separator: Chrome.localized(", "))
        if call.toolName != nil || !paths.isEmpty {
            return [verb(for: call), title].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let roots: [String] = switch call.kind {
        case .command: ["run", "bash", "shell", "exec", "execute", "command"]
        case .read: ["read", "view", "open", "cat"]
        case .edit: ["edit", "write", "multiedit", "create", "notebookedit", "apply_patch", "patch"]
        case .search: ["search", "grep", "glob", "find"]
        case .web: ["fetch", "webfetch", "websearch", "browse"]
        case .mcp: ["call"]
        case .agent: ["delegate", "agent", "task"]
        case .other: ["use"]
        }
        var subject = title
        let words = title.split(separator: " ", maxSplits: 1)
        if let first = words.first?.lowercased(), roots.contains(first) {
            subject = words.count > 1 ? String(words[1]) : ""
        }
        return [verb(for: call), subject].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func verb(for call: ToolCall) -> String {
        let running = call.status == .running
        return switch call.kind {
        case .command: Chrome.localized(running ? "Running" : "Ran")
        case .read: Chrome.localized(running ? "Reading" : "Read")
        case .edit: Chrome.localized(call.ompTool == .write
            ? (running ? "Writing" : "Wrote")
            : (running ? "Editing" : "Edited"))
        case .search: Chrome.localized(running ? "Searching" : "Searched")
        case .web: Chrome.localized(running ? "Browsing" : "Browsed")
        case .mcp: Chrome.localized(running ? "Calling" : "Called")
        case .agent: Chrome.localized(running ? "Delegating" : "Delegated")
        case .other: Chrome.localized(running ? "Using" : "Used")
        }
    }

    static func symbol(for call: ToolCall) -> SFSymbolResource {
        OMPToolSymbols.symbol(for: call)
    }

    static func symbol(for kind: ToolCall.Kind) -> SFSymbolResource {
        OMPToolSymbols.symbol(for: kind)
    }

    static func stats(for call: ToolCall) -> (additions: Int, deletions: Int)? {
        guard !call.edits.isEmpty else { return nil }
        let additions = call.edits.reduce(0) { $0 + $1.additions }
        let deletions = call.edits.reduce(0) { $0 + $1.deletions }
        return additions + deletions > 0 ? (additions, deletions) : nil
    }

    static func mcpParts(_ call: ToolCall) -> (entry: MCPCatalogEntry, tool: String)? {
        // Native MCP names follow OMP's mcp__ namespace. Never guess a catalog
        // server from their path, pattern or other user-controlled title text.
        guard call.toolName == nil else { return nil }
        guard call.kind == .mcp else { return nil }
        guard let range = call.title.range(of: " · ") else { return nil }
        let server = String(call.title[..<range.lowerBound]).trimmed
        let tool = String(call.title[range.upperBound...]).trimmed
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        guard let entry = MCPCatalog.entry(matching: server) else { return nil }
        return (entry, tool)
    }

    static func mcpLabel(entry: MCPCatalogEntry, tool: String, running: Bool) -> String {
        "\(entry.name): \(tool)"
    }
}

struct PlanCard: View {
    let entry: TimelineEntry
    let runtime: ThreadRuntime

    @State private var isShowingPlan = false

    var body: some View {
        if case .plan(let plan) = entry.item.content {
            ChatBadge(
                title: Self.title(for: plan.state),
                caption: Self.caption(for: plan.state),
                showsChevron: !plan.markdown.isEmpty,
                needsAttention: Self.needsAttention(for: plan.state),
                isEnabled: !plan.markdown.isEmpty,
                isPresented: $isShowingPlan,
                glyph: {
                    if plan.state == .drafting {
                        WorkingSpinner(cellSize: 3).frame(width: 14)
                    } else {
                        TimelineRowIcon.plan.foregroundStyle(.tint)
                    }
                },
                detail: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Plan").font(.chat(.headline))
                            Spacer()
                            CopyButton(text: plan.markdown)
                        }
                        PopoverScroll(maxHeight: 420) {
                            MarkdownView(text: plan.markdown, isStreaming: plan.state == .drafting).equatable()
                                .padding(.horizontal, 16)
                        }
                        if plan.state == .proposed {
                            // The controls stay where they are while the thread is busy, greyed
                            // rather than gone: a plan whose buttons vanish mid-turn reads as a
                            // plan that has already been dealt with.
                            let isBusy = runtime.pendingPlanApproval != nil || runtime.isRunning
                            HStack(spacing: 8) {
                                Button("Implement plan") {
                                    isShowingPlan = false
                                    runtime.implementPlan(entry.id)
                                }
                                .buttonStyle(.glassProminent)
                                Button("Dismiss") {
                                    isShowingPlan = false
                                    runtime.dismissPlan(entry.id)
                                }
                                .buttonStyle(.glass)
                            }
                            .disabled(isBusy)
                            .help(Text(verbatim: isBusy ? Chrome.localized("Wait for the current turn to finish") : ""))
                        }
                    }
                    .padding(16)
                    .frame(width: 520)
                }
            )
        }
    }

    private static func title(for state: ProposedPlan.State) -> String {
        switch state {
        case .drafting: Chrome.localized("Writing a plan")
        case .proposed: Chrome.localized("Plan ready")
        case .accepted, .dismissed: Chrome.localized("Plan")
        }
    }

    private static func caption(for state: ProposedPlan.State) -> String? {
        switch state {
        case .drafting: nil
        case .proposed: Chrome.localized("Implement or dismiss")
        case .accepted: Chrome.localized("Approved")
        case .dismissed: Chrome.localized("Dismissed")
        }
    }

    private static func needsAttention(for state: ProposedPlan.State) -> Bool {
        state == .proposed
    }
}

struct NoticeRow: View {
    let entry: TimelineEntry
    @Environment(\.revealTimelineEnd) private var revealBox
    @Environment(\.timelineBlockID) private var blockID
    @State private var fallbackExpanded = false

    private var isExpanded: Bool {
        get { revealBox?.presentation.notices[entry.id] ?? fallbackExpanded }
        nonmutating set {
            if let revealBox { revealBox.presentation.notices[entry.id] = newValue }
            else { fallbackExpanded = newValue }
        }
    }

    var body: some View {
        if case .notice(let notice) = entry.item.content, !notice.isRuntimeSetupNoise {
            if notice.isSystemNotice {
                systemNotice(notice)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TimelineRowIcon(noticeLevel: notice.level)
                        .foregroundStyle(Self.color(for: notice.level))
                        .alignmentGuide(.firstTextBaseline) { dimensions in
                            let font = NSFont.systemFont(ofSize: TypeScale.shared.content(TypeScale.stockPointSize(.callout)))
                            return dimensions[VerticalAlignment.center] + font.capHeight / 2
                        }
                    Text(verbatim: notice.message)
                        .lineSpacing(MarkdownParagraphLayout.lineSpacing)
                        .textSelection(.enabled)
                        .foregroundStyle(notice.level == .info ? .secondary : .primary)
                    if notice.occurrenceCount > 1 {
                        Spacer(minLength: 0)
                        occurrenceCount(notice)
                    }
                }
                .font(.chat(.callout))
                .padding(.leading, notice.level == .info ? 0 : TimelineMetrics.pillLeading)
                .padding(.trailing, notice.level == .info ? 0 : TimelineMetrics.pillTrailing)
                .padding(.vertical, notice.level == .info ? 0 : TimelineMetrics.pillVertical)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Self.background(for: notice.level), in: .rect(cornerRadius: TimelineMetrics.pillRadius, style: .continuous))
            }
        }
    }

    /// The same compact disclosure rhythm and bounded detail viewport as tool rows.
    /// The raw runtime payload is only materialized after the reader opens it.
    private func systemNotice(_ notice: Notice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                revealBox?.disclosure(blockID)
                isExpanded.toggle()
            } label: {
                HStack(spacing: TimelineMetrics.iconSpacing) {
                    TimelineRowIcon(noticeLevel: notice.level)
                    Text("System notice")
                    if notice.occurrenceCount > 1 { occurrenceCount(notice) }
                    Image(systemName: "chevron.right").font(.system(size: TypeScale.shared.content(TypeScale.stockPointSize(.caption2)), weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(.chat(.callout))
                .foregroundStyle(Self.color(for: notice.level))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: Chrome.localized(isExpanded ? "Hide system notice" : "Show system notice")))
            .accessibilityValue(Text(verbatim: Chrome.localized(isExpanded ? "Expanded" : "Collapsed")))
            if isExpanded {
                PopoverScroll(maxHeight: 360, minHeight: 1) {
                    Text(verbatim: notice.message)
                        .font(.code(.caption))
                        .lineSpacing(MarkdownParagraphLayout.lineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 10, style: .continuous))
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.top)
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func occurrenceCount(_ notice: Notice) -> some View {
        Text(verbatim: String(format: Chrome.localized("×%lld"), Int64(notice.occurrenceCount)))
            .monospacedDigit()
            .foregroundStyle(Self.color(for: notice.level))
            .fixedSize()
            .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("%lld occurrences"), Int64(notice.occurrenceCount))))
    }

    /// The theme's own status colours, like every other warning and failure in the app,
    /// rather than the system orange and red.
    private static func color(for level: Notice.Level) -> Color {
        switch level {
        case .info: .secondary
        case .warning: Chrome.warning
        case .error: Chrome.danger
        }
    }

    private static func background(for level: Notice.Level) -> Color {
        switch level {
        case .info: .clear
        case .warning: Chrome.warning.opacity(0.1)
        case .error: Chrome.danger.opacity(0.1)
        }
    }
}

struct TurnEndRow: View {
    let summary: TurnSummary
    /// Whether the turn produced a reply. Set by the timeline; when true the duration
    /// lives on the reply's hover line instead.
    let hasReply: Bool

    var body: some View {
        if !hasReply {
            Text(Self.label(for: summary))
                .font(.chat(.caption))
                .foregroundStyle(Chrome.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func label(for summary: TurnSummary) -> String {
        if summary.durationIsKnown == false {
            return Chrome.localized(summary.status == .failed ? "Failed" : summary.status == .interrupted ? "Stopped" : "Finished")
        }
        let duration = RelativeTime.duration(summary.duration)
        return switch summary.status {
        case .completed, .running: String(format: Chrome.localized("Worked for %@"), duration)
        case .interrupted: String(format: Chrome.localized("Stopped after %@"), duration)
        case .failed: String(format: Chrome.localized("Failed after %@"), duration)
        }
    }
}

/// The quiet round control on a finished turn's line (revert, changes): a flat overlay
/// disc with a secondary glyph that comes up to full under the pointer. Solid accent
/// discs here shouted from every turn of every chat.
private struct MutedRoundGlyph: View {
    let symbol: String
    @State private var isHovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(Chrome.iconFont)
            .foregroundStyle(isHovering ? Chrome.primaryText : Chrome.secondaryText)
            .frame(width: 28, height: 28)
            .background(Chrome.overlay(isHovering ? 0.18 : 0.1), in: .circle)
            .contentShape(.circle)
            .onHover { hovering in
                withAnimation(Chrome.hover) { isHovering = hovering }
            }
    }
}

/// The completed turn keeps its final reply and file changes outside one process disclosure.
/// Expanded process rows use exactly the running turn's chronological projection.
struct FinishedTurnContent {
    var prompt: TimelineEntry?
    var final: TimelineEntry?
    var process: [TimelineEntry]

    @MainActor
    init(entries: [TimelineEntry], finalAssistantID: String?) {
        let prompt = entries.first?.kind == .user ? entries.first : nil
        let final = entries.first {
            $0.id == finalAssistantID && $0.kind == .assistant && !$0.item.hasNothingToRead
        }
        self.prompt = prompt
        self.final = final
        process = entries.filter { $0 !== final && $0 !== prompt }
    }
}

struct TurnFinishedBlock: View {
    @Environment(\.workspaceReviewAction) private var reviewAction
    let runtime: ThreadRuntime
    let turnID: UUID
    let summary: TurnSummary
    let entries: [TimelineEntry]
    let finalAssistantID: String?
    let workingDirectory: String?
    let canUndo: Bool
    var waiting = TurnWaiting()

    @Environment(\.timelineBlockID) private var blockID
    @Environment(\.revealTimelineEnd) private var revealBox
    @State private var fallbackExpanded = false
    @State private var refreshedChanges: FileChangeSummary?

    private var isExpanded: Bool {
        get { revealBox?.presentation.finished[turnID] ?? fallbackExpanded }
        nonmutating set {
            if let revealBox { revealBox.presentation.finished[turnID] = newValue }
            else { fallbackExpanded = newValue }
        }
    }

    var body: some View {
        let projected = FinishedTurnContent(entries: entries, finalAssistantID: finalAssistantID)
        let changes = summary.fileAttributionVersion == TurnSummary.currentFileAttributionVersion
            ? summary.changes : refreshedChanges ?? summary.changes
        let canExpand = !projected.process.isEmpty || !waiting.backgroundTasks.isEmpty
        VStack(alignment: .leading, spacing: TimelineMetrics.rowSpacing) {
            if let entry = projected.prompt {
                UserMessageRow(entry: entry, runtime: runtime, canRevert: canUndo)
            }
            VStack(alignment: .leading, spacing: TimelineMetrics.rowSpacing / 4) {
                Button {
                    guard canExpand else { return }
                    revealBox?.disclosure(blockID)
                    withAnimation(.snappy(duration: 0.24)) { isExpanded.toggle() }
                } label: {
                    ActivityHeaderLabel(title: TurnEndRow.label(for: summary), isOpen: isExpanded, canExpand: canExpand, showsOMPLogo: true)
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: canExpand ? Chrome.localized(isExpanded ? "Hide this turn's steps" : "Show this turn's steps") : ""))

                Divider().opacity(0.6)
            }

            if isExpanded, canExpand {
                TurnRunningBlock(
                    runtime: runtime, entries: projected.process, showsWorking: false,
                    context: RowContext(workingDirectory: workingDirectory, canRewind: canUndo),
                    waiting: TurnWaiting(heads: [], backgroundTasks: waiting.backgroundTasks)
                )
            }
            if !waiting.heads.isEmpty {
                HydraHeadsWorkingRow(heads: waiting.heads, runtime: runtime)
            }
            if let final = projected.final, case .assistant(let message) = final.item.content {
                FoldedAnswerView(text: message.text, runtime: runtime)
            }
            if let changes, !changes.files.isEmpty {
                let reviewRuntime = runtime
                TurnFileCard(
                    changes: changes, canUndo: canUndo,
                    onRevert: { Task {
                        do { _ = try await runtime.revert(to: turnID, restoreFiles: true) }
                        catch { runtime.reportNativeError(error) }
                    } },
                    onReview: { [weak reviewRuntime] button in
                        guard let reviewRuntime else { return }
                        if !reviewAction(threadID: reviewRuntime.threadID, turnID: turnID) {
                            reviewRuntime.showDiff(on: button, turn: turnID)
                        }
                    }
                )
            }
        }
        .task(id: turnID) {
            let changes = await runtime.refreshTurnChanges(turnID: turnID)
            if !Task.isCancelled { refreshedChanges = changes }
        }
    }
}

private struct TurnFileCard: View {
    /// The turn's files, header totals included: one list, so the count in the title and
    /// the rows behind it can never disagree.
    let changes: FileChangeSummary
    let canUndo: Bool
    /// Runs the revert; the card confirms first.
    let onRevert: () -> Void
    /// Receives the Review button's own view, for the popover to open on.
    let onReview: (NSView) -> Void
    /// The Review button's own view, captured once the pointer has been on it: a folded
    /// turn is a block of the lazy stack, and the anchor is only ever for a click, which
    /// has to hover the button first.
    @State private var reviewAnchor = WeakView()
    @State private var needsReviewAnchor = false
    @State private var isShowingFiles = false
    @State private var isConfirmingRevert = false

    var body: some View {
        // The anchor box alone: the hover responder and the anchor view must not keep
        // this card alive after it scrolls away.
        let reviewBox = reviewAnchor
        let files = changes.files
        let title = files.count == 1 ? Chrome.localized("Edited 1 file") : String(format: Chrome.localized("Edited %d files"), files.count)
        HStack(spacing: 8) {
            Button { isShowingFiles.toggle() } label: {
                HStack(spacing: 8) {
                    Text(verbatim: title)
                        .font(.chat(.callout, weight: .medium))
                        .foregroundStyle(Chrome.primaryText.opacity(0.9))
                    DiffStatLabel(additions: changes.additions, deletions: changes.deletions)
                    if !files.isEmpty {
                        Image(systemName: "chevron.right").font(.system(size: TypeScale.shared.content(TypeScale.stockPointSize(.caption2)), weight: .semibold))
                            .foregroundStyle(Chrome.secondaryText)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(files.isEmpty)
            .help("Show the files this turn changed")
            .chromePopover(isPresented: $isShowingFiles, arrowEdge: .bottom) {
                filesPopover.presentedChrome()
            }
            // A fixed gap, not a spacer: the card hugs its title and stats, and the round
            // buttons follow it rather than sitting at the far side of the column.
            Color.clear.frame(width: 20, height: 1)
            if canUndo {
                Button { isConfirmingRevert = true } label: {
                    MutedRoundGlyph(symbol: "arrow.uturn.backward")
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Branch before this turn and restore its files")
                .chromePopover(isPresented: $isConfirmingRevert, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Branch before this turn?")
                            .font(.chat(size: 14, weight: .semibold))
                        Text("OMP preserves the original conversation. Eligible files are restored separately to their state before this turn.")
                            .font(.chat(.callout))
                            .foregroundStyle(Chrome.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Spacer()
                            Button("Cancel") { isConfirmingRevert = false }
                                .buttonStyle(.glass)
                            Button("Branch and restore files") { isConfirmingRevert = false; onRevert() }
                                .buttonStyle(.glassProminent)
                                .keyboardShortcut(.defaultAction)
                        }
                        .controlSize(.small)
                    }
                    .padding(16)
                    .frame(width: 300)
                    .presentedChrome()
                }
            }
            Button { [weak reviewBox] in
                guard let view = reviewBox?.value else { return }
                onReview(view)
            } label: {
                MutedRoundGlyph(symbol: "plusminus")
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { [needed = $needsReviewAnchor] hovering in
                if hovering, !needed.wrappedValue { needed.wrappedValue = true }
            }
            .background {
                if needsReviewAnchor {
                    AttachmentAnchorCapture { [weak reviewBox] in reviewBox?.value = $0 }
                }
            }
            .help("Show this turn's changes")
        }
        .padding(.leading, TimelineMetrics.pillLeading)
        // The round buttons sit in the card with the same clearance on every side.
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: TimelineMetrics.pillRadius, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    private var filesPopover: some View {
        let files = changes.files
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(files.prefix(12), id: \.path) { file in
                HStack(spacing: 8) {
                    Text(verbatim: file.path)
                        .font(.chat(.callout))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if file.isBinary {
                        Text("Binary")
                            .font(.chat(.caption))
                            .foregroundStyle(Chrome.secondaryText)
                    } else {
                        DiffStatLabel(additions: file.additions, deletions: file.deletions)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            if files.count > 12 {
                Text(verbatim: files.count == 13 ? Chrome.localized("and 1 more file") : String(format: Chrome.localized("and %d more files"), files.count - 12))
                    .font(.chat(.callout))
                    .foregroundStyle(Chrome.secondaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
        }
    }
}
