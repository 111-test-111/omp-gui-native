import SwiftUI

/// A presentation owns the values and profile displayed when editing began.
/// Using one item also prevents the first sheet from capturing an empty @State value.
struct OMPConfigurationFormSnapshot: Identifiable {
    let id = UUID()
    let value: JSONValue
    let directory: URL
}

/// Model selectors remain native strings; unknown record fields are retained.
struct OMPSelectorForm: View {
    let title: String
    let names: [String]
    let original: JSONValue
    let directory: URL
    let save: ([String: String]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [String: String] = [:]
    @State private var saving = false
    @State private var error: String?

    private var editableNames: [String] {
        // Preserve unknown non-string fields without coercing them into a model ID.
        names.filter { original[$0] == nil || original[$0]?.string != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            Text(verbatim: Chrome.localized(title)).font(.ui(.title2, weight: .semibold))
            Text("Saved to the active OMP profile. Project and process overrides may supply different effective values in a chat.")
                .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
            Text(verbatim: directory.appendingPathComponent("config.yml").path)
                .font(.ui(.caption, design: .monospaced)).textSelection(.enabled)
            ScrollView {
                ChromeCard {
                    ForEach(Array(editableNames.enumerated()), id: \.element) { index, name in
                        if index > 0 { ChromeRowDivider() }
                        ChromeRow(title: name) {
                            TextField("Native model selector or role alias", text: Binding(
                                get: { fields[name] ?? "" }, set: { fields[name] = $0 }))
                                .textFieldStyle(.chromeGlass).font(.ui(.subheadline, design: .monospaced))
                                .frame(width: 290)
                        }
                    }
                }
            }
            .frame(maxHeight: 420)
            Text("Leave a field blank to remove that assignment. Other native configuration fields are preserved.")
                .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
            if let error { Text(verbatim: error).font(.ui(.subheadline)).foregroundStyle(Chrome.danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Save") {
                    saving = true
                    Task {
                        error = await save(fields)
                        saving = false
                        if error == nil { dismiss() }
                    }
                }.buttonStyle(.glass).disabled(saving).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Chrome.contentHorizontalPadding)
        .frame(width: 650)
        .background { WindowBackdrop(opacity: AppSettings.defaultBackdropOpacity) }
        .onAppear { fields = Dictionary(uniqueKeysWithValues: editableNames.map { ($0, original[$0]?.string ?? "") }) }
        .interactiveDismissDisabled(saving)
    }
}

struct OMPAgentListForm: View {
    let original: JSONValue
    let directory: URL
    let save: (JSONValue) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Disabled native agents").font(.ui(.title2, weight: .semibold))
            Text("Enter one native agent name per line. Leave blank to allow all configured agents.")
                .font(.ui(.subheadline)).foregroundStyle(Chrome.secondaryText)
            Text(verbatim: directory.appendingPathComponent("config.yml").path)
                .font(.ui(.caption, design: .monospaced)).textSelection(.enabled)
            TextEditor(text: $text)
                .font(.ui(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 180)
                .chromeGlassInputSurface()
            if let error { Text(verbatim: error).foregroundStyle(Chrome.danger) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).disabled(saving)
                Button("Save") {
                    var seen = Set<String>()
                    let names = text.split(whereSeparator: \.isNewline).map { String($0).trimmed }.filter { !$0.isEmpty && seen.insert($0).inserted }
                    // Preserve future non-string native elements when editing known names.
                    let unknown = original.array?.filter { $0.string == nil } ?? []
                    saving = true
                    Task {
                        error = await save(.array(names.map(JSONValue.string) + unknown))
                        saving = false
                        if error == nil { dismiss() }
                    }
                }.buttonStyle(.glass).disabled(saving)
            }
        }.padding(24).frame(width: 600)
        .onAppear { text = original.array?.compactMap(\.string).joined(separator: "\n") ?? "" }
        .interactiveDismissDisabled(saving)
    }
}
