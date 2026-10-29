import AppKit
import SwiftUI

/// Native controls around OMP's text-only extension protocol.
struct OMPExtensionAccessoryView: View {
    let runtime: ThreadRuntime
    let placement: OMPExtensionWidget.Placement

    var body: some View {
        let state = runtime.ompExtensionState
        let widgets = state.widgets.filter { $0.placement == placement }
        let showsControls = placement == .aboveEditor
        if !widgets.isEmpty || (showsControls && (!state.statuses.isEmpty || runtime.pendingOMPEditorText != nil || !runtime.ompLoginLinks.isEmpty)) {
            VStack(alignment: .leading, spacing: 8) {
                if showsControls {
                    ForEach(state.statuses.keys.sorted(), id: \.self) { key in
                        Text(verbatim: state.statuses[key] ?? "")
                            .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                            .lineLimit(3).textSelection(.enabled)
                    }
                    if runtime.pendingOMPEditorText != nil {
                        HStack {
                            Text("OMP prepared editor text.").font(.ui(.subheadline))
                            Spacer()
                            Button("Use prepared text") { runtime.applyOMPEditorText() }.buttonStyle(.glass)
                            Button("Dismiss") { runtime.dismissOMPEditorText() }.buttonStyle(.glass)
                        }
                    }
                    ForEach(runtime.ompLoginLinks) { link in
                        OMPLoginLinkView(link: link)
                    }
                }
                ForEach(widgets) { widget in
                    ScrollView {
                        Text(verbatim: widget.lines.joined(separator: "\n"))
                            .font(.ui(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .accessibilityLabel(Text(verbatim: widget.id))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Chrome.overlay(0.04), in: .rect(cornerRadius: 12))
        }
    }
}

struct OMPLoginLinkView: View {
    let link: OMPLoginLink

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: link.url.host ?? "OMP").font(.ui(.subheadline, weight: .semibold))
            if let instructions = link.instructions {
                Text(verbatim: instructions).font(.ui(.subheadline)).textSelection(.enabled).lineLimit(8)
            }
            HStack {
                Button("Open login page") { NSWorkspace.shared.open(link.destination) }.buttonStyle(.glassProminent)
                Button("Copy login URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.destination.absoluteString, forType: .string)
                }.buttonStyle(.glass)
            }
        }
    }
}
