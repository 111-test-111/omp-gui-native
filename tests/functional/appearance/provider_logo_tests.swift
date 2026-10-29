import AppKit
import CryptoKit
import Foundation
@testable import OMPGUI

@main
enum ProviderLogoChecks {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = repo.appendingPathComponent("build.noindex/development/Build/Products/Debug/OMP GUI Dev.app")
        let bundle = Bundle(url: app)!
        let manifestURL = repo.appendingPathComponent("OMPGUI/Resources/ProviderLogos.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = JSONValue.parse(data)!
        let rows = manifest["icons"]!.array!
        var checks = 0
        func expect(_ result: Bool, _ message: String) { precondition(result, message); checks += 1 }
        guard let bundled = bundle.url(forResource: "ProviderLogos", withExtension: "json") else { fatalError("Provider identities must ship with the application") }
        expect(try Data(contentsOf: bundled) == data, "Runtime and asset verification use the same shipped brand table")
        expect(repo.appendingPathComponent("design/icons/provider-logos.json").resolvingSymlinksInPath() == manifestURL,
               "The design entry point refers to the single runtime manifest instead of duplicating aliases")
        let active = Set(rows.filter { $0["providers"]?.array?.isEmpty == false }.map { "provider-lobe-" + $0["slug"]!.string! })
        expect(NativeProviderLogo.assetNames == active, "The active mapping and preserved library manifest agree")
        for row in rows {
            let slug = row["slug"]!.string!, name = "provider-lobe-" + slug
            let path = repo.appendingPathComponent("OMPGUI/Resources/Assets.xcassets/\(name).imageset/\(slug).svg")
            let bytes = try Data(contentsOf: path)
            expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == row["asset_sha256"]?.string,
                   "The pinned provider artwork must match its recorded checksum")
            expect(row["providers"]!.array!.allSatisfy { NativeProviderLogo.assetName(for: $0.string!) == name }, "Every explicit native alias maps to the intended brand")
            guard let image = bundle.image(forResource: name), let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { fatalError("Unrenderable provider logo: \(slug)") }
            expect(image.isTemplate && bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "Provider artwork is compiled as a native template")
            var hasInk = false, hasTransparency = false
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                    if alpha > 0.05 { hasInk = true }
                    if alpha < 0.05 { hasTransparency = true }
                }
            }
            expect(hasInk && hasTransparency, "Provider logo must have visible artwork and a transparent canvas: \(slug)")
        }
        expect(NativeProviderLogo.assetName(for: "my-openai-relay") == nil, "A custom provider never inherits a brand by substring guessing")
        let audit = JSONValue.parse(try Data(contentsOf: repo.appendingPathComponent("docs/evaluations/2026-10-26-provider-brand-audit/native-identities.json")))!
        for identity in audit["rows"]!.array! {
            let id = identity["id"]!.string!
            if let brand = identity["expectedBrand"]?.string {
                expect(NativeProviderLogo.assetName(for: id) == "provider-lobe-" + brand,
                       "Audited native model/key/login identity has its reviewed provider brand: \(id)")
            } else {
                expect(identity["fallbackReason"]?.string?.isEmpty == false && NativeProviderLogo.assetName(for: id) == nil,
                       "Intentionally unbranded native identities keep an explained initial fallback: \(id)")
            }
        }
        expect(["zai", "zai-coding-plan", "zhipu-coding-plan", "ZAI-CODING-PLAN"].allSatisfy { NativeProviderLogo.assetName(for: $0) == "provider-lobe-zai" },
               "Z.ai API keys, browser sign-in and Zhipu Coding Plan share the same brand in every UI")
        expect(["private-zai-relay", "xiaomi-token-plan-private", "opencode-zen-proxy"].allSatisfy { NativeProviderLogo.assetName(for: $0) == nil },
               "Brand-family prefixes and suffixes never brand an unreviewed relay")
        expect(["openai-codex", "openai-codex-device"].allSatisfy { NativeProviderLogo.assetName(for: $0) == NativeProviderLogo.assetName(for: "openai") },
               "Both ChatGPT subscription login routes display the recognizable OpenAI knot")
        expect(NativeProviderLogo.initial(for: "  _Custom relay") == "C" && NativeProviderLogo.initial(for: "云服务") == "云",
               "Unbranded providers use the first name letter, including native Unicode names")
        expect(NativeProviderLogo.initial(for: "ß relay") == "S" && NativeProviderLogo.initial(for: "🦉") == "?",
               "Fallbacks remain one readable glyph when uppercasing expands or no initial exists")
        expect(NativeProviderLogo.assetName(for: "openrouter") == nil && NativeProviderLogo.initial(for: "OpenRouter") == "O",
               "OpenRouter consistently uses its owner-requested uppercase initial")
        expect(NativeProviderPresentation.displayName(for: "minimax-cn").contains("MiniMax")
            && !NativeProviderPresentation.displayName(for: "minimax-cn").contains("-cn"),
               "The native China provider is presented by its proper MiniMax name rather than a raw selector")
        expect(["minimax-cn", "MiniMax China", "MiniMax (China)"].allSatisfy {
            NativeProviderPresentation.matches(provider: "minimax-cn", nativeName: "minimax-cn", environmentKeys: [], query: $0)
        }, "A region-specific key row is searchable by native ID and the complete readable name")
        expect(NativeProviderPresentation.matches(provider: "minimax-cn", nativeName: "MiniMax（中国）", environmentKeys: [], query: "MiniMax 中国"),
               "Localized provider names remain searchable across multiple terms")
        expect(NativeProviderPresentation.displayName(for: "owner-relay", nativeName: "Owner's gateway") == "Owner's gateway"
            && NativeProviderPresentation.displayName(for: "unknown-owner-id") == "unknown-owner-id",
               "Live custom names remain authoritative and unknown identities are not renamed by brand guesses")
        expect(["brave", "firecrawl", "jina", "tinyfish", "azure-openai-responses"].allSatisfy {
            NativeProviderPresentation.displayName(for: $0) != $0
        }, "Legacy API-only identities also have readable provider names")
        expect(bundle.url(forResource: "OMPProviderUsage", withExtension: "js") != nil, "The balance extension ships with the verified application")
        print("Provider logo checks passed: \(checks)")
    }
}
