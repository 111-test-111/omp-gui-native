"""Compile small production slices where the application has no test target.

Fail on missing extraction anchors; never substitute a copied implementation.
"""
import json
import runpy


def prepare(name, repo, output):
    def read(path):
        return (repo / path).read_text()

    def write(path, text):
        (output / path).write_text(text)

    if name == "store":
        state = read("OMPGUI/UI/Preview/FilePreviewContent.swift").split("struct FilePreviewContent: View", 1)
        if len(state) != 2 or "final class PreviewReaderState" not in state[0]:
            raise ValueError("Production PreviewReaderState extraction anchor changed")
        write("PreviewReaderState.swift", state[0])
        window = read("OMPGUI/App/Window/WindowManager.swift")
        write("HostedEnvironment.swift", "import SwiftUI\n" + window[
            window.index("struct HostedEnvironment:"):window.index("final class FrameHostingView:")])
        columns = read("OMPGUI/App/Views/RootView.swift")
        start = columns.index("        private static func root(")
        factory = columns[start:columns.index("        private func drop(", start)]
        visibility = columns[columns.index("private struct ChatColumnVisibility:"):columns.index("struct WelcomeView:")]
        write("PreviewChatRoot.swift", "import SwiftUI\n" + visibility.replace("private struct", "struct", 1) +
              "@MainActor enum PreviewChatRoot {\n" + factory.replace("private static func root(", "static func root(", 1) + "}\n")
        links = read("OMPGUI/UI/Markdown/LinkParagraphView.swift")
        start = links.index("enum MarkdownLinkOpener {")
        write("MarkdownLinkOpener.swift", "import Foundation\n" + links[
            start:links.index("extension NSAttributedString.Key {", start)])
    elif name == "entrypoints":
        models = read("OMPGUI/Core/Models/Timeline.swift")
        stubs = """import Foundation
enum ShellCommandKind { static func mayWriteFiles(_ text: String) -> Bool { false } }
enum AppText { static func localized(_ text: String) -> String { text } }
"""
        write("Models.swift", stubs + models[models.index("struct ToolCall:"):models.index("enum TurnStatus:")])
        decoder = read("OMPGUI/Services/Providers/OMPEventDecoder.swift")
        write("OMPFileReference.swift", "import Foundation\n" + decoder[decoder.index("enum OMPFileReference {"):])
    elif name == "renderers":
        window = read("OMPGUI/App/Window/WindowManager.swift")
        write("FrameHostingView.swift", "import AppKit\nimport SwiftUI\n" + window[window.index("final class FrameHostingView:"):])
        chrome = read("OMPGUI/UI/Chrome/Chrome.swift")
        pieces = [chrome[:chrome.index("/// The window supplies the exterior curve")],
                  chrome[chrome.index("struct ChromeCapsule<"):chrome.index("/// Lets a containing toolbar stay visible")],
                  chrome[chrome.index("struct NoWindowDragArea:"):]]
        write("PreviewChrome.swift", "\n".join(pieces))
    elif name == "markdown-preview":
        parts = read("OMPGUI/UI/Preview/FilePreviewContent.swift").split("struct FilePreviewContent: View", 1)
        if len(parts) != 2:
            raise ValueError("Production reader-state extraction anchor changed")
        write("corpus.json", json.dumps(runpy.run_path(str(repo / "tests/benchmarks/math_renderers/corpus.py"))["fixtures"]()))
        write("Support.swift", parts[0] + """
enum Chrome {
    static var accentNSColor: NSColor { .systemBlue }
    static var glassTint: Color { .white }
    static func panelControlFill(isDark: Bool) -> Color { Color.primary.opacity(isDark ? 0.12 : 0.04) }
    static func localized(_ key: String) -> String { key }
}
enum CaptureRun { static var defaults: UserDefaults? { nil } }
""")
    elif name:
        raise ValueError(f"Unknown source preparation: {name}")
