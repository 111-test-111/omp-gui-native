import Foundation

/// ISO 8601 stamps as they arrive from provider CLIs and from GitLab.
///
/// `Date.ISO8601FormatStyle` is a `Sendable` value, so the two shapes are built once
/// instead of allocating a formatter per stamp. A style that requires fractional seconds
/// rejects a whole-second stamp and vice versa, so parsing tries both.
enum ISO8601 {
    /// `2026-09-13T18:28:42.057Z`.
    static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// `2026-09-13T18:28:42Z`, also the shape written below.
    static let plain = Date.ISO8601FormatStyle()

    /// `2026-09-13` with no time, which GitHub Copilot's quota endpoint writes.
    private static let dateOnly = Date.ISO8601FormatStyle().year().month().day()

    /// A stamp with or without fractional seconds; `nil` for anything else.
    static func date(from text: String) -> Date? {
        (try? fractional.parse(text)) ?? (try? plain.parse(text))
    }

    /// A bare date with no time; `nil` for anything else.
    static func dateOnly(from text: String) -> Date? {
        try? dateOnly.parse(text)
    }

    /// A stamp for a filename or a prompt: whole seconds, UTC, `Z` suffix.
    static func string(from date: Date) -> String {
        plain.format(date)
    }
}
