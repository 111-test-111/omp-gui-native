import SwiftUI

/// Shared by the read-only view and deterministic catalogue checks.
enum ModelDetailsPresentation {
    static func inputTypes(_ metadata: ModelMetadata?) -> String {
        guard let inputs = metadata?.inputTypes, !inputs.isEmpty else { return Chrome.localized("Unknown") }
        var seen: Set<String> = []
        return inputs.filter { seen.insert($0).inserted }.map { input in
            switch input {
            case "text": Chrome.localized("Text")
            case "image": Chrome.localized("Images")
            default: input
            }
        }.joined(separator: " · ")
    }

    static func tokens(_ count: Int?, locale: Locale = .current) -> String {
        guard let count, count > 0 else { return Chrome.localized("Unknown") }
        return String(format: Chrome.localized("%@ tokens"), count.formatted(.number.locale(locale)))
    }

    static func status(_ pricing: ModelPricing?) -> String {
        let key = switch pricing?.status ?? .unknown {
        case .fixed: "Per-token pricing"
        case .free: "Free"
        case .included: "Included in plan"
        case .variable: "Variable pricing"
        case .unknown: "Price unknown"
        }
        return Chrome.localized(key)
    }

    static func price(_ pricing: ModelPricing?, _ component: ModelPricing.Component, locale: Locale = .current) -> String {
        guard let pricing else { return Chrome.localized("Unknown") }
        switch pricing.status {
        case .free: return Chrome.localized("Free")
        case .included: return Chrome.localized("Included in plan")
        case .unknown: return Chrome.localized("Unknown")
        case .fixed, .variable:
            guard let rate = pricing.rate(component), rate.isFinite, rate >= 0 else { return Chrome.localized("Unknown") }
            if pricing.status == .variable && rate == 0 { return Chrome.localized("Variable pricing") }
            // Significant digits retain small cache rates instead of rounding them to $0.00.
            return rate.formatted(.currency(code: "USD").precision(.significantDigits(1...12)).locale(locale))
        }
    }
}

struct ModelDetailsPopover: View {
    let option: ModelOption
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var body: some View {
        let metadata = option.metadata
        let pricing = metadata?.pricing
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: option.name).font(.ui(.headline)).lineLimit(2)
                    Text(verbatim: option.id).font(.code(.caption)).foregroundStyle(Chrome.secondaryText)
                        .lineLimit(2).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                ChromeCircleButton(symbol: "xmark", help: "Close") { dismiss() }
            }
            Divider()
            PopoverScroll(maxHeight: 340, minHeight: 0, width: 368) {
                VStack(alignment: .leading, spacing: 14) {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                        detail("Declared inputs", ModelDetailsPresentation.inputTypes(metadata))
                        detail("Context window", ModelDetailsPresentation.tokens(metadata?.contextWindow, locale: locale))
                        detail("Maximum output", ModelDetailsPresentation.tokens(metadata?.maxOutputTokens, locale: locale))
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Pricing").font(.ui(.body, weight: .semibold))
                            Spacer(minLength: 8)
                            Text(verbatim: ModelDetailsPresentation.status(pricing)).font(.ui(.body))
                        }
                        Text("USD per 1M tokens").font(.ui(.caption)).foregroundStyle(Chrome.secondaryText)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                        detail("Input", ModelDetailsPresentation.price(pricing, .input, locale: locale))
                        detail("Output", ModelDetailsPresentation.price(pricing, .output, locale: locale))
                        detail("Cache read", ModelDetailsPresentation.price(pricing, .cacheRead, locale: locale))
                        detail("Cache write", ModelDetailsPresentation.price(pricing, .cacheWrite, locale: locale))
                    }
                }
                .padding(.trailing, 2)
            }
        }
        .padding(16)
        .frame(width: 400)
        .foregroundStyle(Chrome.primaryText)
        .accessibilityLabel(Text("Model details"))
    }

    private func detail(_ title: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(verbatim: Chrome.localized(title)).font(.ui(.body)).foregroundStyle(Chrome.secondaryText)
            Text(verbatim: value).font(.ui(.body)).textSelection(.enabled)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .gridColumnAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
