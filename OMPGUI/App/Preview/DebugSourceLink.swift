import SwiftUI

struct DebugSourceLink: View {
    let source: OMPDebugSource
    let cwd: String?
    let previews: FilePreviewStore
    let context: FilePreviewContext
    @State private var resolved: FilePreviewReference?
    @State private var opening: Task<Void, Never>?

    private var identity: String { "\(source)|\(cwd ?? "")|\(context.workingDirectory)" }
    var body: some View {
        let iconSize = TypeScale.shared.ui(TypeScale.stockPointSize(.body))
        HStack(spacing: 5) {
            if let resolved {
                Image(nsImage: FileIcons.icon(for: resolved.path))
                    .resizable().scaledToFit().frame(width: iconSize, height: iconSize)
            } else {
                Image(systemName: (source.sourceReference ?? 0) > 0 ? "doc.badge.gearshape" : "number")
                    .font(.symbol(.caption2))
            }
            if resolved != nil {
                Button { open() } label: {
                    Text(verbatim: source.label).lineLimit(1).truncationMode(.middle).contentShape(.rect)
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("debug-source:" + (source.path ?? source.label))
                .help(source.path ?? source.label)
            } else {
                Text(verbatim: source.label).lineLimit(1).truncationMode(.middle)
                    .help((source.path ?? source.label) + "\n" + Chrome.localized((source.sourceReference ?? 0) > 0 ? "Adapter source" : "Source file unavailable"))
            }
        }
        .font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
        .task(id: identity) {
            resolved = nil
            let reference = await OMPDebugSourceResolver.resolve(source, cwd: cwd, directory: context.workingDirectory)
            if !Task.isCancelled { resolved = reference }
        }
        .onDisappear { opening?.cancel(); opening = nil }
    }

    private func open() {
        opening?.cancel()
        opening = Task {
            // The file may have disappeared since the row was mounted.
            let target = await OMPDebugSourceResolver.resolve(source, cwd: cwd, directory: context.workingDirectory)
            guard !Task.isCancelled, previews.context == context else { return }
            resolved = target
            if let target { _ = previews.open(target, context: context) }
        }
    }
}
