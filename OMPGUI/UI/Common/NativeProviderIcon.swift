import Foundation
import SwiftUI

/// Offline names and artwork for native IDs; provider identities and keys stay with OMP.
enum NativeProviderPresentation {
    private final class ResourceBundle: NSObject {}
    private struct Manifest: Decodable, Sendable {
        struct Icon: Decodable, Sendable {
            let slug: String
            let providers: [String]
        }
        let icons: [Icon]
        let providerNames: [String: String]
        let initialOnlyProviders: [String]
    }

    // The bundled manifest is the only brand table, shared by every native UI.
    // A malformed bundle falls back to initials instead of guessing identities.
    private static let manifest: Manifest? = {
        guard let url = Bundle(for: ResourceBundle.self).url(forResource: "ProviderLogos", withExtension: "json"),
              let data = try? Data(contentsOf: url), data.count <= 128 * 1_024,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.icons.count <= 256 else { return nil }
        return manifest
    }()

    private static let assets: [String: String] = {
        guard let manifest else { return [:] }
        let initialOnly = Set(manifest.initialOnlyProviders.map { $0.lowercased() })
        var result: [String: String] = [:]
        for icon in manifest.icons {
            guard !icon.slug.isEmpty, icon.slug.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  icon.providers.count <= 128 else { return [:] }
            for provider in icon.providers {
                let id = provider.lowercased()
                guard !id.isEmpty, id.utf8.count <= 128, result[id] == nil else { return [:] }
                if !initialOnly.contains(id) { result[id] = "provider-lobe-" + icon.slug }
            }
        }
        return result
    }()
    static var assetNames: Set<String> { Set(assets.values) }
    static func assetName(for provider: String) -> String? {
        let id = provider.lowercased()
        return id == "omp" ? "provider-omp" : assets[id]
    }

    static func displayName(for provider: String, nativeName: String? = nil) -> String {
        if let nativeName, !nativeName.isEmpty, nativeName != provider { return nativeName }
        guard let name = manifest?.providerNames[provider.lowercased()] else { return provider }
        return Chrome.localized(name)
    }

    static func matches(provider: String, nativeName: String, environmentKeys: [String], query: String) -> Bool {
        let fields = [provider, nativeName, displayName(for: provider, nativeName: nativeName),
                      manifest?.providerNames[provider.lowercased()] ?? ""] + environmentKeys
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
            fields.contains { $0.localizedCaseInsensitiveContains(term) }
        }
    }

    static func initial(for name: String) -> String {
        guard let first = name.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(String(first).uppercased().prefix(1))
    }
}

typealias NativeProviderLogo = NativeProviderPresentation

struct NativeProviderIcon: View {
    let providerID: String
    var name: String? = nil
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let name = NativeProviderLogo.assetName(for: providerID) {
                Image(name).renderingMode(.template).resizable().scaledToFit()
            } else {
                Text(verbatim: NativeProviderLogo.initial(for: name ?? providerID))
                    .font(.ui(size: size * 1.25, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
