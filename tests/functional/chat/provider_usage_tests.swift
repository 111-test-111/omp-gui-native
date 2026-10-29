import AppKit
import Foundation
import SwiftUI
@testable import OMPGUI

/// Native hosts can notify while a correction is still on the stack, and can
/// constrain a short document to a negative origin during a popover resize.
@MainActor private final class ModelPickerClipView: NSClipView {
    var reentersBoundsChange = false
    var centersDocument = false
    private(set) var reentrantUpdates = 0

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        if centersDocument, let documentView {
            constrained.origin.x = min(0, (documentView.frame.width - proposedBounds.width) / 2)
        }
        return constrained
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        if reentersBoundsChange {
            reentrantUpdates += 1
            precondition(reentrantUpdates < 16, "A bounds correction recursively reentered the model scroll lock")
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: self)
        }
        super.setBoundsOrigin(centersDocument
            ? constrainBoundsRect(NSRect(origin: newOrigin, size: bounds.size)).origin : newOrigin)
    }
}

@main
struct ProviderUsageChecks {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ value: Bool, _ message: String) {
        guard value else { fatalError(message) }
        checks += 1
    }
    @MainActor private static func wait(line: UInt = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Provider usage did not settle at line \(line)")
    }

    private static func payload(at now: Date, plan: String = "Native plan") -> JSONValue {
        let time = now.timeIntervalSince1970 * 1_000
        return ["reports": [[
            "provider": "openai-codex", "fetchedAt": .double(time),
            "metadata": ["planType": .string(plan), "email": "fixture@example.invalid"],
            "limits": [
                ["id": "5h", "label": "5 Hour", "amount": ["unit": "percent", "used": 25],
                 "window": ["resetsAt": .double(time + 3_600_000)]],
                ["id": "credits", "label": "Credits", "amount": ["unit": "credits", "remaining": 17]],
                ["id": "unknown", "label": "Missing", "amount": ["unit": "percent"]],
                ["id": "zero", "label": "Zero", "amount": ["unit": "percent", "used": 0]],
                ["id": "overage", "label": "Overage", "amount": ["unit": "requests", "used": 125, "limit": 100]],
                ["id": "expired", "label": "Expired", "amount": ["unit": "percent", "used": 80],
                 "window": ["resetsAt": .double(time - 1_000)]],
                ["id": "no-unit", "label": "No unit", "amount": ["unit": "unknown", "remaining": 10]],
                ["id": "uncertain", "label": "Uncertain", "status": "unknown", "amount": ["unit": "percent", "used": 50]],
                ["id": "future-status", "label": "Unrecognized", "status": "pending", "amount": ["unit": "percent", "used": 50]],
                ["id": "left", "label": "Remaining fraction", "amount": ["unit": "percent", "remainingFraction": 0.75]]
            ]
        ]], "accountsWithoutUsage": [["provider": "custom-provider"]]]
    }

    @MainActor private static func projection() throws {
        let now = Date()
        let result = try OMPProviderUsage.decode(payload(at: now))
        let report = result.confirmedReports(for: "openai-codex", now: now).first!
        expect(report.plan == "Native plan" && report.account == "fixture@example.invalid", "Native account and plan metadata stay attached to their report")
        expect(report.limits.map(\.label) == ["5 Hour", "Credits", "Zero", "Overage", "Remaining fraction"],
               "Missing, expired, unknown-status and unknown-unit values are omitted, while explicit zero remains visible")
        expect(report.limits.first?.usedFraction == 0.25 && report.limits.last?.usedFraction == 0.25,
               "Native percent and remaining-fraction semantics agree")
        expect(report.limits.first(where: { $0.label == "Overage" })?.usedFraction == 1.25, "Overage is retained rather than clamped in the source value")
        let credits = report.limits.first { $0.label == "Credits" }!
        expect(credits.usedFraction == nil && credits.remaining == 17, "A credits balance never becomes a percentage")
        expect(NativeUsageLimitView(limit: credits).amountText.contains("17"), "Known absolute balances have a readable amount")
        let resetRows: [JSONValue] = ["tick", "regen", "resets", "new-meaning"].map { verb in
            ["label": .string(verb), "amount": ["unit": "percent", "used": 5],
             "window": ["resetsAt": .double(now.timeIntervalSince1970 * 1_000 + 60_000), "resetLabel": .string(verb)]]
        }
        let resetLimits: JSONValue = ["reports": [["provider": "x", "fetchedAt": .double(now.timeIntervalSince1970 * 1_000),
            "limits": .array(resetRows)]]]
        let resets = try OMPProviderUsage.decode(resetLimits).confirmedReports(for: "x", now: now)[0].limits
        let resetTexts = resets.map { NativeUsageLimitView(limit: $0).resetText(now.addingTimeInterval(85)) }
        expect(resetTexts[0] == resetTexts[1] && resetTexts[1] != resetTexts[2] && resetTexts[3] == nil,
               "Incremental replenishment never claims a full reset, and an unknown reset meaning stays hidden")
        expect(result.confirmedReports(for: "custom-provider", now: now).isEmpty, "An unsupported account never becomes an empty or zero quota bar")
        expect(result.confirmedReports(for: "openai-codex", now: now.addingTimeInterval(601)).isEmpty, "Aged reports are not presented as current")
        expect(result.confirmedReports(for: "openai-codex", now: now.addingTimeInterval(-60)).isEmpty, "Invalid future timestamps do not certify usage")
        let missingTime: JSONValue = ["reports": [["provider": "x", "limits": [["amount": ["unit": "percent", "used": 5]]]]]]
        expect(try OMPProviderUsage.decode(missingTime).confirmedReports(for: "x", now: now).isEmpty,
               "A report without a source time stays hidden")
        let estimated: JSONValue = ["reports": [["provider": "x", "fetchedAt": .double(now.timeIntervalSince1970 * 1_000),
            "metadata": ["source": "estimated"], "limits": [["amount": ["unit": "percent", "used": 5]]]]]]
        expect(try OMPProviderUsage.decode(estimated).confirmedReports(for: "x", now: now).isEmpty,
               "An explicitly estimated source is not advertised as confirmed usage")
        do { _ = try OMPProviderUsage.decode(["other": []]); fatalError("Invalid root accepted") }
        catch { expect(true, "Malformed output fails closed") }
        let large: JSONValue = ["reports": [["provider": "x", "limits": .array(Array(repeating: ["amount": ["unit": "percent", "used": 1]], count: 2_000))]]]
        let bounded = try OMPProviderUsage.decode(large)
        expect(bounded.isTruncated && bounded.reports.first?.limits.count == 128, "Large native reports stay bounded")
        let balance: JSONValue = ["reports": [["provider": "deepseek", "fetchedAt": .double(now.timeIntervalSince1970 * 1_000), "limits": [],
            "metadata": ["source": "omp-gui-deepseek-balance-v1", "ompGuiBalances": ["version": 1, "items": [
                ["currency": "CNY", "total": "123456789012345678.123456789012", "granted": "0.00"],
                ["currency": "USD", "total": "4.50", "toppedUp": "NaN"],
                ["currency": "EUR", "total": "5.00"]]]]]]]
        let money = try OMPProviderUsage.decode(balance)
        let values = money.confirmedReports(for: "deepseek", now: now).first!.balances
        expect(values.count == 2 && values[0].total == "123456789012345678.123456789012" && values[0].granted == "0.00",
               "Monetary balances retain exact decimal strings, both official currencies and explicit zero")
        expect(values[1].granted == nil && values[1].toppedUp == nil, "Missing and invalid balances stay absent")
        expect(money.confirmedReports(for: "deepseek", now: now.addingTimeInterval(601)).isEmpty, "Money uses the same native freshness gate as quotas")
        expect(money.confirmedReports(now: now).map(\.id) == money.confirmedReports(for: "deepseek", now: now).map(\.id),
               "The settings-wide snapshot uses the same confirmed account facts as an individual provider")
        let detailOnly: JSONValue = ["reports": [["provider": "deepseek", "fetchedAt": .double(now.timeIntervalSince1970 * 1_000), "limits": [],
            "metadata": ["source": "omp-gui-deepseek-balance-v1", "ompGuiBalances": ["version": 1, "items": [["currency": "CNY", "granted": "1.00"]]]]]]]
        let detail = try OMPProviderUsage.decode(detailOnly).confirmedReports(now: now).first!
        expect(!NativeProviderUsageSummary.hasKeyValues(detail), "A gift-only detail cannot be substituted for a missing total balance in compact settings")
        expect(NativeProviderUsageSummary.hasKeyValues(money.confirmedReports(now: now)[0]), "A known available balance remains a key settings value")
        let configured = ConfiguredProviderProjection.providers(logins: [
            OMPLoginProvider(id: "openai-codex", name: "Codex", authenticated: true, supportsBrowserLogin: true),
            OMPLoginProvider(id: "cursor", name: "Cursor", authenticated: false, supportsBrowserLogin: true),
            OMPLoginProvider(id: "github-copilot", name: "Copilot", authenticated: true, supportsBrowserLogin: true)
        ], models: [ModelOption(id: "deepseek/a", name: "A", provider: "deepseek"),
                    ModelOption(id: "deepseek/b", name: "B", provider: "deepseek")], reports: [report])
        expect(Set(configured.map(\.id)) == ["openai-codex", "deepseek", "github-copilot"],
               "Configured settings include native API-key models and signed-in accounts without chat models, omitting unconfigured login choices")
        expect(configured.filter { $0.id == "deepseek" }.count == 1 && configured.first { $0.id == "deepseek" }?.login == nil,
               "Several API-key models share one configured provider row without inventing a browser sign-in flow")
        let browser = OMPLoginProvider(id: "openai-codex", name: "ChatGPT subscription", authenticated: true, supportsBrowserLogin: true)
        let device = OMPLoginProvider(id: "openai-codex-device", name: "ChatGPT device", authenticated: true, supportsBrowserLogin: true,
                                      credentialProviderID: "openai-codex")
        let aliases = ConfiguredProviderProjection.providers(logins: [device, browser], models: [], reports: [report])
        expect(aliases.count == 1 && aliases[0].id == "openai-codex" && aliases[0].name == browser.name,
               "Two native Codex login methods sharing credentials produce one configured subscription row")
        expect(aliases[0].login?.id == browser.id && aliases[0].nativeIDs == [browser.id, device.id],
               "The primary browser route remains the native action target and both usage identities remain attached")
        let deviceOnly = ConfiguredProviderProjection.providers(logins: [device], models: [], reports: [])
        expect(deviceOnly.count == 1 && deviceOnly[0].id == browser.id && deviceOnly[0].login?.id == device.id,
               "An alias-only installation keeps its real native login route without adding a phantom second row")
        let unrelated = OMPLoginProvider(id: "other-account", name: browser.name, authenticated: true)
        let distinct = ConfiguredProviderProjection.providers(logins: [browser, unrelated], models: [], reports: [])
        expect(distinct.count == 2, "The same display name never merges unrelated native credential sources")
        let china = ModelOption(id: "minimax-cn/fixture", name: "MiniMax fixture", provider: "minimax-cn")
        let regional = ConfiguredProviderProjection.providers(logins: [], models: [china], reports: [])
        expect(regional.count == 1 && regional[0].id == "minimax-cn" && regional[0].name.contains("MiniMax") && !regional[0].name.contains("-cn"),
               "A model-only configured provider receives a readable name without changing its native key-editing identity")
        expect(ModelPickerProjection.matches(china, query: "MiniMax China"), "Model search also recognizes the full regional provider name")
    }

    @MainActor private static func scrolling() {
        let screen = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let centered = NSRect(x: 250, y: 350, width: 120, height: 28)
        expect(ModelPickerLayout.arrowEdge(anchor: centered, visibleFrame: screen) == .trailing,
               "A centered new-chat chip selects room for the model page before the small effort page opens")
        expect(ModelPickerLayout.arrowEdge(anchor: centered.offsetBy(dx: 0, dy: -260), visibleFrame: screen) == .top,
               "A docked composer keeps both model pages above its stable chip anchor")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let clip = ModelPickerClipView(frame: scroll.contentView.frame)
        scroll.contentView = clip
        scroll.horizontalScrollElasticity = .allowed; scroll.hasHorizontalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1400))
        scroll.documentView = document
        let probe = VerticalScrollLockProbe()
        document.addSubview(probe); probe.attach()
        scroll.contentView.setBoundsOrigin(NSPoint(x: 80, y: 100))
        probe.attach()
        expect(!scroll.hasHorizontalScroller && scroll.horizontalScrollElasticity == .none && scroll.contentView.bounds.origin.x == 0,
               "The vertical model viewport refuses horizontal movement and elasticity")
        expect(scroll.contentView.bounds.origin.y == 100, "Locking the horizontal axis preserves vertical reading position")
        probe.detach()
        expect(scroll.hasHorizontalScroller && scroll.horizontalScrollElasticity == .allowed, "A dismantled lock restores only its own native scroll view")

        clip.setBoundsOrigin(NSPoint(x: 80, y: 160))
        clip.reentersBoundsChange = true
        probe.attach()
        expect(clip.bounds.origin == NSPoint(x: 0, y: 160) && clip.reentrantUpdates == 1,
               "A synchronous native bounds notification cannot recursively correct the same horizontal offset")
        probe.detach()
        clip.centersDocument = true
        document.setFrameSize(NSSize(width: 160, height: 1400))
        clip.setBoundsOrigin(NSPoint(x: 0, y: 160))
        let centeredOrigin = clip.bounds.origin
        let updates = clip.reentrantUpdates
        probe.attach()
        expect(centeredOrigin.x < 0 && clip.bounds.origin == centeredOrigin && clip.reentrantUpdates == updates,
               "A native centered origin for a narrow document is already legal and needs no correction")
        clip.reentersBoundsChange = false
        probe.detach()
    }

    @MainActor private static func coldPicker(_ model: AppModel, output: URL) async throws {
        let root = output.appendingPathComponent("cold model picker")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("omp")
        try #"""
        #!/usr/bin/env python3
        import json, pathlib, sys, time
        root = pathlib.Path(__file__).parent
        models = [{"provider": "fixture", "id": "cold", "name": "Cold model"}]
        if sys.argv[1:] == ["models", "--json"]:
            (root / "started").touch()
            deadline = time.monotonic() + 5
            while not (root / "release").exists():
                if time.monotonic() > deadline: sys.exit(2)
                time.sleep(0.005)
            print(json.dumps({"models": models}))
        elif sys.argv[1:] == ["config", "list", "--json"]:
            print("{}")
        elif sys.argv[1:3] == ["--mode", "rpc"]:
            for line in sys.stdin:
                command = json.loads(line)
                assert command["type"] == "get_available_models"
                print(json.dumps({"type": "response", "id": command["id"], "command": command["type"],
                                  "success": True, "data": {"models": models}}), flush=True)
        else:
            sys.exit(3)
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        model.settings.setBinaryPath(executable.path, for: .omp)
        expect(model.providers.models(for: .omp).isEmpty, "The cold picker starts without an app-startup catalogue")
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: ModelPickerLayout.modelSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = FrameHostingView(rootView: AnyView(NativeModelPicker(selectedModelID: nil, onChoose: { _ in }).environment(model)))
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
            model.settings.setBinaryPath("/usr/bin/true", for: .omp)
        }
        try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path) }
        expect(model.providers.loadingCatalogs.contains(.omp) && model.providers.models(for: .omp).isEmpty,
               "Entering an unseeded model page starts its own catalogue read and exposes loading before results arrive")
        try Data().write(to: root.appendingPathComponent("release"))
        try await wait { !model.providers.loadingCatalogs.contains(.omp) }
        expect(model.providers.models(for: .omp).map(\.id) == ["fixture/cold"] && model.providers.catalogErrors[.omp] == nil,
               "The already open cold picker receives native models without waiting for unrelated startup work")
        host.layoutSubtreeIfNeeded()
        expect(host.bounds.size == ModelPickerLayout.modelSize && model.liveRuntimes.isEmpty,
               "Cold catalogue loading keeps the bounded picker and never starts a chat runtime")
    }

    @MainActor private static func leases(_ model: AppModel) async throws -> OMPProviderUsageStore {
        let snapshot = try OMPProviderUsage.decode(payload(at: .now))
        let replacement = try OMPProviderUsage.decode(payload(at: .now, plan: "Replacement plan"))
        var current = URL(fileURLWithPath: "/fixture/profile-a")
        var reads = 0
        var pending: [Int: CheckedContinuation<OMPProviderUsage, Never>] = [:]
        var hold = true
        let store = OMPProviderUsageStore(registry: model.providers, profile: { _ in current }, read: { _ in
            reads += 1
            if hold { return await withCheckedContinuation { pending[reads] = $0 } }
            return snapshot
        })
        let first = UUID(), second = UUID(), third = UUID()
        let one = Task { await store.begin(first) }
        try await wait { pending[1] != nil }
        let two = Task { await store.begin(second) }
        await Task.yield()
        store.end(first)
        pending.removeValue(forKey: 1)?.resume(returning: snapshot)
        await one.value; await two.value
        expect(reads == 1 && store.snapshot == snapshot, "Concurrent settings views share one native read and one closing view cannot cancel another")
        store.end(second)
        expect(store.snapshot == nil, "Hidden settings data is not published without validating the next profile")
        await store.begin(second)
        expect(reads == 1 && store.snapshot == snapshot, "Reopening the same profile reuses a fresh read")
        let old = Task { await store.refresh(force: true) }
        try await wait { pending[2] != nil }
        current = URL(fileURLWithPath: "/fixture/profile-b")
        let new = Task { await store.begin(third) }
        try await wait { pending[3] != nil }
        expect(store.snapshot == nil && store.isLoading, "Changing the native profile immediately removes the prior account's data")
        pending.removeValue(forKey: 2)?.resume(returning: snapshot)
        await old.value
        expect(store.snapshot == nil && store.isLoading, "A late response from the old profile cannot settle the new request")
        pending.removeValue(forKey: 3)?.resume(returning: replacement)
        await new.value
        expect(store.snapshot == replacement, "The matching profile publishes its own report")
        let closing = Task { await store.refresh(force: true) }
        try await wait { pending[4] != nil }
        store.end(second); store.end(third)
        pending.removeValue(forKey: 4)?.resume(returning: snapshot)
        await closing.value
        expect(!store.isLoading && store.snapshot == nil, "Leaving the last settings view cancels and rejects a late native result")
        hold = false
        store.invalidate()
        await store.begin(first)
        expect(reads == 5 && store.snapshot == snapshot, "Native catalogue invalidation cannot reuse obsolete account data")
        store.end(first)
        return store
    }

    @MainActor private static func nativeReader(_ output: URL) async throws {
        let directory = output.appendingPathComponent("native usage fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("omp")
        let helper = directory.appendingPathComponent("usage helper.js")
        try "// fixture".write(to: helper, atomically: true, encoding: .utf8)
        let nativeProfile = directory.appendingPathComponent("profile-a")
        try nativeProfile.path.write(to: directory.appendingPathComponent("profile"), atomically: true, encoding: .utf8)
        try payload(at: .now).data().write(to: directory.appendingPathComponent("usage.json"))
        try """
        #!/bin/sh
        case "$1" in
          config) /bin/cat "$OMP_USAGE_FIXTURE/profile" ;;
          usage) [ "$#" = 4 ] && [ "$2" = --json ] && [ "$3" = --extension ] && [ "$4" = "$OMP_USAGE_FIXTURE/usage helper.js" ] || exit 2
                 /bin/cat "$OMP_USAGE_FIXTURE/usage.json" ;;
          *) exit 3 ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var context = OMPDiscoveryContext(executable: script, environment: ["OMP_USAGE_FIXTURE": directory.path], directory: nativeProfile)
        let result = try await OMPProviderUsageReader.read(context, extensionURL: helper)
        expect(!result.confirmedReports(for: "openai-codex").isEmpty, "The production CLI reader accepts the public JSON shape without disabling extension sources")
        context.directory = directory.appendingPathComponent("profile-b")
        do { _ = try await OMPProviderUsageReader.read(context, extensionURL: helper); fatalError("Profile mismatch accepted") }
        catch { expect(true, "An active-profile change during a native read is rejected") }
        try "not json".write(to: directory.appendingPathComponent("usage.json"), atomically: true, encoding: .utf8)
        do { _ = try await OMPProviderUsageReader.read(context, extensionURL: helper); fatalError("Malformed CLI output accepted") }
        catch { expect(true, "Native parse failures never become zero counters") }
    }

    @MainActor private static func picture(_ model: AppModel, store: OMPProviderUsageStore, output: URL) async throws {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let options = [ModelOption(id: "openai-codex/gpt-6", name: "GPT-6", provider: "openai-codex"),
                       ModelOption(id: "deepseek/deepseek-flash", name: "DeepSeek V4.1 Flash 1017", provider: "deepseek"),
                       ModelOption(id: "deepseek/deepseek-v4-pro", name: "DeepSeek V4 Pro", provider: "deepseek")]
        model.providers.updateCatalog(options, for: .omp)
        model.providers.subscriptionUsage = store
        let groups = ModelPickerProjection.providers(options)
        expect(groups.map(\.id) == ["openai-codex", "deepseek"] && groups[1].models.count == 2, "The rail groups native providers without inventing runtime choices")
        expect(ModelPickerProjection.matches(options[1], query: "flash deepseek") && !ModelPickerProjection.matches(options[2], query: "flash"),
               "Model search matches names and native selectors")
        expect(NativeModelProviderMark.title("openai") == "OpenAI", "An API provider is not mislabeled as a CLI runtime")
        let thread = model.newThread(affiliation: .standalone)!
        model.updateThread(thread.id) { $0.model = options[0].id }
        for (name, scheme) in [("model-picker-dark", ColorScheme.dark), ("model-picker-light", .light)] {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: ModelPickerLayout.modelSize), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            let view = ModelList(thread: model.thread(thread.id)!, hasHistory: false, onChoose: { _ in }, onBack: {})
                .environment(model).preferredColorScheme(scheme).font(.ui(.body))
                .background(scheme == .dark ? Color(red: 0.13, green: 0.13, blue: 0.13) : Color.white)
            let host = FrameHostingView(rootView: AnyView(view))
            window.contentView = host
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            expect(host.bounds.size == ModelPickerLayout.modelSize && host.bounds.width < 620 && host.bounds.height < 500,
                   "The clean model picker fits its smaller bounded viewport")
            guard let viewport = descendants(host).compactMap({ $0 as? NSScrollView }).max(by: { $0.bounds.width < $1.bounds.width }) else {
                fatalError("The model viewport must expose its native scroll view")
            }
            let visibleFrame = host.convert(viewport.bounds, from: viewport)
            expect(visibleFrame.minX >= -0.5 && visibleFrame.maxX <= host.bounds.maxX + 0.5,
                   "The model viewport fits inside the panel without pushing its rail or trailing selection out of bounds")
            expect((viewport.documentView?.bounds.width ?? .infinity) <= viewport.contentView.bounds.width + 0.5,
                   "Model rows have no horizontal document overflow at the compact panel size")
            expect(store.snapshot == nil && !store.isLoading, "Opening the model selector never acquires usage or starts account reads")
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: output.appendingPathComponent(name + ".png")) }
            }
            window.contentView = nil
            window.close()
        }
    }

    @MainActor static func main() async throws {
        guard CaptureRun.isEnabled, let output = CaptureRun.outputDirectory else { fatalError("Require isolated capture storage") }
        _ = NSApplication.shared
        await LoginEnvironment.load()
        try projection()
        scrolling()
        let model = AppModel()
        model.settings.setBinaryPath("/usr/bin/true", for: .omp)
        try await coldPicker(model, output: output)
        let store = try await leases(model)
        try await nativeReader(output)
        try await picture(model, store: store, output: output)
        print("Provider usage checks passed: \(checks)")
    }
}
