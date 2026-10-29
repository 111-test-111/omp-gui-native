import SwiftUI

struct ToolsSettingsPage: View {
    let query: String
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var activation = 0
    @State private var pending: (control: OMPToolCatalogue.Control, value: JSONValue)?

    private struct Request: Equatable {
        let context: OMPDiscoveryContext?
        let activation: Int
    }

    private var context: OMPDiscoveryContext? {
        guard let executable = model.providers.executable(for: .omp) else { return nil }
        return OMPDiscoveryContext(executable: executable,
            environment: OMPCLI.profileConfigurationEnvironment(model.providers.environment(for: .omp)))
    }

    private var configuration: OMPToolCatalogue.Configuration {
        .init(values: context != nil && model.omp.configurationContext == context ? model.omp.values : [:],
              memoryEnabled: model.settings.ompMemory.enabled)
    }

    private var busy: Bool {
        model.omp.isLoading || model.omp.isSaving || pending != nil
    }

    private func rows(_ configuration: OMPToolCatalogue.Configuration) -> [OMPToolCatalogue.Entry] {
        let query = query.trimmed
        guard !query.isEmpty else { return OMPToolCatalogue.entries }
        return OMPToolCatalogue.entries.filter { item in
            let shared = item.editableControls.contains { OMPToolCatalogue.members(of: $0).count > 1 }
            let terms = [item.name, item.purpose, item.group.title, item.call.title(xdev: configuration.xdev),
                         item.gate.status(configuration).compactTitle, item.statusTitle(configuration), item.condition ?? ""] + item.gate.keys
                + item.controls.map(\.title) + item.controls.compactMap(\.settingsPage) + (shared ? ["Shared switch"] : [])
            return (terms + terms.map { Chrome.localized($0) }).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        let configuration = self.configuration
        let rows = self.rows(configuration)
        // A shared native setting gets one control, on its first visible member.
        let owners = rows.reduce(into: [String: String]()) { owners, item in
            for control in item.editableControls where owners[control.id] == nil { owners[control.id] = item.id }
        }
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            if let error = model.omp.error {
                HStack(spacing: 12) {
                    Text(verbatim: error).font(.ui(.subheadline)).foregroundStyle(Chrome.danger)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Reload") { activation += 1 }.buttonStyle(.glass).disabled(busy)
                }
            }
            ForEach(OMPToolCatalogue.Group.allCases, id: \.self) { group in
                let items = rows.filter { $0.group == group }
                if !items.isEmpty {
                    ChromeSection(title: group.title) {
                        ChromeCard {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { ChromeRowDivider() }
                                HStack(spacing: 10) {
                                    Text(verbatim: item.name).font(.ui(.body, weight: .medium))
                                        .foregroundStyle(Chrome.primaryText)
                                        .lineLimit(1).truncationMode(.middle)
                                        .help(Text(verbatim: item.name))
                                    tags(item, configuration: configuration)
                                    Spacer(minLength: 0)
                                    HStack(spacing: 10) {
                                        ForEach(item.editableControls.filter { owners[$0.id] == item.id }) { control in
                                            controlView(control, configuration: configuration)
                                        }
                                    }
                                    .fixedSize(horizontal: true, vertical: false)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            if rows.isEmpty {
                Text("No matching tools.").font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
            }
        }
        .task(id: Request(context: context, activation: activation)) {
            await model.omp.refresh(force: true, configurationOnly: true)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { activation += 1 }
        }
    }

    private func tags(_ item: OMPToolCatalogue.Entry, configuration: OMPToolCatalogue.Configuration) -> some View {
        let status = item.gate.status(configuration)
        return HStack(spacing: 6) {
            callTag(item, configuration: configuration)
            tag(status.compactTitle, color: status == .enabled ? Chrome.blue : Chrome.secondaryText)
                .help(Text(verbatim: statusHelp(item, configuration: configuration)))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func callTag(_ item: OMPToolCatalogue.Entry, configuration: OMPToolCatalogue.Configuration) -> some View {
        tag(item.call.title(xdev: configuration.xdev), color: Chrome.secondaryText)
            .help(Text(verbatim: item.callExample(configuration)))
    }

    private func statusHelp(_ item: OMPToolCatalogue.Entry, configuration: OMPToolCatalogue.Configuration) -> String {
        let detail = item.statusTitle(configuration)
        var lines = [Chrome.localized(detail)]
        if let condition = item.condition, condition != detail { lines.append(Chrome.localized(condition)) }
        lines += item.gate.keys
        if item.gate.usesGUIMemory { lines.append(Chrome.localized("GUI memory setting")) }
        for control in item.controls {
            let members = OMPToolCatalogue.members(of: control)
            if members.count > 1 { lines.append(String(format: Chrome.localized("Controls: %@"), members.joined(separator: ", "))) }
            if let page = control.settingsPage {
                lines.append(String(format: Chrome.localized("Managed in %@ settings"), Chrome.localized(page)))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func tag(_ title: String, color: Color) -> some View {
        Text(verbatim: Chrome.localized(title)).font(.ui(.caption))
            .lineLimit(1)
            .foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 3)
            .background(Chrome.overlay(0.06), in: Capsule())
    }

    @ViewBuilder private func controlView(_ control: OMPToolCatalogue.Control,
                                         configuration: OMPToolCatalogue.Configuration) -> some View {
        let value = pending?.control == control ? pending?.value : control.value(in: configuration)
        Group {
            switch control {
            case .flag:
                HStack(spacing: 8) {
                    if control == .flag("eval.js") || control == .flag("eval.py") {
                        Text(verbatim: Chrome.localized(control.inlineTitle)).font(.ui(.caption)).lineLimit(1)
                    }
                    SettingsSwitch(isOn: Binding(get: { value?.bool ?? false }, set: { set(control, .bool($0)) }))
                        .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("Enable %@"),
                            control.title == "Tool enabled" ? OMPToolCatalogue.members(of: control).joined(separator: ", ")
                                : Chrome.localized(control.title))))
                }
            case .find:
                Picker("Search mode", selection: Binding(get: { value?.string ?? "auto" }, set: { set(control, .string($0)) })) {
                    Text("Automatic").tag("auto")
                    Text("On").tag("on")
                    Text("Off").tag("off")
                }.labelsHidden().controlSize(.small)
            case .depth:
                let depth = value?.int ?? 0
                Picker("Delegation depth", selection: Binding(get: { depth }, set: { set(control, .int($0)) })) {
                    Text("Off").tag(0)
                    ForEach(Array(Set([1, 2, 3, depth].filter { $0 > 0 })).sorted(), id: \.self) { value in
                        Text(verbatim: String(format: Chrome.localized("Depth %lld"), value)).tag(value)
                    }
                    Text("Unlimited").tag(-1)
                }.labelsHidden().controlSize(.small)
            case .memory: EmptyView()
            }
        }
        .disabled(busy || value == nil)
        .help(Text(verbatim: controlHelp(control)))
    }

    private func controlHelp(_ control: OMPToolCatalogue.Control) -> String {
        let members = OMPToolCatalogue.members(of: control).joined(separator: ", ")
        return String(format: Chrome.localized("Controls: %@"), members) + "\n" + (control.key ?? Chrome.localized("GUI memory setting"))
    }

    private func set(_ control: OMPToolCatalogue.Control, _ value: JSONValue) {
        guard !busy, control.settingsPage == nil, control.accepts(value),
              let expected = control.value(in: configuration), expected != value else { return }
        let originalContext = context
        pending = (control, value)
        Task {
            defer { pending = nil }
            guard originalContext == context, model.omp.configurationContext == context else { return }
            await model.omp.setTool(control, value, expected: expected)
        }
    }
}
