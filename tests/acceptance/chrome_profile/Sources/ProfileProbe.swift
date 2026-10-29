import AppKit
import CCefAppKit
import CefSwiftUI

/// Manual, isolated compatibility probe using the app's pinned CEF wrapper.
/// It never receives or opens a personal Chrome profile.
@main private enum ProfileProbe {
    @MainActor static func main() {
        CEFApplication.install()
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("PROFILE_PROBE_ERROR: \(error)"); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: env["PROFILE_PROBE_ROOT"]!, isDirectory: true)
        let output = URL(fileURLWithPath: env["PROFILE_PROBE_OUTPUT"]!, isDirectory: true)
        guard root.path.contains("/build.noindex/chrome-profile/"),
              output.path.contains("/build.noindex/chrome-profile/") else { fatalError("Isolated fixture roots required") }
        var config = CefConfiguration()
        config.rootCachePath = root
        config.cachePath = root.appendingPathComponent("Default", isDirectory: true)
        config.logFile = output.appendingPathComponent("chromium.log")
        config.remoteDebuggingPort = Int(env["PROFILE_PROBE_PORT"]!)!
        config.extraCommandLineSwitches = ["remote-debugging-address": "127.0.0.1"]
        config.defaultRuntimeStyle = .alloy
        config.persistSessionCookies = true
        config.safeStorage = .mockKeychain // Matches the GUI's unsigned Debug policy.
        config.noSandbox = false
        try CefRuntime.shared.initialize(configuration: config)
        CEFApplication.setTerminateHandler(nil)
        var options = CefBrowserOptions()
        options.runtimeStyle = .alloy
        if env["PROFILE_PROBE_NAMED"] == "1" { options.profile = .persistent(name: "migration") }
        let model = CefWebViewModel(url: URL(string: env["PROFILE_PROBE_URL"]!)!, options: options)
        var ready = false
        model.onBrowserCreated = { _ in ready = true }
        let host = CefBrowserHostView(model: model)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(60)
        while !ready, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        guard ready else { throw NSError(domain: "CEF page creation timed out", code: 1) }
        try Data("ready".utf8).write(to: output.appendingPathComponent("ready"))
        while !FileManager.default.fileExists(atPath: output.appendingPathComponent("finish").path),
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard FileManager.default.fileExists(atPath: output.appendingPathComponent("finish").path) else {
            throw NSError(domain: "Probe controller timed out", code: 1)
        }
        let browser = model.browser
        browser?.close(force: true)
        host.tearDown()
        window.contentView = nil
        model.options.profile = nil
        let closeDeadline = ContinuousClock.now + .seconds(5)
        while browser?.isClosed == false, ContinuousClock.now < closeDeadline { try await Task.sleep(for: .milliseconds(25)) }
        guard browser?.isClosed != false else { throw NSError(domain: "CEF close timed out", code: 1) }
        await Task.yield()
        CefRuntime.shared.shutdown()
        window.close()
        try Data("closed".utf8).write(to: output.appendingPathComponent("closed"))
    }
}
