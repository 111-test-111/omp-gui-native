import AppKit
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// An NSImage crossing from the detached decode work back to the main actor. The picture
/// is fully decoded before it crosses and only ever touched on the main actor after.
private struct DecodedPicture: @unchecked Sendable {
    let image: NSImage
}

/// The window's picked picture: one file kept in the library, handed out decoded,
/// downsampled and optionally softened for the backdrop.
@MainActor @Observable
final class WallpaperStore {
    static let shared = WallpaperStore()

    private enum Key {
        static let softness = "wallpaperSoftness"
        static let file = "wallpaperFile"
    }

    /// One blur context for every render: making one per picture stalls the softness slider.
    /// The context draws from any thread, so it sits outside the main actor.
    nonisolated static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static let acceptedTypes: [UTType] = [.image]

    /// The rendered picture for the backdrop, downsampled and blurred per `softness`.
    /// Nil when no wallpaper is set.
    private(set) var image: NSImage?
    /// True while a picked file is being copied and decoded.
    private(set) var isInstalling = false
    /// A short sentence for the settings card when a pick fails. Nil otherwise.
    private(set) var lastError: String?

    /// How soft the picture renders, 0 crisp to 1 fully blurred. Saved at once, and a
    /// change re-renders: live from the small copy while the slider is dragged and at
    /// full size when the drag ends.
    var softness: Double {
        didSet {
            // Writing the property from its own observer calls the observer again, and an
            // unconditional clamp here recursed until the stack ran out: dragging the
            // softness slider crashed the app. Only write back a value that was really out
            // of range, and let that one extra pass do the saving and the re-render.
            let clamped = min(1, max(0, softness))
            guard clamped == softness else {
                softness = clamped
                return
            }
            defaults.set(softness, forKey: Key.softness)
            scheduleRerender()
        }
    }

    var hasWallpaper: Bool { image != nil || fileURL != nil }

    /// True while the softness slider is being dragged: each change renders live from the
    /// small copy, and the full-size render happens once when the drag ends.
    var isAdjustingSoftness = false {
        didSet {
            guard isAdjustingSoftness != oldValue, fileURL != nil else { return }
            if isAdjustingSoftness {
                renderLive()
            } else {
                liveRequested = nil
                render()
            }
        }
    }

    /// The installed file inside the library. Ignored by observation: views watch `image`.
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private let defaults = CaptureRun.defaults ?? .standard
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    // The live softness render in flight; one at a time, newest value wins.
    @ObservationIgnored private var liveRequested: Double?
    // The downsampled picture the renders start from, unblurred.
    @ObservationIgnored private var baseImage: CGImage?
    // A half-size copy of the same picture, so a drag renders live in half the time.
    @ObservationIgnored private var previewBase: CGImage?

    private init() {
        let stored = defaults.object(forKey: Key.softness) as? Double ?? 0
        softness = min(1, max(0, stored))
        if let name = defaults.string(forKey: Key.file), !name.isEmpty {
            let url = StoragePaths.wallpaperDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                fileURL = url
                render()
            }
        }
    }

    /// True when the URL points at a picture, by its extension or its content type.
    nonisolated static func accepts(_ url: URL) -> Bool {
        if !url.pathExtension.isEmpty,
           let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .image) {
            return true
        }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .image) {
            return true
        }
        return false
    }

    /// Copies a picked picture into the library and renders it. A pick that is not a
    /// picture or cannot be used reports a sentence and leaves the current wallpaper alone.
    func install(from source: URL) {
        guard Self.accepts(source) else {
            lastError = "That is not a picture."
            return
        }
        isInstalling = true
        lastError = nil
        renderTask?.cancel()
        let softness = self.softness
        Task.detached(priority: .userInitiated) { [softness] in
            // The panel hands over a scoped URL, which dies with the panel, so the copy
            // takes its access with it.
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased()
            let destination = StoragePaths.wallpaperDirectory.appendingPathComponent("wallpaper-\(UUID().uuidString).\(ext)")
            do {
                try FileManager.default.createDirectory(at: StoragePaths.wallpaperDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                await WallpaperStore.shared.failInstall()
                return
            }
            guard let decoded = Self.decode(destination, softness: softness) else {
                try? FileManager.default.removeItem(at: destination)
                await WallpaperStore.shared.failInstall()
                return
            }
            await WallpaperStore.shared.finishInstall(file: destination, picture: DecodedPicture(image: decoded))
        }
    }

    /// Drops the wallpaper: the file goes, the backdrop clears, the complaint clears.
    func remove() {
        renderTask?.cancel()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        self.fileURL = nil
        defaults.removeObject(forKey: Key.file)
        withAnimation(.easeOut(duration: 0.25)) {
            image = nil
        }
        lastError = nil
    }

    /// Renders the wallpaper at full size from the installed file: downsample, then blur.
    /// A newer render cancels this one; a cancelled or failed render leaves the picture alone.
    private func render() {
        guard let fileURL else { return }
        let softness = self.softness
        renderTask?.cancel()
        renderTask = Task { [weak self, fileURL, softness] in
            let bases = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?) in
                (Self.thumbnail(fileURL, maxPixel: 3200), Self.thumbnail(fileURL, maxPixel: 1600))
            }.value
            guard let base = bases.0 else { return }
            let rendered = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                softness > 0 ? Self.blurred(base, softness: softness) : base
            }.value
            guard let self, !Task.isCancelled, self.fileURL == fileURL, let rendered else { return }
            self.baseImage = base
            self.previewBase = bases.1
            // Deliberately no animation here: an animated bitmap swap makes the picture flash.
            self.image = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
        }
    }

    private func scheduleRerender() {
        guard fileURL != nil else { return }
        if isAdjustingSoftness {
            renderLive()
        } else {
            render()
        }
    }

    /// Renders the live preview for the current drag: one render at a time, and a softness
    /// that arrives while one is in flight is rendered as soon as it finishes, so a fast
    /// drag never queues work or stalls the slider.
    private func renderLive() {
        guard let previewBase, let baseImage else {
            render()
            return
        }
        liveRequested = softness
        guard liveTask == nil else { return }
        let scale = CGFloat(previewBase.width) / CGFloat(baseImage.width)
        liveTask = Task { [weak self] in
            while let value = self?.takeLiveRequest() {
                let rendered = await Task.detached(priority: .userInitiated) {
                    WallpaperStore.blurred(previewBase, softness: value, radiusScale: scale)
                }.value
                guard let self, let rendered, self.isAdjustingSoftness else { break }
                self.image = NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
            }
            self?.liveTask = nil
        }
    }

    /// The newest softness asked for since the last live render, or nil when the drag is over.
    private func takeLiveRequest() -> Double? {
        guard isAdjustingSoftness, let value = liveRequested else { return nil }
        liveRequested = nil
        return value
    }

    private func finishInstall(file: URL, picture: DecodedPicture) {
        if let previous = fileURL { try? FileManager.default.removeItem(at: previous) }
        fileURL = file
        defaults.set(file.lastPathComponent, forKey: Key.file)
        withAnimation(.spring(duration: 0.45, bounce: 0.2)) {
            image = picture.image
        }
        isInstalling = false
    }

    private func failInstall() {
        isInstalling = false
        lastError = "Could not use that picture."
    }

    /// Downsamples the file to at most `maxPixel` px. Runs anywhere: ImageIO does the work,
    /// and nothing here touches the main actor.
    nonisolated static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Softens the base picture per `softness`, scaled by `radiusScale` so a smaller copy
    /// gets a proportionally smaller radius. Runs anywhere: Core Image does the work.
    nonisolated static func blurred(_ base: CGImage, softness: Double, radiusScale: CGFloat = 1) -> CGImage? {
        let radius = softness * 28 * radiusScale
        guard radius > 0.01 else { return base }
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return base }
        // The blur shrinks opaque edges toward transparent, so the image is clamped first
        // and cropped back to its own extent: the middle softens while the frame stays solid.
        let extent = CGRect(origin: .zero, size: CGSize(width: base.width, height: base.height))
        blur.setValue(CIImage(cgImage: base).clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = blur.outputImage?.cropped(to: extent) else { return nil }
        return ciContext.createCGImage(output, from: extent)
    }

    /// Downsamples the file to at most 3200 px and softens it per `softness`. Runs anywhere:
    /// ImageIO and Core Image do the work, and nothing here touches the main actor.
    nonisolated static func decode(_ url: URL, softness: Double) -> NSImage? {
        guard let base = thumbnail(url, maxPixel: 3200) else { return nil }
        let rendered = softness > 0 ? blurred(base, softness: softness) : base
        guard let rendered else { return nil }
        return NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height))
    }
}
