import AppKit
import SwiftUI

extension View {
    /// What every SwiftUI-presented tree (popover, sheet, hosted view) gets so its
    /// buttons match the window's capsules: the tree hangs off the window's own,
    /// so it needs the window root's capsule shape and tint restated here.
    func presentedChrome() -> some View {
        self
            .font(.ui(.body))
            .buttonBorderShape(.capsule)
            .tint(ThemeManager.spec.accent)
    }
}

/// A compact input form shared by naming popovers. System alert fields do not
/// adopt custom text field styles, so these use the same capsule as other inputs.
struct ChromeTextInputPopover: View {
    let title: String
    let prompt: String
    let submitTitle: String
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    var validationMessage: String? = nil
    @FocusState private var isFocused: Bool

    private var canSubmit: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validationMessage == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: Chrome.localized(title))
                .font(.ui(.body, weight: .semibold))
            TextField(Chrome.localized(prompt), text: $text)
                .textFieldStyle(.chromeGlass)
                .focused($isFocused)
                .onSubmit(submit)
            if let validationMessage {
                Text(verbatim: Chrome.localized(validationMessage))
                    .font(.ui(.subheadline))
                    .foregroundStyle(Chrome.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button(Chrome.localized(submitTitle), action: submit)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .controlSize(.regular)
        }
        .padding(14)
        .frame(width: 300)
        .presentedChrome()
        .onAppear { isFocused = true }
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmit()
    }
}

/// Resolve a fitting direction before AppKit starts its presentation animation, instead
/// of asking for a vertical edge that must immediately fall back to a horizontal one.
enum PopoverPlacement {
    /// Screen coordinates, with positive Y pointing up. AppKit still owns final placement,
    /// screen-edge clamping and the arrow; this only selects its initial preferred edge.
    static func edge(contentSize: NSSize, anchor: NSRect, visibleFrame: NSRect,
                     preferred: NSRectEdge) -> NSRectEdge {
        let screen = visibleFrame.insetBy(dx: 8, dy: 8)
        // Leave room for the native frame and arrow outside the measured content.
        let width = contentSize.width + 16
        let height = contentSize.height + 16
        let candidates: [NSRectEdge] = switch preferred {
        case .maxY: [.maxY, .minY, .maxX, .minX]
        case .minY: [.minY, .maxY, .maxX, .minX]
        case .maxX: [.maxX, .minX, .maxY, .minY]
        case .minX: [.minX, .maxX, .maxY, .minY]
        @unknown default: [preferred]
        }
        return candidates.first { edge in
            switch edge {
            case .maxY: width <= screen.width && height <= screen.maxY - anchor.maxY
            case .minY: width <= screen.width && height <= anchor.minY - screen.minY
            case .maxX: height <= screen.height && width <= screen.maxX - anchor.maxX
            case .minX: height <= screen.height && width <= anchor.minX - screen.minX
            @unknown default: false
            }
        } ?? preferred
    }

    @MainActor
    static func edge(contentSize: NSSize, relativeTo rect: NSRect, of view: NSView,
                     preferred: NSRectEdge) -> NSRectEdge {
        guard let window = view.window else { return preferred }
        let anchor = window.convertToScreen(view.convert(rect, to: nil))
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? window.screen
        guard let screen else { return preferred }
        func convert(_ edge: NSRectEdge) -> NSRectEdge {
            guard view.isFlipped else { return edge }
            switch edge {
            case .minY: return .maxY
            case .maxY: return .minY
            default: return edge
            }
        }
        return convert(edge(contentSize: contentSize, anchor: anchor, visibleFrame: screen.visibleFrame,
                            preferred: convert(preferred)))
    }
}

extension NSPopover {
    /// Installs SwiftUI content at a fixed size and makes that size the only
    /// one the panel ever has. A hosting controller normally publishes its
    /// own `preferredContentSize` a moment after `show(relativeTo:)`, and
    /// AppKit applies it by resizing the shown panel from its top edge, so
    /// the arrow ends up floating well above the anchor. Sizing the hosting
    /// controller off (`sizingOptions = []`) leaves `contentSize` in charge,
    /// and framing the content to it keeps SwiftUI filling the panel.
    ///
    /// The panel hosts a SwiftUI tree of its own, outside the window's, so it
    /// is given what the window root gives every view: capsule buttons and the
    /// theme's tint. A Save button in it is then the same capsule as one in
    /// Settings, not the stock rounded rectangle.
    @MainActor
    func setFixedContent<Content: View>(_ content: Content, size: NSSize) {
        // Top-aligned: content that turns out taller than measured loses its tail behind
        // the panel's edge, never its header.
        let root = content
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
            .popoverChrome()
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        contentViewController = host
        contentSize = size
    }
}

/// A popover's scrolling body, as tall as its content up to `maxHeight` and scrolling
/// past that. A popover opens at its content's ideal size, and a scroll view offered
/// nothing collapses to a few rows; a fixed ideal height opens short content on empty
/// space and long content cut off. So the content's own height sets the frame, and
/// never past the cap.
///
/// The height read as the content lays out (`onGeometryChange`) lands one pass after
/// the popover has been sized, and AppKit animates the panel to the new size from its
/// top edge: the popover reads as sliding in from above. Given its `width`, the body
/// lays the content out once before the popover opens, so the first size is the final
/// one; the geometry read then only follows changes made while it is open.
struct PopoverScroll<Content: View>: View {
    @Environment(\.self) private var environment
    var maxHeight: CGFloat = 460
    /// What the popover opens at before the content has laid out.
    var minHeight: CGFloat = 80
    var width: CGFloat?
    /// Keeps an open popover fitted to its content instead of freezing the
    /// height it opened at. Use where disclosures can expand and collapse.
    var followsContentHeight: Bool
    let content: () -> Content

    @MainActor
    init(maxHeight: CGFloat = 460, minHeight: CGFloat = 80, width: CGFloat? = nil,
         followsContentHeight: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.maxHeight = maxHeight
        self.minHeight = minHeight
        self.width = width
        self.followsContentHeight = followsContentHeight
        self.content = content
    }

    var body: some View {
        // Resolve the inherited environment before creating the independent
        // measurement host. Measuring in init loses required observable objects
        // such as AppModel, as well as the presented view's locale and appearance.
        PopoverScrollViewport(maxHeight: maxHeight, minHeight: minHeight, width: width,
                              followsContentHeight: followsContentHeight,
                              environment: environment, content: content())
    }
}

private struct PopoverScrollViewport<Content: View>: View {
    let maxHeight: CGFloat
    let minHeight: CGFloat
    let content: Content
    let followsContentHeight: Bool
    @State private var contentHeight: CGFloat
    /// Whether the height was settled before the popover opened. A pre-measured body
    /// keeps that height: the panel around it was sized to it once and never resizes
    /// (see `NSPopover.setFixedContent`), so a later, taller reading only pushed the
    /// body past the panel and cut the header off; the scroll takes any difference.
    /// Content-following popovers opt out so their disclosure height can shrink.
    private let isPremeasured: Bool

    @MainActor
    init(maxHeight: CGFloat, minHeight: CGFloat, width: CGFloat?, followsContentHeight: Bool,
         environment: EnvironmentValues, content: Content) {
        self.maxHeight = maxHeight
        self.minHeight = minHeight
        self.content = content
        self.followsContentHeight = followsContentHeight
        isPremeasured = width != nil
        _contentHeight = State(initialValue: width.map {
            Self.measuredHeight(of: content.environment(\.self, environment), width: $0)
        } ?? 0)
    }

    /// The height `content` takes at `width`: one layout of it off screen, the same
    /// one the popover would run to size itself.
    @MainActor
    static func measuredHeight(of content: some View, width: CGFloat) -> CGFloat {
        NSHostingView(rootView: content.font(.ui(.body)).frame(width: width)).fittingSize.height.rounded(.up)
    }

    var body: some View {
        ScrollView {
            content
                // Growth past the cap scrolls without publishing a new viewport
                // height for every streamed line or lazy row measurement.
                .onGeometryChange(for: CGFloat.self, of: { [limit = maxHeight] geometry in
                    min(geometry.size.height, limit)
                }) { height in
                    if followsContentHeight || !isPremeasured { contentHeight = height }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(contentHeight, minHeight), maxHeight))
    }
}

/// The native popover every chrome and composer button opens, in place of a pull-down menu.
struct PopoverMenu<Content: View>: View {
    var maxHeight: CGFloat = 460
    /// Forces the popover open at this height. Needed because a ScrollView inside
    /// a popover otherwise collapses to a few rows and maxHeight never engages.
    var idealHeight: CGFloat?
    var width: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(6)
            .frame(minWidth: width ?? 210, maxWidth: width ?? 360, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .frame(width: width)
        .frame(idealHeight: idealHeight, maxHeight: maxHeight)
        .presentedChrome()
    }
}

struct PopoverSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(verbatim: Chrome.localized(title))
            .font(.ui(.subheadline, weight: .semibold))
            .foregroundStyle(Chrome.secondaryText)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PopoverNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: Chrome.localized(text))
            .font(.ui(.callout))
            .foregroundStyle(Chrome.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PopoverDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }
}

/// The close closure in a box with an identity. A closure can never compare equal to
/// itself, so an environment value holding one bare tells SwiftUI that every reader of
/// the environment is out of date on every update; a box compares by reference and only
/// the popover's own host ever makes a new one.
final class PopoverCloseBox: Equatable {
    let close: @MainActor () -> Void

    init(_ close: @escaping @MainActor () -> Void) {
        self.close = close
    }

    static func == (lhs: PopoverCloseBox, rhs: PopoverCloseBox) -> Bool {
        lhs === rhs
    }
}

/// How a popover hosted by AppKit closes. SwiftUI's own popovers answer `dismiss`; one shown
/// through an `NSPopover` sets this instead, and every row in it closes through it.
extension EnvironmentValues {
    @Entry var closePopoverBox: PopoverCloseBox?

    /// Set and read as a plain closure; kept in the box above, which is what the rows
    /// actually read, so they are not invalidated by every unrelated environment change.
    var closePopover: (@MainActor () -> Void)? {
        get { closePopoverBox?.close }
        set { closePopoverBox = newValue.map(PopoverCloseBox.init) }
    }
}

/// One row. Pass `isChecked` (true or false) for choice lists so every row keeps the checkmark column.
struct PopoverItem: View {
    let title: String
    /// A styled title, such as a bold verb before a plain label, in place of the plain one.
    var titleText: Text?
    var detail: String?
    var symbol: String?
    var image: NSImage?
    var asset: String?
    /// A custom 16pt leading view (a colour swatch, say) in place of an icon.
    var leading: AnyView?
    var isChecked: Bool?
    var isEnabled = true
    var isDestructive = false
    var wrapsTitle = false
    /// What the row says once tapped ("Copied"), in place with a checkmark, before the
    /// popover closes on its own. The action runs at once, so it must not present anything.
    var confirmation: String?
    let action: @MainActor () -> Void

    @Environment(\.chromeLocalizationBundle) private var localizationBundle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePopoverBox) private var closePopoverBox
    @State private var isHovering = false
    @State private var isConfirmed = false

    /// How long the confirmation shows before the popover closes.
    private static let confirmationHold: Duration = .milliseconds(650)

    init(
        _ title: String,
        detail: String? = nil,
        symbol: String? = nil,
        image: NSImage? = nil,
        asset: String? = nil,
        leading: AnyView? = nil,
        isChecked: Bool? = nil,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        confirmation: String? = nil,
        wrapsTitle: Bool = false,
        action: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.image = image
        self.asset = asset
        self.leading = leading
        self.isChecked = isChecked
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.confirmation = confirmation
        self.wrapsTitle = wrapsTitle
        self.action = action
    }

    /// A row whose title is styled text; `title` names it for accessibility.
    init(
        _ title: String,
        text: Text,
        symbol: String? = nil,
        image: NSImage? = nil,
        isChecked: Bool? = nil,
        wrapsTitle: Bool = false,
        action: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.titleText = text
        self.symbol = symbol
        self.image = image
        self.isChecked = isChecked
        self.wrapsTitle = wrapsTitle
        self.action = action
    }

    var body: some View {
        Button {
            if confirmation != nil, !isConfirmed {
                // The row answers in place first: the deed is done, the words say so, and
                // the popover goes a beat later once the checkmark has been seen.
                action()
                withAnimation(.snappy(duration: 0.22)) { isConfirmed = true }
                Task { @MainActor in
                    try? await Task.sleep(for: Self.confirmationHold)
                    if let close = closePopoverBox?.close { close() } else { dismiss() }
                }
                return
            }
            guard !isConfirmed else { return }
            if let close = closePopoverBox?.close { close() } else { dismiss() }
            // Runs after the popover closes, so an action that presents a sheet or alert is not swallowed.
            Task { @MainActor in action() }
        } label: {
            HStack(spacing: 8) {
                if let isChecked {
                    Image(systemName: "checkmark").font(.symbol(.subheadline, weight: .semibold))
                        .opacity(isChecked ? 1 : 0)
                        .frame(width: 14)
                }
                if let leading {
                    leading
                        .frame(width: 16, height: 16)
                } else if let asset {
                    Image(asset)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                } else if let image {
                    Image(nsImage: image)
                        .resizable()
                        .renderingMode(image.isTemplate ? .template : .original)
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                } else if isConfirmed {
                    Image(systemName: "checkmark").font(.symbol(.callout, weight: .semibold))
                        .foregroundStyle(Chrome.success)
                        .frame(width: 16)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else if let symbol {
                    Image(systemName: symbol).font(.symbol(.callout))
                        .frame(width: 16)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                (isConfirmed ? Text(verbatim: Chrome.localized(confirmation ?? title, bundle: localizationBundle)) : (titleText ?? Text(verbatim: Chrome.localized(title, bundle: localizationBundle))))
                    .font(.ui(.body))
                    .lineLimit(wrapsTitle ? nil : 1)
                    .fixedSize(horizontal: false, vertical: wrapsTitle)
                    .truncationMode(.middle)
                    .contentTransition(.numericText())
                Spacer(minLength: 16)
                if let detail {
                    Text(verbatim: Chrome.localized(detail, bundle: localizationBundle))
                        .font(.ui(.callout))
                        .foregroundStyle(Chrome.secondaryText)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isDestructive ? Chrome.danger : Chrome.primaryText)
            .padding(.horizontal, 8)
            .frame(minHeight: 26, maxHeight: wrapsTitle ? nil : 26)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering && isEnabled ? Chrome.overlay(0.1) : Color.clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(Text(verbatim: detail.map { "\(Chrome.localized(title, bundle: localizationBundle)), \(Chrome.localized($0, bundle: localizationBundle))" } ?? Chrome.localized(title, bundle: localizationBundle)))
        .onHover { hovering in
            withAnimation(Chrome.hover) { isHovering = hovering }
        }
    }
}

// MARK: - Row actions

/// An action a sidebar row offers both from its ellipsis popover and its context menu.
struct RowAction: Identifiable {
    let title: String
    var symbol: String?
    var isDestructive = false
    var startsGroup = false
    /// What the popover row says in place once tapped ("Copied"); see `PopoverItem.confirmation`.
    var confirms: String?
    let action: @MainActor () -> Void

    var id: String { title }
}

struct RowActionItems: View {
    let actions: [RowAction]

    var body: some View {
        ForEach(actions) { item in
            if item.startsGroup { PopoverDivider() }
            PopoverItem(item.title, symbol: item.symbol, isDestructive: item.isDestructive, confirmation: item.confirms, action: item.action)
        }
    }
}

struct RowActionMenuButtons: View {
    let actions: [RowAction]

    var body: some View {
        ForEach(actions) { item in
            if item.startsGroup { Divider() }
            Button(role: item.isDestructive ? .destructive : nil) {
                item.action()
            } label: {
                if let symbol = item.symbol {
                    Label { Text(verbatim: Chrome.localized(item.title)) } icon: { Image(systemName: symbol) }
                } else {
                    Text(verbatim: Chrome.localized(item.title))
                }
            }
        }
    }
}

/// The ellipsis on a hovered sidebar row.
struct RowActionsButton: View {
    let actions: [RowAction]
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            RowAccessoryIcon("ellipsis")
        }
        .buttonStyle(.plain)
        .help("More")
        .chromePopover(isPresented: $isPresented, arrowEdge: .bottom) {
            PopoverMenu { RowActionItems(actions: actions) }
        }
    }
}
