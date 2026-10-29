import AppKit
import SwiftUI

/// A local lock for a vertical SwiftUI scroll view, including trackpad elasticity.
struct VerticalScrollLock: NSViewRepresentable {
    func makeNSView(context: Context) -> VerticalScrollLockProbe { VerticalScrollLockProbe() }
    func updateNSView(_ view: VerticalScrollLockProbe, context: Context) { view.attach() }
    static func dismantleNSView(_ view: VerticalScrollLockProbe, coordinator: ()) { view.detach() }
}

@MainActor
final class VerticalScrollLockProbe: NSView {
    private weak var scroll: NSScrollView?
    private var elasticity: NSScrollView.Elasticity = .automatic
    private var hadScroller = false
    private var postedBounds = false
    private var isClamping = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }

    func attach() {
        var ancestor = superview
        for _ in 0..<32 {
            guard let view = ancestor else { break }
            if let candidate = view as? NSScrollView {
                if candidate === scroll { clamp(); return }
                detach()
                scroll = candidate
                elasticity = candidate.horizontalScrollElasticity
                hadScroller = candidate.hasHorizontalScroller
                postedBounds = candidate.contentView.postsBoundsChangedNotifications
                candidate.horizontalScrollElasticity = .none
                candidate.hasHorizontalScroller = false
                candidate.contentView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                    name: NSView.boundsDidChangeNotification, object: candidate.contentView)
                clamp()
                return
            }
            ancestor = view.superview
        }
        if window == nil { detach() }
    }

    func detach() {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: scroll?.contentView)
        if let scroll {
            scroll.horizontalScrollElasticity = elasticity
            scroll.hasHorizontalScroller = hadScroller
            scroll.contentView.postsBoundsChangedNotifications = postedBounds
        }
        scroll = nil
    }

    @objc private func boundsChanged(_ notification: Notification) { clamp() }
    private func clamp() {
        guard !isClamping, let clip = scroll?.contentView else { return }
        // AppKit/SwiftUI can post another bounds notification before setBoundsOrigin
        // finishes. Never enter a second correction on that notification's stack.
        isClamping = true
        defer { isClamping = false }
        var proposed = clip.bounds
        proposed.origin.x = 0
        // A short document or a resizing popover can have a native centered origin
        // below zero. Respect that constraint instead of repeatedly fighting it.
        let x = clip.constrainBoundsRect(proposed).origin.x
        guard abs(clip.bounds.origin.x - x) > 0.01 else { return }
        clip.setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
    }
}
