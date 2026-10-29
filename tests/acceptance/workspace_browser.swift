import AppKit
import CCefAppKit
import CefSwiftUI
import SwiftUI
@testable import OMPGUI

/// Visible, isolated production-panel regression. Run only with owner consent.
@main private enum WorkspaceBrowserAcceptance {
    @MainActor static func main() {
        CEFApplication.install()
        NSApp.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("Browser acceptance failed: \(error)"); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        guard let output = CaptureRun.outputDirectory, output.path.contains("/build.noindex/"),
              let root = CaptureRun.storageRoot else { fatalError("Require isolated capture directory") }
        if let index = CommandLine.arguments.firstIndex(of: "--automation-url") {
            try await runAutomation(output: output, url: URL(string: CommandLine.arguments[index + 1])!)
            return
        }
        if CommandLine.arguments.contains("--profile-settings") {
            let defaults = CaptureRun.defaults!
            defaults.removeObject(forKey: BrowserProfileConfiguration.preferenceKey)
            let model = AppModel()
            let view = ScrollView { VStack(spacing: 24) { BrowserSettingsPage() }.padding(24) }
                .environment(model).font(.ui(.body)).frame(width: 760, height: 680)
            let window = DCDisplayCycleGuardedWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 680),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "OMP GUI Browser Profile Settings Acceptance"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try Data().write(to: output.appendingPathComponent("settings-ready"))
            let deadline = ContinuousClock.now + .seconds(75)
            while !FileManager.default.fileExists(atPath: output.appendingPathComponent("settings-finish").path),
                  ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
            let value = model.settings.browserProfiles
            let report: [String: Any] = ["profiles": value.profiles.map { ["id": $0.id.uuidString, "name": $0.name] },
                "selected": value.selectedID.uuidString, "active": BrowserProfileConfiguration.activeProfile.id.uuidString]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("settings.json"))
            window.close()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--profile-phase"),
           let fixtureIndex = CommandLine.arguments.firstIndex(of: "--fixture-url") {
            try await runProfiles(output: output, root: root, phase: CommandLine.arguments[index + 1],
                                  base: CommandLine.arguments[fixtureIndex + 1])
            return
        }
        let restart = CommandLine.arguments.contains("--restart")
        let presentation = CommandLine.arguments.contains("--presentation")
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        var checks: [String] = []
        func expect(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: message, code: 1) }
            checks.append(message)
            print("PASS: \(message)")
        }
        func wait(_ message: String, _ condition: @MainActor () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            try expect(condition(), message)
        }
        func window(_ state: BrowserWorkspaceStore) -> NSWindow {
            let window = DCDisplayCycleGuardedWindow(contentRect: NSRect(x: 100, y: 100, width: 860, height: 640),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "OMP GUI Browser Acceptance"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BrowserWorkspacePane(state: state))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return window
        }
        let registry = BrowserWorkspaceRegistry.shared
        let state = registry.workspace(for: id)
        try expect(state.pages.count == (restart ? 1 : 0), "restart restores saved tab metadata only")
        let firstWindow = window(state)
        try await wait("first page reports readiness") { state.selectedPage?.targetID != nil || state.selectedPage?.error != nil }
        let first = state.selectedPage!
        try expect(first.error == nil && first.targetID != nil, "first persistent profile creates an attached page")
        try expect(firstWindow.isVisible, "opening the browser leaves the application window visible")
        try expect(first.url == "about:blank", "internal discovery URL is not persisted")
        let originalTarget = first.targetID
        let originalHost = first.host
        let profile = root.appendingPathComponent("browser/profiles/Profile-" + BrowserProfileConfiguration.activeProfile.storageName)
        try expect(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Cookies").path),
                   "Chromium created the shared profile cookie database")
        if presentation {
            // Observe startup from the open action through native completion,
            // then let CUA exercise the real tab strip and menu on this instance.
            let next = try state.open()
            var titles = Set<String>(), loadingWasVisible = false
            let settle = ContinuousClock.now + .seconds(1)
            while ContinuousClock.now < settle || next.targetID == nil {
                titles.insert(next.title)
                loadingWasVisible = loadingWasVisible || next.isLoading
                guard ContinuousClock.now < settle + .seconds(14) else { throw WorkspaceBrowserError.connection }
                try await Task.sleep(for: .milliseconds(8))
            }
            try expect(titles == [Chrome.localized("New browser tab")], "new-tab title stays stable throughout native startup")
            try expect(!loadingWasVisible, "new blank tab never exposes bootstrap loading controls")
            try expect(next.model.url.map(BrowserAddress.isBootstrapURL) == true && !next.model.canGoBack,
                       "new blank tab reuses its initial document without a second navigation")
            try Data().write(to: output.appendingPathComponent("presentation-ready"))
            let deadline = ContinuousClock.now + .seconds(60)
            while !FileManager.default.fileExists(atPath: output.appendingPathComponent("presentation-finish").path),
                  ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
            try expect(firstWindow.isVisible, "tab and menu inspection preserves the host window")
        } else if !restart {
            let second = try state.open(select: false)
            _ = try await second.attachment()
            try expect(first.targetID == originalTarget && first.host === originalHost, "adding a sibling retains the original native page")
            state.selectedID = second.id
            try await Task.sleep(for: .milliseconds(150))
            let secondWindow = window(state)
            print("Window transfer: policy=\(NSApp.activationPolicy().rawValue), active=\(NSApp.isActive), firstKey=\(firstWindow.isKeyWindow), secondKey=\(secondWindow.isKeyWindow), hostWindow=\(second.host?.window?.windowNumber ?? -1), first=\(firstWindow.windowNumber), second=\(secondWindow.windowNumber)")
            try await wait("selected sibling moves to second window") { second.host?.window === secondWindow }
            state.selectedID = first.id
            try await wait("original page moves to second window") { first.host?.window === secondWindow }
            try expect(first.targetID == originalTarget && first.host === originalHost, "window transfer retains target and native view identity")
            secondWindow.contentView = NSView()
            try await Task.sleep(for: .milliseconds(150))
            firstWindow.makeKeyAndOrderFront(nil)
            try await wait("parked page returns to first window") { first.host?.window === firstWindow }
            try expect(first.targetID == originalTarget, "dismantling a presentation parks and restores its page")
            let closed = first.model.browser!
            first.requestClose()
            try await wait("single page finishes close and leaves store") { closed.isClosed && !state.pages.contains(where: { $0 === first }) }
            try expect(firstWindow.isVisible && secondWindow.isVisible, "closing an embedded tab never closes either host window")
            try expect(state.selectedPage === second && second.targetID != nil, "closing one tab preserves its sibling")
            let transientState = registry.workspace(for: UUID())
            let transient = try transientState.open()
            let pending = transient.model.browser!
            try expect(pending.isCreationPending, "browser creation is asynchronous")
            transientState.closeAll()
            try await wait("pending creation finishes close") { pending.isClosed }
            try expect(firstWindow.isVisible, "closing during creation cannot close the application window")
            secondWindow.close()
        }
        let live = state.pages.compactMap { $0.model.browser }
        await registry.shutdown()
        try expect(live.allSatisfy(\.isClosed), "shutdown completes all browser close callbacks")
        try expect(EmbeddedBrowserRuntime.shared.endpoint == nil, "shutdown releases CEF after browser destruction")
        try expect(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Preferences").path),
                   "clean shutdown flushes the persistent profile preferences")
        try expect(firstWindow.isVisible, "runtime shutdown does not close the application window")
        let data = try JSONSerialization.data(withJSONObject: ["restart": restart, "checks": checks, "passed": true], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent(restart ? "restart.json" : "first.json"))
        firstWindow.close()
        print("Workspace browser acceptance: \(checks.count) checks passed (restart=\(restart))")
    }

    @MainActor private static func evaluate(_ page: BrowserPage, _ expression: String) async throws -> JSONValue {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let endpoint = EmbeddedBrowserRuntime.shared.endpoint!
        let (data, _) = try await session.data(from: endpoint.appendingPathComponent("json/list"))
        guard let targets = JSONValue.parse(data)?.array,
              let target = targets.first(where: { $0["id"]?.string == page.targetID }),
              let address = target["webSocketDebuggerUrl"]?.string, let url = URL(string: address) else {
            throw WorkspaceBrowserError.connection
        }
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        let request: JSONValue = ["id": 1, "method": "Runtime.evaluate", "params": [
            "expression": .string(expression), "returnByValue": true, "awaitPromise": true]]
        try await socket.send(.string(request.compactString))
        for _ in 0..<10 {
            let message = try await socket.receive()
            let bytes: Data
            switch message {
            case .data(let value): bytes = value
            case .string(let value): bytes = Data(value.utf8)
            @unknown default: throw WorkspaceBrowserError.connection
            }
            guard let result = JSONValue.parse(bytes) else { throw WorkspaceBrowserError.connection }
            guard result["id"]?.int == 1 else { continue }
            guard result["error"] == nil, result["result"]?["exceptionDetails"] == nil,
                  let value = result["result"]?["result"]?["value"] else {
                throw NSError(domain: "CDP evaluation failed: " + String(decoding: bytes, as: UTF8.self), code: 1)
            }
            return value
        }
        throw WorkspaceBrowserError.connection
    }

    /// File rendezvous is confined to this capture directory; it never targets a running user app.
    @MainActor private static func runAutomation(output: URL, url: URL) async throws {
        let registry = BrowserWorkspaceRegistry.shared
        let state = registry.workspace(for: UUID())
        let a = try state.open(url: url)
        let b = try state.open(url: url, select: false)
        var loadErrors: [UUID: [JSONValue]] = [:]
        for page in [a, b] {
            let original = page.model.onLoadError
            let id = page.id
            page.model.onLoadError = { code, text, url in
                original?(code, text, url)
                loadErrors[id, default: []].append(.object([
                    "code": .int(code), "text": .string(text), "url": .string(url),
                ]))
            }
        }
        let window = DCDisplayCycleGuardedWindow(contentRect: NSRect(x: 100, y: 100, width: 960, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "OMP GUI Browser Automation Acceptance"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserWorkspacePane(state: state))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let first = try await a.attachment()
        let second = try await b.attachment()
        let ready: JSONValue = .object(["a": first, "b": second])
        try Data(ready.compactString.utf8).write(to: output.appendingPathComponent("automation-ready.json"), options: .atomic)
        let deadline = ContinuousClock.now + .seconds(240)
        var lastSequence = -1
        while !FileManager.default.fileExists(atPath: output.appendingPathComponent("automation-finish").path),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
            let requestURL = output.appendingPathComponent("automation-request.json")
            guard let data = try? Data(contentsOf: requestURL), let request = JSONValue.parse(data),
                  let sequence = request["sequence"]?.int, sequence != lastSequence else { continue }
            lastSequence = sequence
            var response: JSONValue
            do {
                let page = request["tab"]?.string == "b" ? b : a
                switch request["action"]?.string {
                case "select": state.selectedID = page.id
                case "hide": window.contentView = nil; window.orderOut(nil)
                case "show":
                    window.contentView = NSHostingView(rootView: BrowserWorkspacePane(state: state))
                    window.makeKeyAndOrderFront(nil)
                case "close":
                    let native = page.model.browser
                    page.requestClose()
                    let until = ContinuousClock.now + .seconds(5)
                    while (state.pages.contains(where: { $0 === page }) || native?.isClosed == false),
                          ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(25)) }
                    guard !state.pages.contains(where: { $0 === page }), native?.isClosed != false else {
                        throw NSError(domain: "Page close did not complete", code: 1)
                    }
                case "dialog":
                    _ = try await evaluate(page, "setTimeout(() => confirm('acceptance dialog'), 0); true")
                    let until = ContinuousClock.now + .seconds(5)
                    while page.dialog == nil, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(25)) }
                    guard page.dialog != nil else { throw NSError(domain: "Dialog did not open", code: 1) }
                case "download":
                    _ = try await evaluate(page, "document.querySelector('#download').href='/download?name=manual-after-release'; document.querySelector('#download').click(); true")
                    let until = ContinuousClock.now + .seconds(5)
                    while !page.downloads.contains(where: { $0.isComplete && $0.url?.query == "name=manual-after-release" }),
                          ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(25)) }
                    guard page.downloads.contains(where: { $0.isComplete && $0.url?.query == "name=manual-after-release" }) else {
                        throw NSError(domain: "Manual download did not complete after release", code: 1)
                    }
                case "sample", "status": break
                default: throw NSError(domain: "Unknown automation control", code: 1)
                }
                let sample: JSONValue = request["action"]?.string == "sample"
                    ? try await evaluate(page, "({value:document.querySelector('#name').value,output:document.querySelector('#output').textContent,trusted:window.trustedEvents,visibility:document.visibilityState,dropped:window.dropped,scrollY:window.scrollY})") : .null
                response = .object(["sequence": .int(sequence), "ok": .bool(true), "sample": sample,
                    "loadErrors": .array(loadErrors[page.id, default: []]),
                    "downloads": .array(page.downloads.filter(\.isComplete).map { .string($0.fullPath?.path ?? "") }),
                    "selected": .string(state.selectedID == a.id ? "a" : "b"), "windowVisible": .bool(window.isVisible)])
            } catch {
                response = .object(["sequence": .int(sequence), "ok": .bool(false), "error": .string(String(describing: error))])
            }
            try Data(response.compactString.utf8).write(to: output.appendingPathComponent("automation-response.json"), options: .atomic)
        }
        await registry.shutdown()
        window.close()
        guard FileManager.default.fileExists(atPath: output.appendingPathComponent("automation-finish").path) else {
            throw NSError(domain: "Automation driver timed out", code: 1)
        }
    }

    @MainActor private static func runProfiles(output: URL, root: URL, phase: String, base: String) async throws {
        let defaults = CaptureRun.defaults!
        if phase == "first" { defaults.removeObject(forKey: BrowserProfileConfiguration.preferenceKey) }
        let model = AppModel()
        let settings = model.settings
        let active = BrowserProfileConfiguration.activeProfile
        let blank = phase == "first" ? settings.browserProfiles.add(named: "独立空白配置")!
            : settings.browserProfiles.profiles.first { !$0.isDefault }!
        let account = phase.hasPrefix("blank") ? "account-b" : "account-a"
        var checks: [String] = []
        func expect(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: message, code: 1) }
            checks.append(message); print("PASS: \(message)")
        }
        func wait(_ message: String, _ condition: @MainActor () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            var lastError: Error?
            while ContinuousClock.now < deadline {
                do {
                    if try await condition() { try expect(true, message); return }
                } catch { lastError = error }
                try await Task.sleep(for: .milliseconds(40))
            }
            if let lastError { print("Last readiness error: \(lastError)") }
            try expect(false, message)
        }
        func makeWindow<Content: View>(_ content: Content) -> NSWindow {
            let window = DCDisplayCycleGuardedWindow(contentRect: NSRect(x: 100, y: 100, width: 860, height: 700),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "OMP GUI Browser Profile Acceptance"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: content)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return window
        }
        if phase == "first" {
            try expect(settings.browserProfiles.selectedID == blank.id && active.isDefault,
                       "creating a profile before the first browser keeps the launch selection frozen")
            let view = ScrollView { VStack(spacing: 24) { BrowserSettingsPage() }.padding(24) }
                .environment(model).font(.ui(.body)).frame(width: 760, height: 680)
            let window = makeWindow(view)
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            window.close()
        }
        let registry = BrowserWorkspaceRegistry.shared
        let state = registry.workspace(for: UUID())
        let first = try state.open(url: URL(string: base + "/")!)
        let window = makeWindow(BrowserWorkspacePane(state: state))
        _ = try await first.attachment()
        try await wait("login fixture loads in the production browser") {
            try await evaluate(first, "location.origin === '\(base)' && document.readyState === 'complete'").bool == true
        }
        let readStorage = """
        (async () => {
          const session = await (await fetch('/session', {cache: 'no-store'})).json();
          let indexed = null;
          if ((await indexedDB.databases()).some(x => x.name === 'omp-profile')) {
            indexed = await new Promise((resolve, reject) => {
              const open = indexedDB.open('omp-profile', 1);
              open.onerror = () => reject(open.error);
              open.onsuccess = () => { const db = open.result;
                const get = db.transaction('identity').objectStore('identity').get('account');
                get.onsuccess = () => { resolve(get.result ?? null); db.close(); };
                get.onerror = () => { reject(get.error); db.close(); };
              };
            });
          }
          return {session, local: localStorage.getItem('identity'), indexed, readableCookies: document.cookie};
        })()
        """
        func checkAccount(_ page: BrowserPage, _ expected: String, _ message: String) async throws {
            let value = try await evaluate(page, readStorage)
            try expect(value["session"]?["authenticated"]?.bool == true
                && value["session"]?["account"]?.string == expected
                && value["session"]?["session"]?.string == expected
                && value["local"]?.string == expected && value["indexed"]?.string == expected, message)
            try expect(value["readableCookies"]?.string == "", "login cookies remain HttpOnly")
        }
        if phase == "first" || phase == "blank" {
            let empty = try await evaluate(first, readStorage)
            try expect(empty["session"]?["authenticated"]?.bool == false
                && empty["session"]?["account"]?.string == "" && empty["session"]?["session"]?.string == ""
                && empty["local"] == .null && empty["indexed"] == .null,
                       "a newly selected profile has no login, persistent/session cookies, localStorage or IndexedDB")
            first.model.browser!.executeJavaScript("document.querySelector('#account').value = '\(account)'; document.querySelector('#login').requestSubmit();")
            try await wait("real form login completes through HTTP") {
                try await evaluate(first, "document.querySelector('#signed-in') !== null").bool == true
            }
            _ = try await evaluate(first, """
            (async () => {
              localStorage.setItem('identity', '\(account)');
              await new Promise((resolve, reject) => {
                const open = indexedDB.open('omp-profile', 1);
                open.onupgradeneeded = () => open.result.createObjectStore('identity');
                open.onerror = () => reject(open.error);
                open.onsuccess = () => { const db = open.result; const tx = db.transaction('identity', 'readwrite');
                  tx.objectStore('identity').put('\(account)', 'account');
                  tx.oncomplete = () => { db.close(); resolve(true); };
                  tx.onerror = () => { db.close(); reject(tx.error); };
                };
              }); return true;
            })()
            """)
        }
        try await checkAccount(first, account, "login and both storage APIs survive the expected profile/process boundary")
        let otherState = registry.workspace(for: UUID())
        let other = try otherState.open(url: URL(string: base + "/")!)
        _ = try await other.attachment()
        try await wait("another conversation loads its independent tab") {
            try await evaluate(other, "location.origin === '\(base)' && document.readyState === 'complete'").bool == true
        }
        try await checkAccount(other, account, "another conversation immediately shares the same authenticated account and storage")
        try expect(first.model.options.profile === other.model.options.profile && first.id != other.id,
                   "conversation tabs stay independent while using one native profile")
        settings.browserProfiles.select(active.isDefault ? blank.id : BrowserProfileRecord.defaultProfile.id)
        let laterState = registry.workspace(for: UUID())
        let later = try laterState.open(url: URL(string: base + "/")!)
        _ = try await later.attachment()
        try await wait("a conversation created after changing settings loads") {
            try await evaluate(later, "location.origin === '\(base)' && document.readyState === 'complete'").bool == true
        }
        try await checkAccount(later, account, "pending profile selection cannot mix accounts in newly created conversations")
        state.closeAll(); otherState.closeAll(); laterState.closeAll()
        let reopened = try registry.workspace(for: UUID()).open(url: URL(string: base + "/")!)
        _ = try await reopened.attachment()
        try await wait("a new tab loads after every previous tab closed") {
            try await evaluate(reopened, "location.origin === '\(base)' && document.readyState === 'complete'").bool == true
        }
        try await checkAccount(reopened, account, "closing all tabs and reopening cannot clear the shared login")
        if phase == "first" { settings.browserProfiles.select(active.id) }
        defaults.synchronize()
        await registry.shutdown()
        let profile = root.appendingPathComponent("browser/profiles/Profile-" + active.storageName)
        try expect(FileManager.default.fileExists(atPath: profile.appendingPathComponent("Cookies").path)
            && FileManager.default.fileExists(atPath: profile.appendingPathComponent("Preferences").path),
                   "clean CEF shutdown writes the selected persistent profile")
        let report: [String: Any] = ["phase": phase, "activeProfile": active.id.uuidString,
            "account": account, "checks": checks, "passed": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent(phase + ".json"))
        window.close()
        print("Browser profile acceptance: \(checks.count) checks passed (\(phase))")
    }
}
