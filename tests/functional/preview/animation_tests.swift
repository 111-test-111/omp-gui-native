import AppKit
import SwiftUI

// Only the app's window-notification state is stubbed. The native split, clip,
// spring, hosting view and bounded closing snapshot are production code.
@MainActor final class WindowLiveResize {
    var isActive = false
    var isPaneResizing = false
    var isPreviewResizing = false
    var isPreviewSliding = false
    var previewSlideDelta: CGFloat = 0
}

private struct PreviewAnimationFailure: Error, CustomStringConvertible {
    var description: String
}

@MainActor enum PreviewAnimationChecks {
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw PreviewAnimationFailure(description: message) }
    }
    private static func settled(_ split: PreviewSplitView) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while split.isSliding {
            try expect(ContinuousClock.now < deadline, "The native sidebar transition did not finish")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func run() async throws {
        let curve = PreviewSidebarSlide(from: 0, to: 481, velocity: 0, started: 10, reducedMotion: false)
        try expect(curve.sample(at: 10).span == 0 && curve.sample(at: 10.1).span > 0,
                   "The sidebar spring does not begin from its presentation width")
        try expect(curve.sample(at: 11).span == 481 && curve.sample(at: 11).finished,
                   "The sidebar spring did not settle exactly at its target")
        let reduced = PreviewSidebarSlide(from: 481, to: 0, velocity: 0, started: 10, reducedMotion: true)
        try expect(reduced.duration < curve.duration && reduced.sample(at: 10.05).span < 481,
                   "Reduced motion did not use the shorter non-spring transition")

        let split = PreviewSplitView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 700))
        split.isVertical = true
        split.dividerStyle = .thin
        let resizing = WindowLiveResize()
        split.liveResize = resizing
        let chat = FrameHostingView(rootView: AnyView(Color.white))
        let chatClip = SidebarChatClip(chat: chat)
        let reader = FrameHostingView(rootView: AnyView(Color.orange))
        let clip = PreviewSidebarClip(reader: reader)
        try expect(!clip.autoresizesSubviews, "The clip would autoresize its reader on each reveal frame")
        split.addSubview(chatClip)
        split.addSubview(clip)
        split.chat = chat
        split.chatClip = chatClip
        split.reader = reader
        split.previewClip = clip
        split.presentationIdentity = "fixture.swift"
        split.setPreviewVisible(false, animated: false)
        defer { split.hideImmediately() }
        try expect(split.dividerThickness == 0 && chat.frame.width == split.bounds.width && clip.isHidden,
                   "A collapsed sidebar retained its divider or width reservation")

        reader.isHidden = false
        reader.rootView = AnyView(Color.orange)
        split.setPreviewVisible(true, animated: true, reducedMotion: false)
        let width = reader.frame.width
        let openingChatWidth = chat.frame.width
        try await Task.sleep(for: .milliseconds(70))
        try expect(split.isSliding && split.revealedSpan > 0 && split.revealedSpan < width,
                   "Opening skipped the native intermediate reveal frames")
        try expect(reader.frame.width == width && clip.frame.width < width && resizing.isPreviewSliding,
                   "The native reader reflowed instead of being clipped at a fixed width")
        try expect(!resizing.isPreviewResizing && resizing.previewSlideDelta < 0,
                   "The animated slide was mistaken for a saved divider resize")
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(20))
            try expect(chat.frame.width == openingChatWidth && reader.frame.width == width,
                       "Opening reflowed a live chat/composer or file host on an intermediate frame")
            try expect(abs(chat.frame.midX - chatClip.bounds.midX) < 0.5,
                       "The stable chat host lost its viewport-centred position")
        }
        try await settled(split)
        try expect(split.targetVisible && split.dividerThickness > 0 && !resizing.isPreviewSliding,
                   "Opening did not release the timeline's reshape signal")

        // The caller captures the old visual before clearing the live reader.
        reader.layoutSubtreeIfNeeded()
        try expect(clip.freeze() && clip.snapshotBytes > 0 && clip.snapshotBytes <= 2_048 * 2_048 * 4,
                   "The closing viewport snapshot is missing or exceeds its pixel budget")
        guard let still = clip.subviews.compactMap({ $0 as? NSImageView }).first,
              let bitmap = still.image?.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else {
            throw PreviewAnimationFailure(description: "The closing visual did not retain native pixels")
        }
        try expect(color.redComponent > 0.5 && color.greenComponent > 0.1 && color.blueComponent < 0.3 && color.alphaComponent > 0.5,
                   "The closing visual captured a blank viewport instead of its file content")
        reader.rootView = AnyView(Color.clear)
        reader.isHidden = true
        split.setPreviewVisible(false, animated: true, reducedMotion: false)
        let closingChatWidth = chat.frame.width
        try await Task.sleep(for: .milliseconds(65))
        try expect(split.isSliding && clip.hasSnapshot && reader.frame.width == width,
                   "Closing discarded the file visual before its reveal was finished")
        try expect(chat.frame.width == closingChatWidth && closingChatWidth == split.bounds.width,
                   "Closing kept reflowing the chat instead of adopting its destination width once")
        let closingSpan = split.revealedSpan

        // Synchronous intent prevents the old close completion from disposing
        // a newly reopened reader. Retarget from the current visual, not an end.
        split.interruptVisibilityTransition()
        reader.rootView = AnyView(Color.orange)
        reader.isHidden = false
        split.setPreviewVisible(true, animated: true, reducedMotion: false)
        try expect(split.revealedSpan > 0 && abs(split.revealedSpan - closingSpan) < 120,
                   "Rapid reopen jumped to an endpoint instead of continuing its presentation")
        try await settled(split)
        try expect(split.targetVisible && !reader.isHidden && !clip.hasSnapshot && clip.snapshotBytes == 0,
                   "A stale close completion removed the reopened file or retained snapshot pixels")

        // Visibility mutations can coalesce before updateNSView. The stored
        // boolean can match the last presentation after closing cleared its
        // reader; the synchronous intent still requires a remount/retarget.
        split.lastVisible = true
        try expect(clip.freeze(), "The coalesced-close fixture did not capture its file")
        split.visibilityWillChange(false)
        reader.rootView = AnyView(Color.clear)
        reader.isHidden = true
        split.visibilityWillChange(true)
        try expect(split.requiresVisibilityUpdate(true) && split.lastVisible == true,
                   "Coalesced hide/reopen lost the update needed to restore its reader")
        reader.rootView = AnyView(Color.orange)
        reader.isHidden = false
        split.setPreviewVisible(true, animated: true, reducedMotion: false)
        try await settled(split)
        try expect(!split.needsVisibilityUpdate && !split.isSliding && !resizing.isPreviewSliding && !clip.hasSnapshot,
                   "Coalesced reopen retained an interrupted slide or stale closing pixels")

        try expect(clip.freeze(), "The second closing snapshot failed")
        reader.isHidden = true
        split.setPreviewVisible(false, animated: true, reducedMotion: true)
        split.lastVisible = false
        try await Task.sleep(for: .milliseconds(30))
        split.visibilityWillChange(true)
        split.visibilityWillChange(false)
        try expect(split.requiresVisibilityUpdate(false),
                   "Coalesced reopen/hide lost the update needed to complete its close")
        split.setPreviewVisible(false, animated: true, reducedMotion: true)
        try await settled(split)
        try expect(split.revealedSpan == 0 && split.dividerThickness == 0 && clip.isHidden && !clip.hasSnapshot,
                   "Collapse left the vertical divider, ghost file or clipping view behind")
        try expect(chat.frame.width == split.bounds.width && !resizing.isPreviewSliding && resizing.previewSlideDelta == 0,
                   "Collapse left unused chat width or a permanent reshape flag")

        reader.isHidden = false
        split.setPreviewVisible(true, animated: true, reducedMotion: false)
        try await Task.sleep(for: .milliseconds(30))
        split.setFrameSize(NSSize(width: 900, height: 650))
        split.resizeSubviews(withOldSize: NSSize(width: 1_000, height: 700))
        try expect(!split.isSliding && !resizing.isPreviewSliding && clip.snapshotBytes == 0,
                   "Window resizing retained the old transition or snapshot")
        split.hideImmediately()
        try expect(!split.isSliding && split.dividerThickness == 0 && !clip.hasSnapshot,
                   "Window hide did not cancel and release the native transition")

        // Left-sidebar animation changes the outer split width. Its projected
        // endpoint keeps both native content hosts fixed, including narrow panes.
        for previewVisible in [false, true] {
            reader.isHidden = false
            split.setPreviewVisible(previewVisible, animated: false)
            split.conversationSlideTargetWidth = 620
            split.resizeSubviews(withOldSize: split.bounds.size)
            let fixedChat = chat.frame.width, fixedReader = reader.frame.width
            for intermediate: CGFloat in [900, 860, 800, 720, 660, 620] {
                split.setFrameSize(NSSize(width: intermediate, height: 650))
                split.resizeSubviews(withOldSize: split.bounds.size)
                try expect(chat.frame.width == fixedChat && reader.frame.width == fixedReader,
                           "Left-sidebar motion resized a content host between its endpoints")
            }
            split.conversationSlideTargetWidth = nil
            split.resizeSubviews(withOldSize: split.bounds.size)
            try expect(chat.frame.width == fixedChat && chat.frame.origin.x == 0,
                       "Ending left-sidebar motion applied a second layout width")

            split.conversationSlideTargetWidth = 1_000
            split.resizeSubviews(withOldSize: split.bounds.size)
            let reversedWidth = chat.frame.width
            for intermediate: CGFloat in [640, 700, 760] {
                split.setFrameSize(NSSize(width: intermediate, height: 650))
                split.resizeSubviews(withOldSize: split.bounds.size)
                try expect(chat.frame.width == reversedWidth, "Reopening the left sidebar reflowed the live chat")
            }
            split.conversationSlideTargetWidth = 620
            split.resizeSubviews(withOldSize: split.bounds.size)
            for intermediate: CGFloat in [740, 680, 620] {
                split.setFrameSize(NSSize(width: intermediate, height: 650))
                split.resizeSubviews(withOldSize: split.bounds.size)
                try expect(chat.frame.width == fixedChat, "Reversing a left-sidebar slide retained its old target width")
            }
            split.conversationSlideTargetWidth = nil
            split.resizeSubviews(withOldSize: split.bounds.size)
            split.setFrameSize(NSSize(width: 900, height: 650))
            split.resizeSubviews(withOldSize: split.bounds.size)
            try expect(chat.frame.width == chatClip.bounds.width && chat.frame.origin.x == 0,
                       "A subsequent manual resize retained the sidebar's frozen geometry")
        }

        // Fullscreen reuses both native hosts and reserves only the shared
        // toolbar above the selected reader. Returning restores the divider.
        reader.isHidden = false
        split.setPreviewVisible(true, animated: false)
        let splitReaderWidth = reader.frame.width
        split.fullscreenHeaderHeight = 56
        split.setFullscreen(true, showsConversation: false)
        try expect(chatClip.isHidden && !clip.isHidden && split.dividerThickness == 0,
                   "A fullscreen sidebar must hide the chat and remove its divider")
        try expect(reader.frame.width == split.bounds.width && clip.frame.minX == 0
                   && clip.frame.height == split.bounds.height && reader.frame.height == split.bounds.height - 56,
                   "A fullscreen reader did not occupy the entire area below its toolbar")
        split.setFullscreen(true, showsConversation: true)
        try expect(!chatClip.isHidden && clip.isHidden && chat.frame.width == split.bounds.width,
                   "The conversation peer must fill the same fullscreen workspace")
        try expect(split.chat === chat && split.reader === reader && !clip.hasSnapshot,
                   "Switching fullscreen peers replaced native hosts or retained animation pixels")
        split.setFullscreen(false, showsConversation: true)
        try expect(!chatClip.isHidden && !clip.isHidden && reader.frame.width == splitReaderWidth
                   && split.dividerThickness > 0 && clip.frame.height == split.bounds.height,
                   "Leaving fullscreen did not restore the original split geometry")

        // The split and both nested hosting views must allow one surrounding
        // surface to reach the chat, browser and any transparent reader.
        chat.rootView = AnyView(Color.clear)
        reader.rootView = AnyView(Color.clear)
        reader.isHidden = false
        split.setPreviewVisible(true, animated: false)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            split.appearance = NSAppearance(named: appearance)
            split.layoutSubtreeIfNeeded()
            guard let bitmap = split.bitmapImageRepForCachingDisplay(in: split.bounds) else {
                throw PreviewAnimationFailure(description: "The split canvas could not be captured")
            }
            split.cacheDisplay(in: split.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / split.bounds.width
            for frame in [chat.frame, clip.frame] {
                let color = bitmap.colorAt(x: Int(frame.midX * scale), y: Int(frame.midY * scale))
                try expect((color?.alphaComponent ?? 1) < 0.05, "A nested host obscured the shared chat/preview surface")
            }
        }
        try expect(NSApp?.windows.contains(where: \.isVisible) != true, "Sidebar checks presented an application window")
        print("Sidebar animation checks: fixed chat/composer and reader widths during both sidebar motions, narrow panes, reversal, bounded closing pixels, reduced motion, resize/hide cleanup and collapsed divider passed")
    }
}
