import AppKit
import CoreGraphics
import ImageIO
import QuartzCore

private struct PreviewOpeningFailure: Error, CustomStringConvertible {
    var description: String
}

@MainActor private final class PreviewOpeningProbe {
    var frames: [PreviewImageDecoder.Decoded] = []
    var firstTime: TimeInterval?
    var task: Task<PreviewImageDecoder.Decoded?, Never>?
    var cancelsAfterFirst = false

    func receive(_ decoded: PreviewImageDecoder.Decoded) {
        frames.append(decoded)
        firstTime = firstTime ?? CACurrentMediaTime()
        if cancelsAfterFirst { task?.cancel() }
    }
}

@MainActor enum PreviewOpeningChecks {
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw PreviewOpeningFailure(description: message) }
    }

    private static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            try expect(ContinuousClock.now < deadline, "The native first-frame check did not finish")
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func hasSpinner(_ view: NSView) -> Bool {
        view is NSProgressIndicator || view.subviews.contains(where: hasSpinner)
    }

    private static func writeImage(_ url: URL) throws {
        guard let context = CGContext(data: nil, width: 4_000, height: 2_000, bitsPerComponent: 8,
                                      bytesPerRow: 4_000 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw PreviewOpeningFailure(description: "The progressive image fixture could not be created")
        }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4_000, height: 2_000))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        try expect(CGImageDestinationFinalize(destination), "The progressive JPEG fixture was not saved")
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omp-preview-first-frame-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("large.jpg")
        try writeImage(url)

        let probe = PreviewOpeningProbe()
        let start = CACurrentMediaTime()
        let final = await PreviewImageDecoder.load(url: url, maximumDimension: 3_072) { probe.receive($0) }
        guard let first = probe.frames.first, let final, let firstTime = probe.firstTime else {
            throw PreviewOpeningFailure(description: "The image did not publish its first frame before full decoding")
        }
        try expect(probe.frames.count == 1 && max(first.image.width, first.image.height) <= 768,
                   "The image's first frame did not stay within its lightweight pixel budget")
        try expect(max(final.image.width, final.image.height) <= 3_072 && final.image.width > first.image.width,
                   "The image did not upgrade clarity within the final pixel budget")
        try expect(first.originalSize == CGSize(width: 4_000, height: 2_000) && final.originalSize == first.originalSize,
                   "Progressive pixels changed the original image coordinates")
        try expect(firstTime - start < 1, "The representative image first frame took more than one second")

        let canceled = PreviewOpeningProbe()
        canceled.cancelsAfterFirst = true
        canceled.task = Task {
            await PreviewImageDecoder.load(url: url, maximumDimension: 3_072) { canceled.receive($0) }
        }
        let canceledResult = await canceled.task!.value
        canceled.task = nil
        try expect(canceled.frames.count == 1 && canceledResult == nil,
                   "Canceling after the first frame published stale high-resolution pixels")

        let host = PreviewImageHost()
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        let state = PreviewReaderState()
        state.imageScale = 1
        host.update(url: url, revision: "first-frame", state: state, requestedScale: 1)
        defer { host.tearDown() }
        let scroll = host.subviews.compactMap { $0 as? NSScrollView }.first!
        try await until {
            host.layoutSubtreeIfNeeded()
            return scroll.documentView?.frame.width == 4_000
        }
        let requested = NSPoint(x: 180, y: 120)
        scroll.contentView.scroll(to: requested)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await until {
            host.controls.display.detailHelp.contains("3072")
        }
        host.layoutSubtreeIfNeeded()
        try expect(state.imageScale == 1 && abs(scroll.contentView.bounds.origin.x - requested.x) < 1
                   && abs(scroll.contentView.bounds.origin.y - requested.y) < 1,
                   "The clarity upgrade reset the image's zoom or scrolling")
        let pdf = PreviewPDFHost()
        defer { pdf.tearDown() }
        try expect(!hasSpinner(host) && !hasSpinner(pdf), "A native preview still contains a loading spinner")
        try expect(NSApp?.windows.contains(where: \.isVisible) != true, "First-frame checks presented a window")
        print(String(format: "Opening checks: 4000×2000 JPEG first pixels %.1f ms; bounded clarity upgrade, cancellation, stable image viewport and spinner-free native hosts passed",
                     (firstTime - start) * 1_000))
    }
}
