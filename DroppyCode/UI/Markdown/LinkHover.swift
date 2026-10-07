import AppKit
import SwiftUI

/// The pointing hand over a link and the head card over a mention. `LinkTextView` has no
/// tracking areas (AppKit rebuilds them every scrolled frame), so the cursor comes from here.
struct LinkHoverModifier: ViewModifier {
    /// Weak, so a scrolled-away paragraph isn't kept alive.
    let linkView: WeakView
    @Binding var showsHand: Bool
    @Binding var hoveredHeadID: UUID?
    let personas: [HydraPersona]
    let targets: [String: HydraMentionTarget]

    func body(content: Content) -> some View {
        let personasByName = Dictionary(personas.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return content
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard let view = linkView.value as? LinkTextView else { return }
                switch phase {
                case .active(let point):
                    let overLink = view.hasLink(at: point)
                    if overLink != showsHand {
                        showsHand = overLink
                        if overLink { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    if let (name, url, rect) = view.headMentionRect(at: point),
                       let target = targets[name], target.url == url,
                       let persona = personasByName[name] {
                        if hoveredHeadID != target.threadID {
                            hoveredHeadID = target.threadID
                            HydraHeadHoverPopover.shared.show(persona: persona, target: target, relativeTo: rect, of: view)
                        }
                    } else if hoveredHeadID != nil {
                        hoveredHeadID = nil
                        HydraHeadHoverPopover.shared.hide()
                    }
                case .ended:
                    endHover()
                }
            }
            .onDisappear {
                endHover()
            }
    }

    private func endHover() {
        if showsHand { NSCursor.pop(); showsHand = false }
        hoveredHeadID = nil
        HydraHeadHoverPopover.shared.hide()
    }
}
