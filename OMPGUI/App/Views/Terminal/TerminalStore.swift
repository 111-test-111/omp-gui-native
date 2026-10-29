import AppKit
import Observation
import SwiftTerm

enum TerminalLocation: CaseIterable, Hashable {
    case bottom, sidebar
}

/// Keep terminal web links on the same window's application URL route.
final class AppTerminalView: LocalProcessTerminalView {
    var onOpenURL: ((URL) -> Void)?

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), url.isHTTPWebLink, let onOpenURL {
            onOpenURL(url)
        } else {
            super.requestOpenLink(source: source, link: link, params: params)
        }
    }
}

/// A shell running in a pseudo terminal, kept alive while its thread is open.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    let threadID: UUID
    let directory: String
    var title: String
    fileprivate(set) var location: TerminalLocation = .bottom
    private(set) var isRunning = true

    @ObservationIgnored let view: AppTerminalView
    @ObservationIgnored let viewPlacement = TerminalViewPlacement()
    @ObservationIgnored private var bridge: TerminalBridge?
    @ObservationIgnored private let originalPreferredFont: NSFont
    @ObservationIgnored private var appliedFontRevision: Int?

    init(threadID: UUID, directory: String, title: String, command: String?, startsProcess: Bool = true, font: NSFont? = nil) {
        self.threadID = threadID
        self.directory = directory
        self.title = title
        view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        originalPreferredFont = font ?? TerminalFont.preferred()
        applyFont()
        view.optionAsMetaKey = true
        let bridge = TerminalBridge(session: self)
        self.bridge = bridge
        view.processDelegate = bridge

        guard startsProcess else { isRunning = false; return }
        let shell = LoginEnvironment.userShell()
        var environment = LoginEnvironment.current
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "OMP GUI"
        environment["TIVANO_PROJECT_ROOT"] = directory
        let pairs = environment.map { "\($0.key)=\($0.value)" }
        let shellName = "-" + (shell as NSString).lastPathComponent
        var arguments: [String] = []
        if let command {
            arguments = ["-l", "-i", "-c", "\(command); exec \(shell) -l"]
        }
        view.startProcess(executable: shell, args: arguments, environment: pairs, execName: shellName, currentDirectory: directory)
    }

    func applyFont() {
        let revision = AppFont.revision
        guard appliedFontRevision != revision else { return }
        appliedFontRevision = withObservationTracking {
            AppFont.revision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.applyFont() }
        }
        let font = AppFont.customMonospaced(size: originalPreferredFont.pointSize)
            ?? originalPreferredFont
        view.font = font
    }

    /// The appearance last applied: setting the colours again clears SwiftTerm's attribute
    /// caches and redraws the whole screen, so the host applies them only on a change.
    private var appliedColors: [NSColor] = []

    func applyAppearance(isDark: Bool, theme: AppTheme = .system) {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)!
        var background = NSColor.clear
        var foreground = NSColor.labelColor
        var accent = NSColor.controlAccentColor
        appearance.performAsCurrentDrawingAppearance {
            background = (NSColor(theme.spec.surface).usingColorSpace(.deviceRGB) ?? .textBackgroundColor).withAlphaComponent(0)
            foreground = (NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor).withAlphaComponent(1)
            accent = (theme.spec.accent.map(NSColor.init) ?? .controlAccentColor).usingColorSpace(.deviceRGB) ?? .controlAccentColor
        }
        let colors = [background, foreground, accent]
        guard appliedColors != colors else { return }
        appliedColors = colors
        // The window already owns backdrop/tint/opacity and solid fallbacks.
        // Only SwiftTerm's default background is clear; ANSI cell backgrounds,
        // text and the caret keep their own colors and opacity.
        view.nativeBackgroundColor = background
        view.backgroundOpacity = 0
        view.nativeForegroundColor = foreground
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
    private struct Key: Hashable {
        let threadID: UUID
        let location: TerminalLocation
    }
    private var sessions: [Key: [TerminalSession]] = [:]
    private var selection: [Key: UUID] = [:]
    typealias Factory = @MainActor (UUID, String, String, String?) -> TerminalSession
    @ObservationIgnored private let makeSession: Factory

    init(makeSession: @escaping Factory = { TerminalSession(threadID: $0, directory: $1, title: $2, command: $3) }) {
        self.makeSession = makeSession
    }

    func sessions(for threadID: UUID, in location: TerminalLocation = .bottom) -> [TerminalSession] {
        sessions[Key(threadID: threadID, location: location)] ?? []
    }

    func hasSessions(for threadID: UUID) -> Bool {
        TerminalLocation.allCases.contains { !sessions(for: threadID, in: $0).isEmpty }
    }

    func selected(for threadID: UUID, in location: TerminalLocation = .bottom) -> TerminalSession? {
        let list = sessions(for: threadID, in: location)
        return list.first { $0.id == selection[Key(threadID: threadID, location: location)] } ?? list.last
    }

    func select(_ session: TerminalSession) {
        let key = Key(threadID: session.threadID, location: session.location)
        guard sessions[key]?.contains(where: { $0 === session }) == true else { return }
        selection[key] = session.id
    }

    @discardableResult
    func open(threadID: UUID, directory: String, title: String? = nil, command: String? = nil,
              in location: TerminalLocation = .bottom) -> TerminalSession {
        let key = Key(threadID: threadID, location: location)
        let number = sessions(for: threadID, in: location).count + 1
        let session = makeSession(threadID, directory, title ?? String(format: Chrome.localized("Terminal %lld"), number), command)
        session.location = location
        sessions[key, default: []].append(session)
        selection[key] = session.id
        return session
    }

    func run(_ script: ProjectScript, threadID: UUID, directory: String) {
        open(threadID: threadID, directory: directory, title: script.name, command: script.command)
    }

    func ensureTerminal(threadID: UUID, directory: String, in location: TerminalLocation = .bottom) {
        if sessions(for: threadID, in: location).isEmpty {
            open(threadID: threadID, directory: directory, in: location)
        }
    }

    /// Explicit moves preserve every shell and the source selection. Independent
    /// destination sessions remain in place, followed by the transferred tabs.
    func moveSessions(for threadID: UUID, from source: TerminalLocation, to destination: TerminalLocation) {
        guard source != destination else { return }
        let sourceKey = Key(threadID: threadID, location: source)
        let destinationKey = Key(threadID: threadID, location: destination)
        let selectedID = selected(for: threadID, in: source)?.id
        guard let moving = sessions.removeValue(forKey: sourceKey), !moving.isEmpty else { return }
        selection[sourceKey] = nil
        for session in moving { session.location = destination }
        sessions[destinationKey, default: []].append(contentsOf: moving)
        selection[destinationKey] = selectedID
    }

    /// Replaces an exited shell with a fresh one in the same place in the row, keeping the
    /// tab's name and its directory, so a shell that quit is one click from working again.
    @discardableResult
    func restart(_ session: TerminalSession) -> TerminalSession {
        session.terminate()
        let key = Key(threadID: session.threadID, location: session.location)
        let fresh = makeSession(session.threadID, session.directory, session.title, nil)
        fresh.location = session.location
        if let index = sessions[key]?.firstIndex(where: { $0.id == session.id }) {
            sessions[key]?[index] = fresh
        } else {
            sessions[key, default: []].append(fresh)
        }
        selection[key] = fresh.id
        return fresh
    }

    func close(_ session: TerminalSession) {
        session.terminate()
        let key = Key(threadID: session.threadID, location: session.location)
        sessions[key]?.removeAll { $0.id == session.id }
        if selection[key] == session.id {
            selection[key] = sessions[key]?.last?.id
        }
    }

    func closeAll(for threadID: UUID) {
        for location in TerminalLocation.allCases {
            let key = Key(threadID: threadID, location: location)
            for session in sessions[key] ?? [] { session.terminate() }
            sessions[key] = nil
            selection[key] = nil
        }
    }

    func terminateAll() {
        for list in sessions.values {
            for session in list { session.terminate() }
        }
    }
}
