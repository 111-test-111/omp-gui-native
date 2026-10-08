import AppKit
import SwiftTerm

/// A shell running in a pseudo terminal, kept alive while its thread is open.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    let threadID: UUID
    let directory: String
    var title: String
    private(set) var isRunning = true

    @ObservationIgnored let view: LocalProcessTerminalView
    @ObservationIgnored private var bridge: TerminalBridge?

    init(threadID: UUID, directory: String, title: String, command: String?) {
        self.threadID = threadID
        self.directory = directory
        self.title = title
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        view.font = TerminalFont.preferred()
        view.optionAsMetaKey = true
        let bridge = TerminalBridge(session: self)
        self.bridge = bridge
        view.processDelegate = bridge

        let shell = LoginEnvironment.userShell()
        var environment = LoginEnvironment.current
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Droppy Code"
        environment["DROPPY_CODE_PROJECT_ROOT"] = directory
        let pairs = environment.map { "\($0.key)=\($0.value)" }
        let shellName = "-" + (shell as NSString).lastPathComponent
        var arguments: [String] = []
        if let command {
            arguments = ["-l", "-i", "-c", "\(command); exec \(shell) -l"]
        }
        view.startProcess(executable: shell, args: arguments, environment: pairs, execName: shellName, currentDirectory: directory)
    }

    /// The appearance last applied: setting the colours again clears SwiftTerm's attribute
    /// caches and redraws the whole screen, so the host applies them only on a change.
    private var appliedDark: Bool?

    func applyAppearance(isDark: Bool) {
        guard appliedDark != isDark else { return }
        appliedDark = isDark
        view.nativeBackgroundColor = isDark ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.985, alpha: 1)
        view.nativeForegroundColor = isDark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.12, alpha: 1)
        // The caret and the selection follow the theme's accent, like every other
        // insertion point in the app.
        let accent = Chrome.accentNSColor
        view.caretColor = accent
        view.selectedTextBackgroundColor = accent.withAlphaComponent(0.3)
    }

    func terminate() {
        guard isRunning else { return }
        view.terminate()
        isRunning = false
    }

    /// Whether the shell owns the foreground of its terminal: true at the prompt, false while
    /// a job it started (vim, claude, less) has the terminal. Read from the kernel's view of
    /// the shell, since the pty's master side answers no `tcgetpgrp` to a process it is not
    /// the controlling terminal of.
    nonisolated static func foregroundJobIsTheShell(_ shell: pid_t) -> Bool {
        guard shell > 0 else { return false }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, shell]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_eproc.e_tpgid == info.kp_eproc.e_pgid
    }

    fileprivate func processEnded() {
        isRunning = false
    }
}

/// Receives SwiftTerm callbacks, which arrive on the main thread.
private final class TerminalBridge: NSObject, LocalProcessTerminalViewDelegate {
    weak var session: TerminalSession?

    init(session: TerminalSession) {
        self.session = session
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        let session = self.session
        Task { @MainActor in session?.processEnded() }
    }
}

@MainActor
@Observable
final class TerminalStore {
    private(set) var sessions: [UUID: [TerminalSession]] = [:]
    var selection: [UUID: UUID] = [:]

    func sessions(for threadID: UUID) -> [TerminalSession] {
        sessions[threadID] ?? []
    }

    func selected(for threadID: UUID) -> TerminalSession? {
        let list = sessions(for: threadID)
        return list.first { $0.id == selection[threadID] } ?? list.last
    }

    @discardableResult
    func open(threadID: UUID, directory: String, title: String? = nil, command: String? = nil) -> TerminalSession {
        let number = sessions(for: threadID).count + 1
        let session = TerminalSession(threadID: threadID, directory: directory, title: title ?? String(format: Chrome.localized("Terminal %lld"), number), command: command)
        sessions[threadID, default: []].append(session)
        selection[threadID] = session.id
        return session
    }

    func run(_ script: ProjectScript, threadID: UUID, directory: String) {
        open(threadID: threadID, directory: directory, title: script.name, command: script.command)
    }

    func ensureTerminal(threadID: UUID, directory: String) {
        if sessions(for: threadID).isEmpty {
            open(threadID: threadID, directory: directory)
        }
    }

    /// Replaces an exited shell with a fresh one in the same place in the row, keeping the
    /// tab's name and its directory, so a shell that quit is one click from working again.
    @discardableResult
    func restart(_ session: TerminalSession) -> TerminalSession {
        session.terminate()
        let fresh = TerminalSession(
            threadID: session.threadID,
            directory: session.directory,
            title: session.title,
            command: nil
        )
        if let index = sessions[session.threadID]?.firstIndex(where: { $0.id == session.id }) {
            sessions[session.threadID]?[index] = fresh
        } else {
            sessions[session.threadID, default: []].append(fresh)
        }
        selection[session.threadID] = fresh.id
        return fresh
    }

    func close(_ session: TerminalSession) {
        session.terminate()
        sessions[session.threadID]?.removeAll { $0.id == session.id }
        if selection[session.threadID] == session.id {
            selection[session.threadID] = sessions[session.threadID]?.last?.id
        }
    }

    func closeAll(for threadID: UUID) {
        for session in sessions(for: threadID) { session.terminate() }
        sessions[threadID] = nil
        selection[threadID] = nil
    }

    func terminateAll() {
        for list in sessions.values {
            for session in list { session.terminate() }
        }
    }
}
