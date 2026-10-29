// Offscreen design evidence. Run from the repository root after `make build`:
// xcrun swiftc -swift-version 6 -parse-as-library docs/evaluations/2026-10-28-tool-symbol-audit/render.swift -o build.noindex/custom-symbols/render
// build.noindex/custom-symbols/render
import AppKit
import SwiftUI

private let evidenceDirectory = "docs/evaluations/2026-10-28-tool-symbol-audit"

private enum Mark {
    case system(String)
    case custom(String)
    case recipe(String, String)
}

private struct Candidate {
    let tool: String
    let current: String
    let proposed: Mark
    let note: String
}

private struct Glyph: View {
    let mark: Mark
    let pointSize: CGFloat
    let bundle: Bundle

    @ViewBuilder var body: some View {
        switch mark {
        case .system(let name):
            Image(systemName: name).font(.system(size: pointSize))
        case .custom(let name):
            Image(name, bundle: bundle).renderingMode(.template).font(.system(size: pointSize))
        case .recipe(let base, let badge):
            // Show the actual native components rather than claiming an unexported
            // composite has passed SF Symbols' annotation/optical-size validation.
            HStack(spacing: 5) {
                Image(systemName: base)
                Text(verbatim: "+").font(.system(size: pointSize * 0.6))
                Image(systemName: badge)
            }
            .font(.system(size: pointSize))
        }
    }
}

private struct FindPanel: View {
    let dark: Bool
    let bundle: Bundle

    private let labels = ["原文字搜索", "布局参考", "find · 已应用"]
    private let marks: [Mark] = [
        .system("rectangle.and.text.magnifyingglass"),
        .system("folder.badge.questionmark"),
        .custom("tool-find-folder"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(verbatim: dark ? "深色" : "浅色").font(.system(size: 14, weight: .semibold))
            HStack(alignment: .top, spacing: 0) {
                ForEach(0..<marks.count, id: \.self) { index in
                    VStack(spacing: 16) {
                        Glyph(mark: marks[index], pointSize: 42, bundle: bundle).frame(height: 50)
                        Text(verbatim: labels[index]).font(.system(size: 13, weight: .medium))
                        HStack(spacing: 7) {
                            Glyph(mark: marks[index], pointSize: 12, bundle: bundle).frame(width: 16, height: 16)
                            Text(verbatim: "find  src/").font(.system(size: 12))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .frame(width: 150)
                }
            }
            Text(verbatim: "工具行 12 pt / 槽位 16 pt · 上方为放大预览")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(24)
        .foregroundStyle(dark ? Color.white : Color.black)
        .background(dark ? Color(white: 0.10) : Color(white: 0.98))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

private struct AuditPanel: View {
    let dark: Bool
    let bundle: Bundle
    let candidates: [Candidate] = [
        .init(tool: "analyze_files", current: "wind", proposed: .system("doc.text.magnifyingglass"), note: "现成 SF · 文件分析"),
        .init(tool: "write", current: "pencil.tip.crop.circle.badge.plus", proposed: .system("doc.badge.plus"), note: "现成 SF · 创建文件"),
        .init(tool: "security_scan", current: "viewfinder.trianglebadge.exclamationmark", proposed: .recipe("shield", "magnifyingglass.circle.fill"), note: "可定制 · 安全检查"),
        .init(tool: "ast_grep", current: "point.3.connected.trianglepath.dotted", proposed: .recipe("point.3.connected.trianglepath.dotted", "magnifyingglass.circle.fill"), note: "可定制 · 语法树搜索"),
        .init(tool: "web_search", current: "safari", proposed: .recipe("globe", "magnifyingglass.circle.fill"), note: "可定制 · 网络搜索"),
        .init(tool: "glob", current: "folder", proposed: .recipe("folder", "asterisk.circle.fill"), note: "可定制 · 路径通配"),
        .init(tool: "ast_edit", current: "point.3.filled.connected.trianglepath.dotted", proposed: .recipe("point.3.connected.trianglepath.dotted", "pencil.circle.fill"), note: "可制作 · 小尺寸需取舍"),
        .init(tool: "memory_edit", current: "brain.head.profile", proposed: .recipe("brain.head.profile", "pencil.circle.fill"), note: "可制作 · 小尺寸需取舍"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "其余工具候选 · 尚未应用")
                .font(.system(size: 19, weight: .semibold)).padding(.bottom, 10)
            Text(verbatim: "统一为空心主体＋右上实心圆标；“＋”展示素材，组合仍需制作并检查 12 pt 效果。")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 20)
            HStack {
                Text(verbatim: "工具").frame(width: 135, alignment: .leading)
                Text(verbatim: "当前").frame(width: 70)
                Text(verbatim: "候选 / 组合素材").frame(width: 155)
                Text(verbatim: "判断").frame(width: 180, alignment: .leading)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(candidates.indices, id: \.self) { index in
                Divider().padding(.top, 12).padding(.bottom, 12)
                let item = candidates[index]
                HStack {
                    Text(verbatim: item.tool).font(.system(size: 13, design: .monospaced))
                        .frame(width: 135, alignment: .leading)
                    Glyph(mark: .system(item.current), pointSize: 23, bundle: bundle).frame(width: 70)
                    Glyph(mark: item.proposed, pointSize: 23, bundle: bundle).frame(width: 155)
                    Text(verbatim: item.note).font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(width: 180, alignment: .leading)
                }.frame(height: 28)
            }
        }
        .padding(24)
        .foregroundStyle(dark ? Color.white : Color.black)
        .background(dark ? Color(white: 0.10) : Color(white: 0.98))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

@main @MainActor private enum RenderToolSymbolEvidence {
    static func save<V: View>(_ view: V, name: String, directory: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let data = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
            fatalError("Could not render \(name)")
        }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let app = root.appendingPathComponent("build.noindex/development/Build/Products/Debug/OMP GUI Dev.app")
        guard let bundle = Bundle(url: app), bundle.image(forResource: "tool-find-folder") != nil else {
            fatalError("Run make build in this worktree first")
        }
        let directory = root.appendingPathComponent(evidenceDirectory)
        try save(HStack(spacing: 0) {
            FindPanel(dark: false, bundle: bundle)
            FindPanel(dark: true, bundle: bundle)
        }, name: "find-preview", directory: directory)
        try save(VStack(spacing: 0) {
            AuditPanel(dark: false, bundle: bundle)
            AuditPanel(dark: true, bundle: bundle)
        }, name: "candidates", directory: directory)
        print("Saved native SF Symbol previews in \(evidenceDirectory)")
    }
}
