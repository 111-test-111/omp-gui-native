import AppKit
import SwiftUI
import UniformTypeIdentifiers

// A picked picture with a sample of the actual window backdrop and a slider
// to soften it for readability.
struct WallpaperCard: View {
    @Environment(AppModel.self) private var model
    let store = WallpaperStore.shared
    @State private var isTargeted = false

    private var isOffStock: Bool { store.softness > 0.005 }

    var body: some View {
        ChromeCard {
            preview
            ChromeRowDivider()
            wallpaperRow
            if store.hasWallpaper {
                ChromeRowDivider()
                softnessRow
            }
        }
    }

    private var preview: some View {
        Button { choose() } label: {
            ZStack {
                if let image = store.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            // Use the same compositing as the main and settings windows,
                            // including opacity and performance/accessibility fallbacks.
                            GeometryReader { geo in
                                let mockShape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                                WindowBackdrop(opacity: model.settings.backdropOpacity, wallpaper: image)
                                    .clipShape(mockShape)
                                    .overlay { mockShape.strokeBorder(Chrome.overlay(0.12)) }
                                    .overlay { mockShape.fill(Color.black.opacity(0.2)) }
                                    .overlay(alignment: .topLeading) {
                                        HStack(spacing: 4) {
                                            ForEach(0..<3, id: \.self) { _ in
                                                Circle()
                                                    .fill(Chrome.overlay(0.35))
                                                    .frame(width: 5, height: 5)
                                            }
                                        }
                                        .padding(.top, 8)
                                        .padding(.leading, 8)
                                    }
                                    .frame(width: geo.size.width * 0.6, height: geo.size.height * 0.6)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Chrome.overlay(0.04))
                        .frame(height: 150)
                        .overlay {
                            VStack(spacing: 6) {
                                Image(systemName: "photo.on.rectangle.angled").font(.symbol(.title))
                                    .foregroundStyle(Chrome.secondaryText)
                                Text("Drop a picture here, or choose one")
                                    .font(.ui(.callout))
                                    .foregroundStyle(Chrome.secondaryText)
                            }
                        }
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                if store.isInstalling {
                    ProgressView()
                        .controlSize(.small)
                }
                if isTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Chrome.accent.opacity(0.18))
                        .frame(height: 150)
                        .transition(.opacity)
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .scaleEffect(isTargeted ? 1.02 : 1)
            .animation(.snappy(duration: 0.2), value: isTargeted)
            .animation(.spring(duration: 0.45, bounce: 0.2), value: store.image != nil)
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .dropDestination(for: URL.self, action: { urls, _ in
            guard let url = urls.first(where: WallpaperStore.accepts) else { return false }
            store.install(from: url)
            return true
        }, isTargeted: { isTargeted = $0 })
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    private var wallpaperRow: some View {
        ChromeRow(
            title: "Wallpaper",
            detail: store.lastError ?? (store.hasWallpaper
                ? "Fills the window edge to edge; the transparency slider lets the desktop show through it"
                : "A picture of your own for the window, mixed with the desktop by the transparency slider")
        ) {
            HStack(spacing: 8) {
                if store.hasWallpaper {
                    Button("Remove") { store.remove() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(store.isInstalling)
                }
                Button(Chrome.localized(store.hasWallpaper ? "Change…" : "Choose…")) { choose() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(store.isInstalling)
            }
        }
    }

    private var softnessRow: some View {
        ChromeRow(title: "Softness", detail: "Gaussian blur, from sharp to soft") {
            HStack(spacing: 8) {
                Image(systemName: "drop").font(.symbol(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .help("Sharp")
                Slider(
                    value: Binding(get: { store.softness }, set: { store.softness = $0 }),
                    in: 0...1,
                    onEditingChanged: { editing in store.isAdjustingSoftness = editing }
                )
                .controlSize(.small)
                .frame(width: 140)
                Image(systemName: "drop.fill").font(.symbol(.subheadline))
                    .foregroundStyle(Chrome.secondaryText)
                    .help("More blur")
            }
            .overlay(alignment: .leading) {
                if isOffStock {
                    Button {
                        store.softness = 0
                    } label: {
                        Image(systemName: "arrow.counterclockwise").font(.symbol(.subheadline, weight: .medium))
                            .foregroundStyle(Chrome.secondaryText)
                            .frame(width: 22, height: 22)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Reset softness")
                    .offset(x: -28)
                    .transition(.opacity.combined(with: .offset(x: 6)))
                }
            }
            .animation(.snappy(duration: 0.2), value: isOffStock)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Wallpaper softness"))
        }
    }

    private func choose() {
        // The sheet must not block, so the picker runs async against the key window.
        let panel = NSOpenPanel()
        panel.allowedContentTypes = WallpaperStore.acceptedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = Chrome.localized("Choose a picture for the window")
        panel.prompt = Chrome.localized("Use as Wallpaper")
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url {
                    store.install(from: url)
                }
            }
        } else {
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    store.install(from: url)
                }
            }
        }
    }
}
