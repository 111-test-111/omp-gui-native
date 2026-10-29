import Foundation

/// A provider's subscription limits: each rolling window, how much of it is used and when it resets.
struct PlanLimits: Sendable, Equatable {
    struct Window: Sendable, Equatable, Identifiable {
        var id: String
        var title: String
        var percent: Double
        var resetsAt: Date?
        var detail: String? = nil
    }

    var planName: String?
    var windows: [Window]
    var resetCredits: ResetCredits? = nil
    /// Why the read filled no windows, in the provider's own words; shown in place of the bars so an expired login never reads as an unchanged number.
    var problem: String? = nil

    /// One reset Codex has banked for the account. `title` and `detail` are the app-server's own words when it gives any.
    struct ResetCredit: Sendable, Equatable, Identifiable {
        var id: String
        var title: String?
        var detail: String?
        var expiresAt: Date?
    }

    /// Codex only: resets the account has banked, each spendable to clear the active windows. `credits` can be shorter than `availableCount` when the app-server reported only a total.
    struct ResetCredits: Sendable, Equatable {
        var availableCount: Int
        var credits: [ResetCredit]
    }

    /// What the app-server answered when a reset was spent.
    enum ResetOutcome: String, Sendable, Equatable {
        case reset, nothingToReset, noCredit, alreadyRedeemed

        var message: String {
            switch self {
            case .reset: "Usage was reset."
            case .nothingToReset: "There was no active usage to reset."
            case .noCredit: "No banked resets are left."
            case .alreadyRedeemed: "That reset was already used."
            }
        }
    }
}

/// Why a banked reset could not be spent.
enum ResetCreditError: LocalizedError {
    case codexUnavailable
    case unknownOutcome
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .codexUnavailable: "Codex CLI not found."
        case .unknownOutcome: "Codex returned an unknown reset result."
        case .rejected(let message): message
        }
    }
}

@MainActor
enum PlanLimitsReader {
    static func exposesLimits(_ provider: ProviderKind) -> Bool { false }
    static func read(_ provider: ProviderKind, apiKey: String) async -> PlanLimits? { nil }
    static func read(_ provider: ProviderKind, executable: URL, environment: [String: String]) async -> PlanLimits? { nil }
}
