import AppKit
import SwiftUI
@testable import OMPGUI

@MainActor @Observable
private final class LayoutProbe {
    var height: CGFloat = 120
    @ObservationIgnored var readings: [String] = []
}

private struct RequiredEnvironmentContent: View {
    @Environment(LayoutProbe.self) private var probe
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let language = locale.identifier.replacingOccurrences(of: "_", with: "-")
        probe.readings.append("\(language)|\(colorScheme)|\(controlSize)|\(isEnabled)")
        return Color.clear.frame(height: probe.height)
    }
}

private struct ForegroundMaterialFixture: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.identifier = NSUserInterfaceItemIdentifier("popover.foreground.fixture")
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Keep WindowServer-backed test popovers invisible before their first display.
private final class HiddenPopoverFixtureView: NSView {
    var onWindow: (NSWindow) -> Void = { _ in }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.alphaValue = 0
        onWindow(window)
    }
}

private struct HiddenPopoverFixture: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> HiddenPopoverFixtureView {
        let view = HiddenPopoverFixtureView()
        view.onWindow = onWindow
        return view
    }
    func updateNSView(_ view: HiddenPopoverFixtureView, context: Context) { view.onWindow = onWindow }
}

@MainActor @Observable
private final class PopoverPresentationFixture {
    var isPresented = false
}

@MainActor @Observable
private final class PopoverResizeProbe {
    var expanded = false
}

private struct PopoverResizeContent: View {
    @Environment(PopoverResizeProbe.self) private var probe

    var body: some View {
        PopoverScroll(maxHeight: 320, width: 240, followsContentHeight: true) {
            DisclosureGroup(isExpanded: Binding(get: { probe.expanded }, set: { probe.expanded = $0 })) {
                Color.clear.frame(height: 240)
            } label: {
                Text("Details")
            }
            .padding(12)
        }
        .frame(width: 240)
    }
}

@main
private enum PopoverEnvironmentChecks {
    @MainActor private static var checks = 0

    @MainActor private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }

    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private static func checkMeasurementEnvironment() async throws {
        let probe = LayoutProbe()
        let content = PopoverScroll(maxHeight: 160, minHeight: 20, width: 240) {
            RequiredEnvironmentContent()
        }
        .frame(width: 240)
        .environment(probe)
        .environment(\.locale, Locale(identifier: "zh_Hans"))
        .environment(\.colorScheme, .dark)
        .controlSize(.small)
        .disabled(true)
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        expect(size.width == 240 && size.height == 120, "The first layout must use the inherited model's actual height")
        expect(!probe.readings.isEmpty && probe.readings.allSatisfy { $0 == "zh-Hans|dark|small|false" },
               "Measurement must inherit required objects, locale, appearance and controls: \(probe.readings)")
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        expect(probe.readings.count >= 2 && probe.readings.allSatisfy { $0 == "zh-Hans|dark|small|false" },
               "Mounted content must inherit the same environment as measurement: \(probe.readings)")
        probe.height = 480
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        expect(host.fittingSize.height == 120, "A refresh must retain the popover's opening viewport height")
        guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first,
              let document = scroll.documentView else { preconditionFailure("The popover must mount a native scroller") }
        expect(scroll.frame.height <= 160 && document.frame.height >= 480,
               "Content growing after measurement must remain available inside the bounded scroller")
        probe.height = 600
        let capped = NSHostingView(rootView: content)
        expect(capped.fittingSize.height == 160, "Long content must open at the height cap")
    }

    @MainActor private static func checkPopoverResize() async throws {
        let probe = PopoverResizeProbe()
        var popup: NSWindow?
        let content = PopoverResizeContent()
            .environment(probe)
            .background { HiddenPopoverFixture { popup = $0 } }
        let presentation = PopoverPresentationFixture()
        let anchor = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.alphaValue = 0
        defer { anchor.close() }
        let host = NSHostingController(rootView: Text("Anchor").frame(width: 300, height: 200)
            .chromePopover(isPresented: Binding(get: { presentation.isPresented },
                                                set: { presentation.isPresented = $0 }),
                           arrowEdge: .bottom) { content })
        anchor.contentViewController = host
        anchor.orderBack(nil)
        host.view.frame = anchor.contentLayoutRect
        _ = host.view.fittingSize
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        presentation.isPresented = true
        host.view.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(2)
        while popup == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let popup else { preconditionFailure("The resize fixture must create a real SwiftUI popover") }
        defer { popup.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))
        let initial = popup.frame.height
        probe.expanded = true
        try await Task.sleep(for: .milliseconds(400))
        let grown = popup.frame.height
        probe.expanded = false
        try await Task.sleep(for: .milliseconds(400))
        let shrunk = popup.frame.height
        expect(grown > initial + 80,
               "Expanding disclosure content must grow the popover window: \(initial) -> \(grown)")
        expect(abs(shrunk - initial) < 2,
               "Collapsing disclosure content must restore the fitted popover height: \(initial) -> \(grown) -> \(shrunk)")
    }

    @MainActor private static func checkUsageWithMemory() async {
        let app = AppModel()
        let runtime = app.runtime(for: UUID())
        await runtime.ensureLoaded()
        for enabled in [false, true, false] {
            var memory = app.settings.ompMemory
            memory.enabled = enabled
            await app.changeMemory(memory)
            expect(app.settings.ompMemory.enabled == enabled && app.memoryError == nil,
                   "The isolated memory configuration must complete each on/off transition")
            for known in [false, true] {
                var snapshot = OMPContextSnapshot()
                if known {
                    snapshot.observeState(["autoCompactionEnabled": true, "isCompacting": false,
                                           "contextUsage": ["tokens": 4200, "contextWindow": 128000]])
                }
                runtime.receiveOMPEvent(.ompContext(snapshot))
                let content = PopoverScroll(maxHeight: 520, width: 360) {
                    UsagePanel(runtime: runtime, provider: .omp)
                }
                .environment(app)
                .environment(\.locale, Locale(identifier: "zh_Hans"))
                let host = NSHostingView(rootView: content)
                let size = host.fittingSize
                expect(size.width == 360 && size.height >= 80 && size.height <= 520,
                       "Opening real context controls with memory \(enabled) and known context \(known) must have a bounded layout")
            }
        }
    }

    @MainActor static func main() async throws {
        guard let root = CaptureRun.storageRoot, root.path.contains("/build.noindex/verification/runs/") else {
            preconditionFailure("Require isolated settings and storage")
        }
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await checkPopoverBackdrop()
        try await checkNativePopoverBackgrounds()
        try await checkBadgePopoverPlacement()
        try await checkHeadStepsViewport()
        await checkPluginScopeLayout()
        try await checkSkillSourceScrolling(root: root)
        try await checkMeasurementEnvironment()
        try await checkPopoverResize()
        try await checkPromptEditorViewport(root: root)
        await checkUsageWithMemory()
        print("PASS \(checks) popover checks: fully applied native frost, window-setting independence, native mask/foreground isolation, live performance preference, fitting presentation edges, stable worker steps, content-following disclosure height, plugin scope layout, inherited environment, stable prompt editors, skill source scrolling and context controls across memory on/off")
    }

    @MainActor private static func checkHeadStepsViewport() async throws {
        let model = AppModel()
        let headID = UUID()
        let runtime = model.runtime(for: headID)
        await runtime.ensureLoaded()
        runtime.rehearseTurn(nil)
        func appendSteps(_ range: Range<Int>) {
            for index in range {
                runtime.rehearse(.toolStarted(id: "viewport-step-\(index)", call:
                    ToolCall(kind: index.isMultiple(of: 2) ? .read : .edit, title: "/workspace/step-\(index).swift", status: .completed)))
            }
        }
        appendSteps(0..<2)
        let content = HydraHeadStepsPopover(headID: headID)
            .environment(model).environment(\.chatColumnIsShown, false)
        let host = NSHostingView(rootView: content)
        let initial = host.fittingSize
        expect(initial.width == 440 && initial.height > 100 && initial.height < 520,
               "Worker steps must open at their actual short-content height on the first layout")
        let batch = NSHostingView(rootView: HydraHeadStepsPopover(headID: headID, reservesFullHeight: true)
            .environment(model).environment(\.chatColumnIsShown, false))
        expect(batch.fittingSize == NSSize(width: 440, height: 520),
               "Batch selection must reserve one viewport that also fits a longer worker journal")
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: initial),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        expect(host.fittingSize == initial, "Opening layout must retain the worker steps' measured viewport")
        appendSteps(2..<32)
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        expect(host.fittingSize == initial, "New journal entries must not resize the open steps popover")
        guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first,
              let document = scroll.documentView else { preconditionFailure("Worker steps require a native scroll viewport") }
        expect(document.frame.height > initial.height && scroll.frame.height <= initial.height,
               "Later steps must remain reachable inside the opening viewport")
        let reopened = NSHostingView(rootView: content)
        expect(reopened.fittingSize == NSSize(width: 440, height: 520),
               "Reopening a longer journal must measure its capped height before presentation")
    }

    @MainActor private static func checkBadgePopoverPlacement() async throws {
        let screen = NSRect(x: -1200, y: 100, width: 1200, height: 800)
        let short = NSSize(width: 300, height: 180)
        let tall = NSSize(width: 300, height: 560)
        let middle = NSRect(x: -1100, y: 480, width: 180, height: 40)
        expect(PopoverPlacement.edge(contentSize: short, anchor: middle, visibleFrame: screen, preferred: .maxY) == .maxY,
               "A fitting preferred direction must retain the normal vertical presentation")
        expect(PopoverPlacement.edge(contentSize: short, anchor: middle.offsetBy(dx: 0, dy: 300), visibleFrame: screen, preferred: .maxY) == .minY,
               "A report near the screen top must begin below its anchor")
        expect(PopoverPlacement.edge(contentSize: tall, anchor: middle, visibleFrame: screen, preferred: .maxY) == .maxX,
               "A tall report with insufficient room above and below must start on the right, including negative screen origins")
        expect(PopoverPlacement.edge(contentSize: tall, anchor: middle.offsetBy(dx: 800, dy: 0), visibleFrame: screen, preferred: .maxY) == .minX,
               "A tall report near the right screen edge must start on the left")
        expect(PopoverPlacement.edge(contentSize: NSSize(width: 2000, height: 2000), anchor: middle,
                                     visibleFrame: screen, preferred: .maxY) == .maxY,
               "When no direction fits, AppKit must retain control of the fallback")

        guard let visible = NSScreen.main?.visibleFrame else { preconditionFailure("Require a native screen for hidden popover checks") }
        let anchor = NSWindow(contentRect: NSRect(x: visible.minX + 32, y: visible.midY - 40, width: 180, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.alphaValue = 0
        anchor.contentView = NSHostingView(rootView: Color.clear.frame(width: 180, height: 80))
        anchor.orderBack(nil)
        let coordinator = BadgePopoverCoordinator()
        defer { coordinator.close(); anchor.close() }
        let view = anchor.contentView!
        let anchorRect = anchor.convertToScreen(view.convert(view.bounds, to: nil))
        let size = NSSize(width: min(280, visible.width / 4), height: visible.height * 0.68)
        expect(PopoverPlacement.edge(contentSize: size, relativeTo: view.bounds, of: view,
                                     preferred: view.isFlipped ? .minY : .maxY) == .maxX,
               "The native anchor conversion must choose the fitting side before showing")
        var popup: NSWindow?
        coordinator.setAnchor(view: view)
        coordinator.show(Text("Completed report fixture").frame(width: size.width, height: size.height)
            .background { HiddenPopoverFixture { popup = $0 } })
        try await Task.sleep(for: .milliseconds(40))
        guard let popup else { preconditionFailure("The production badge presenter must create its native container") }
        let initialFrame = popup.frame
        expect(initialFrame.midX > anchorRect.maxX + size.width / 3,
               "The report must open to the right of its anchor")
        try await Task.sleep(for: .milliseconds(250))
        expect(popup.frame == initialFrame, "The opening layout must not resize or reposition the fixed report window")
        expect(popup.alphaValue == 0 && anchor.alphaValue == 0,
               "Placement checks must keep the anchor and popover invisible throughout")
    }

    @MainActor private static func maskAlpha(_ image: NSImage?, x: Int = 4, y: Int = 4) -> CGFloat {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            preconditionFailure("Require an actual native material mask")
        }
        return NSBitmapImageRep(cgImage: cg).colorAt(x: x, y: y)!.alphaComponent
    }

    @MainActor private static func checkPopoverBackdrop() async throws {
        let defaults = CaptureRun.defaults!
        let oldOpacity = defaults.object(forKey: "backdropOpacity")
        let oldPerformance = defaults.object(forKey: "performanceMode")
        defer {
            defaults.set(oldOpacity, forKey: "backdropOpacity")
            defaults.set(oldPerformance, forKey: "performanceMode")
        }
        func style(performance: Bool = false, reduced: Bool = false) -> PopoverBackdropStyle {
            PopoverBackdropStyle(performanceMode: performance, reduceTransparency: reduced)
        }
        let normal = style()
        expect(!normal.isSolid, "Normal popovers must use native frost instead of the solid fallback")
        for fallback in [style(performance: true), style(reduced: true)] {
            expect(fallback.isSolid, "Performance and Reduce Transparency must each request the solid fallback")
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .red
        window.isOpaque = true
        defer { window.close() }
        let frame = NSView(frame: window.contentView!.bounds)
        window.contentView = frame
        let material = NSVisualEffectView(frame: frame.bounds)
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        let mask = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { _ in
            NSColor.white.withAlphaComponent(0.8).setFill()
            NSRect(x: 2, y: 2, width: 4, height: 4).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        material.maskImage = mask
        frame.addSubview(material)
        let content = NSView(frame: frame.bounds)
        material.addSubview(content)
        let controlEffect = NSVisualEffectView(frame: content.bounds)
        controlEffect.material = .menu
        content.addSubview(controlEffect)
        let probe = PopoverBackdropProbe()
        defer { probe.stop() }
        probe.style = normal
        probe.apply(to: window, frame: frame, excluding: content)
        let renderedAlpha = maskAlpha(material.maskImage)
        expect(abs(renderedAlpha - maskAlpha(mask)) < 0.01 && material.material == .popover
               && material.blendingMode == .behindWindow && material.state == .active,
               "Native backdrop blur must retain full coverage so sharp background pixels cannot bypass it")
        expect(maskAlpha(material.maskImage, x: 0, y: 0) == 0 && material.maskImage?.capInsets.top == 2,
               "Native shape masks and their stretch insets must remain intact")
        expect(window.alphaValue == 1 && content.alphaValue == 1 && controlEffect.alphaValue == 1 && controlEffect.maskImage == nil,
               "Background treatment must leave foreground controls and ancestor opacity intact")
        expect(!window.isOpaque && window.backgroundColor.alphaComponent == 0 && content.frame == frame.bounds,
               "The window base must let the material alpha through without changing the content geometry")
        let applied = material.maskImage
        probe.apply(to: window, frame: frame, excluding: content)
        expect(material.maskImage === applied && abs(maskAlpha(material.maskImage) - renderedAlpha) < 0.01,
               "Repeated layout must reuse the same mask instead of compounding transparency")
        probe.style = style(performance: true)
        probe.apply(to: window, frame: frame, excluding: content)
        expect(material.material == .windowBackground && material.blendingMode == .withinWindow && material.state == .inactive,
               "The solid fallback must stop sampling the window behind the popover")
        expect(abs(maskAlpha(material.maskImage) - maskAlpha(mask)) < 0.01,
               "Solid fallbacks must restore full background coverage while preserving the native shape")
        probe.restore()
        expect(material.maskImage === mask && material.material == .popover && material.blendingMode == .behindWindow && material.state == .active,
               "Closing or reusing a native popover must restore its original material")
        expect(window.isOpaque && window.backgroundColor == .red,
               "Restore must release all background and window overrides")

        let glass = NSGlassEffectView(frame: frame.bounds)
        glass.style = .regular
        glass.tintColor = .blue
        material.addSubview(glass, positioned: .below, relativeTo: content)
        probe.style = normal
        probe.apply(to: window, frame: frame, excluding: content)
        expect(maskAlpha(material.maskImage) == 0 && glass.alphaValue == 1 && glass.style == .regular && content.alphaValue == 1,
               "A fully applied regular-glass background must be the single active surface, without fading the blur or foreground")
        probe.restore()
        expect(glass.alphaValue == 1 && glass.style == .regular && glass.tintColor == .blue,
               "Restore must return a native glass background's original alpha, style and tint")

        // Mount the actual SwiftUI root and change preferences while it is alive.
        // This verifies both native hosting and the shared SwiftUI modifier without
        // ordering a window onscreen or showing a popover.
        defaults.set(0, forKey: "backdropOpacity")
        defaults.set(false, forKey: "performanceMode")
        let native = NSVisualEffectView(frame: frame.bounds)
        native.material = .popover
        let host = NSHostingController(rootView: VStack {
            Text("Popover fixture")
            ForegroundMaterialFixture().frame(height: 20)
        }.frame(width: 120, height: 80).popoverChrome())
        window.contentView = native
        host.view.frame = native.bounds
        native.addSubview(host.view)
        host.view.layoutSubtreeIfNeeded()
        func waitFor(_ message: String, _ ready: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while !ready(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            expect(ready(), message)
        }
        try await waitFor("The actual hosted popover root must find and style its native background") { native.maskImage != nil }
        let initial = maskAlpha(native.maskImage, x: 0, y: 0)
        defaults.set(1, forKey: "backdropOpacity")
        try await Task.sleep(for: .milliseconds(60))
        expect(initial == 1 && abs(maskAlpha(native.maskImage, x: 0, y: 0) - initial) < 0.01,
               "Changing the window opacity setting must leave the mounted popover's native frost fully applied")
        defaults.set(true, forKey: "performanceMode")
        try await waitFor("Already mounted popovers must react to performance mode changes") { native.material == .windowBackground }
        expect(host.view.alphaValue == 1 && host.view.frame.size == NSSize(width: 120, height: 80),
               "Live opacity changes must leave foreground opacity and layout intact")
        let foreground = descendants(host.view).compactMap { $0 as? NSVisualEffectView }.first {
            $0.identifier?.rawValue == "popover.foreground.fixture"
        }
        expect(foreground?.maskImage == nil && foreground?.material == .menu && foreground?.alphaValue == 1,
               "The mounted root must exclude actual SwiftUI-hosted control materials from the background treatment")
        for view in descendants(host.view).compactMap({ $0 as? PopoverBackdropProbe }) { view.stop() }
    }

    @MainActor private static func checkNativePopoverBackgrounds() async throws {
        let defaults = CaptureRun.defaults!
        let oldOpacity = defaults.object(forKey: "backdropOpacity")
        let oldPerformance = defaults.object(forKey: "performanceMode")
        defer {
            defaults.set(oldOpacity, forKey: "backdropOpacity")
            defaults.set(oldPerformance, forKey: "performanceMode")
        }
        defaults.set(1, forKey: "backdropOpacity")
        defaults.set(false, forKey: "performanceMode")
        for swiftUI in [false, true] {
            let anchor = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            anchor.isReleasedWhenClosed = false
            anchor.alphaValue = 0
            defer { anchor.close() }
            var popupWindow: NSWindow?
            let body = VStack {
                Text("Native popover fixture").font(.system(size: 24))
                ForegroundMaterialFixture().frame(height: 20)
            }.frame(width: 280, height: 160)
            let popover = NSPopover()
            popover.animates = false
            defer { popover.close() }
            if swiftUI {
                @Bindable var presentation = PopoverPresentationFixture()
                let host = NSHostingController(rootView: Text("Anchor").frame(width: 280, height: 160)
                    .chromePopover(isPresented: $presentation.isPresented, arrowEdge: .bottom) {
                        body.background { HiddenPopoverFixture { popupWindow = $0 } }
                    })
                anchor.contentViewController = host
                anchor.orderBack(nil)
                host.view.frame = anchor.contentLayoutRect
                _ = host.view.fittingSize
                host.view.layoutSubtreeIfNeeded()
                // Match a real trigger: the anchor exists and has completed its
                // opening layout before the presentation binding changes.
                try await Task.sleep(for: .milliseconds(30))
                presentation.isPresented = true
                host.view.layoutSubtreeIfNeeded()
            } else {
                let hidden = HiddenPopoverFixtureView(frame: NSRect(x: 0, y: 0, width: 280, height: 160))
                hidden.onWindow = { popupWindow = $0 }
                let host = NSHostingController(rootView: body.popoverChrome())
                hidden.addSubview(host.view)
                host.view.frame = hidden.bounds
                let controller = NSViewController()
                controller.view = hidden
                controller.addChild(host)
                popover.contentViewController = controller
                popover.contentSize = hidden.frame.size
                anchor.orderBack(nil)
                popover.show(relativeTo: NSRect(x: 20, y: 20, width: 20, height: 20),
                             of: anchor.contentView!, preferredEdge: .maxY)
            }
            let deadline = ContinuousClock.now + .seconds(2)
            while popupWindow == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let popup = popupWindow, let frame = popup.contentView?.superview else {
                preconditionFailure("A real \(swiftUI ? "SwiftUI" : "NSPopover") container must be constructed")
            }
            defer { popup.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(80))
            expect(popup.alphaValue == 0 && anchor.alphaValue == 0,
                   "Native container checks must never display a visible window")
            let views = descendants(frame)
            guard let foreground = views.first(where: { $0.identifier?.rawValue == "popover.foreground.fixture" }) else {
                preconditionFailure("Require the actual presented foreground")
            }
            let backgrounds = views.compactMap { $0 as? NSGlassEffectView }.filter { !foreground.isDescendant(of: $0) }
            expect(!backgrounds.isEmpty, "The actual native popover must exercise its glass background instead of a synthesized material fixture")
            let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            for glass in backgrounds {
                expect(glass.alphaValue == 1 && (reduced || glass.style == .regular),
                       "Actual popovers must fully apply standard frosted glass, preventing clear glass or a faded blur from leaking sharp text")
                expect(reduced || (glass.tintColor?.alphaComponent ?? 0) < 0.8,
                       "The real glass must not gain a near-opaque tint on top of its own material")
            }
            for material in views.compactMap({ $0 as? NSVisualEffectView }) where backgrounds.contains(where: { $0.isDescendant(of: material) }) {
                expect(maskAlpha(material.maskImage, x: 0, y: 0) == 0,
                       "An actual legacy popover frame must not stack a second material behind its glass background")
            }
            var ancestor: NSView? = foreground
            while let view = ancestor {
                expect(view.alphaValue == 1, "The actual presented foreground and all of its view ancestors must stay opaque")
                ancestor = view.superview
            }
            for probe in views.compactMap({ $0 as? PopoverBackdropProbe }) { probe.stop() }
        }
    }

    @MainActor private static func checkPromptEditorViewport(root: URL) async throws {
        let app = AppModel()
        let runtime = app.runtime(for: UUID())
        await runtime.ensureLoaded()
        let edit = PromptEdit(id: UUID(), text: "移除图中红框选中的说明文字。", attachments: (1...2).map {
            Attachment(name: "Image \($0).png", path: root.appendingPathComponent("image-\($0).png").path, mimeType: "image/png")
        })
        let message = PromptEditorViewport(content: MessageEditor(edit: edit, runtime: runtime), maximumHeight: 800)
        expect(message.size.width == 520 && message.size.height > 0 && message.size.height < 350 && !message.needsScrolling,
               "A short sent message with two images must open compactly without a scrollbar: \(message.size)")
        weak var sizingWindow: NSWindow?
        var reportedSizes: [CGSize] = []
        let viewport = PromptEditorViewport(content: FollowUpEditor(edit: edit, runtime: runtime), maximumHeight: 800) { size in
            reportedSizes.append(size)
            Task { @MainActor in sizingWindow?.setContentSize(size) }
        }
        let host = NSHostingView(rootView: viewport.presentedChrome())
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: viewport.size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        sizingWindow = window
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        guard let text = descendants(host).compactMap({ $0 as? ComposerNSTextView }).first,
              let textScroll = text.enclosingScrollView else { preconditionFailure("Require the actual native prompt field") }
        let shortHeight = viewport.size.height
        expect(shortHeight < 350 && !viewport.needsScrolling && textScroll.autohidesScrollers,
               "Fitting contents must keep native autohiding scrollbars and no outer overflow")
        func waitFor(_ message: String, _ ready: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while !ready(), ContinuousClock.now < deadline {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
            expect(ready(), message)
        }
        edit.text = (1...12).map { "Edited line \($0)" }.joined(separator: "\n")
        try await waitFor("An editor below its height cap must grow with actual text") {
            viewport.size.height > shortHeight + 60 && viewport.size.height < 800
        }
        let mediumHeight = viewport.size.height
        expect(!viewport.needsScrolling && text.frame.height <= textScroll.contentView.bounds.height + 1,
               "Medium text must fit without scrolling before the window reaches its cap")
        edit.text = String(repeating: "A longer edited message\n", count: 60)
        try await waitFor("Long text must use the increased 800 pt window limit") { viewport.size.height == 800 }
        host.layoutSubtreeIfNeeded()
        expect(!viewport.needsScrolling && text.frame.height > textScroll.contentView.bounds.height,
               "Only the native text field should scroll once the complete form reaches its maximum height")
        expect(textScroll.frame.height > 500 && textScroll.frame.height < 800,
               "The text field must use the available room while leaving its title, attachments and actions visible")
        edit.text = "Short again"
        edit.attachments = []
        try await waitFor("Deleting text and attachments must shrink the editor back to actual contents") {
            viewport.size.height < shortHeight && viewport.size.height < mediumHeight
        }
        expect(!viewport.needsScrolling && text.frame.height <= textScroll.contentView.bounds.height + 1,
               "Shrinking below the cap must remove the need for scrolling")
        expect(reportedSizes.contains { $0.height == 800 } && reportedSizes.last == viewport.size,
               "Native popover sizing must receive the cap and the later compact size for re-anchoring")

        let probe = LayoutProbe()
        let extra = PromptEditorViewport(content: RequiredEnvironmentContent().environment(probe).frame(width: 520), maximumHeight: 800)
        let overflowHost = NSHostingView(rootView: extra)
        let overflowWindow = NSWindow(contentRect: CGRect(origin: .zero, size: extra.size),
                                      styleMask: .borderless, backing: .buffered, defer: false)
        overflowWindow.isReleasedWhenClosed = false
        overflowWindow.contentView = overflowHost
        defer { overflowWindow.close() }
        probe.height = 1000
        try await waitFor("Non-text contents beyond the cap must enable the outer scrollbar") {
            overflowHost.layoutSubtreeIfNeeded()
            return extra.needsScrolling && extra.size.height == 800
        }
        probe.height = 80
        try await waitFor("The outer scrollbar must disappear and height contract when contents fit again") {
            overflowHost.layoutSubtreeIfNeeded()
            return !extra.needsScrolling && extra.size.height == 80
        }
    }

    @MainActor private static func checkPluginScopeLayout() async {
        let defaults = CaptureRun.defaults!
        let originalPerformanceMode = defaults.object(forKey: "performanceMode")
        defer { defaults.set(originalPerformanceMode, forKey: "performanceMode") }
        let projects = (0..<60).map {
            Project(name: "项目 \($0) " + String(repeating: "long name ", count: 8), path: "/fixture/project-\($0)")
        }
        var selection: UUID? = nil
        let binding = Binding<UUID?>(get: { selection }, set: { selection = $0 })
        for performanceMode in [false, true] {
            defaults.set(performanceMode, forKey: "performanceMode")
            let reload = NSHostingView(rootView: Group {
                if performanceMode {
                    Button("Reload") {}.buttonStyle(.bordered)
                } else {
                    Button("Reload") {}.buttonStyle(.glass)
                }
            }.presentedChrome().controlSize(.small))
            let actionHeight = reload.fittingSize.height
            expect(actionHeight > 0, "The reference settings action must have a native button height")
            for available in [[], projects] {
                for selected in [nil, projects[0].id, UUID()] {
                    selection = selected
                    let picker = OMPPluginScopePicker(projects: available, selection: binding)
                    let trigger = NSHostingView(rootView: picker.presentedChrome().controlSize(.small))
                    let size = trigger.fittingSize
                    expect(size.width <= 220 && abs(size.height - actionHeight) <= 1,
                           "Plugin scope must retain native padding with empty, selected and long project titles (performance mode \(performanceMode)): \(size) vs \(actionHeight)")
                    let options = NSHostingView(rootView: picker.choices.frame(width: 280))
                    for _ in 0..<3 {
                        let menuSize = options.fittingSize
                        options.layoutSubtreeIfNeeded()
                        expect(menuSize.width == 280 && menuSize.height > 0 && menuSize.height <= 460,
                               "Repeatedly laying out empty/long plugin scope lists must stay within the shared popover viewport: \(menuSize)")
                        await Task.yield()
                    }
                    expect(selection == selected, "Preparing scope choices must not select a project or change the active profile")
                }
            }
        }
    }

    @MainActor private static func checkSkillSourceScrolling(root: URL) async throws {
        let file = root.appendingPathComponent("skill-scroll/SKILL.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = (1...140).map { "Skill instruction \($0): " + String(repeating: "example ", count: $0.isMultiple(of: 10) ? 30 : 6) }.joined(separator: "\n")
        try Data(source.utf8).write(to: file)
        let reader = PreviewReaderState()
        let skill = OMPGlobalSkill(name: "scroll-fixture", description: "", filePath: file.path, source: "native:user")
        let host = NSHostingView(rootView: SkillFilePreview(skill: skill, reader: reader).presentedChrome())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func native<T: NSView>(_ type: T.Type) -> T? { descendants(host).compactMap { $0 as? T }.first }
        let deadline = ContinuousClock.now + .seconds(3)
        while native(PreviewMarkdownHost.self) == nil {
            host.layoutSubtreeIfNeeded()
            expect(ContinuousClock.now < deadline, "The real skill preview did not load its Markdown reader")
            try await Task.sleep(for: .milliseconds(10))
        }
        reader.showsSource = true
        while native(PreviewTextHost.self) == nil {
            host.layoutSubtreeIfNeeded()
            expect(ContinuousClock.now < deadline, "Switching the real skill preview did not mount its source reader")
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let text = native(PreviewTextHost.self)!
        expect(text.hasHorizontalScroller && text.reader.isHorizontallyResizable
               && text.reader.textContainer?.widthTracksTextView == false,
               "Skill source must keep long lines intact and provide native horizontal scrolling")
        if let bitmap = text.bitmapImageRepForCachingDisplay(in: text.bounds) {
            text.cacheDisplay(in: text.bounds, to: bitmap)
        }
        for y: CGFloat in [80, 160, 240, 320, 400] {
            let clip = text.contentView
            clip.scroll(to: clip.constrainBoundsRect(NSRect(x: 0, y: y, width: clip.bounds.width, height: clip.bounds.height)).origin)
            text.reflectScrolledClipView(clip)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        host.layoutSubtreeIfNeeded()
        let origin = text.contentView.bounds.origin
        expect(origin.y > 200, "The real skill source must scroll down in a bounded popover: origin \(origin), document \(text.reader.frame), viewport \(text.contentView.bounds)")
        let clip = text.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(x: 160, y: origin.y, width: clip.bounds.width, height: clip.bounds.height)).origin)
        text.reflectScrolledClipView(clip)
        let horizontal = clip.bounds.minX
        expect(horizontal > 40, "Long skill source lines must be reachable by scrolling right")
        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(10))
            _ = host.fittingSize
            host.layoutSubtreeIfNeeded()
            expect(native(PreviewTextHost.self) === text, "Source scrolling must retain the native reader")
            expect(text.contentView.bounds.minY >= origin.y - 1,
                   "The real skill source jumped upward after scrolling: \(origin.y) → \(text.contentView.bounds.minY)")
            expect(abs(clip.bounds.minX - horizontal) <= 1, "Popover layout must preserve horizontal source scrolling")
        }
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY))
        text.reflectScrolledClipView(clip)
        expect(clip.bounds.minX < horizontal - 40, "Skill source must also scroll back to the left")
    }
}
