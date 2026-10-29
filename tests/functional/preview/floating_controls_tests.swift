import AppKit
import AVKit
import CoreGraphics
import Observation
import PDFKit
import SwiftUI

private struct PreviewFloatingControlsFailure: Error, CustomStringConvertible {
    var description: String
}

@MainActor private final class PreviewControlObservationProbe { var changed = false }

private struct PreviewImageControlProbe: View {
    let url: URL
    let state: PreviewReaderState
    var body: some View {
        PreviewImageRenderer(url: url, revision: "controls", state: state, scale: state.imageScale)
    }
}

private struct PreviewPDFControlProbe: View {
    let url: URL
    let state: PreviewReaderState
    var body: some View {
        PreviewPDFRenderer(url: url, revision: "controls", state: state, findRequest: state.findRequest)
    }
}

/// Exercise actual SwiftUI overlays and native readers without creating a window.
@MainActor enum PreviewFloatingControlsChecks {
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw PreviewFloatingControlsFailure(description: message) }
    }

    private static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            try expect(ContinuousClock.now < deadline, "The floating control check did not finish")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        for child in view.subviews {
            if let result = find(type, in: child) { return result }
        }
        return nil
    }

    private static func controlAreas(in view: NSView, native: NSView) -> [NSRect] {
        if view is NoWindowDragView { return [view.convert(view.bounds, to: native)] }
        return view.subviews.flatMap { controlAreas(in: $0, native: native) }
    }

    private static func checkControlAreas(_ pane: NSView, native: NSView) async throws {
        // NSHostingView's event graph requires a window. Check the actual native
        // control footprints offscreen, without creating an application window.
        try await until { pane.layoutSubtreeIfNeeded(); return !controlAreas(in: pane, native: native).isEmpty }
        let areas = controlAreas(in: pane, native: native)
        let outside = NSPoint(x: 5, y: 28)
        let inside = NSPoint(x: native.bounds.midX, y: 28)
        try expect(!areas.contains { $0.contains(outside) }, "Transparent space beside the capsule acquired a native control hit area")
        try expect(areas.contains { $0.contains(inside) }, "The floating capsule does not overlay the bottom of native content")
        try expect(areas.allSatisfy { $0.minX >= 0 && $0.maxX <= native.bounds.width && $0.minY >= 11 && $0.maxY <= 45 },
                   "Floating controls are clipped or occupy more than their bottom capsule")
    }

    private static func checkBottomReachability(_ scroll: NSScrollView, native: NSView) throws {
        guard let document = scroll.documentView else {
            throw PreviewFloatingControlsFailure(description: "The reader has no native document viewport")
        }
        let clip = scroll.contentView
        let origin = clip.bounds.origin
        let bottom = document.isFlipped ? document.bounds.maxY : document.bounds.minY
        let end = document.isFlipped ? document.bounds.maxY + 100 : document.bounds.minY - clip.bounds.height - 100
        let proposed = NSRect(x: origin.x, y: end, width: clip.bounds.width, height: clip.bounds.height)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(clip)
        let point = document.convert(NSPoint(x: document.bounds.midX, y: bottom), to: native)
        try expect(point.y >= PreviewFloatingControls.bottomClearance - 1,
                   "The document's bottom cannot scroll above the floating controls")
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    static func run() async throws {
        try checkOwnership()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omp-preview-controls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600, bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0), let bytes = pixels.bitmapData else {
            throw PreviewFloatingControlsFailure(description: "The control image fixture could not be created")
        }
        memset(bytes, 0, pixels.bytesPerRow * pixels.pixelsHigh)
        let png = pixels.representation(using: .png, properties: [:])!
        let imageURL = root.appendingPathComponent("controls.png")
        try png.write(to: imageURL)
        try await checkImage(imageURL)
        let pdfURL = root.appendingPathComponent("controls.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 700)
        guard let consumer = CGDataConsumer(url: pdfURL as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw PreviewFloatingControlsFailure(description: "The control PDF fixture could not be created")
        }
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0.8, alpha: 1))
            context.fill(box.insetBy(dx: 20, dy: 20))
            context.endPDFPage()
        }
        context.closePDF()
        try await checkPDF(pdfURL)
        let media = PreviewMediaHost()
        media.frame = NSRect(x: 0, y: 0, width: 260, height: 320)
        media.layoutSubtreeIfNeeded()
        defer { media.tearDown() }
        let player = find(AVPlayerView.self, in: media)
        try expect(player?.controlsStyle == .floating && player?.frame == media.bounds,
                   "Media controls still reserve an inline bottom row")
        try expect(NSApp?.windows.contains(where: \.isVisible) != true, "Floating control checks presented a window")
        print("Floating control checks: full native viewports, capsule-only control areas, readable document ends, stable image/PDF hosts, transparent PDF margins/page gaps/overscroll, zoom/fit/page/search, ownership cleanup and native floating media passed")
    }

    private static func checkOwnership() throws {
        let model = PreviewFloatingControlsModel(kind: .image)
        let old = NSView(), new = NSView()
        var oldActions = 0, newActions = 0
        model.bind(to: old) { _ in oldActions += 1 }
        let ready = PreviewFloatingControlsModel.Display(isAvailable: true, status: "100%", canZoomOut: true, canZoomIn: true)
        model.publish(ready, from: old)
        let observation = PreviewControlObservationProbe()
        withObservationTracking { _ = model.display } onChange: { @Sendable in
            // The callback can run on the publishing actor, but its API is Sendable.
            MainActor.assumeIsolated { observation.changed = true }
        }
        model.publish(ready, from: old)
        try expect(!observation.changed, "Unchanged control state schedules another SwiftUI update")
        model.perform(.zoomIn)
        try expect(oldActions == 1, "Available controls did not dispatch their native action")
        model.bind(to: new) { _ in newActions += 1 }
        model.publish(ready, from: new)
        model.release(from: old)
        model.reset(from: old)
        model.perform(.zoomIn)
        try expect(model.display == ready && newActions == 1 && oldActions == 1,
                   "An old native host cleared or modified a newer control binding")
        model.release(from: new)
        model.perform(.zoomIn)
        try expect(!model.display.isAvailable && newActions == 1, "Torn-down controls retained a native action")
    }

    private static func checkImage(_ url: URL) async throws {
        let state = PreviewReaderState()
        let pane = FrameHostingView(rootView: AnyView(PreviewImageControlProbe(url: url, state: state)))
        pane.frame = NSRect(x: 0, y: 0, width: 260, height: 320)
        let container = NSView(frame: pane.frame)
        container.addSubview(pane)
        defer { pane.rootView = AnyView(Color.clear); pane.layoutSubtreeIfNeeded() }
        try await until {
            pane.layoutSubtreeIfNeeded()
            return find(PreviewImageHost.self, in: pane)?.controls.display.isAvailable == true
        }
        let host = find(PreviewImageHost.self, in: pane)!
        let scroll = find(NSScrollView.self, in: host)!
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw PreviewFloatingControlsFailure(description: "The image canvas could not be captured")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try expect((bitmap.colorAt(x: 5, y: 5)?.alphaComponent ?? 1) < 0.05,
                   "Transparent image pixels or margins obscured the shared backdrop")
        try expect(host.bounds.size == pane.bounds.size && scroll.frame == host.bounds,
                   "The image reader still reserves a bottom controls row")
        try await checkControlAreas(pane, native: host)
        let model = host.controls
        model.perform(.zoomIn)
        try await until { pane.layoutSubtreeIfNeeded(); return !model.display.isFitActive && state.imageScale > 0 }
        model.perform(.actualSize)
        try await until { pane.layoutSubtreeIfNeeded(); return model.display.isActualSizeActive && model.display.status == "100%" }
        try expect(scroll.contentView.frame.height == host.bounds.height, "Image bottom insets shrink the content viewport")
        try checkBottomReachability(scroll, native: host)
        model.perform(.fit)
        try await until { pane.layoutSubtreeIfNeeded(); return model.display.isFitActive && state.imageScale == 0 }
        try expect(find(PreviewImageHost.self, in: pane) === host && host.controls === model,
                   "Image control updates recreated the native reader or its decoded pixels")
        pane.rootView = AnyView(Color.clear)
        pane.layoutSubtreeIfNeeded()
        try await until { !model.display.isAvailable }
    }

    private static func checkPDF(_ url: URL) async throws {
        let state = PreviewReaderState()
        let pane = FrameHostingView(rootView: AnyView(PreviewPDFControlProbe(url: url, state: state)))
        pane.frame = NSRect(x: 0, y: 0, width: 260, height: 320)
        let container = NSView(frame: pane.frame)
        container.addSubview(pane)
        defer { pane.rootView = AnyView(Color.clear); pane.layoutSubtreeIfNeeded() }
        try await until {
            pane.layoutSubtreeIfNeeded()
            return find(PreviewPDFHost.self, in: pane)?.controls.display.isAvailable == true
        }
        let host = find(PreviewPDFHost.self, in: pane)!
        let pdf = find(PDFView.self, in: host)!
        try expect(pdf.backgroundColor.alphaComponent == 0, "The PDF canvas obscured the shared backdrop")
        try expect(host.bounds.size == pane.bounds.size && pdf.frame == host.bounds,
                   "The PDF reader still reserves a bottom controls row")
        let scroll = pdf.documentView!.enclosingScrollView!
        let bottomInset = scroll.contentInsets.bottom
        try expect(bottomInset >= PreviewFloatingControls.bottomClearance && scroll.contentView.frame.height == pdf.bounds.height,
                   "PDF bottom insets shrink the content viewport: bottom=\(bottomInset), clip=\(scroll.contentView.frame), PDF=\(pdf.bounds)")
        try checkBottomReachability(scroll, native: host)
        try await checkControlAreas(pane, native: host)
        pane.setFrameSize(NSSize(width: 210, height: 320))
        pane.layoutSubtreeIfNeeded()
        try await checkControlAreas(pane, native: host)
        try expect(pdf.frame == host.bounds, "Narrow PDF controls shrink the native content viewport")
        for _ in 0..<3 { host.needsLayout = true; host.layoutSubtreeIfNeeded() }
        try expect(scroll.contentInsets.bottom == bottomInset, "PDF layout accumulates bottom scroll insets")
        let model = host.controls
        try expect(model.display.canGoForward && !model.display.canGoBack, "First-page navigation does not reflect native PDF state")
        model.perform(.nextPage)
        try await until { model.display.status == "2 / 3" }
        model.perform(.previousPage)
        try await until { model.display.status == "1 / 3" }
        model.perform(.zoomIn)
        try expect(!pdf.autoScales && !model.display.isFitActive, "PDF zoom does not update the floating fit state")
        model.perform(.fit)
        try expect(pdf.autoScales && model.display.isFitActive, "PDF fit does not restore native scaling")
        state.findRequest += 1
        try await until {
            pane.layoutSubtreeIfNeeded()
            return abs(pdf.frame.height - (host.bounds.height - 34)) < 0.1
        }
        try expect(pdf.frame.minY == 0 && find(PreviewPDFHost.self, in: pane) === host && host.controls === model,
                   "PDF search or control state replaced its host or recreated a bottom row")
        model.perform(.nextPage)
        model.perform(.nextPage)
        try await until { model.display.status == "3 / 3" }
        let oldDocument = pdf.document!
        let nextState = PreviewReaderState()
        pane.rootView = AnyView(PreviewPDFControlProbe(url: url, state: nextState))
        try await until {
            pane.layoutSubtreeIfNeeded()
            return pdf.document != nil && pdf.document !== oldDocument && model.display.isAvailable
        }
        try expect(nextState.pdfPage == 0 && model.display.status == "1 / 3",
                   "Removing the old scroll inset overwrote the replacement reader's saved page")
        try checkPDFBackground(pdf)
        pane.rootView = AnyView(Color.clear)
        pane.layoutSubtreeIfNeeded()
        try await until { !model.display.isAvailable && pdf.document == nil }
    }

    private static func checkPDFBackground(_ pdf: PDFView) throws {
        pdf.autoScales = false
        pdf.scaleFactor = 0.35
        pdf.layoutDocumentView()
        pdf.layoutSubtreeIfNeeded()
        let document = pdf.documentView!, scroll = document.enclosingScrollView!, clip = scroll.contentView
        let origin = clip.bounds.origin
        let appearance = pdf.appearance
        defer { clip.scroll(to: origin); pdf.appearance = appearance }

        func capture() throws -> NSBitmapImageRep {
            guard let bitmap = pdf.bitmapImageRepForCachingDisplay(in: pdf.bounds) else {
                throw PreviewFloatingControlsFailure(description: "The PDF canvas could not be captured")
            }
            pdf.cacheDisplay(in: pdf.bounds, to: bitmap)
            return bitmap
        }
        func color(at point: NSPoint, in bitmap: NSBitmapImageRep) -> NSColor? {
            guard pdf.bounds.contains(point) else { return nil }
            let x = Int((point.x - pdf.bounds.minX) * CGFloat(bitmap.pixelsWide) / pdf.bounds.width)
            let y = pdf.isFlipped ? point.y - pdf.bounds.minY : pdf.bounds.maxY - point.y
            return bitmap.colorAt(x: x, y: Int(y * CGFloat(bitmap.pixelsHigh) / pdf.bounds.height))?.usingColorSpace(.deviceRGB)
        }
        func transparent(_ point: NSPoint, in bitmap: NSBitmapImageRep, area: String) throws {
            let actual = color(at: point, in: bitmap)
            try expect(actual.map { $0.alphaComponent < 0.05 } == true,
                       "PDF \(area) obscured the shared backdrop in \(pdf.effectiveAppearance.name.rawValue): \(String(describing: actual))")
        }

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            pdf.appearance = NSAppearance(named: name)
            pdf.go(to: pdf.document!.page(at: 0)!)
            pdf.layoutSubtreeIfNeeded()
            let first = pdf.convert(pdf.document!.page(at: 0)!.bounds(for: pdf.displayBox), from: pdf.document!.page(at: 0)!)
            let second = pdf.convert(pdf.document!.page(at: 1)!.bounds(for: pdf.displayBox), from: pdf.document!.page(at: 1)!)
            let gapY = first.midY > second.midY ? (first.minY + second.maxY) / 2 : (first.maxY + second.minY) / 2
            let bitmap = try capture()
            try transparent(NSPoint(x: 5, y: pdf.bounds.midY), in: bitmap, area: "side margin")
            try transparent(NSPoint(x: first.midX, y: gapY), in: bitmap, area: "page gap")
            let pageColor = color(at: NSPoint(x: first.midX, y: first.midY), in: bitmap)
            try expect(pageColor.map { $0.alphaComponent > 0.95 && $0.redComponent > 0.5 && $0.redComponent < 0.95 } == true,
                       "Clearing the PDF canvas also removed or recolored page content")

            // Move the native clip beyond either document edge, as during a
            // rubber-band gesture. Its exposed canvas must stay transparent.
            for top in [true, false] {
                let low = top == document.isFlipped
                let y = low ? document.bounds.minY - 200 : document.bounds.maxY - clip.bounds.height + 200
                clip.scroll(to: NSPoint(x: origin.x, y: y))
                let sampleY = (top != pdf.isFlipped) ? pdf.bounds.maxY - 10 : pdf.bounds.minY + 10
                try transparent(NSPoint(x: pdf.bounds.midX, y: sampleY), in: capture(), area: top ? "top overscroll" : "bottom overscroll")
            }
        }
    }
}
