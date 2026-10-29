import SwiftUI

struct AppCommands: Commands {
    let model: AppModel
    private let shortcuts = ShortcutStore.shared

    private var runtime: ThreadRuntime? {
        model.selectedThreadID.map(model.runtime(for:))
    }

    private var chatIsCovered: Bool { SettingsNavigation.shared.isPresented }

    private var filePreviews: FilePreviewStore? { WindowManager.shared.filePreviews }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { WindowManager.shared.showSettings() }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .openSettings))
        }

        // File's stock Close sits before the Thread menu and would take ⌘W from Archive thread…,
        // closing the main window instead. Secondary windows close on ⌘W themselves (SecondaryWindow).
        CommandGroup(replacing: .saveItem) {}

        CommandGroup(before: .windowArrangement) {
            Button(AppInfo.name) { WindowManager.shared.showMain() }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .showMainWindow))
            Divider()
        }

        CommandGroup(replacing: .newItem) {
            Group {
                Button("New thread") { model.newThread() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .newThread))
                Button("New thread in worktree") { model.newThread(workspace: .worktree) }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .newWorktreeThread))
                Divider()
                Button("Add project…") { model.chooseProjectFolder() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .addProject))
                Button("Clone from GitHub…") { GitHubClonePanel.shared.present(model: model) }
                Divider()
                Button("Open file in preview…") { WindowManager.shared.openFilesInPreview() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .openFilePreview))
                    .disabled(filePreviews?.context == nil)
            }.disabled(chatIsCovered)
        }

        CommandGroup(after: .sidebar) {
            Group {
                Button("Toggle sidebar") { model.sidebar.toggle() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .toggleSidebar))
                Button("Command palette") { model.isCommandPalettePresented.toggle() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .commandPalette))
                Button("Toggle terminal") { WindowManager.shared.toggleTerminal() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .toggleTerminal))
                    .disabled(model.selectedThreadID == nil)
                Button("Toggle changes") { runtime?.toggleDiff() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .toggleChanges))
                    .disabled(model.selectedThreadID == nil)
                Button("Toggle workspace sidebar") { WindowManager.shared.toggleFilePreview() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .toggleFilePreview))
                    .disabled(filePreviews?.context == nil)
                Button("Previous sidebar tab") { WindowManager.shared.selectPreviewTab(offset: -1) }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .previousPreviewTab))
                    .disabled(filePreviews?.isVisible != true || filePreviews?.sidebarTabs.isEmpty != false)
                Button("Next sidebar tab") { WindowManager.shared.selectPreviewTab(offset: 1) }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .nextPreviewTab))
                    .disabled(filePreviews?.isVisible != true || filePreviews?.sidebarTabs.isEmpty != false)
                Button("Toggle activity view") {
                    withAnimation(Chrome.panelSlide) { model.settings.sidebarActivityView.toggle() }
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .toggleActivityView))
            }.disabled(chatIsCovered)
            Divider()
            Button("Increase Font Size") { model.settings.stepFontSizes(by: 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Decrease Font Size") { model.settings.stepFontSizes(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Default Font Size") { model.settings.resetFontSizes() }
                .keyboardShortcut("0", modifiers: .command)
            // US keyboards produce '=' for Command-plus without Shift.
            Button("Increase Font Size") { model.settings.stepFontSizes(by: 1) }
                .keyboardShortcut("=", modifiers: .command)
                .hidden()
        }

        CommandMenu("Thread") {
            Group {
                Button("Stop") { runtime?.interrupt() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .stopTurn))
                    .disabled(!(runtime?.isRunning ?? false))
                // Off while the thread is waiting on an approval: the approval popover's Allow
                // button ships with the same ⌘Return, and a menu command always wins over a
                // button's shortcut, so the queue would swallow the chord the popover asks for.
                // On with nothing to queue behind: the draft then just goes out (see
                // `queueDraftAsFollowUp`), rather than the chord doing nothing at all.
                Button("Queue a chat") { runtime?.queueDraftAsFollowUp() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .queueChat))
                    .disabled((runtime?.draftIsEmpty ?? true)
                        || (runtime?.isDictating ?? false)
                        || !(runtime?.approvals.isEmpty ?? true))
                Divider()
                Button("Previous thread") { model.selectThread(offset: -1) }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .previousThread))
                Button("Next thread") { model.selectThread(offset: 1) }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .nextThread))
                Button(model.topScript.map { String(format: Chrome.localized("Run %@"), $0.name) } ?? Chrome.localized("Run top script")) {
                    guard let script = model.topScript, let threadID = model.selectedThreadID else { return }
                    model.runScript(script, threadID: threadID)
                }
                .keyboardShortcut(shortcuts.keyboardShortcut(for: .runScript))
                .disabled(model.topScript == nil)
                ForEach(1...9, id: \.self) { number in
                    Button("Thread \(number)") { model.selectThread(number: number) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                }
                Divider()
                Button(Chrome.localized(model.finishActionTitle)) { model.finishSelectedThread() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .finishThread))
                    .disabled(model.selectedThreadID == nil)
                Button("Archive thread…") { model.askToArchiveSelectedThread() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .archiveThread))
                    .disabled(model.selectedThreadID == nil)
                Button(Chrome.localized(model.selectedThread?.isSettled == true ? "Reopen thread" : "Settle thread")) { model.settleSelectedThread() }
                    .keyboardShortcut(shortcuts.keyboardShortcut(for: .settleThread))
                    .disabled(model.selectedThread.map { $0.isHelper } ?? true)
            }.disabled(chatIsCovered)
        }
    }
}
