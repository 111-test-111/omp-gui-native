// Offscreen design preview. Compile with Swift 6 and run from the repo root.
// Optional arguments: current resource bundle, previous resource bundle.
import AppKit
import SwiftUI

private struct ToolIconRow: View {
    let tool: String
    let before: String
    let after: String
    let custom: Bool
    let previousCustom: Bool
    let note: String
    let bundle: Bundle
    let previous: Bundle

    private func icon(after updated: Bool, size: CGFloat) -> some View {
        Group {
            if updated && custom {
                Image(after, bundle: bundle).renderingMode(.template)
            } else if !updated && previousCustom {
                Image(before, bundle: previous).renderingMode(.template)
            } else {
                Image(systemName: updated ? after : before)
            }
        }
        .font(.system(size: size))
        .symbolRenderingMode(.monochrome)
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: tool).font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text(verbatim: note).font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(width: 135, alignment: .leading)
            icon(after: false, size: 34).frame(width: 72, height: 48)
            icon(after: true, size: 34).frame(width: 72, height: 48)
            HStack(spacing: 6) {
                icon(after: true, size: 12).frame(width: 16, height: 16)
                Text(verbatim: tool).font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .frame(width: 130, alignment: .leading)
        }.padding(.vertical, 16)
    }
}

private struct Panel: View {
    let dark: Bool
    let bundle: Bundle
    let previous: Bundle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: dark ? "深色 · 本次四项调整" : "浅色 · 本次四项调整")
                .font(.system(size: 18, weight: .semibold)).padding(.bottom, 22)
            HStack(spacing: 16) {
                Text(verbatim: "工具 / 位置").frame(width: 135, alignment: .leading)
                Text(verbatim: "之前").frame(width: 72)
                Text(verbatim: "现在").frame(width: 72)
                Text(verbatim: "12 pt 实际工具行").frame(width: 130, alignment: .leading)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            Group {
                Divider().padding(.top, 12)
                ToolIconRow(tool: "find", before: "preview-find-before", after: "tool-find-folder", custom: true,
                    previousCustom: true, note: "右上圆标增大 30%", bundle: bundle, previous: previous)
                Divider()
                ToolIconRow(tool: "glob", before: "folder", after: "tool-glob-folder", custom: true,
                    previousCustom: false, note: "右上实心星号圆标", bundle: bundle, previous: previous)
                Divider()
                ToolIconRow(tool: "read", before: "text.rectangle", after: "text.menu", custom: false,
                    previousCustom: false, note: "原生 text.menu", bundle: bundle, previous: previous)
                Divider()
                ToolIconRow(tool: "analyze_files", before: "wind", after: "tool-analyze-files", custom: true,
                    previousCustom: false, note: "右下实心放大镜圆标", bundle: bundle, previous: previous)
            }
            Text(verbatim: "12 pt 符号字号 / 16 pt 槽位；中间两列为放大预览。")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 12)
        }
        .padding(26)
        .foregroundStyle(dark ? Color.white : Color.black)
        .background(dark ? Color(white: 0.10) : Color(white: 0.98))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

@main @MainActor private enum RenderToolIconRefinements {
    static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let app = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
            : "build.noindex/development/Build/Products/Debug/OMP GUI Dev.app"
        let old = CommandLine.arguments.count > 2 ? CommandLine.arguments[2]
            : "build.noindex/custom-symbols/Preview.bundle"
        guard let bundle = Bundle(url: root.appendingPathComponent(app)),
              let previous = Bundle(url: root.appendingPathComponent(old)) else {
            fatalError("Require current and previous symbol resources")
        }
        let renderer = ImageRenderer(content: HStack(spacing: 0) {
            Panel(dark: false, bundle: bundle, previous: previous)
            Panel(dark: true, bundle: bundle, previous: previous)
        })
        renderer.scale = 2
        guard let image = renderer.nsImage, let data = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
            fatalError("Could not render native tool symbols")
        }
        let destination = root.appendingPathComponent("docs/evaluations/2026-10-28-tool-symbol-refinements/preview.png")
        try png.write(to: destination)
        print("Saved \(destination.path)")
    }
}
