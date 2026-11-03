import AppKit
import Foundation
import SwiftUI
@testable import OMPGUI

@main
struct SettingsNavigationChecks {
    @MainActor static var checks = 0
    @MainActor static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        checks += 1
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { fatalError(message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private static func checkPanelShortcuts(_ output: URL) throws {
        guard let defaults = CaptureRun.defaults else { fatalError("Shortcut edits require isolated preferences") }
        let originalPerformanceMode = defaults.object(forKey: "performanceMode")
        let shortcuts = ShortcutStore.shared
        shortcuts.reset(.workspacePanels)
        defer {
            shortcuts.reset(.workspacePanels)
            defaults.set(originalPerformanceMode, forKey: "performanceMode")
        }
        let commands = WorkspacePanel.allCases.map(\.shortcut)
        expect(Set(commands) == Set(AppShortcut.Section.workspacePanels.shortcuts),
               "Every picker card has its own editable command in workspace panel settings")
        let chords = commands.compactMap { shortcuts.chord(for: $0) }
        expect(chords.count == commands.count && Set(chords).count == commands.count,
               "Every panel ships with a distinct shortcut")
        expect(commands.allSatisfy { command in
            !AppShortcut.allCases.contains { $0 != command && $0.defaultChord == command.defaultChord }
        }, "Panel defaults must not take another application command's shortcut")
        let remapped = KeyChord(keyCode: 97, modifiers: [.control, .option])
        shortcuts.set(remapped, for: .openGitPanel)
        expect(ShortcutStore.label(for: .openGitPanel) == remapped.description
            && shortcuts.keyboardShortcut(for: .openGitPanel)?.key == remapped.keyboardShortcut?.key
            && shortcuts.keyboardShortcut(for: .openGitPanel)?.modifiers == remapped.keyboardShortcut?.modifiers,
               "Remapping a panel updates its displayed hint and menu binding together")
        expect(shortcuts.refusal(for: remapped, replacing: .openFilesPanel) != nil,
               "Another panel cannot take a recorded panel shortcut")
        shortcuts.set(nil, for: .openGitPanel)
        expect(ShortcutStore.label(for: .openGitPanel) == nil && shortcuts.keyboardShortcut(for: .openGitPanel) == nil,
               "Clearing a panel shortcut removes both its hint and menu binding")
        shortcuts.reset(.openGitPanel)
        expect(shortcuts.chord(for: .openGitPanel) == AppShortcut.openGitPanel.defaultChord,
               "Reset restores the panel's default shortcut")

        let store = FilePreviewStore(persistenceURL: output.appendingPathComponent("panel-previews.json"))
        for language in ["en", "zh-Hans"] {
            let bundle = BrowserLocalization.localizedBundle(for: language)
            if language == "zh-Hans" {
                for key in commands.flatMap({ [$0.title, $0.detail] }) + [AppShortcut.Section.workspacePanels.title] {
                    expect(Chrome.localized(key, bundle: bundle) != key, "Panel descriptions and shortcut settings need Chinese translations")
                }
            }
            for (mode, performance, scheme) in [("glass", false, ColorScheme.light), ("performance", true, .dark)] {
                defaults.set(performance, forKey: "performanceMode")
                for width: CGFloat in [400, 760] {
                    let picker = WorkspacePanelPicker(store: store)
                        .environment(\.chromeLocalizationBundle, bundle)
                        .preferredColorScheme(scheme)
                        .frame(width: width, height: 960)
                        .background(Color(nsColor: .windowBackgroundColor))
                    let host = NSHostingView(rootView: picker)
                    let size = host.fittingSize
                    expect(size.width == width && size.height == 960, "Panel cards stay inside narrow and wide viewports in \(mode) mode")
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                          styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    defer { window.contentView = nil; window.close() }
                    host.frame = NSRect(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Missing panel picker image") }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(
                        to: output.appendingPathComponent("panel-picker-\(language)-\(Int(width))-\(mode).png"))
                }
            }
        }
    }

    @MainActor private static func checkChromeCookieMessages(_ output: URL) throws {
        let failureKey = "macOS blocked access to Chrome data. Allow OMP GUI in System Settings → Privacy & Security → Full Disk Access, then try again."
        for language in ["en", "zh-Hans"] {
            let bundle = BrowserLocalization.localizedBundle(for: language)
            func render(width: CGFloat) throws -> NSSize {
                let form = ChromeCookieImportForm(
                    introduction: Chrome.localized(ChromeCookieImportForm.introductionKey, bundle: bundle),
                    storageNotice: Chrome.localized(ChromeCookieImportForm.storageNoticeKey, bundle: bundle),
                    profiles: [], selectedID: .constant(nil), loading: false,
                    errorMessage: Chrome.localized(failureKey, bundle: bundle), permissionDenied: true,
                    availableWidth: width, onImport: { _ in }, onCancel: {}
                )
                // Reproduce a single-line inherited environment from the presenter.
                let host = NSHostingView(rootView: form.lineLimit(1).background(Color.white))
                let size = host.fittingSize
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: output.appendingPathComponent("chrome-import-\(language)-\(Int(width)).png"))
                    }
                }
                return size
            }
            let wide = try render(width: 1_200), narrow = try render(width: 360)
            expect(wide.width > 400 && wide.width <= 640, "\(language) import notices stay compact while long errors wrap")
            expect(narrow.width <= 360.5 && narrow.height > wide.height + 30,
                   "\(language) notices expand vertically instead of inheriting single-line truncation on narrow screens")
        }
    }

    @MainActor private static func checkWarmSkills(_ output: URL) async throws {
        let fixture = output.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let executable = fixture.appendingPathComponent("omp")
        let rows: [JSONValue] = (0..<40).map { index in
            ["name": .string("Cached skill \(index)"), "description": "Keep the populated list visible during refresh.",
             "filePath": .string(fixture.appendingPathComponent("\(index)/SKILL.md").path), "source": "native:user"]
        }
        let inventory = String(decoding: JSONValue.object(["skills": .array(rows)]).data(), as: UTF8.self)
        let script = """
        #!/bin/sh
        [ "$1" = skill ] || exit 1
        base="$(dirname "$0")"
        if [ -e "$base/loaded" ]; then
            trap ': > "$base/cancelled"; exit 0' TERM INT
            : > "$base/refreshing"
            while [ ! -e "$base/release" ]; do /bin/sleep 0.05; done
        else
            : > "$base/loaded"
        fi
        printf '%s\\n' '\(inventory)'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        await LoginEnvironment.load()
        let model = AppModel()
        model.settings.setBinaryPath(executable.path, for: .omp)
        let navigation = SettingsNavigation.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = FrameHostingView(rootView: AnyView(SettingsView().environment(model).font(.ui(.body))))
        window.contentView = host
        defer {
            navigation.dismiss()
            window.contentView = nil
            window.close()
        }
        func detailHeight() -> CGFloat {
            host.layoutSubtreeIfNeeded()
            return descendants(host).compactMap { $0 as? NSScrollView }
                .filter { $0.bounds.width > 400 }.first?.documentView?.frame.height ?? 0
        }
        navigation.present(page: .skills)
        try await eventually("The first skill inventory must populate the real settings page") { detailHeight() > 2_000 }
        navigation.page = .appearance
        try await eventually("Leaving skills must display the other page") { detailHeight() < 2_000 }
        navigation.page = .skills
        try await eventually("Reentering skills must start its background refresh") {
            FileManager.default.fileExists(atPath: fixture.appendingPathComponent("refreshing").path)
        }
        expect(detailHeight() > 2_000, "Returning to skills keeps the populated list visible before its next native reply")
        navigation.page = .general
        try await eventually("Leaving a cached page must cancel its pending native read") {
            host.layoutSubtreeIfNeeded()
            return FileManager.default.fileExists(atPath: fixture.appendingPathComponent("cancelled").path)
        }
    }

    @MainActor static func main() async throws {
        guard CaptureRun.storageRoot != nil else { fatalError("Require isolated capture storage") }
        _ = NSApplication.shared
        let navigation = SettingsNavigation.shared
        defer { navigation.dismiss() }
        let manager = WindowManager.shared
        let model = manager.model
        await model.bootstrap()
        let task = model.newThread(affiliation: .standalone)!
        let runtime = model.runtime(for: task.id)
        await runtime.ensureLoaded()
        runtime.draft = ComposerDraft(text: "Keep this draft while changing settings")
        let window = manager.makeCaptureWindow(size: NSSize(width: 900, height: 600), threadControls: true)
        defer { window.contentView = nil; window.close() }
        let count = NSApp.windows.filter { $0 is DCDisplayCycleGuardedWindow }.count
        let root = window.contentView!
        for page in [SettingsPage.general, .usage, .appearance, .browser, .shortcuts, .usage, .general] {
            navigation.present(page: page)
            try await Task.sleep(for: .milliseconds(90))
            root.layoutSubtreeIfNeeded()
            expect(navigation.isPresented && navigation.page == page, "Deep links select their settings page in the main window")
            expect(NSApp.windows.filter { $0 is DCDisplayCycleGuardedWindow }.count == count,
                   "Settings navigation creates no additional application window")
            expect(model.selectedThreadID == task.id && model.existingRuntime(for: task.id) === runtime,
                   "Opening settings keeps the selected runtime mounted")
            expect(runtime.draft.text == "Keep this draft while changing settings", "Settings cannot replace the conversation draft")
            expect(root.bounds.width == 900 && root.bounds.height == 600, "Settings follows the main window's size")
            navigation.dismiss()
        }
        navigation.present(page: .appearance)
        navigation.dismiss()
        navigation.present()
        expect(navigation.page == .appearance, "Reopening settings remembers the selected page")
        let close = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13)!
        expect(window.performKeyEquivalent(with: close) && !navigation.isPresented, "Command-W returns from settings instead of archiving a hidden chat")
        expect(model.thread(task.id)?.isArchived == false && model.thread(task.id)?.isSettled == false,
               "Closing settings preserves the underlying task")
        try await checkWarmSkills(CaptureRun.storageRoot!.deletingLastPathComponent())
        try checkChromeCookieMessages(CaptureRun.storageRoot!.deletingLastPathComponent())
        try checkPanelShortcuts(CaptureRun.storageRoot!.deletingLastPathComponent())
        print("Settings navigation checks passed: \(checks)")
    }
}
