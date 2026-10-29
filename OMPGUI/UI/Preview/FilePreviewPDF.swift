import AppKit
import PDFKit
import SwiftUI

struct PreviewPDFRenderer: View {
    let url: URL
    let revision: String
    let state: PreviewReaderState
    let findRequest: Int
    @State private var controls = PreviewFloatingControlsModel(kind: .pdf)

    var body: some View {
        PreviewPDFSurface(url: url, revision: revision, state: state, findRequest: findRequest, controls: controls)
            .overlay(alignment: .bottom) {
                PreviewFloatingControls(model: controls)
                    .padding(.horizontal, PreviewFloatingControls.edgeInset)
                    .padding(.bottom, PreviewFloatingControls.edgeInset)
            }
    }
}

private struct PreviewPDFSurface: NSViewRepresentable {
    let url: URL
    let revision: String
    let state: PreviewReaderState
    let findRequest: Int
    let controls: PreviewFloatingControlsModel
    @AppStorage("performanceMode", store: CaptureRun.defaults ?? .standard) private var performanceMode = false
    func makeNSView(context: Context) -> PreviewPDFHost {
        let view = PreviewPDFHost()
        view.attachControls(controls)
        return view
    }
    func updateNSView(_ view: PreviewPDFHost, context: Context) {
        let openURL = context.environment.openURL
        view.onOpenURL = { openURL($0) }
        view.updateGlass(performanceMode: performanceMode)
        view.update(url: url, revision: revision, state: state, findRequest: findRequest)
    }
    static func dismantleNSView(_ view: PreviewPDFHost, coordinator: ()) { view.tearDown() }
}

private struct PreviewLoadedPDF: @unchecked Sendable { let document: PDFDocument? }
private struct PreviewPDFMatch: @unchecked Sendable { let selection: PDFSelection }

/// Bound callback allocation before hopping to the main actor. PDFKit can emit
/// many matches on one page before the main actor processes queued UI updates.
final class PreviewPDFFindBudget: @unchecked Sendable {
    static let limit = 500
    private let lock = NSLock()
    private var count = 0

    func take() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard count < Self.limit else { return nil }
        count += 1
        return count
    }
}

private final class PreviewPDFFindDelegate: NSObject, PDFDocumentDelegate, @unchecked Sendable {
    private weak var host: PreviewPDFHost?
    private let generation: Int
    private let documentID: ObjectIdentifier
    private let query: String
    private let budget = PreviewPDFFindBudget()

    init(host: PreviewPDFHost, generation: Int, document: PDFDocument, query: String) {
        self.host = host; self.generation = generation
        documentID = ObjectIdentifier(document); self.query = query
    }

    func didMatchString(_ instance: PDFSelection) {
        guard let document = instance.pages.first?.document, ObjectIdentifier(document) == documentID,
              instance.string?.range(of: query, options: .caseInsensitive) != nil else { return }
        guard let count = budget.take() else { document.cancelFindString(); return }
        if count == PreviewPDFFindBudget.limit { document.cancelFindString() }
        let match = PreviewPDFMatch(selection: instance)
        let generation = generation
        Task { @MainActor [weak host] in host?.acceptMatch(match.selection, generation: generation) }
    }

    func documentDidEndDocumentFind(_ notification: Notification) {
        let generation = generation
        Task { @MainActor [weak host] in host?.searchEnded(generation: generation) }
    }
}

@MainActor
final class PreviewPDFHost: NSView, NSSearchFieldDelegate, PDFViewDelegate {
    private let pdf = PDFView()
    var onOpenURL: ((URL) -> Void)?
    private(set) var controls = PreviewFloatingControlsModel(kind: .pdf)
    private let search = NSSearchField()
    private lazy var searchSurface = PreviewGlassInputSurface(field: search)
    private let matchLabel = NSTextField(labelWithString: "")
    private let previousMatch = NSButton()
    private let nextMatch = NSButton()
    private let closeSearch = NSButton()
    private let status = NSTextField(labelWithString: "")
    private let password = NSSecureTextField()
    private lazy var passwordSurface = PreviewGlassInputSurface(field: password)
    private let unlockButton = NSButton()
    private var lockedDocument: PDFDocument?
    private var state: PreviewReaderState?
    private var revisionKey = ""
    private var generation = 0
    private var work: Task<Void, Never>?
    private var searchWork: Task<Void, Never>?
    private var searchDelegate: PreviewPDFFindDelegate?
    private var searchGeneration = 0
    private var matches: [PDFSelection] = []
    private var matchIndex = -1
    private var searchVisible = false
    private var restoring = false
    private weak var observedClip: NSClipView?
    private weak var insetScroll: NSScrollView?
    private var originalBottomInset: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        pdf.delegate = self
        pdf.displayMode = .singlePageContinuous
        pdf.displaysPageBreaks = true
        pdf.backgroundColor = .clear
        pdf.autoScales = true
        pdf.minScaleFactor = 0.05
        pdf.maxScaleFactor = 20
        addSubview(pdf)
        search.placeholderString = Chrome.localized("Find in PDF")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        addSubview(searchSurface)
        matchLabel.font = .systemFont(ofSize: 11)
        matchLabel.textColor = .secondaryLabelColor
        addSubview(matchLabel)
        configure(previousMatch, title: "Previous match", symbol: "chevron.up", action: #selector(previousResult))
        configure(nextMatch, title: "Next match", symbol: "chevron.down", action: #selector(nextResult))
        configure(closeSearch, title: "Close search", symbol: "xmark", action: #selector(hideSearch))
        addSubview(previousMatch); addSubview(nextMatch); addSubview(closeSearch)
        status.font = .systemFont(ofSize: 13)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.isHidden = true
        addSubview(status)
        password.placeholderString = Chrome.localized("PDF password")
        passwordSurface.isHidden = true
        password.target = self
        password.action = #selector(unlock)
        addSubview(passwordSurface)
        unlockButton.title = Chrome.localized("Unlock PDF")
        unlockButton.bezelStyle = .rounded
        unlockButton.target = self
        unlockButton.action = #selector(unlock)
        unlockButton.isHidden = true
        addSubview(unlockButton)
        updateGlass(performanceMode: (CaptureRun.defaults ?? .standard).bool(forKey: "performanceMode"))
        setSearchVisible(false)
        NotificationCenter.default.addObserver(self, selector: #selector(positionChanged), name: .PDFViewPageChanged, object: pdf)
        NotificationCenter.default.addObserver(self, selector: #selector(positionChanged), name: .PDFViewScaleChanged, object: pdf)
        bindControls()
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

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
            case .zoomIn: self?.zoomIn()
            case .previousPage: self?.previousPage()
            case .nextPage: self?.nextPage()
            case .actualSize: break
            }
        }
        positionChanged()
    }
    private func configure(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: Chrome.localized(title))
        button.imagePosition = .imageOnly
        button.bezelStyle = .inline
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = Chrome.localized(title)
        button.setAccessibilityLabel(Chrome.localized(title))
    }

    func updateGlass(performanceMode: Bool) {
        searchSurface.update(performanceMode: performanceMode)
        passwordSurface.update(performanceMode: performanceMode)
        for button in [previousMatch, nextMatch, closeSearch, unlockButton] {
            PreviewNativeGlass.update(button, performanceMode: performanceMode)
        }
    }

    func update(url: URL, revision: String, state: PreviewReaderState, findRequest: Int) {
        let replacing = self.state !== state
        if replacing { savePosition() }
        self.state = state
        let key = url.path + "\n" + revision
        if key != revisionKey || replacing {
            if !replacing { savePosition() }
            revisionKey = key
            generation += 1
            work?.cancel()
            searchWork?.cancel()
            pdf.document?.cancelFindString()
            pdf.document?.delegate = nil
            searchDelegate = nil
            searchGeneration += 1
            controls.reset(from: self)
            pdf.document = nil
            // Removing an inset can clamp scrolling and post a notification.
            // Clear the old document first so it cannot overwrite new state.
            restoreScrollInsets()
            lockedDocument = nil
            matches = []
            password.stringValue = ""
            passwordSurface.isHidden = true
            unlockButton.isHidden = true
            status.isHidden = true
            pdf.isHidden = true
            let currentGeneration = generation
            work = Task { [weak self] in
                let load = Task.detached(priority: .userInitiated) { PreviewLoadedPDF(document: Task.isCancelled ? nil : PDFDocument(url: url)) }
                let result = await withTaskCancellationHandler(operation: { await load.value }, onCancel: { load.cancel() })
                guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                guard let document = result.document, document.pageCount > 0 || document.isLocked else {
                    self.status.stringValue = Chrome.localized("Unable to preview PDF")
                    self.status.isHidden = false
                    return
                }
                if document.isLocked {
                    self.lockedDocument = document
                    self.status.stringValue = Chrome.localized("This PDF is password protected")
                    self.status.isHidden = false
                    self.passwordSurface.isHidden = false
                    self.unlockButton.isHidden = false
                    self.needsLayout = true
                } else { self.install(document) }
            }
        }
        if findRequest != state.consumedFindRequest {
            state.consumedFindRequest = findRequest
            setSearchVisible(true)
            window?.makeFirstResponder(search)
        }
    }

    private func install(_ document: PDFDocument) {
        restoring = true
        pdf.document = document
        pdf.isHidden = false
        pdf.autoScales = state?.pdfAutoScales ?? true
        if !pdf.autoScales { pdf.scaleFactor = state?.pdfScale ?? 1 }
        layoutSubtreeIfNeeded()
        pdf.layoutDocumentView()
        updateScrollSurface()
        let pageIndex = min(max(0, state?.pdfPage ?? 0), max(0, document.pageCount - 1))
        if let page = document.page(at: pageIndex) {
            if let x = state?.pdfX, let y = state?.pdfY, x.isFinite, y.isFinite {
                let point = page.bounds(for: pdf.displayBox)
                pdf.go(to: PDFDestination(page: page, at: NSPoint(x: min(max(point.minX, x), point.maxX), y: min(max(point.minY, y), point.maxY))))
            } else { pdf.go(to: page) }
        }
        if let observedClip { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClip) }
        observedClip = pdf.documentView?.enclosingScrollView?.contentView
        observedClip?.postsBoundsChangedNotifications = true
        if let observedClip { NotificationCenter.default.addObserver(self, selector: #selector(positionChanged), name: NSView.boundsDidChangeNotification, object: observedClip) }
        restoring = false
        positionChanged()
        if searchVisible, !search.stringValue.isEmpty { beginSearch() }
    }

    override func layout() {
        super.layout()
        let searchHeight: CGFloat = searchVisible ? 34 : 0
        let pdfFrame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - searchHeight))
        if pdf.frame != pdfFrame { pdf.frame = pdfFrame }
        updateScrollSurface()
        let y = bounds.height - 29
        searchSurface.frame = NSRect(x: 8, y: y, width: max(60, bounds.width - 180), height: 24)
        matchLabel.frame = NSRect(x: max(72, bounds.width - 164), y: y + 4, width: 90, height: 18)
        previousMatch.frame = NSRect(x: bounds.width - 72, y: y, width: 22, height: 24)
        nextMatch.frame = NSRect(x: bounds.width - 48, y: y, width: 22, height: 24)
        closeSearch.frame = NSRect(x: bounds.width - 24, y: y, width: 22, height: 24)
        status.frame = NSRect(x: 8, y: bounds.midY + 20, width: max(0, bounds.width - 16), height: 24)
        passwordSurface.frame = NSRect(x: max(8, bounds.midX - 110), y: bounds.midY - 12, width: min(220, max(0, bounds.width - 16)), height: 24)
        unlockButton.frame = NSRect(x: max(8, bounds.midX - 55), y: bounds.midY - 46, width: 110, height: 28)
    }

    private func updateScrollSurface() {
        guard pdf.document != nil, let scroll = pdf.documentView?.enclosingScrollView else { return }
        // PDFKit's scroll/clip views keep painting their default background
        // even when PDFView.backgroundColor is clear. Clear both surfaces after
        // document layout, including when PDFKit replaces its scroll view.
        if scroll.drawsBackground { scroll.drawsBackground = false }
        if scroll.backgroundColor != .clear { scroll.backgroundColor = .clear }
        if scroll.contentView.drawsBackground { scroll.contentView.drawsBackground = false }
        if scroll.contentView.backgroundColor != .clear { scroll.contentView.backgroundColor = .clear }
        // Finish any tiling invalidated by those changes before restoring the
        // clearance used to scroll the final page above the floating controls.
        scroll.layoutSubtreeIfNeeded()
        if insetScroll !== scroll {
            restoreScrollInsets()
            insetScroll = scroll
            originalBottomInset = scroll.contentInsets.bottom
        }
        let bottom = originalBottomInset + PreviewFloatingControls.bottomClearance
        guard scroll.contentInsets.bottom != bottom else { return }
        var insets = scroll.contentInsets
        insets.bottom = bottom
        scroll.contentInsets = insets
    }

    private func restoreScrollInsets() {
        if let scroll = insetScroll, scroll.contentInsets.bottom == originalBottomInset + PreviewFloatingControls.bottomClearance {
            var insets = scroll.contentInsets
            insets.bottom = originalBottomInset
            scroll.contentInsets = insets
        }
        insetScroll = nil
    }

    @objc private func unlock() {
        guard let document = lockedDocument else { return }
        if document.unlock(withPassword: password.stringValue) {
            password.stringValue = ""
            passwordSurface.isHidden = true
            unlockButton.isHidden = true
            status.isHidden = true
            lockedDocument = nil
            install(document)
        } else {
            status.stringValue = Chrome.localized("Incorrect PDF password")
            password.selectText(nil)
        }
    }

    @objc private func positionChanged() {
        guard let document = pdf.document else { return }
        let pageIndex = (pdf.currentDestination?.page ?? pdf.currentPage).map(document.index(for:)) ?? 0
        controls.publish(.init(isAvailable: true, status: "\(max(0, pageIndex) + 1) / \(document.pageCount)",
                               isFitActive: pdf.autoScales, canZoomOut: pdf.canZoomOut, canZoomIn: pdf.canZoomIn,
                               canGoBack: pdf.canGoToPreviousPage, canGoForward: pdf.canGoToNextPage), from: self)
        guard !restoring, let state else { return }
        state.pdfPage = max(0, pageIndex)
        state.pdfScale = pdf.scaleFactor
        state.pdfAutoScales = pdf.autoScales
        if let destination = pdf.currentDestination {
            state.pdfX = destination.point.x
            state.pdfY = destination.point.y
        }
    }
    private func savePosition() { positionChanged() }
    @objc private func previousPage() { pdf.goToPreviousPage(nil) }
    @objc private func nextPage() { pdf.goToNextPage(nil) }
    @objc private func zoomOut() { pdf.autoScales = false; pdf.zoomOut(nil); positionChanged() }
    @objc private func zoomIn() { pdf.autoScales = false; pdf.zoomIn(nil); positionChanged() }
    @objc private func fit() { pdf.autoScales = true; positionChanged() }

    /// Called by the window's preview shortcut scope before menu font commands
    /// receive the chord. The document remains owned by this visible view.
    func stepPreviewZoom(_ step: Int) {
        if step == 0 { fit() }
        else if step > 0 { zoomIn() }
        else { zoomOut() }
    }

    private func setSearchVisible(_ visible: Bool) {
        searchVisible = visible
        for view in [searchSurface, matchLabel, previousMatch, nextMatch, closeSearch] as [NSView] { view.isHidden = !visible }
        needsLayout = true
    }
    @objc private func hideSearch() {
        setSearchVisible(false)
        searchWork?.cancel()
        pdf.document?.cancelFindString()
        pdf.document?.delegate = nil
        searchDelegate = nil
        searchGeneration += 1
        pdf.highlightedSelections = nil
        matches = []
        window?.makeFirstResponder(pdf)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === search else { return }
        searchWork?.cancel()
        searchWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.beginSearch()
        }
    }
    private func beginSearch() {
        pdf.document?.cancelFindString()
        pdf.document?.delegate = nil
        searchDelegate = nil
        searchGeneration += 1
        matches = []
        matchIndex = -1
        pdf.highlightedSelections = nil
        matchLabel.stringValue = ""
        guard !search.stringValue.isEmpty, let document = pdf.document else { return }
        matchLabel.stringValue = Chrome.localized("Searching…")
        let delegate = PreviewPDFFindDelegate(host: self, generation: searchGeneration, document: document, query: search.stringValue)
        searchDelegate = delegate
        document.delegate = delegate
        document.beginFindString(search.stringValue, withOptions: [.caseInsensitive])
    }
    fileprivate func acceptMatch(_ instance: PDFSelection, generation: Int) {
        guard generation == searchGeneration, searchVisible, !search.stringValue.isEmpty,
              instance.pages.first?.document === pdf.document,
              instance.string?.range(of: search.stringValue, options: .caseInsensitive) != nil else { return }
        guard matches.count < PreviewPDFFindBudget.limit else { return }
        instance.color = .systemYellow.withAlphaComponent(0.3)
        matches.append(instance)
        if matchIndex < 0 { matchIndex = 0; showResult() }
        updateMatchLabel()
    }
    fileprivate func searchEnded(generation: Int) {
        guard generation == searchGeneration else { return }
        updateMatchLabel()
    }
    private func updateMatchLabel() {
        if search.stringValue.isEmpty { matchLabel.stringValue = "" }
        else if matches.isEmpty { matchLabel.stringValue = Chrome.localized("No matches") }
        else { matchLabel.stringValue = String(format: Chrome.localized(matches.count == PreviewPDFFindBudget.limit ? "%d+ matches" : "%d matches"), matches.count) }
    }
    @objc private func previousResult() { guard !matches.isEmpty else { return }; matchIndex = (matchIndex - 1 + matches.count) % matches.count; showResult() }
    @objc private func nextResult() { guard !matches.isEmpty else { return }; matchIndex = (matchIndex + 1) % matches.count; showResult() }
    private func showResult() {
        guard matches.indices.contains(matchIndex) else { return }
        pdf.setCurrentSelection(matches[matchIndex], animate: false)
        pdf.go(to: matches[matchIndex])
        savePosition()
    }

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        if url.isHTTPWebLink, let onOpenURL { onOpenURL(url) } else { NSWorkspace.shared.open(url) }
    }

    func tearDown() {
        pdf.delegate = nil
        onOpenURL = nil
        savePosition()
        generation += 1
        work?.cancel(); searchWork?.cancel()
        work = nil; searchWork = nil
        pdf.document?.cancelFindString()
        pdf.document?.delegate = nil
        searchDelegate = nil
        searchGeneration += 1
        pdf.document = nil
        restoreScrollInsets()
        lockedDocument = nil
        password.stringValue = ""
        matches = []
        state = nil
        controls.release(from: self)
        NotificationCenter.default.removeObserver(self)
    }
}
