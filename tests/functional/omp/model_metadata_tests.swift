import AppKit
import SwiftUI
@testable import OMPGUI

@MainActor
enum ModelMetadataChecks {
    private static var checks = 0

    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
    }

    private static let row: JSONValue = [
        "provider": "openai-codex", "id": "fixture-model", "name": "Fixture model",
        "api": "openai-codex-responses", "serviceTiers": ["default", "priority"],
        "input": ["text", "image"], "contextWindow": 1_000_000, "maxTokens": 32_768,
        "thinking": ["low", "medium", "high"], "pricingStatus": "fixed",
        "cost": ["input": 0.3, "output": 1.2, "cacheRead": 0.006, "cacheWrite": 0]
    ]

    private static func option(_ fields: JSONValue? = nil, cli: Bool = true) -> ModelOption {
        OMPCLI.modelOptions([fields ?? row], pricesAreCLISnapshot: cli)[0]
    }

    static func run(root: URL) async throws -> Int {
        let paid = option()
        let metadata = paid.metadata!
        let locale = Locale(identifier: "en_US")
        expect(metadata.inputTypes == ["text", "image"] && metadata.contextWindow == 1_000_000
               && metadata.maxOutputTokens == 32_768, "CLI discovery preserves declared inputs and both token limits")
        expect(metadata.pricing.input == 0.3 && metadata.pricing.output == 1.2
               && metadata.pricing.cacheRead == 0.006 && metadata.pricing.cacheWrite == 0,
               "All four rate components survive discovery, including a declared zero component")
        expect(paid.supportsFast && paid.efforts == ["low", "medium", "high"],
               "Adding detail metadata preserves existing Fast and thinking discovery")
        expect(try JSONDecoder().decode(ModelOption.self, from: JSONEncoder().encode(paid)) == paid,
               "Metadata and price provenance survive a model-option round trip")
        let legacy = try JSONDecoder().decode(ModelOption.self, from: Data(#"{"id":"legacy","name":"Legacy"}"#.utf8))
        expect(legacy.metadata == nil && ModelDetailsPresentation.inputTypes(legacy.metadata) == "Unknown",
               "Old archives remain decodable and missing modality metadata stays unknown")
        expect(ModelDetailsPresentation.tokens(metadata.contextWindow, locale: locale) == "1,000,000 tokens",
               "Token limits are grouped exactly without an approximate K/M abbreviation")
        expect(ModelDetailsPresentation.price(metadata.pricing, .cacheRead, locale: locale) == "$0.006",
               "Small cache prices retain their precision")
        expect(ModelDetailsPresentation.price(metadata.pricing, .cacheWrite, locale: locale) == "$0",
               "A zero component on a paid card remains an explicit zero rate")
        var tiny = metadata.pricing
        tiny.cacheRead = 0.000000004
        expect(ModelDetailsPresentation.price(tiny, .cacheRead, locale: locale) == "$0.000000004",
               "Positive cache rates never round down to a displayed zero")

        var fields = row.object!
        fields["input"] = .null
        fields["contextWindow"] = .null
        fields["maxTokens"] = 42.5
        fields["cost"] = .null
        fields.removeValue(forKey: "pricingStatus")
        let missing = option(.object(fields)).metadata!
        expect(missing.inputTypes == nil && missing.contextWindow == nil && missing.maxOutputTokens == nil,
               "Absent, null and invalid fractional limits stay unknown")
        expect(ModelDetailsPresentation.tokens(missing.contextWindow) == "Unknown"
               && ModelDetailsPresentation.price(missing.pricing, .input) == "Unknown",
               "Unavailable limits and prices render explicitly as unknown")

        fields = row.object!
        fields["cost"] = ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0]
        fields.removeValue(forKey: "pricingStatus")
        expect(option(.object(fields)).metadata?.pricing.status == .unknown,
               "A legacy all-zero rate card is never inferred to be free")
        let statusCases: [(ModelPricing.Status, String, String)] = [
            (.free, "Free", "Free"), (.included, "Included in plan", "Included in plan"),
            (.unknown, "Price unknown", "Unknown"), (.variable, "Variable pricing", "Variable pricing")
        ]
        for (status, title, value) in statusCases {
            fields["pricingStatus"] = .string(status.rawValue)
            let pricing = option(.object(fields)).metadata!.pricing
            expect(pricing.status == status && ModelDetailsPresentation.status(pricing) == title,
                   "The declared billing status remains distinct: \(status)")
            expect(ModelPricing.Component.allCases.allSatisfy { ModelDetailsPresentation.price(pricing, $0, locale: locale) == value },
                   "Zero rates follow their explicit free/included/unknown/variable interpretation: \(status)")
        }
        fields["pricingStatus"] = "future-billing-mode"
        fields["cost"] = row["cost"]
        expect(option(.object(fields)).metadata?.pricing.status == .unknown,
               "An unfamiliar explicit billing mode remains unknown rather than guessing a price interpretation")
        fields.removeValue(forKey: "pricingStatus")
        fields["cost"] = ["output": 2]
        let partial = option(.object(fields)).metadata!.pricing
        expect(partial.status == .fixed && ModelDetailsPresentation.price(partial, .output, locale: locale) == "$2"
               && ModelDetailsPresentation.price(partial, .input) == "Unknown",
               "Legacy positive rates remain usable without inventing missing components")
        fields["pricingStatus"] = "fixed"
        fields["cost"] = ["input": -1, "output": .null, "cacheRead": "0.1", "cacheWrite": .double(.infinity)]
        let invalid = option(.object(fields)).metadata!.pricing
        expect(ModelPricing.Component.allCases.allSatisfy { invalid.rate($0) == nil },
               "Invalid, negative and nonfinite rates cannot enter the price display")

        fields = row.object!
        fields["input"] = ["text", "future-modality"]
        fields["contextWindow"] = 2_000_000
        fields["maxTokens"] = .null
        fields["cost"] = ["input": 9, "output": 99, "cacheRead": 1, "cacheWrite": 2]
        fields.removeValue(forKey: "pricingStatus")
        let live = option(.object(fields), cli: false).metadata!
        let merged = live.merging(cached: metadata)
        expect(merged.inputTypes == ["text", "future-modality"] && merged.contextWindow == 2_000_000
               && merged.maxOutputTokens == 32_768, "RPC refresh refines known capability fields and retains omitted CLI limits")
        expect(merged.pricing == metadata.pricing, "A session RPC refresh cannot replace resolved CLI prices or billing status with raw rates")
        expect(ModelDetailsPresentation.inputTypes(merged).contains("future-modality"),
               "Future modality names remain visible verbatim")

        fields = row.object!
        fields["cost"] = ["input": 1, "output": 2, "cacheRead": 0.1, "cacheWrite": 0,
                          "longContext": ["inputThreshold": 200_000], "timeBased": ["offPeakMultiplier": 0.5]]
        expect(option(.object(fields)).metadata!.pricing.hasContextOrTimeTiers,
               "Tiered or scheduled rates remain identified in catalogue metadata")

        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await render(paid, name: "paid", root: root)
        for status in [ModelPricing.Status.free, .included, .unknown] {
            fields = row.object!
            fields["pricingStatus"] = .string(status.rawValue)
            fields["cost"] = ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0]
            try await render(option(.object(fields)), name: status.rawValue, root: root)
        }
        var long = paid
        long.name = String(repeating: "Long model name ", count: 8)
        long.id = "fixture/" + String(repeating: "long-model-identifier-", count: 8)
        long.metadata?.inputTypes = (0..<8).map { "Long future input modality \($0)" }
        long.metadata?.contextWindow = Int.max
        long.metadata?.maxOutputTokens = Int.max
        long.metadata?.pricing.input = 1e100
        long.metadata?.pricing.output = 1e100
        long.metadata?.pricing.cacheRead = 1e100
        long.metadata?.pricing.cacheWrite = 1e100
        try await render(long, name: "long", root: root, expectsScrolling: true)
        return checks
    }

    private static func render(_ option: ModelOption, name: String, root: URL, expectsScrolling: Bool = false) async throws {
        let content = ModelDetailsPopover(option: option).presentedChrome()
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.colorScheme, .light)
            .background(Color.white)
        let host = NSHostingView(rootView: content)
        let openingSize = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: openingSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        let finalSize = host.fittingSize
        expect(finalSize.width == 400 && finalSize.height > 150 && finalSize.height < (expectsScrolling ? 500 : 420),
               "The \(name) model detail fits its content without retaining the old fixed-height gap")
        expect(abs(finalSize.height - openingSize.height) <= 1,
               "The \(name) model detail opens at its final height without a second resize")
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first,
              let document = scroll.documentView else { preconditionFailure("Model details must retain bounded scrolling") }
        expect(scroll.contentView.bounds.height <= 341,
               "The \(name) model detail's scrolling body stays within its height cap")
        if expectsScrolling {
            expect(document.frame.height > scroll.contentView.bounds.height,
                   "Long metadata remains accessible by scrolling rather than stretching the popover")
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            preconditionFailure("Model details must render offscreen")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            preconditionFailure("Model detail PNG encoding failed")
        }
        try png.write(to: root.appendingPathComponent("model-details-\(name).png"))
    }
}
