import AppKit

/// Compatible editions coexist; older exclusive-only editions still exclude them.
@MainActor
enum LibraryAccess {
    private static var lease: SharedLibraryLease?

    static func prepare() {
        guard !CaptureRun.isEnabled else { return }
        for identifier in ["iordv.droppycode", "iordv.droppycode.dev", "iordv.cody"] {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
                stop(Chrome.localized("Quit the older app before opening Tivano or Tivano Dev. Both editions use your real library; the older app cannot participate in its writer lock."))
            }
        }
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            lease = try SharedLibraryLease(at: support.appendingPathComponent(".tivano-library.lock"), mode: .shared)
            let migration = try SharedLibraryLease(at: support.appendingPathComponent(".tivano-migration.lock"), wait: true)
            try withExtendedLifetime(migration) { try LegacyMigration.run() }
        } catch {
            stop(String(format: Chrome.localized("The shared library could not be opened. A running older Tivano build may still require exclusive access; update both editions before running them together. Otherwise check permissions and available disk space.\n\n%@"), error.localizedDescription))
        }
    }

    private static func stop(_ message: String) -> Never {
        let alert = NSAlert()
        alert.messageText = Chrome.localized("Shared Tivano library")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: Chrome.localized("Close"))
        alert.runModal()
        exit(1)
    }
}
