import AppKit
import ImageIO
import SwiftUI
import WebKit

enum PreviewMarkdownDocument {
    // Bound whole-document parsing; never silently omit later images or math.
    static let maximumBytes = 2 * 1024 * 1024
    static func requiresSource(_ source: String) -> Bool {
        guard source.utf8.count <= maximumBytes else { return true }
        var lines = 1
        for byte in source.utf8 where byte == 10 {
            lines += 1
            if lines > 20_000 { return true }
        }
        return false
    }
}

struct PreviewMarkdownRenderer: NSViewRepresentable {
    let url: URL
    let source: String
    let revision: String
    let state: PreviewReaderState
    let findRequest: Int
    let onOpen: (FilePreviewReference, URL) -> Void
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    func makeNSView(context: Context) -> PreviewMarkdownHost { PreviewMarkdownHost() }
    func updateNSView(_ view: PreviewMarkdownHost, context: Context) {
        let openURL = context.environment.openURL
        view.onOpenURL = { openURL($0) }
        _ = CodeHighlighting.shared.theme
        view.updateFonts(revision: AppFont.revision)
        view.updateGlass(performanceMode: performanceMode)
        view.update(url: url, source: source, revision: revision, state: state,
                    findRequest: findRequest, onOpen: onOpen)
    }
    static func dismantleNSView(_ view: PreviewMarkdownHost, coordinator: ()) { view.tearDown() }
}

/// Only bundled code/fonts and explicitly referenced local raster images are
/// served. No server, CDN, filesystem read grant or persistent browser storage.
@MainActor
final class PreviewMarkdownResources: NSObject, WKURLSchemeHandler {
    let root: URL
    var directory: URL?
    var token = ""
    private var work: [ObjectIdentifier: Task<Void, Never>] = [:]
    private(set) var servedPaths: Set<String> = []
    private(set) var failedPaths: Set<String> = []
    init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        let id = ObjectIdentifier(task)
        let root = root, directory = directory, token = token
        work[id] = Task { [weak self] in
            let read = Task.detached(priority: .userInitiated) {
                Self.response(url, root: root, directory: directory, token: token)
            }
            let result = await withTaskCancellationHandler(operation: { await read.value }, onCancel: { read.cancel() })
            guard !Task.isCancelled, let self, self.work.removeValue(forKey: id) != nil else { return }
            guard let (data, mime) = result else {
                if self.failedPaths.count < 64 { self.failedPaths.insert(url.absoluteString) }
                task.didFailWithError(URLError(.resourceUnavailable)); return
            }
            self.servedPaths.insert(url.host == "bundle" ? url.path : "image")
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": mime, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*",
                "Cache-Control": url.host == "bundle" ? "max-age=31536000, immutable" : "no-store",
            ])!
            task.didReceive(response); task.didReceive(data); task.didFinish()
        }
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        work.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }
    func cancel() { for task in work.values { task.cancel() }; work.removeAll(); directory = nil }

    nonisolated private static func response(_ url: URL, root: URL, directory: URL?, token: String) -> (Data, String)? {
        guard !Task.isCancelled, url.scheme == "omp-preview" else { return nil }
        if url.host == "bundle" {
            let file = root.appendingPathComponent(url.path).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.path + "/") else { return nil }
            let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8", "woff2": "font/woff2"]
            guard let mime = types[file.pathExtension], let data = try? Data(contentsOf: file) else { return nil }
            return (data, mime)
        }
        guard url.host == "image", url.path == "/" + token, !token.isEmpty, let directory,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = query.first(where: { $0.name == "path" })?.value, !path.isEmpty else { return nil }
        let file: URL
        if let absolute = URL(string: path), absolute.scheme != nil {
            guard absolute.isFileURL else { return nil }; file = absolute
        } else {
            file = URL(fileURLWithPath: path.removingPercentEncoding ?? path, relativeTo: directory).standardizedFileURL
        }
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              size.isRegularFile == true, let bytes = size.fileSize, bytes <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        if query.contains(where: { $0.name == "info" && $0.value == "1" }) {
            let rotated = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
            let data = try? JSONSerialization.data(withJSONObject: ["width": rotated ? height : width, "height": rotated ? width : height])
            return data.map { ($0, "application/json") }
        }
        // WebKit can decode these already-bounded static formats directly.
        // Preserve their compressed bytes instead of allocating pixels and then
        // PNG-encoding them on every render. Larger/rotated/animated inputs keep
        // the existing thumbnail path and its 2,048-pixel bound.
        if bytes <= 4 * 1024 * 1024, width <= 2048, height <= 2048,
           (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
           let type = CGImageSourceGetType(source) as String?,
           let mime = ["public.png": "image/png", "public.jpeg": "image/jpeg"][type],
           CGImageSourceGetCount(source) == 1,
           !Task.isCancelled, let data = try? Data(contentsOf: file), !Task.isCancelled {
            return (data, mime)
        }
        guard !Task.isCancelled, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), !Task.isCancelled else { return nil }
        return (data as Data, "image/png")
    }
}

@MainActor
private final class PreviewMarkdownMessages: NSObject, WKScriptMessageHandler {
    weak var host: PreviewMarkdownHost?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any] else { return }
        host?.receive(value)
    }
}

/// One view for the visible document. Revisions reuse its process and resources;
/// inactive tabs retain only PreviewReaderState, never a WebView or DOM cache.
@MainActor
final class PreviewMarkdownHost: NSView, WKNavigationDelegate, NSSearchFieldDelegate {
    let web: WKWebView
    let resources: PreviewMarkdownResources
    private let messages = PreviewMarkdownMessages()
    private let search = NSSearchField()
    private lazy var searchSurface = PreviewGlassInputSurface(field: search)
    private let previous = NSButton(), next = NSButton(), close = NSButton()
    private let status = NSTextField(labelWithString: "")
    private var searchVisible = false
    private var state: PreviewReaderState?
    private var url: URL?
    private var onOpen: ((FilePreviewReference, URL) -> Void)?
    var onOpenURL: ((URL) -> Void)?
    private var revisionKey = "", token = ""
    private var job: [String: Any]?
    private var ready = false
    private var tornDown = false
    private let transparentCanvas: Bool
    private var theme: [String: String] = [:]
    private var fontRevision: Int?
    private var fontSize: Int?
    private var fontTheme: [String: String] = [:]
    private var fontFaces = ""
    private var appliedFontFaces = ""
    private var pendingFind: DispatchWorkItem?
    private(set) var renderedToken = ""
    private(set) var renderMilliseconds: Double = 0
    private(set) var formulaCount = 0
    private(set) var formulaErrors = 0

    init(resourceRoot: URL? = nil) {
        let root = resourceRoot ?? Bundle.main.resourceURL!.appendingPathComponent("MarkdownPreview", isDirectory: true)
        resources = PreviewMarkdownResources(root: root)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.setURLSchemeHandler(resources, forURLScheme: "omp-preview")
        config.userContentController.add(messages, name: "preview")
        web = WKWebView(frame: .zero, configuration: config)
        // macOS WKWebView has no public drawsBackground property. WebKit's
        // longstanding KVC switch also clears the web-process base canvas;
        // CSS and underPageBackgroundColor alone leave that canvas opaque.
        // Probe its setter so an SDK change falls back to a readable document.
        // https://bugs.webkit.org/show_bug.cgi?id=221663
        transparentCanvas = web.responds(to: NSSelectorFromString("_setDrawsBackground:"))
        super.init(frame: .zero)
        messages.host = self
        web.navigationDelegate = self
        if transparentCanvas { web.setValue(false, forKey: "drawsBackground") }
        web.underPageBackgroundColor = transparentCanvas ? .clear : resolvedBackgroundColor()
        addSubview(web)
        search.placeholderString = Chrome.localized("Find in preview")
        search.delegate = self
        search.target = self; search.action = #selector(nextResult)
        search.sendsSearchStringImmediately = true
        addSubview(searchSurface)
        for (button, title, symbol, action) in [
            (previous, "Previous match", "chevron.up", #selector(previousResult)),
            (next, "Next match", "chevron.down", #selector(nextResult)),
            (close, "Close search", "xmark", #selector(hideSearch))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: Chrome.localized(title))
            button.toolTip = Chrome.localized(title); button.target = self; button.action = action
            button.bezelStyle = .inline; addSubview(button)
        }
        status.font = .systemFont(ofSize: 13); status.textColor = .secondaryLabelColor
        status.isHidden = true; addSubview(status)
        updateGlass(performanceMode: (CaptureRun.defaults ?? .standard).bool(forKey: "performanceMode"))
        setSearchVisible(false)
        web.load(URLRequest(url: URL(string: "omp-preview://bundle/index.html")!))
    }
    required init?(coder: NSCoder) { nil }

    func update(url: URL, source: String, revision: String, state: PreviewReaderState,
                findRequest: Int, onOpen: @escaping (FilePreviewReference, URL) -> Void) {
        guard !tornDown else { return }
        updateFonts(revision: AppFont.revision)
        let key = url.path + "\n" + revision
        let changed = self.state !== state || key != revisionKey
        if changed { capturePosition() }
        self.state = state; self.url = url; self.onOpen = onOpen
        if changed {
            revisionKey = key; token = UUID().uuidString; renderedToken = ""
            resources.directory = url.deletingLastPathComponent(); resources.token = token
            let saved = state.document
            job = ["source": source, "token": token, "labels": ["metadata": Chrome.localized("Document metadata")],
                   "position": ["x": saved.x.isFinite ? saved.x : 0, "y": saved.y.isFinite ? saved.y : 0,
                                "selectionLocation": saved.selectionLocation, "selectionLength": saved.selectionLength]]
            status.isHidden = true
            if ready { sendDocument() }
        }
        applyTheme()
        if findRequest != state.consumedFindRequest {
            state.consumedFindRequest = findRequest; showFind()
        }
    }

    private func capturePosition() {
        guard ready, let state, !renderedToken.isEmpty else { return }
        let expected = token
        // Capture the outgoing state before submitting the next document; the
        // JavaScript commands are ordered, and this callback owns only the state.
        web.evaluateJavaScript("window.preview.readingPosition()") { value, _ in
            guard let value = value as? [String: Any], value["token"] as? String == expected else { return }
            Self.storePosition(value, in: state)
        }
    }
    private static func storePosition(_ value: [String: Any], in state: PreviewReaderState) {
        guard let x = value["x"] as? Double, let y = value["y"] as? Double, x.isFinite, y.isFinite else { return }
        state.document = .init(x: max(0, x), y: max(0, y),
                               selectionLocation: max(0, value["selectionLocation"] as? Int ?? 0),
                               selectionLength: max(0, value["selectionLength"] as? Int ?? 0))
    }

    private func sendDocument() {
        guard let job else { return }
        self.job = nil
        web.callAsyncJavaScript("window.preview.render(job)", arguments: ["job": job], in: nil, in: .page) { [weak self] result in
            if case .failure = result { self?.showFailure() }
        }
    }

    fileprivate func receive(_ value: [String: Any]) {
        guard !tornDown, let type = value["type"] as? String else { return }
        if type == "ready" { ready = true; applyTheme(force: true); sendDocument(); return }
        if type == "find" { showFind(); return }
        if type == "mathMenu", let latex = value["latex"] as? String {
            let menu = NSMenu()
            let item = NSMenuItem(title: Chrome.localized("Copy LaTeX"), action: #selector(copyMath(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = latex; menu.addItem(item)
            menu.popUp(positioning: nil, at: NSPoint(x: value["x"] as? Double ?? 0, y: web.bounds.height - (value["y"] as? Double ?? 0)), in: web)
            return
        }
        guard value["token"] as? String == token else { return }
        switch type {
        case "position":
            if let state { Self.storePosition(value, in: state) }
        case "rendered":
            renderedToken = token; renderMilliseconds = value["milliseconds"] as? Double ?? 0
            formulaCount = value["formulas"] as? Int ?? 0; formulaErrors = value["errors"] as? Int ?? 0
        case "link": if let href = value["href"] as? String { open(href) }
        case "error": showFailure()
        default: break
        }
    }

    func open(_ href: String) {
        guard let url, let link = URL(string: href) else { return }
        let directory = url.deletingLastPathComponent()
        if href.hasPrefix("#"), href.range(of: "^#L[0-9]+(?:C[0-9]+|-L[0-9]+)?$", options: .regularExpression) != nil {
            onOpen?(FilePreviewReference(path: url.absoluteString + href), directory)
        } else if link.isFileURL || link.scheme == nil {
            onOpen?(FilePreviewReference(path: link.isFileURL ? href : "file:" + href), directory)
        } else if ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") {
            if link.isHTTPWebLink, let onOpenURL { onOpenURL(link) } else { NSWorkspace.shared.open(link) }
        } else if href.range(of: #"^.+:[1-9][0-9]*(?::[1-9][0-9]*)?$"#, options: .regularExpression) != nil, !href.contains("://") {
            onOpen?(FilePreviewReference(path: href), directory)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let initial = navigationAction.navigationType == .other && navigationAction.request.url?.absoluteString == "omp-preview://bundle/index.html"
        decisionHandler(initial ? .allow : .cancel)
        if navigationAction.navigationType == .linkActivated, let href = navigationAction.request.url?.absoluteString { open(href) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showFailure() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showFailure() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { ready = false; showFailure() }

    private func showFailure() {
        guard !tornDown else { return }
        status.stringValue = Chrome.localized("Unable to render Markdown preview. Switch to source to read this file.")
        status.isHidden = false; needsLayout = true
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyTheme() }
    private func resolvedBackgroundColor() -> NSColor {
        var color = NSColor.textBackgroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? color
        }
        return color
    }
    func updateFonts(revision: Int) {
        let size = TypeScale.shared.ui
        guard fontRevision != revision || fontSize != size else { return }
        fontRevision = revision
        fontSize = size
        status.font = .systemFont(ofSize: CGFloat(size))
        let monospacedFace = AppFont.monospacedPostScriptName
        fontTheme = [
            "interface-font-size": "\(size)px",
            "monospaced-font": Self.fontStack(monospacedFace.map { _ in "omp-preview-monospaced" }, fallback: "ui-monospace, Menlo, monospace"),
        ]
        // Bind the selected face as CSS's normal baseline, retaining emphasis semantics.
        fontFaces = [(alias: "omp-preview-monospaced", name: monospacedFace)].compactMap { face in
            face.name.map {
                "@font-face { font-family: \(Self.cssString(face.alias)); src: local(\(Self.cssString($0))); }"
            }
        }.joined(separator: "\n")
        applyTheme()
    }

    private static func fontStack(_ family: String?, fallback: String) -> String {
        guard let family else { return fallback }
        return cssString(family) + ", " + fallback
    }

    private static func cssString(_ value: String) -> String {
        // CSS string escaping is distinct from the JSON transport used below.
        var quoted = "\""
        for scalar in value.unicodeScalars {
            quoted += "\\" + String(scalar.value, radix: 16) + " "
        }
        return quoted + "\""
    }

    private func applyTheme(force: Bool = false) {
        guard ready else { return }
        var colors = ["background": "transparent"]
        effectiveAppearance.performAsCurrentDrawingAppearance {
            var palette: [(String, NSColor)] = [("text", .labelColor), ("secondary", .secondaryLabelColor),
                                               ("line", .separatorColor), ("surface", .controlBackgroundColor), ("accent", Chrome.accentNSColor)]
            if !transparentCanvas { palette.append(("background", .textBackgroundColor)) }
            for (key, color) in palette {
                if let c = color.usingColorSpace(.sRGB) {
                    colors[key] = "rgba(\(Int(c.redComponent * 255)),\(Int(c.greenComponent * 255)),\(Int(c.blueComponent * 255)),\(c.alphaComponent))"
                }
            }
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        colors.merge(CodeHighlighting.shared.theme.palette(dark: dark).cssVariables) { _, code in code }
        colors.merge(fontTheme) { _, font in font }
        guard force || colors != theme || fontFaces != appliedFontFaces else { return }
        theme = colors
        appliedFontFaces = fontFaces
        if !transparentCanvas { web.underPageBackgroundColor = resolvedBackgroundColor() }
        web.callAsyncJavaScript("""
            let style = document.getElementById('omp-preview-font-faces');
            if (!style) {
                style = document.createElement('style');
                style.id = 'omp-preview-font-faces';
                document.head.appendChild(style);
            }
            if (style.textContent !== fontFaces) style.textContent = fontFaces;
            window.preview.theme(colors);
            """, arguments: ["colors": colors, "fontFaces": fontFaces], in: nil, in: .page, completionHandler: nil)
    }
    override func layout() {
        super.layout()
        let bar: CGFloat = searchVisible ? 36 : 0
        web.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - bar))
        searchSurface.frame = NSRect(x: 8, y: bounds.height - 28, width: max(50, bounds.width - 110), height: 22)
        for (i, button) in [previous, next, close].enumerated() {
            button.frame = NSRect(x: bounds.width - CGFloat(3 - i) * 28 - 6, y: bounds.height - 29, width: 26, height: 24)
        }
        status.frame = NSRect(x: 16, y: max(0, bounds.height - bar - 72), width: max(0, bounds.width - 32), height: 56)
        status.maximumNumberOfLines = 3
    }
    private func setSearchVisible(_ visible: Bool) {
        searchVisible = visible
        for view in [searchSurface as NSView, previous, next, close] { view.isHidden = !visible }
        needsLayout = true
    }
    func updateGlass(performanceMode: Bool) {
        searchSurface.update(performanceMode: performanceMode)
        for button in [previous, next, close] {
            PreviewNativeGlass.update(button, performanceMode: performanceMode)
        }
    }
    private func showFind() { setSearchVisible(true); window?.makeFirstResponder(search) }
    @objc private func hideSearch() { setSearchVisible(false); window?.makeFirstResponder(web) }
    @objc private func previousResult() { find(backwards: true) }
    @objc private func nextResult() { find(backwards: false) }
    private func find(backwards: Bool) {
        guard ready else { return }
        let config = WKFindConfiguration(); config.backwards = backwards; config.wraps = true; config.caseSensitive = false
        web.find(search.stringValue, configuration: config) { [weak self] result in
            self?.search.textColor = result.matchFound || self?.search.stringValue.isEmpty == true ? .labelColor : .systemRed
        }
    }
    func controlTextDidChange(_ obj: Notification) {
        pendingFind?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.find(backwards: false) }
        pendingFind = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { hideSearch(); return true }; return false
    }
    @objc private func copyMath(_ item: NSMenuItem) {
        guard let latex = item.representedObject as? String else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(latex, forType: .string)
    }
    func tearDown() {
        guard !tornDown else { return }
        capturePosition(); tornDown = true
        pendingFind?.cancel(); pendingFind = nil
        messages.host = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "preview")
        web.navigationDelegate = nil; web.stopLoading(); resources.cancel()
        state = nil; onOpen = nil; onOpenURL = nil; job = nil
        web.removeFromSuperview()
    }
}
