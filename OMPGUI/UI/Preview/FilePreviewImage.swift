import AppKit
import ImageIO
import SwiftUI

enum PreviewImageDecoder {
    static let firstFrameDimension = 768
    struct Decoded: @unchecked Sendable {
        let image: CGImage
        let originalSize: CGSize
    }

    static func load(url: URL, maximumDimension: Int,
                     onFirstFrame: (@MainActor @Sendable (Decoded) -> Void)? = nil) async -> Decoded? {
        let work = Task.detached(priority: .userInitiated) {
            await decode(url: url, maximumDimension: maximumDimension, onFirstFrame: onFirstFrame)
        }
        return await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
    }

    private static func decode(url: URL, maximumDimension: Int,
                               onFirstFrame: (@MainActor @Sendable (Decoded) -> Void)?) async -> Decoded? {
        guard !Task.isCancelled, url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let originalSize = CGSize(width: rotated ? height.doubleValue : width.doubleValue,
                                  height: rotated ? width.doubleValue : height.doubleValue)
        func thumbnail(_ dimension: Int) -> CGImage? {
            guard !Task.isCancelled else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, dimension),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        // Decode the visible first frame before the larger inspection image.
        // Both passes use one ImageIO source; only the active host keeps pixels.
        if let onFirstFrame, maximumDimension > firstFrameDimension,
           max(originalSize.width, originalSize.height) > CGFloat(firstFrameDimension),
           let first = thumbnail(firstFrameDimension), !Task.isCancelled {
            await onFirstFrame(Decoded(image: first, originalSize: originalSize))
        }
        guard let image = thumbnail(maximumDimension), !Task.isCancelled else { return nil }
        return Decoded(image: image, originalSize: originalSize)
    }
}

struct PreviewImageRenderer: View {
    let url: URL
    let revision: String
    let state: PreviewReaderState
    let scale: Double
    @State private var controls = PreviewFloatingControlsModel(kind: .image)

    var body: some View {
        PreviewImageSurface(url: url, revision: revision, state: state, scale: scale, controls: controls)
            .overlay(alignment: .bottom) {
                PreviewFloatingControls(model: controls)
                    .padding(.horizontal, PreviewFloatingControls.edgeInset)
                    .padding(.bottom, PreviewFloatingControls.edgeInset)
            }
    }
}

private struct PreviewImageSurface: NSViewRepresentable {
    let url: URL
    let revision: String
    let state: PreviewReaderState
    let scale: Double
    let controls: PreviewFloatingControlsModel

    func makeNSView(context: Context) -> PreviewImageHost {
        let view = PreviewImageHost()
        view.attachControls(controls)
        return view
    }
    func updateNSView(_ view: PreviewImageHost, context: Context) {
        view.update(url: url, revision: revision, state: state, requestedScale: scale)
    }
    static func dismantleNSView(_ view: PreviewImageHost, coordinator: ()) { view.tearDown() }
}

@MainActor
final class PreviewImageHost: NSView {
    private let scroll = NSScrollView()
    private let canvas = PreviewImageCanvas()
    private let status = NSTextField(labelWithString: "")
    private(set) var controls = PreviewFloatingControlsModel(kind: .image)
    private var detailHelp = ""
    private var state: PreviewReaderState?
    private var originalSize = NSSize.zero
    private var scale: CGFloat = 1
    private var requestedScale: Double = 0
    private var revisionKey = ""
    private var work: Task<Void, Never>?
    private var generation = 0
    private var restoring = false
    private var restoreOnLayout = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        // Extend the scroll range past the image, while keeping the clip view
        // full size, so its bottom pixels can move above the floating capsule.
        scroll.contentInsets.bottom = PreviewFloatingControls.bottomClearance
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.contentView.drawsBackground = false
        scroll.documentView = canvas
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        addSubview(scroll)
        status.font = .systemFont(ofSize: 13)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.isHidden = true
        addSubview(status)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Chrome.localized("Image preview"))
        bindControls()
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    func attachControls(_ controls: PreviewFloatingControlsModel) {
        guard self.controls !== controls else { return }
        self.controls.release(from: self)
        self.controls = controls
        bindControls()
    }

    private func bindControls() {
        controls.bind(to: self) { [weak self] action in
            switch action {
            case .zoomOut: self?.zoomOut()
            case .fit: self?.fit()
            case .actualSize: self?.actualSize()
            case .zoomIn: self?.zoomIn()
            case .previousPage, .nextPage: break
            }
        }
        if originalSize.width > 0 { updateControls() }
    }

    func update(url: URL, revision: String, state: PreviewReaderState, requestedScale: Double) {
        let replacing = self.state !== state
        if replacing { savePosition() }
        self.state = state
        let key = url.path + "\n" + revision
        if key != revisionKey || replacing {
            if !replacing { savePosition() }
            revisionKey = key
            self.requestedScale = requestedScale
            generation += 1
            work?.cancel()
            let currentGeneration = generation
            canvas.image = nil
            originalSize = .zero
            status.isHidden = true
            detailHelp = ""
            controls.reset(from: self)
            work = Task { [weak self] in
                // A single visible image consumes at most ~36 MiB of decoded
                // pixels. Huge camera images never decode at their full size.
                let decoded = await PreviewImageDecoder.load(url: url, maximumDimension: 3_072) { [weak self] first in
                    guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                    self.display(first)
                }
                guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                guard let decoded else {
                    if self.canvas.image != nil { return }
                    self.status.stringValue = Chrome.localized("Unable to preview image")
                    self.status.isHidden = false
                    return
                }
                self.display(decoded)
            }
        } else if self.requestedScale != requestedScale {
            changeScale(to: requestedScale)
        }
    }

    private func display(_ decoded: PreviewImageDecoder.Decoded) {
        let isFirstFrame = canvas.image == nil
        originalSize = decoded.originalSize
        canvas.image = NSImage(cgImage: decoded.image, size: decoded.originalSize)
        canvas.setAccessibilityLabel(String(format: Chrome.localized("Image: %d × %d pixels"), Int(decoded.originalSize.width), Int(decoded.originalSize.height)))
        detailHelp = String(format: Chrome.localized("Preview resolution: %d × %d pixels"), decoded.image.width, decoded.image.height)
        if isFirstFrame {
            restoring = true
            restoreOnLayout = true
            needsLayout = true
        } else {
            updateControls()
        }
        // A clarity upgrade replaces pixels without resetting the user's zoom
        // or scroll position, even if they interacted with the first frame.
        canvas.needsDisplay = true
    }

    override func layout() {
        super.layout()
        if scroll.frame != bounds { scroll.frame = bounds }
        status.frame = NSRect(x: 10, y: max(0, bounds.midY - 12), width: max(0, bounds.width - 20), height: 24)
        guard originalSize.width > 0, originalSize.height > 0 else { return }
        configureCanvas()
        if restoreOnLayout {
            restoreOnLayout = false
            let x = state?.imageX ?? 0, y = state?.imageY ?? 0
            scrollTo(NSPoint(x: x.isFinite ? x : 0, y: y.isFinite ? y : 0))
            restoring = false
            savePosition()
        }
    }

    private func configureCanvas() {
        let viewport = scroll.contentSize
        scale = requestedScale > 0 ? requestedScale : min(1, min(max(1, viewport.width - 20) / originalSize.width, max(1, viewport.height - 20) / originalSize.height))
        state?.imageCurrentScale = scale
        let size = NSSize(width: originalSize.width * scale, height: originalSize.height * scale)
        canvas.frame = NSRect(origin: .zero, size: NSSize(width: max(viewport.width, size.width), height: max(viewport.height, size.height)))
        canvas.imageRect = NSRect(x: (canvas.bounds.width - size.width) / 2, y: (canvas.bounds.height - size.height) / 2, width: size.width, height: size.height)
        updateControls()
        canvas.needsDisplay = true
    }

    private func updateControls() {
        controls.publish(.init(isAvailable: true, status: String(format: "%.0f%%", scale * 100), detailHelp: detailHelp,
                               isFitActive: requestedScale == 0, isActualSizeActive: requestedScale == 1,
                               canZoomOut: scale > 1.0 / 64, canZoomIn: scale < 16), from: self)
    }

    private func changeScale(to requested: Double) {
        guard originalSize.width > 0 else { requestedScale = requested; return }
        let viewportCenter = NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY)
        let imageCenter = NSPoint(x: (viewportCenter.x - canvas.imageRect.minX) / scale,
                                  y: (viewportCenter.y - canvas.imageRect.minY) / scale)
        requestedScale = requested
        restoring = true
        configureCanvas()
        let viewport = scroll.contentSize
        scrollTo(requested == 0 ? .zero : NSPoint(x: canvas.imageRect.minX + imageCenter.x * scale - viewport.width / 2,
                                                y: canvas.imageRect.minY + imageCenter.y * scale - viewport.height / 2))
        restoring = false
        savePosition()
    }

    private func scrollTo(_ point: NSPoint) {
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: point, size: scroll.contentView.bounds.size)).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func scrolled() { savePosition() }
    private func savePosition() {
        guard !restoring, originalSize.width > 0, let state else { return }
        state.imageX = scroll.contentView.bounds.origin.x
        state.imageY = scroll.contentView.bounds.origin.y
    }
    @objc private func fit() { state?.resetImageZoom() }
    @objc private func actualSize() { state?.imageScale = 1 }
    @objc private func zoomIn() { state?.stepImageZoom(1) }
    @objc private func zoomOut() { state?.stepImageZoom(-1) }

    override func magnify(with event: NSEvent) { state?.imageScale = min(16, max(1.0 / 64, scale * (1 + event.magnification))) }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "+", "=": zoomIn(); return
            case "-": zoomOut(); return
            case "0": fit(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    func tearDown() {
        savePosition()
        generation += 1
        work?.cancel()
        work = nil
        canvas.image = nil
        state = nil
        controls.release(from: self)
        NotificationCenter.default.removeObserver(self)
    }
}

private final class PreviewImageCanvas: NSView {
    var image: NSImage?
    var imageRect = NSRect.zero
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}
