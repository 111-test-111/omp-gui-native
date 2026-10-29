import AppKit
import CoreImage
import SwiftUI

/// The selected treatment has one entry point for future material replacements.
/// Keep opacity handling inside the treatment: native glass, if selected later,
/// must sample the mixed image rather than have its entire layer faded out.
enum WallpaperEffect: Sendable {
    case gaussian

    nonisolated static let current: Self = .gaussian

    /// Reuse one thread-safe context for full-size and live slider renders.
    nonisolated private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Prepare the bitmap once, before opacity/compositing. Zero softness must
    /// preserve the decoded picture; the surface must not apply a second blur.
    nonisolated func prepare(_ base: CGImage, softness: Double, radiusScale: CGFloat = 1) -> CGImage? {
        switch self {
        case .gaussian:
            let radius = min(1, max(0, softness)) * 28 * max(0, radiusScale)
            guard radius > 0.01 else { return base }
            guard let blur = CIFilter(name: "CIGaussianBlur") else { return base }
            // Clamp before blurring, then crop to keep the image's edges opaque.
            let extent = CGRect(origin: .zero, size: CGSize(width: base.width, height: base.height))
            blur.setValue(CIImage(cgImage: base).clampedToExtent(), forKey: kCIInputImageKey)
            blur.setValue(radius, forKey: kCIInputRadiusKey)
            guard let output = blur.outputImage?.cropped(to: extent) else { return nil }
            return Self.ciContext.createCGImage(output, from: extent)
        }
    }
}

struct WallpaperEffectSurface: View {
    @Environment(\.colorScheme) private var colorScheme
    let image: NSImage
    let opacity: Double
    var effect: WallpaperEffect = .current

    private var picture: some View {
        GeometryReader { geometry in
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
    }

    var body: some View {
        let amount = min(1, max(0, opacity))
        ZStack {
            if amount < 1 {
                // Frost desktop content before blending, so browser text cannot
                // become sharp again when the wallpaper is made transparent.
                Rectangle().fill(.ultraThinMaterial)
            }
            switch effect {
            case .gaussian:
                // The store has already applied the chosen softness. Scaling this
                // bitmap also keeps the miniature preview proportional to the window.
                picture
                    .opacity(amount)
            }
        }
        .overlay {
            // A bright picture still needs contrast for light text at full opacity.
            if colorScheme == .dark { Color.black.opacity(0.66) }
        }
        .clipped()
    }
}
