import Foundation

/// Public OMP catalogue facts. Missing fields remain unknown rather than inferred
/// from the model's name, provider, or another provider's copy of the model.
struct ModelMetadata: Codable, Hashable, Sendable {
    var inputTypes: [String]?
    var contextWindow: Int?
    var maxOutputTokens: Int?
    var pricing: ModelPricing

    /// A live RPC catalogue can refine limits and input types. Preserve the CLI's
    /// resolved price snapshot instead of replacing it with a raw RPC rate card.
    func merging(cached: ModelMetadata?) -> ModelMetadata {
        guard let cached else { return self }
        return ModelMetadata(
            inputTypes: inputTypes ?? cached.inputTypes,
            contextWindow: contextWindow ?? cached.contextWindow,
            maxOutputTokens: maxOutputTokens ?? cached.maxOutputTokens,
            pricing: cached.pricing.isCLISnapshot ? cached.pricing : pricing
        )
    }
}

struct ModelPricing: Codable, Hashable, Sendable {
    enum Status: String, Codable, CaseIterable, Sendable {
        case fixed, free, included, variable, unknown
    }

    enum Component: CaseIterable, Sendable {
        case input, output, cacheRead, cacheWrite
    }

    var status: Status
    var input: Double?
    var output: Double?
    var cacheRead: Double?
    var cacheWrite: Double?
    /// `omp models --json` resolves its base rate card. No GUI pricing engine is used.
    var isCLISnapshot = false
    var hasContextOrTimeTiers = false

    func rate(_ component: Component) -> Double? {
        switch component {
        case .input: input
        case .output: output
        case .cacheRead: cacheRead
        case .cacheWrite: cacheWrite
        }
    }
}
