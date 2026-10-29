import AppKit
import QuickLookUI
import SwiftUI

struct PreviewQuickLookRenderer: NSViewRepresentable {
    let url: URL
    let revision: String
    let state: PreviewReaderState
    func makeNSView(context: Context) -> PreviewQuickLookHost { PreviewQuickLookHost() }
    func updateNSView(_ view: PreviewQuickLookHost, context: Context) { view.update(url: url, revision: revision, state: state) }
    static func dismantleNSView(_ view: PreviewQuickLookHost, coordinator: ()) { view.tearDown() }
}

@MainActor
final class PreviewQuickLookHost: NSView {
    private let preview: QLPreviewView?
    private var state: PreviewReaderState?
    private var itemURL: URL?
    private var revision = ""
    private var closed = false

    override init(frame: NSRect) {
        preview = QLPreviewView(frame: frame, style: .normal)
        super.init(frame: frame)
        preview?.shouldCloseWithWindow = false
        preview?.autostarts = false
        if let preview { addSubview(preview) }
        else {
            let label = NSTextField(labelWithString: Chrome.localized("System preview is unavailable"))
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func update(url: URL, revision: String, state: PreviewReaderState) {
        guard !closed, let preview else { return }
        if self.state !== state || itemURL != url {
            self.state?.quickLookDisplayState = preview.displayState
            self.state = state
            itemURL = url
            self.revision = revision
            preview.previewItem = url as NSURL
            if let displayState = state.quickLookDisplayState { preview.displayState = displayState }
        } else if self.revision != revision {
            self.revision = revision
            let displayState = preview.displayState
            preview.refreshPreviewItem()
            if let displayState { preview.displayState = displayState }
        }
    }

    override func layout() { super.layout(); preview?.frame = bounds }

    func tearDown() {
        guard !closed else { return }
        state?.quickLookDisplayState = preview?.displayState
        preview?.close()
        state = nil
        closed = true
    }
}
