import SwiftUI

/// A saved stop is a read-only value tree. Expanding it can only reveal values
/// already captured in this stop; it has no native session or transport.
struct DebugSavedInspection: View {
    let stop: OMPDebugStop
    var previous: OMPDebugStop? = nil
    var showStack = true
    let previews: FilePreviewStore
    let context: FilePreviewContext
    @State private var selectedFrame: Int?
    @State private var expanded: Set<String> = []
    @State private var collapsedScopes: Set<String> = []

    private var frameID: Int {
        selectedFrame ?? stop.frames.first?.id ?? stop.captures.first(where: { $0.operation == "scopes" })?.frameID
            ?? stop.captures.first(where: { $0.operation == "variables" })?.frameID ?? 0
    }
    private var scopes: [JSONValue] { stop.scopes(frameID: frameID) }
    private var ungrouped: [OMPDebugCapture] {
        stop.captures.filter { capture in
            guard capture.operation == "variables", capture.frameID == nil || capture.frameID == frameID else { return false }
            let references = capture.frameID == nil ? [] : scopes.compactMap { $0["reference"]?.int }
            let children = stop.captures.filter { $0.operation == "variables" && $0.frameID == capture.frameID }
                .flatMap { $0.data?["variables"]?.array ?? [] }.compactMap { $0["reference"]?.int }
            return capture.reference.map { !references.contains($0) && !children.contains($0) } == true
        }
    }

    var body: some View {
        let frameCapHeight = AppFont.monospaced(size: TypeScale.shared.code(TypeScale.stockPointSize(.callout))).capHeight
        VStack(alignment: .leading, spacing: 16) {
            scopeGroup(registers: false)
            scopeGroup(registers: true)
            if !ungrouped.isEmpty {
                section("Variables") {
                    ForEach(ungrouped) { capture in
                        values(capture.data?["variables"]?.array ?? [], frame: capture.frameID, path: capture.id, ancestors: [], depth: 0,
                               previous: previous?.id == stop.id ? capture.reference.flatMap { previous?.variables(reference: $0, frameID: capture.frameID) } : nil)
                    }
                }
            }
            if showStack, !stop.frames.isEmpty {
                section("Call stack") {
                    ForEach(stop.frames) { frame in
                        VStack(alignment: .leading, spacing: 4) {
                            Button { selectedFrame = frame.id } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: "arrow.right").font(.symbol(.caption)).foregroundStyle(Color.accentColor)
                                        .opacity(frameID == frame.id ? 1 : 0).frame(width: 12)
                                        .alignmentGuide(.firstTextBaseline) { [frameCapHeight] dimensions in
                                            dimensions[VerticalAlignment.center] + frameCapHeight / 2
                                        }
                                    Text(verbatim: frame.name).font(.code(.callout)).frame(maxWidth: .infinity, alignment: .leading)
                                }.contentShape(.rect)
                            }.buttonStyle(.plain)
                            if let source = frame.source {
                                DebugSourceLink(source: source, cwd: stop.session.cwd, previews: previews, context: context).padding(.leading, 18)
                            }
                        }
                    }
                }
            }
            if stop.limited { Text("Snapshot truncated").font(.ui(.caption)).foregroundStyle(Chrome.secondaryText) }
        }
        .accessibilityIdentifier("debug.saved-inspection")
    }

    @ViewBuilder private func scopeGroup(registers: Bool) -> some View {
        let values = scopes.filter { value in
            let isRegister = value["presentationHint"]?.string == "registers" || value["name"]?.string?.lowercased().contains("register") == true
            return isRegister == registers && value["reference"]?.int.flatMap { stop.variables(reference: $0, frameID: frameID) }?.isEmpty == false
        }
        if !values.isEmpty {
            section(registers ? "Registers" : "Variables") {
                ForEach(Array(values.enumerated()), id: \.offset) { index, scope in
                    let reference = scope["reference"]?.int ?? 0
                    let key = "scope:\(frameID):\(index)"
                    DisclosureGroup(isExpanded: Binding(get: { !collapsedScopes.contains(key) }, set: {
                        if $0 { collapsedScopes.remove(key) } else { collapsedScopes.insert(key) }
                    })) {
                        self.values(stop.variables(reference: reference, frameID: frameID) ?? [], frame: frameID,
                                    path: key, ancestors: [reference], depth: 0, previous: previousValues(scope: scope)).padding(.top, 8)
                    } label: {
                        Text(verbatim: scope["name"]?.string ?? "").font(.code(.caption)).foregroundStyle(Chrome.secondaryText)
                    }
                }
            }
        }
    }

    private var previousFrameID: Int? {
        if previous?.id == stop.id { return frameID }
        guard let index = stop.frames.firstIndex(where: { $0.id == frameID }),
              let previous, previous.frames.indices.contains(index) else { return nil }
        let old = previous.frames[index], current = stop.frames[index]
        return old.name == current.name && old.source?.path == current.source?.path ? old.id : nil
    }

    private func previousValues(scope: JSONValue) -> [JSONValue]? {
        guard let frame = previousFrameID, let previous,
              let reference = previous.scopes(frameID: frame).first(where: {
                  $0["name"] == scope["name"] && $0["presentationHint"] == scope["presentationHint"]
              })?["reference"]?.int else { return nil }
        return previous.variables(reference: reference, frameID: frame)
    }

    private func values(_ values: [JSONValue], frame: Int?, path: String, ancestors: Set<Int>, depth: Int,
                        previous oldValues: [JSONValue]?) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                let key = path + ":" + String(index)
                let reference = value["reference"]?.int ?? 0
                let old = oldValues?.first { $0["name"] == value["name"] }
                let children = reference > 0 && depth < 8 && !ancestors.contains(reference)
                    ? stop.variables(reference: reference, frameID: frame) : nil
                if let children, !children.isEmpty {
                    DisclosureGroup(isExpanded: Binding(get: { expanded.contains(key) }, set: {
                        if $0 { expanded.insert(key) } else { expanded.remove(key) }
                    })) {
                        self.values(children, frame: frame, path: key, ancestors: ancestors.union([reference]), depth: depth + 1,
                                    previous: old?["reference"]?.int.flatMap { previous?.variables(reference: $0, frameID: frame == nil ? nil : previousFrameID) }).padding(.top, 8)
                    } label: { valueLabel(value, previous: old) }
                } else { valueLabel(value, previous: old) }
            }
        })
    }

    private func valueLabel(_ value: JSONValue, previous: JSONValue?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: value["name"]?.string ?? "").font(.code(.callout))
                Spacer(minLength: 0)
                if let type = value["type"]?.string, !type.isEmpty {
                    Text(verbatim: type).font(.code(.caption2)).foregroundStyle(Chrome.secondaryText).lineLimit(1)
                }
            }
            if let text = value["value"]?.string, !text.isEmpty {
                valueText(text, previous: previous?["value"]?.string)
                    .font(.code(.caption))
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.textSelection(.enabled)
    }

    private func valueText(_ text: String, previous: String?) -> Text {
        var result = AttributedString()
        let changed = previous != nil && previous != text
        if let previous, changed {
            var old = AttributedString(OMPDebugDetails.clip(previous, bytes: 160))
            old.strikethroughStyle = .single; old.foregroundColor = Chrome.secondaryText
            result += old
            var arrow = AttributedString(" → "); arrow.foregroundColor = Chrome.secondaryText
            result += arrow
        }
        var current = AttributedString(text)
        current.foregroundColor = changed ? .accentColor : Chrome.secondaryText
        result += current
        return Text(result)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: Chrome.localized(title)).font(.ui(.caption, weight: .semibold)).foregroundStyle(Chrome.secondaryText)
            VStack(alignment: .leading, spacing: 8) { content() }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
