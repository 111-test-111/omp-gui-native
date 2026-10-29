import AppKit
import SwiftUI
import SwiftTerm
@testable import OMPGUI

@main
private enum TerminalChecks {
    @MainActor private static var checks = 0

    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private static func layout(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        // The real workspace has nested independent hosting views. An unshown
        // window has no display pass to drive a newly revealed child host.
        for child in descendants(host).compactMap({ $0 as? FrameHostingView }) {
            child.layoutSubtreeIfNeeded()
        }
    }

    @MainActor private static func eventually(_ message: String, diagnostics: () -> String = { "" }, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now >= deadline {
                FileHandle.standardError.write(Data((message + ": " + diagnostics() + "\n").utf8))
                preconditionFailure(message)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor static func main() async throws {
        guard let output = CaptureRun.storageRoot else { fatalError("Require isolated capture storage") }
        _ = NSApplication.shared // Only an unshown window; no shell or application launch.
        let workspace = output.appendingPathComponent("terminal-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var createdSessions = 0
        let terminals = TerminalStore { threadID, directory, title, command in
            createdSessions += 1
            return TerminalSession(threadID: threadID, directory: directory, title: title, command: command,
                                   startsProcess: false, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        }
        let model = AppModel(terminals: terminals)
        model.settings.performanceMode = true
        let project = model.addProject(at: workspace)
        let thread = model.newThread(in: project, workspace: .local)!
        let runtime = model.runtime(for: thread.id)
        let previews = FilePreviewStore(persistenceURL: output.appendingPathComponent("terminal-previews.json"))
        runtime.isTerminalVisible = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 720),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        let resize = WindowLiveResize(window: window)
        let host = FrameHostingView(rootView: AnyView(
            WorkspaceDetailView(previews: previews)
                .modifier(HostedEnvironment(model: model, liveResize: resize, previews: previews))
        ))
        window.contentView = host
        defer {
            previews.suspend()
            window.contentView = nil
            window.close()
            terminals.terminateAll()
        }

        try await eventually("The existing bottom terminal must mount its native view") {
            layout(host)
            return terminals.selected(for: thread.id)?.view.window === window
        }
        let first = terminals.selected(for: thread.id)!
        let native = first.view
        let bottomHost = native.superview!
        native.feed(text: "Retained output before moving\r\n\u{1b}[41mANSI background\u{1b}[0m\r\n")
        expect(createdSessions == 1 && first.directory == workspace.path, "The bottom shell starts once in its execution directory")

        // Opening the sidebar directly starts its independent group. It must
        // neither select the bottom button nor take the bottom renderer away.
        runtime.isTerminalVisible = false
        previews.openPanel(.terminal)
        try await eventually("The sidebar must create and mount its independent terminal") {
            layout(host)
            return terminals.selected(for: thread.id, in: .sidebar)?.view.window === window
                && native.superview == nil
        }
        let sideFirst = terminals.selected(for: thread.id, in: .sidebar)!
        expect(sideFirst !== first && sideFirst.view !== native && createdSessions == 2,
               "Direct sidebar opening must not reuse the bottom session or renderer")
        expect(!runtime.isTerminalVisible && terminals.selected(for: thread.id) === first,
               "A sidebar-only terminal must leave the page's bottom toggle unselected")
        expect(terminals.hasSessions(for: thread.id), "Either terminal location must keep its runtime alive")

        runtime.isTerminalVisible = true
        try await eventually("Opening the bottom panel while the sidebar is active must mount both renderers") {
            layout(host)
            return native.window === window && sideFirst.view.window === window
                && native.superview !== sideFirst.view.superview
        }
        expect(terminals.selected(for: thread.id) === first && createdSessions == 2,
               "The page's terminal toggle must reopen its own bottom shell")
        let second = terminals.open(threadID: thread.id, directory: workspace.path, title: "Sidebar second", in: .sidebar)
        second.view.feed(text: "Retained sidebar output\r\n")
        try await eventually("A new sidebar selection must not replace the bottom terminal") {
            layout(host)
            return second.view.window === window && native.window === window && sideFirst.view.superview == nil
        }
        expect(terminals.selected(for: thread.id) === first && terminals.selected(for: thread.id, in: .sidebar) === second,
               "The two terminal groups must retain independent selections")
        terminals.select(sideFirst)
        try await eventually("Selecting another sidebar tab must only switch that group") {
            layout(host)
            return sideFirst.view.window === window && second.view.superview == nil && native.window === window
        }
        terminals.select(second)
        try await eventually("The selected sidebar renderer must return") {
            layout(host)
            return second.view.window === window
        }
        previews.setVisible(false)
        try await eventually("Hiding the sidebar must leave the bottom terminal mounted") {
            layout(host)
            return second.view.superview == nil && native.window === window
        }
        previews.openPanel(.terminal)
        try await eventually("Reopening the sidebar must retain its own selected session") {
            layout(host)
            return second.view.window === window && native.window === window
        }
        expect(createdSessions == 3, "Visibility changes must not start replacement shells")

        let sidebarHost = second.view.superview!
        expect(model.moveTerminal(for: thread.id, from: .sidebar, sidebar: previews.terminalAction),
               "The sidebar's move action must be handled by its own window")
        try await eventually("Moving to the bottom must close the sidebar tab and reparent its selected renderer") {
            layout(host)
            return runtime.isTerminalVisible && previews.session?.panels.contains(.terminal) == false
                && second.view.window === window && second.view.superview !== sidebarHost
                && native.superview == nil
        }
        expect(terminals.sessions(for: thread.id, in: .sidebar).isEmpty
               && terminals.sessions(for: thread.id).map(\.id) == [first.id, sideFirst.id, second.id],
               "An explicit move must transfer all source tabs and preserve existing destination sessions")
        expect(terminals.selected(for: thread.id) === second && createdSessions == 3,
               "A move must preserve source selection without restarting a shell")
        expect(String(decoding: second.view.getTerminal().getBufferAsData(), as: UTF8.self).contains("Retained sidebar output"),
               "An explicit move must retain the terminal buffer")
        expect((sidebarHost as? TerminalHostContainer)?.hostedView == nil,
               "The source host must release resize ownership after a move")
        try await Task.sleep(for: .milliseconds(80))
        layout(host)
        expect(second.view.window === window, "Late teardown of the source must not detach the destination renderer")

        // A fresh direct sidebar open remains independent after a migration.
        previews.openPanel(.terminal)
        try await eventually("A direct sidebar reopen must create its own fresh terminal group") {
            layout(host)
            return terminals.selected(for: thread.id, in: .sidebar)?.view.window === window
                && second.view.window === window
        }
        let sideFresh = terminals.selected(for: thread.id, in: .sidebar)!
        expect(sideFresh !== second && createdSessions == 4, "Direct opening must not implicitly move the bottom group")
        runtime.isTerminalVisible = false
        try await eventually("Hiding the bottom panel must not hide the sidebar terminal") {
            layout(host)
            return second.view.superview == nil && sideFresh.view.window === window
        }
        runtime.isTerminalVisible = true
        try await eventually("The bottom group must reopen without affecting the sidebar selection") {
            layout(host)
            return second.view.window === window && sideFresh.view.window === window
        }
        expect(model.moveTerminal(for: thread.id, from: .bottom, sidebar: previews.terminalAction),
               "The bottom's move action must open its sidebar tab")
        try await eventually("Moving to the sidebar must close the bottom panel and preserve its selected renderer") {
            layout(host)
            return !runtime.isTerminalVisible && previews.activeSidebarTab == .panel(.terminal)
                && second.view.window === window && sideFresh.view.superview == nil
        }
        expect(terminals.sessions(for: thread.id).isEmpty
               && terminals.sessions(for: thread.id, in: .sidebar).map(\.id) == [sideFresh.id, first.id, sideFirst.id, second.id],
               "Moving back must retain all sessions already present in the destination")
        expect(terminals.selected(for: thread.id, in: .sidebar) === second && createdSessions == 4,
               "Both migration directions must preserve selection and session identity")
        expect(String(decoding: native.getTerminal().getBufferAsData(), as: UTF8.self).contains("Retained output before moving"),
               "The original bottom output must survive a complete round trip")
        expect((bottomHost as? TerminalHostContainer)?.hostedView == nil, "An inactive old host must not retain the terminal")
        expect(!model.moveTerminal(for: UUID(), from: .sidebar, sidebar: previews.terminalAction)
               && !model.moveTerminal(for: thread.id, from: .sidebar, sidebar: WorkspaceTerminalAction()),
               "Missing or unrelated window routes must reject migration without moving shells")
        expect(!runtime.isTerminalVisible && terminals.selected(for: thread.id, in: .sidebar) === second,
               "Rejected migrations must preserve panel visibility and selection")

        // Exercise the real renderer's color API; no layer alpha is applied to text.
        first.applyAppearance(isDark: true, theme: .dracula)
        let darkText = native.nativeForegroundColor.usingColorSpace(.deviceRGB)!
        let purpleCaret = native.caretColor
        expect(native.backgroundOpacity == 0 && native.nativeBackgroundColor.alphaComponent == 0,
               "The terminal default background must expose the shared window backdrop")
        expect(darkText.alphaComponent == 1 && native.alphaValue == 1,
               "Background transparency must not fade terminal text or the native view: text=\(darkText.alphaComponent), view=\(native.alphaValue)")
        first.applyAppearance(isDark: true, theme: .nord)
        expect(native.caretColor != purpleCaret, "Changing themes in the same appearance must update terminal accents")
        first.applyAppearance(isDark: false, theme: .light)
        let lightText = native.nativeForegroundColor.usingColorSpace(.deviceRGB)!
        expect(lightText.alphaComponent == 1 && lightText.redComponent < darkText.redComponent,
               "The terminal foreground must adapt to light and dark appearances")
        expect(native.backgroundOpacity == 0, "Appearance changes must preserve the clear default background")
        expect(String(decoding: native.getTerminal().getBufferAsData(), as: UTF8.self).contains("ANSI background"),
               "Theme updates must preserve existing terminal content")
        let restarted = terminals.restart(sideFirst)
        expect(restarted.location == .sidebar && terminals.sessions(for: thread.id).isEmpty
               && terminals.sessions(for: thread.id, in: .sidebar).contains { $0 === restarted },
               "Restart must replace a shell in its current location after migration")
        terminals.close(restarted)
        expect(!terminals.sessions(for: thread.id, in: .sidebar).contains { $0 === restarted },
               "Close must remove only the requested terminal from its current group")
        let bottomExtra = terminals.open(threadID: thread.id, directory: workspace.path)
        let otherID = UUID()
        let other = terminals.open(threadID: otherID, directory: workspace.path, in: .sidebar)
        terminals.closeAll(for: thread.id)
        expect(!terminals.hasSessions(for: thread.id) && terminals.selected(for: thread.id) == nil
               && terminals.selected(for: thread.id, in: .sidebar) == nil,
               "Deleting a conversation must clear sessions and selections at both locations")
        expect(terminals.selected(for: otherID, in: .sidebar) === other && !terminals.sessions(for: thread.id).contains { $0 === bottomExtra },
               "Conversation cleanup must preserve other chats' terminal sessions")
        expect(!window.isVisible, "Terminal checks must never display their window")
        print("Terminal checks passed: \(checks)")
    }
}
