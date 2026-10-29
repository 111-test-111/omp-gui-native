import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
@testable import OMPGUI

@MainActor
private final class PendingImages {
    var requests: [CheckedContinuation<CGImage?, Never>] = []
    var delivered = 0

    func load(_ path: String, _ size: CGFloat) async -> CGImage? {
        let image = await withCheckedContinuation { requests.append($0) }
        delivered += 1
        return image
    }
}

@main
private enum AttachmentPreviewChecks {
    @MainActor private static var checks = 0

    @MainActor private static func expect(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }

    @MainActor private static func until(_ message: String, _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !ready() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        expect(ready(), message)
    }

    private static func fixture(red: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8, bytesPerRow: 96,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        return context.makeImage()!
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            preconditionFailure("Unable to write isolated image fixture: \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
    }

    @MainActor private static func checkMeasurementAndRendering(root: URL, red: CGImage) async throws {
        let pending = PendingImages()
        let loader = AttachmentPreviewImageLoader(path: root.appendingPathComponent("measured.png").path,
            pointSize: AttachmentLargePreview.imageBounds.width, loadImage: pending.load)
        let attachment = Attachment(name: "Pasted image.png", path: root.appendingPathComponent("measured.png").path,
                                    mimeType: "image/png")
        let slot = CGSize(width: 600, height: 400)
        let content = AttachmentLargePreview(attachment: attachment, imageSize: slot, imageLoader: loader)
            .environment(\.locale, Locale(identifier: "zh_Hans"))
            .frame(width: AttachmentLargePreview.contentWidth)
            .presentedChrome()
        var measuredHeight: CGFloat = 0
        for _ in 0..<3 {
            autoreleasepool {
                let measurement = NSHostingView(rootView: content)
                measuredHeight = measurement.fittingSize.height
            }
        }
        await Task.yield()
        expect(pending.requests.isEmpty, "Measuring and discarding preview hosts must not start image requests")

        // As in the popover, the live host follows temporary measurement hosts.
        // It stays offscreen: decoding must not depend on an appearance callback.
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        expect(size.width == 624 && size.height == measuredHeight, "Measurement and live content must use the same fixed viewport")
        loader.start()
        try await until("Opening must start a decode without mounting an application window") { pending.requests.count == 1 }
        pending.requests[0].resume(returning: red)
        try await until("The live preview must receive its image after measurement") { loader.image === red }
        expect(abs(host.fittingSize.height - measuredHeight) <= 1, "Loading must not resize the panel or change its footer inset")

        let renderer = ImageRenderer(content: content.frame(height: measuredHeight, alignment: .top))
        renderer.scale = 1
        guard let rendered = renderer.cgImage else { preconditionFailure("The production preview must render offscreen") }
        let pixel = NSBitmapImageRep(cgImage: rendered).colorAt(x: 312, y: 212)!.usingColorSpace(.deviceRGB)!
        expect(pixel.redComponent > 0.9 && pixel.blueComponent < 0.1,
               "The production preview must draw the decoded image, rather than retain its spinner")
        write(rendered, to: root.appendingPathComponent("attachment-loaded.png"))
    }

    @MainActor private static func checkCancellationAndReopening(root: URL, red: CGImage, blue: CGImage) async throws {
        let pending = PendingImages()
        let path = root.appendingPathComponent("reopened.png").path
        let old = AttachmentPreviewImageLoader(path: path, pointSize: 600, loadImage: pending.load)
        old.start()
        try await until("The first presentation must start its request") { pending.requests.count == 1 }
        old.cancel()
        let reopened = AttachmentPreviewImageLoader(path: path, pointSize: 600, loadImage: pending.load)
        reopened.start()
        try await until("Reopening the same photo must start a fresh presentation request") { pending.requests.count == 2 }
        pending.requests[1].resume(returning: red)
        try await until("The reopened preview must load while the old decode is pending") { reopened.image === red }
        pending.requests[0].resume(returning: blue)
        try await until("The cancelled decode must finish its controlled response") { pending.delivered == 2 }
        expect(old.image == nil && !old.failed && reopened.image === red,
               "Late pixels from a closed or replaced presentation must not publish into either preview")

        reopened.start()
        try await until("A retry must enter a new request") { pending.requests.count == 3 }
        reopened.start()
        try await until("Replacing a pending retry must keep the new request active") { pending.requests.count == 4 }
        pending.requests[3].resume(returning: blue)
        try await until("The most recent retry must publish its pixels") { reopened.image === blue }
        pending.requests[2].resume(returning: nil)
        try await until("The superseded retry must finish its controlled response") { pending.delivered == 4 }
        expect(reopened.image === blue && !reopened.failed, "A late failure must not replace a newer successful image")
    }

    @MainActor private static func checkDecodeFailureAndRetry(root: URL, red: CGImage) async throws {
        let url = root.appendingPathComponent("retry.png")
        let loader = AttachmentPreviewImageLoader(path: url.path, pointSize: 600)
        loader.start()
        try await until("A missing image must end loading with an explicit failure") { loader.failed }
        try Data("invalid image".utf8).write(to: url)
        loader.start()
        try await until("An undecodable image must also end loading") { loader.failed }
        write(red, to: url)
        loader.start()
        try await until("Retry must decode a repaired file at the same path") { loader.image != nil }
        expect(!loader.failed && loader.image!.width == 24 && loader.image!.height == 16,
               "Failure must not poison the shared thumbnail cache or the next presentation")
        for _ in 0..<3 {
            let reopened = AttachmentPreviewImageLoader(path: url.path, pointSize: 600)
            reopened.start()
            try await until("Repeated presentations must load from the shared cache") { reopened.image != nil }
            expect(reopened.image === loader.image, "The presentation loader must reuse the existing bounded decode cache")
        }
    }

    @MainActor static func main() async throws {
        guard let root = CaptureRun.storageRoot, root.path.contains("/build.noindex/verification/runs/") else {
            preconditionFailure("Require isolated capture storage")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        CaptureRun.defaults!.set(true, forKey: "performanceMode")
        let red = fixture(red: 1, blue: 0), blue = fixture(red: 0, blue: 1)
        try await checkMeasurementAndRendering(root: root, red: red)
        try await checkCancellationAndReopening(root: root, red: red, blue: blue)
        try await checkDecodeFailureAndRetry(root: root, red: red)
        print("PASS \(checks) attachment preview checks: passive measurement, explicit loading, rendered pixels, cancellation, reopening, stale results and failure/retry")
    }
}
