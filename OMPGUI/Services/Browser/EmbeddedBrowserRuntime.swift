import AppKit
import CCefAppKit
import CefKit
import Darwin
import Foundation

/// Process-wide CEF, initialized only when the first web page is requested.
/// It has no OMP executor: native OMP Browser remains the sole automation tool.
@MainActor
final class EmbeddedBrowserRuntime {
    static let shared = EmbeddedBrowserRuntime()
    private(set) var endpoint: URL?
    private var parkingWindow: NSWindow?
    private var profile: CefProfile?
    private var hasShutDown = false

    func start() throws {
        guard !hasShutDown else { throw WorkspaceBrowserError.unavailable }
        if endpoint != nil { return }
        let port = try Self.reservePort()
        var config = CefConfiguration()
        config.locale = BrowserLocalization.chromiumLocale
        let root = StoragePaths.directory("browser")
        config.rootCachePath = root.appendingPathComponent("profiles", isDirectory: true)
        config.cachePath = config.rootCachePath?.appendingPathComponent("Default", isDirectory: true)
        config.logFile = root.appendingPathComponent("chromium.log")
        config.remoteDebuggingPort = port
        config.extraCommandLineSwitches = ["remote-debugging-address": "127.0.0.1"]
        config.defaultRuntimeStyle = .alloy
        config.noSandbox = false
        config.persistSessionCookies = true
        config.useCDPJavaScriptDialogs = true
        // Automatic uses Keychain for signed packages and the upstream mock
        // storage only for unsigned local development. No external profile directories.
        config.safeStorage = .automatic
        try CefRuntime.shared.initialize(configuration: config)
        // AppDelegate saves/drains OMP first, then closes pages on a later
        // run-loop turn. CEF must not bypass that application's quit contract.
        CEFApplication.setTerminateHandler(nil)
        endpoint = URL(string: "http://127.0.0.1:\(port)")
    }

    func browsingProfile() -> CefProfile {
        if let profile { return profile }
        let profile = CefProfile.persistent(name: BrowserProfileConfiguration.activeProfile.storageName)
        self.profile = profile
        return profile
    }

    func park(_ view: NSView) {
        if parkingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isExcludedFromWindowsMenu = true
            parkingWindow = window // Never ordered on screen or made key.
        }
        guard let parent = parkingWindow?.contentView, view.superview !== parent else { return }
        view.removeFromSuperview()
        parent.addSubview(view)
        if view.frame.width < 100 || view.frame.height < 100 { view.frame = parent.bounds }
        view.isHidden = true
    }

    func identifyPage(initialURL: URL) async throws -> String {
        guard let endpoint else { throw WorkspaceBrowserError.unavailable }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 1
        config.timeoutIntervalForResource = 1
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for _ in 0..<12 {
            try Task.checkCancellation()
            if let (data, _) = try? await session.data(from: endpoint.appendingPathComponent("json/list")),
               data.count < 1_048_576,
               let pages = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let page = pages.first(where: { $0["type"] as? String == "page" && $0["url"] as? String == initialURL.absoluteString }),
               let id = page["id"] as? String, !id.isEmpty {
                return id
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WorkspaceBrowserError.connection
    }

    func shutdown() {
        guard endpoint != nil else { return }
        // Call only after on_before_close completed and all request contexts
        // have been released. CEF cannot be reinitialized in this process.
        parkingWindow?.close(); parkingWindow = nil
        profile = nil
        CefRuntime.shared.shutdown()
        endpoint = nil
        hasShutDown = true
    }

    private static func reservePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw WorkspaceBrowserError.connection }
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &size) }
        }
        guard bound == 0, read == 0 else { throw WorkspaceBrowserError.connection }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
