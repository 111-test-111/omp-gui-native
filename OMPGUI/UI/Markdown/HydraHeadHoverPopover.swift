import AppKit
import SwiftUI

@MainActor
final class HydraHeadHoverPopover: NSObject, NSPopoverDelegate {
    static let shared = HydraHeadHoverPopover()

    private let popover = NSPopover()
    private var shownID: UUID?
    private var pending: Task<Void, Never>?

    private override init() {
        super.init()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
    }

    func show(persona: HydraPersona, target: HydraMentionTarget, relativeTo rect: NSRect, of view: NSView) {
        if popover.isShown, shownID == target.threadID { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            if self.popover.isShown { self.popover.close() }
            // Measured with the card's own width pinned, and never laid out narrower
            // than it: asked for its intrinsic size the hosting view can answer below
            // the card's fixed frame, and the popover then wraps the task a couple of
            // words a line in a card that had the room for it.
            let width = HydraHeadHoverCard.width
            let content = HydraHeadHoverCard(persona: persona, target: target)
                .font(.ui(.body))
            var size = NSHostingView(rootView: content.frame(width: width)).intrinsicContentSize
            if size.width < width { size.width = width }
            if size.height <= 0 { size.height = 78 }
            self.popover.setFixedContent(content, size: size)
            self.shownID = target.threadID
            self.popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        }
    }

    func hide() {
        pending?.cancel()
        pending = nil
        if popover.isShown { popover.performClose(nil) }
        shownID = nil
    }

    func popoverDidClose(_ notification: Notification) {
        shownID = nil
    }
}

private struct HydraHeadHoverCard: View {
    /// The card's width, and the popover's: a narrower frame breaks a task title
    /// after two words with the card's own width left unused.
    static let width: CGFloat = 300

    let persona: HydraPersona
    let target: HydraMentionTarget

    var body: some View {
        HStack(spacing: 10) {
            HydraGlyph(persona: persona, size: 28, isRunning: target.status == .running, status: target.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: persona.name)
                    .font(.ui(.body, weight: .semibold))
                    .foregroundStyle(persona.color)
                Text(verbatim: target.task)
                    .font(.ui(.callout))
                    .foregroundStyle(Chrome.primaryText)
                    .lineLimit(3)
                Text(verbatim: Chrome.localized(statusLine))
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
    }

    private var statusLine: String {
        switch target.status {
        case .running: "Working…"
        case .completed: "Done · click to open the chat"
        case .failed: "Failed · click to open the chat"
        case .stopped: "Stopped · click to open the chat"
        }
    }
}
