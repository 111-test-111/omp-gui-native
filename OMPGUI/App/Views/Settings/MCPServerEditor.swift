import SwiftUI

struct MCPServerEditor: View {
    let snapshot: OMPMCPSnapshot
    let server: OMPMCPServer?
    let save: (JSONValue) async -> String?
    let openFile: () async -> String?
    private let supportsVisual: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var draft: OMPMCPServerDraft
    @State private var enabled: Bool
    @State private var saving = false
    @State private var opening = false
    @State private var error: String?

    init(snapshot: OMPMCPSnapshot, server: OMPMCPServer?, openFile: @escaping () async -> String?,
         save: @escaping (JSONValue) async -> String?) {
        self.snapshot = snapshot
        self.server = server
        self.save = save
        self.openFile = openFile
        let definition: JSONValue = server?.definition ?? ["type": "stdio", "command": ""]
        _name = State(initialValue: server?.id ?? "")
        supportsVisual = server == nil || OMPMCPServerDraft.supportsVisualEditing(definition)
        _draft = State(initialValue: OMPMCPServerDraft(supportsVisual ? definition : ["command": ""]))
        _enabled = State(initialValue: server?.enabled ?? true)
    }

    private var busy: Bool { saving || opening }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: Chrome.localized(server == nil ? "Install MCP server" : "Edit MCP server"))
                    .font(.ui(.body, weight: .semibold))
                Spacer()
                Button("Open JSON file") {
                    Task {
                        opening = true
                        error = await openFile()
                        opening = false
                    }
                }.buttonStyle(.glass).disabled(busy)
            }
            if supportsVisual {
                ChromeCard {
                    ChromeRow(title: "Server name") {
                        TextField("", text: $name).textFieldStyle(.chromeGlass).frame(width: 360)
                            .accessibilityLabel(Text("Server name"))
                    }
                }.disabled(busy)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        MCPServerForm(draft: $draft, enabled: $enabled)
                    }
                    // Leave room for glass drawing beyond the controls' layout bounds.
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .padding(.horizontal, -8)
                .disabled(busy)
            }
            if let error {
                Text(verbatim: error).font(.ui(.subheadline)).foregroundStyle(Chrome.danger).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction).disabled(busy)
                if supportsVisual {
                    Button {
                        Task { await submit() }
                    } label: {
                        Text(verbatim: Chrome.localized(server == nil ? "Install" : "Save"))
                    }.buttonStyle(.glass).keyboardShortcut(.defaultAction).disabled(busy)
                }
            }
        }
        .padding(20).frame(width: 640, height: supportsVisual ? 580 : nil)
        .interactiveDismissDisabled(busy)
    }

    @MainActor private func submit() async {
        guard !busy, supportsVisual else { return }
        do {
            let definition = try draft.definition()
            let value = try OMPMCPDocument.replacingServer(in: snapshot.document(), oldName: server?.id,
                name: name, definition: definition, enabled: enabled)
            saving = true
            error = await save(value)
            saving = false
            if error == nil { dismiss() }
        } catch { self.error = error.localizedDescription }
    }
}

private struct MCPServerForm: View {
    @Binding var draft: OMPMCPServerDraft
    @Binding var enabled: Bool

    var body: some View {
        ChromeCard {
            ChromeRow(title: "Transport") {
                Picker("Transport", selection: $draft.transport) {
                    ForEach(OMPMCPTransport.allCases, id: \.self) { kind in
                        Text(verbatim: Chrome.localized(kind.title)).tag(kind)
                    }
                }.labelsHidden().frame(width: 260, alignment: .trailing)
            }
            ChromeRowDivider()
            ChromeRow(title: "Enabled") { SettingsSwitch(isOn: $enabled).accessibilityLabel(Text("Enabled")) }
            if draft.transport == .stdio {
                ChromeRowDivider()
                ChromeRow(title: "Command") {
                    TextField("", text: $draft.command)
                        .textFieldStyle(.chromeGlass).font(.code(.subheadline)).frame(width: 360)
                        .accessibilityLabel(Text("Command"))
                }
                ChromeRowDivider()
                ChromeRow(title: "Working directory") {
                    TextField("", text: $draft.directory)
                        .textFieldStyle(.chromeGlass).font(.code(.subheadline)).frame(width: 360)
                        .accessibilityLabel(Text("Working directory"))
                }
            } else {
                ChromeRowDivider()
                ChromeRow(title: "Endpoint URL") {
                    TextField("", text: $draft.url)
                        .textFieldStyle(.chromeGlass).font(.code(.subheadline)).frame(width: 360).privacySensitive()
                        .accessibilityLabel(Text("Endpoint URL"))
                }
            }
        }
        if draft.transport == .stdio {
            ChromeSection(title: "Arguments") {
                VStack(spacing: 8) {
                    ForEach($draft.arguments) { $argument in
                        HStack {
                            TextField("", text: $argument.value).textFieldStyle(.chromeGlass).font(.code(.subheadline)).privacySensitive()
                                .accessibilityLabel(Text("Argument"))
                            ChromeCircleButton(symbol: "minus", help: "Remove argument") {
                                let id = argument.id
                                draft.arguments.removeAll { $0.id == id }
                            }
                        }
                    }
                    HStack {
                        Button("Add argument") { draft.arguments.append(OMPMCPArgument()) }.buttonStyle(.glass)
                            .disabled(draft.arguments.count >= OMPMCPServerDraft.rowLimit)
                        Spacer()
                    }
                }
            }
            MCPKeyValueEditor(title: "Environment variables", entries: $draft.environment)
        } else {
            MCPKeyValueEditor(title: "HTTP headers", entries: $draft.headers)
        }
        ChromeCard {
            ChromeRow(title: "Request timeout (ms)") {
                TextField("", text: $draft.timeout)
                    .textFieldStyle(.chromeGlass).font(.code(.subheadline)).frame(width: 260)
                    .accessibilityLabel(Text("Request timeout (ms)"))
            }
            ChromeRowDivider()
            ChromeRow(title: "Include server instructions") {
                SettingsSwitch(isOn: $draft.instructions).accessibilityLabel(Text("Include server instructions"))
            }
        }
    }
}

private struct MCPKeyValueEditor: View {
    let title: String
    @Binding var entries: [OMPMCPKeyValue]
    @State private var revealed: Set<UUID> = []

    var body: some View {
        ChromeSection(title: title) {
            VStack(spacing: 8) {
                ForEach($entries) { $entry in
                    HStack(spacing: 8) {
                        TextField("", text: $entry.key).textFieldStyle(.chromeGlass)
                            .font(.code(.subheadline)).frame(width: 190)
                            .accessibilityLabel(Text("Name"))
                        Group {
                            if revealed.contains(entry.id) { TextField("", text: $entry.value) }
                            else { SecureField("", text: $entry.value) }
                        }.textFieldStyle(.chromeGlass).font(.code(.subheadline)).privacySensitive()
                            .accessibilityLabel(Text("Value or native reference"))
                        ChromeCircleButton(symbol: revealed.contains(entry.id) ? "eye.slash" : "eye",
                                           help: revealed.contains(entry.id) ? "Hide value" : "Show value") {
                            if !revealed.insert(entry.id).inserted { revealed.remove(entry.id) }
                        }
                        ChromeCircleButton(symbol: "minus", help: "Remove entry") {
                            let id = entry.id
                            entries.removeAll { $0.id == id }
                            revealed.remove(id)
                        }
                    }
                }
                HStack {
                    Button("Add entry") { entries.append(OMPMCPKeyValue()) }.buttonStyle(.glass)
                        .disabled(entries.count >= OMPMCPServerDraft.rowLimit)
                    Spacer()
                }
            }
        }
    }
}
