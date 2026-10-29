import AppKit
import Observation
import SwiftUI

/// Each tab keeps only this small reading state. Documents and players belong to
/// the visible native view and are released when that view is dismantled.
@MainActor @Observable
final class PreviewReaderState {
    struct TextPosition: Codable, Equatable, Sendable {
        var x: Double = 0
        var y: Double = 0
        var selectionLocation: Int = 0
        var selectionLength: Int = 0
    }

    struct Snapshot: Codable, Equatable, Sendable {
        var showsSource = false
        /// Optional so journals written before the Diff mode still decode.
        var showsDiff: Bool?
        var wrapsLines = false
        var source = TextPosition()
        var document = TextPosition()
        var pdfPage = 0
        var pdfScale: Double = 1
        var pdfAutoScales = true
        var pdfX: Double?
        var pdfY: Double?
        /// Zero means fit to the viewport; other values are pixels per point.
        var imageScale: Double = 0
        var imageX: Double = 0
        var imageY: Double = 0
        var mediaTime: Double = 0
    }

    var showsSource: Bool
    var showsDiff: Bool
    var wrapsLines: Bool
    var findRequest = 0
    /// A repeated request for the same line must navigate again. Selecting the
    /// tab by itself does not increment this value.
    var navigationRequest = 0
    @ObservationIgnored var consumedNavigationRequest = 0
    @ObservationIgnored var consumedFindRequest = 0
    var imageScale: Double
    @ObservationIgnored var imageCurrentScale: Double = 1
    @ObservationIgnored var source: TextPosition
    @ObservationIgnored var document: TextPosition
    @ObservationIgnored var pdfPage: Int
    @ObservationIgnored var pdfScale: Double
    @ObservationIgnored var pdfAutoScales: Bool
    @ObservationIgnored var pdfX: Double?
    @ObservationIgnored var pdfY: Double?
    @ObservationIgnored var imageX: Double
    @ObservationIgnored var imageY: Double
    @ObservationIgnored var mediaTime: Double
    @ObservationIgnored var quickLookDisplayState: Any?

    init(snapshot: Snapshot = .init()) {
        showsSource = snapshot.showsSource
        showsDiff = snapshot.showsDiff ?? false
        wrapsLines = snapshot.wrapsLines
        source = snapshot.source
        document = snapshot.document
        pdfPage = max(0, snapshot.pdfPage)
        pdfScale = snapshot.pdfScale.isFinite ? max(0.05, min(20, snapshot.pdfScale)) : 1
        pdfAutoScales = snapshot.pdfAutoScales
        pdfX = snapshot.pdfX
        pdfY = snapshot.pdfY
        imageScale = snapshot.imageScale.isFinite ? max(0, min(16, snapshot.imageScale)) : 0
        imageX = snapshot.imageX
        imageY = snapshot.imageY
        mediaTime = snapshot.mediaTime.isFinite ? max(0, snapshot.mediaTime) : 0
    }

    var snapshot: Snapshot {
        Snapshot(showsSource: showsSource, showsDiff: showsDiff ? true : nil, wrapsLines: wrapsLines,
                 source: source, document: document, pdfPage: pdfPage,
                 pdfScale: pdfScale, pdfAutoScales: pdfAutoScales,
                 pdfX: pdfX, pdfY: pdfY,
                 imageScale: imageScale, imageX: imageX, imageY: imageY,
                 mediaTime: mediaTime)
    }

    func stepImageZoom(_ direction: Int) {
        imageScale = min(16, max(1.0 / 64, imageCurrentScale * (direction > 0 ? 1.25 : 0.8)))
    }

    func resetImageZoom() { imageScale = 0 }
}

struct FilePreviewContent: View {
    let url: URL
    let kind: FilePreviewKind
    let text: String?
    let revision: String
    let location: FilePreviewLocation?
    let state: PreviewReaderState
    let onOpen: (FilePreviewReference, URL) -> Void

    var body: some View {
        Group {
            switch kind {
            case .text, .markdown:
                if let text {
                    let renderDocument = kind == .markdown && !state.showsSource
                    let largeDocument = renderDocument && PreviewMarkdownDocument.requiresSource(text)
                    VStack(spacing: 0) {
                        if largeDocument {
                            Text("Large or complex Markdown files are shown as source")
                                .font(.ui(.caption))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        if renderDocument && !largeDocument {
                            PreviewMarkdownRenderer(url: url, source: text, revision: revision,
                                                    state: state, findRequest: state.findRequest, onOpen: onOpen)
                        } else {
                            PreviewTextRenderer(url: url, source: text, revision: revision,
                                            location: location, state: state,
                                            wraps: state.wrapsLines, findRequest: state.findRequest,
                                            navigationRequest: state.navigationRequest, onOpen: onOpen)
                        }
                    }
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .image:
                PreviewImageRenderer(url: url, revision: revision, state: state, scale: state.imageScale)
            case .pdf:
                PreviewPDFRenderer(url: url, revision: revision, state: state, findRequest: state.findRequest)
            case .media:
                PreviewMediaRenderer(url: url, revision: revision, state: state)
            case .quickLook:
                PreviewQuickLookRenderer(url: url, revision: revision, state: state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
