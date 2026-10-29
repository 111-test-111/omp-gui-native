import AppKit
import Observation
import SwiftUI

/// Only the floating chrome observes this small snapshot. Scrolling and control
/// updates never replace the native reader or retain its document after teardown.
@MainActor @Observable
final class PreviewFloatingControlsModel {
    enum Kind { case image, pdf }
    enum Action { case zoomOut, fit, actualSize, zoomIn, previousPage, nextPage }

    struct Display: Equatable {
        var isAvailable = false
        var status = ""
        var detailHelp = ""
        var isFitActive = false
        var isActualSizeActive = false
        var canZoomOut = false
        var canZoomIn = false
        var canGoBack = false
        var canGoForward = false
    }

    let kind: Kind
    private(set) var display = Display()
    @ObservationIgnored private weak var owner: NSView?
    @ObservationIgnored private var action: ((Action) -> Void)?

    init(kind: Kind) { self.kind = kind }

    func bind(to owner: NSView, action: @escaping (Action) -> Void) {
        self.owner = owner
        self.action = action
        reset(from: owner)
    }

    func publish(_ next: Display, from owner: NSView) {
        guard self.owner === owner, display != next else { return }
        display = next
    }

    func reset(from owner: NSView) { publish(Display(), from: owner) }

    func release(from owner: NSView) {
        // SwiftUI can install a replacement before dismantling the old host.
        guard self.owner === owner else { return }
        reset(from: owner)
        self.owner = nil
        action = nil
    }

    func perform(_ requested: Action) {
        guard owner != nil, display.isAvailable else { return }
        switch requested {
        case .zoomOut: guard display.canZoomOut else { return }
        case .zoomIn: guard display.canZoomIn else { return }
        case .previousPage: guard display.canGoBack else { return }
        case .nextPage: guard display.canGoForward else { return }
        case .fit, .actualSize: break
        }
        action?(requested)
    }
}

struct PreviewFloatingControls: View {
    static let edgeInset: CGFloat = 12
    static var bottomClearance: CGFloat { Chrome.capsuleHeight + edgeInset }
    let model: PreviewFloatingControlsModel

    var body: some View {
        if model.display.isAvailable {
            switch model.kind {
            case .image:
                ChromeCapsule {
                    zoomOut
                    fit(help: "Fit image")
                    ChromeIconButton(symbol: "1.magnifyingglass", isActive: model.display.isActualSizeActive, help: "Actual size") {
                        model.perform(.actualSize)
                    }
                    zoomIn
                    separator
                    meter(width: 44)
                        .help(Text(verbatim: model.display.detailHelp))
                }
                .fixedSize(horizontal: true, vertical: true)
            case .pdf:
                ViewThatFits(in: .horizontal) {
                    pdfCapsule(meterWidth: 64, dividerPadding: 6)
                    pdfCapsule(meterWidth: 32, dividerPadding: 3)
                }
            }
        }
    }

    private func pdfCapsule(meterWidth: CGFloat, dividerPadding: CGFloat) -> some View {
        ChromeCapsule {
            ChromeIconButton(symbol: "chevron.left", isEnabled: model.display.canGoBack, help: "Previous page") {
                model.perform(.previousPage)
            }
            meter(width: meterWidth)
                .help(Text(verbatim: model.display.status))
            ChromeIconButton(symbol: "chevron.right", isEnabled: model.display.canGoForward, help: "Next page") {
                model.perform(.nextPage)
            }
            ChromeDivider().padding(.horizontal, dividerPadding)
            zoomOut
            fit(help: "Fit width")
            zoomIn
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var zoomOut: some View {
        ChromeIconButton(symbol: "minus.magnifyingglass", isEnabled: model.display.canZoomOut, help: "Zoom out") {
            model.perform(.zoomOut)
        }
    }

    private var zoomIn: some View {
        ChromeIconButton(symbol: "plus.magnifyingglass", isEnabled: model.display.canZoomIn, help: "Zoom in") {
            model.perform(.zoomIn)
        }
    }

    private func fit(help: String) -> some View {
        ChromeIconButton(symbol: "arrow.up.left.and.arrow.down.right", isActive: model.display.isFitActive, help: help) {
            model.perform(.fit)
        }
    }

    private var separator: some View { ChromeDivider().padding(.horizontal, 6) }

    private func meter(width: CGFloat) -> some View {
        Text(verbatim: model.display.status)
            .font(.ui(.caption2))
            .monospacedDigit()
            .foregroundStyle(Chrome.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: width)
    }
}
