import AppKit
import CefSwiftUI
import SwiftUI

// A standalone acceptance host. It never links or opens the owner's GUI library.
@main
struct PrototypeApp: CefSwiftApp {
    @State private var store = BrowserStore()

    static var cefConfiguration: CefConfiguration {
        var config = CefConfiguration()
        let env = ProcessInfo.processInfo.environment
        config.rootCachePath = URL(fileURLWithPath: env["CEF_PROTOTYPE_RUN"]!).appendingPathComponent("cef-profile")
        config.remoteDebuggingPort = Int(env["CEF_PROTOTYPE_CDP_PORT"]!)!
        config.defaultRuntimeStyle = .alloy
        config.safeStorage = .mockKeychain
        config.useCDPJavaScriptDialogs = true
        // This unsigned local acceptance host loads only its loopback fixture.
        // Distribution signing and Chromium sandbox acceptance are separate work.
        config.noSandbox = true
        return config
    }

    var body: some Scene {
        WindowGroup("OMP GUI CEF Prototype") {
            VStack(spacing: 0) {
                HStack {
                    Picker("Browser tabs", selection: $store.selected) {
                        ForEach(store.tabs) { tab in Text(verbatim: tab.id).tag(tab.id) }
                    }.pickerStyle(.segmented).frame(width: 220)
                    Spacer()
                    Text(verbatim: store.endpoint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }.padding(12)
                Divider()
                BrowserSurface(store: store)
                Divider()
                Text("Prototype data is temporary.").font(.caption).padding(8)
            }
            .frame(minWidth: 880, minHeight: 620)
            .onAppear { store.start() }
        }.defaultSize(width: 1040, height: 720)
    }
}

@Observable @MainActor
final class BrowserTab: Identifiable {
    let id: String
    let instance = UUID().uuidString
    let model: CefWebViewModel
    // Keep native host identity independent of SwiftUI collection diffing.
    // CefWebView dismantle owns browser close, so disposing a sibling host
    // during a tab-array update would otherwise close an unrelated page.
    @ObservationIgnored var host: NSHostingView<AnyView>?
    var bound = false

    init(id: String, base: String) {
        self.id = id
        var options = CefBrowserOptions()
        options.runtimeStyle = .alloy
        model = CefWebViewModel(url: URL(string: base + "/fixture?tab=" + id + "&instance=" + instance), options: options)
        model.onWindowOpen = { _ in .deny }
        model.onDownloadDecision = { _, suggestedName in
            let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CEF_PROTOTYPE_RUN"]!).appendingPathComponent("native-downloads")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return .allow(destination: folder.appendingPathComponent((suggestedName as NSString).lastPathComponent))
        }
        model.onConsoleMessage = { [weak self] message in
            guard message == "fixture-ready", let self, let browser = self.model.browser else { return }
            browser.setAccessibilityEnabled(true)
            let identity = ["instance": self.instance, "cefBrowserID": String(browser.id)]
            guard let data = try? JSONSerialization.data(withJSONObject: identity), let json = String(data: data, encoding: .utf8) else { return }
            browser.executeJavaScript("window.nativeIdentity = \(json); document.querySelector('#native').textContent = JSON.stringify(window.nativeIdentity); console.log('native-bound');")
            self.bound = true
        }
    }

    func nativeHost() -> NSHostingView<AnyView> {
        if let host { return host }
        let view = NSHostingView(rootView: AnyView(CefWebView(model: model)))
        host = view
        return view
    }

    func disposeHost() {
        host?.rootView = AnyView(Color.clear)
        host?.removeFromSuperview()
        host = nil
    }
}

private struct BrowserSurface: NSViewRepresentable {
    let store: BrowserStore
    func makeNSView(context: Context) -> BrowserContainer { BrowserContainer() }
    func updateNSView(_ view: BrowserContainer, context: Context) {
        for tab in store.tabs {
            let host = tab.nativeHost()
            if host.superview !== view { view.addSubview(host) }
            host.frame = view.bounds
            host.autoresizingMask = [.width, .height]
            host.isHidden = tab.id != store.selected
        }
    }
}

private final class BrowserContainer: NSView {
    override func layout() {
        super.layout()
        for view in subviews { view.frame = bounds }
    }
}

@Observable @MainActor
final class BrowserStore {
    var tabs: [BrowserTab] = []
    var selected = "A"
    let endpoint: String
    private let root: URL
    private let base: String
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCommand = ""
    @ObservationIgnored private var closing: [CefBrowser]?

    init() {
        let env = ProcessInfo.processInfo.environment
        root = URL(fileURLWithPath: env["CEF_PROTOTYPE_RUN"]!)
        base = env["CEF_PROTOTYPE_FIXTURE_URL"]!
        endpoint = "http://127.0.0.1:" + env["CEF_PROTOTYPE_CDP_PORT"]!
        tabs = [BrowserTab(id: "A", base: base), BrowserTab(id: "B", base: base)]
    }

    func start() {
        guard timer == nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        if let data = try? Data(contentsOf: root.appendingPathComponent("command.json")),
           let command = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let id = command["id"], id != lastCommand {
            lastCommand = id
            let tabID = command["tab"] ?? selected
            switch command["action"] {
            case "select": selected = tabID
            case "close":
                tabs.first { $0.id == tabID }?.disposeHost()
                tabs.removeAll { $0.id == tabID }
                if selected == tabID { selected = tabs.first?.id ?? "A" }
            case "reopen":
                if !tabs.contains(where: { $0.id == tabID }) { tabs.append(BrowserTab(id: tabID, base: base)) }
                selected = tabID
            case "sample":
                // Independent native-owner observation of the actual hosted browser.
                tabs.first { $0.id == tabID }?.model.browser?.executeJavaScript("fetch('/native-proof', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({identity:window.nativeIdentity,tab:new URL(location.href).searchParams.get('tab'),value:document.querySelector('#name').value,output:document.querySelector('#output').textContent,trusted:window.inputEvents})});")
            case "dialog":
                // Trigger a pending modal without awaiting it through an OMP
                // execution cell. OMP still owns inspection and the response.
                tabs.first { $0.id == tabID }?.model.browser?.executeJavaScript("window.cap.prompt = prompt('CEF lifecycle', 'default');")
            case "quit":
                // Tear down the hosted views first. Requesting termination while
                // CEF's on_before_close callback is active can shut the runtime
                // down inside that callback in the pinned CefSwift revision.
                closing = tabs.compactMap { $0.model.browser }
                for tab in tabs { tab.disposeHost() }
                tabs.removeAll()
            default: break
            }
        }
        let snapshot: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "selected": selected,
            "lastCommand": lastCommand, "endpoint": endpoint,
            "tabs": tabs.map { tab -> [String: Any] in
                ["id": tab.id, "instance": tab.instance, "bound": tab.bound,
                 "cefBrowserID": tab.model.browser?.id ?? -1, "url": tab.model.url?.absoluteString ?? "", "title": tab.model.title]
            }]
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("native-state.json"), options: .atomic)
        }
        if let closing, closing.allSatisfy({ $0.isClosed }) {
            self.closing = nil
            timer?.invalidate(); timer = nil
            NSApp.terminate(nil)
        }
    }
}
