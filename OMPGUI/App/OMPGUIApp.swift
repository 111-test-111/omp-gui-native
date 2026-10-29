import SwiftUI
import CCefAppKit

@main
enum OMPGUIMain {
    @MainActor static func main() {
        DCInstallNotificationGuard()
        // Install the CEF-compatible application before SwiftUI touches NSApp;
        // loading Chromium itself remains lazy until a browser tab is opened.
        CEFApplication.install()
        OMPGUIApp.main()
    }
}

struct OMPGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Before anything posts a notification: a framework observer that raises while one is posted
        // (the popover window ordering on macOS 27) then costs a log line, not the app.
        DCInstallNotificationGuard()
        // Provider processes can exit while we write to them; report EPIPE instead of crashing.
        signal(SIGPIPE, SIG_IGN)
        // Before anything reads settings or the library.
        #if DEBUG
        if OMPNativeControlsAcceptanceRun.enabled { OMPNativeControlsAcceptanceRun.prepare() }
        else if OMPCapabilityAcceptanceRun.enabled { OMPCapabilityAcceptanceRun.prepare() }
        else if OMPWorkflowAcceptanceRun.enabled { OMPWorkflowAcceptanceRun.prepare() }
        else if OMPPerformanceRun.enabled { OMPPerformanceRun.prepare() }
        else { WebsiteCaptures.prepare() }
        #endif
        LibraryAccess.prepare()
        // A frozen main thread gets its stacks written to this edition's log directory.
        HangWatchdog.start()
        SwitchLatency.start()
    }

    var body: some Scene {
        // The windows themselves are AppKit windows owned by WindowManager. This scene only carries the menus.
        Settings { EmptyView() }
            .commands { AppCommands(model: WindowManager.shared.model) }
    }
}
