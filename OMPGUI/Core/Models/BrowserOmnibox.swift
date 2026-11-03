import Darwin
import Foundation

/// Classify user intent separately from BrowserAddress's URL-only entry points.
/// Like Chromium's Omnibox, explicit schemes, IPs, ports and known registries
/// are stronger signals than punctuation alone. Ambiguous input becomes search.
enum BrowserOmnibox {
    enum Input: Equatable, Sendable {
        case empty
        case navigate(URL)
        case search(String)
        case invalid
    }

    private static let topLevelDomains: Set<String> = {
        // Unmodified IANA root-zone snapshot; provenance/update instructions
        // live in docs/browser.md. No DNS or network request while classifying.
        guard let file = BrowserLocalization.resources.url(forResource: "BrowserTLDs", withExtension: "txt"),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return Set(text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }.map { $0.lowercased() })
    }()

    static func classify(_ input: String) -> Input {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        guard text.count <= 16_384,
              !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !text.contains(where: \.isNewline) else { return .invalid }
        if text.hasPrefix("?") {
            let query = text.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? .empty : .search(query)
        }
        if text.lowercased() == "about:blank" { return .navigate(URL(string: "about:blank")!) }
        if isIPv6(text), let url = webURL("http://[" + text + "]") { return .navigate(url) }

        if let range = text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) {
            let scheme = text[range].dropLast().lowercased()
            if scheme == "http" || scheme == "https" {
                let remainder = String(text[range.upperBound...].drop(while: { $0 == "/" }))
                // Spaces in a path/query are URL data; words after a hostname
                // are a query, even when the first word has a web scheme.
                let authority = remainder.prefix { !"/?#".contains($0) }
                if authority.contains(where: \.isWhitespace), !authority.contains("@") { return .search(text) }
                return webURL(scheme + "://" + remainder).map(Input.navigate) ?? .invalid
            }
            let remainder = text[range.upperBound...]
            if remainder.hasPrefix("//") || ["javascript", "data", "file", "chrome", "about", "blob",
                "mailto", "ftp", "tel", "ssh", "ws", "wss", "view-source"].contains(scheme) {
                return .invalid
            }
            // Other colon expressions can be search operators (site:, inurl:)
            // or host:port. URLComponents below disambiguates numeric ports.
        }
        if text.hasPrefix("//") { return webURL("https:" + text).map(Input.navigate) ?? .invalid }
        if text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./") || text.hasPrefix("../") {
            return .invalid
        }
        if text.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil { return .invalid }

        let authority = text.prefix { !"/?#".contains($0) }
        let firstWord = authority.prefix { !$0.isWhitespace }
        if firstWord.contains("@"), firstWord.contains(":") { return .invalid }
        if authority.contains(where: \.isWhitespace) { return .search(text) }
        // Plain email addresses are queries. Never send a credential-bearing
        // URL to a search provider as a fallback for failed URL validation.
        if authority.contains("@") { return authority.contains(":") ? .invalid : .search(text) }
        if let port = URLComponents(string: "http://" + text)?.port, !(0...65_535).contains(port) { return .invalid }
        guard let url = webURL("http://" + text), let rawHost = url.host else { return .search(text) }
        let host = normalizedHost(rawHost)
        if host.hasSuffix(".invalid") { return .search(text) }
        let isIP = isIPv4(host) || isIPv6(host)
        let isLocal = host == "localhost" || ["localhost", "local", "test", "example", "internal"].contains {
            host.hasSuffix("." + $0)
        }
        let knownDomain = host.contains(".") && host.split(separator: ".").last.map { topLevelDomains.contains(String($0)) } == true
        // A trailing slash explicitly requests an intranet host. Multiple URL
        // components (e.g. host/path?query) also provide a strong URL signal.
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
        let explicitPath = !path.isEmpty && (path.hasSuffix("/") || url.query != nil || url.fragment != nil)
        guard isIP || isLocal || knownDomain || url.port != nil || explicitPath else { return .search(text) }
        if text.contains(where: \.isWhitespace), !isIP, !isLocal, !knownDomain { return .search(text) }
        let scheme = isIP || isLocal || url.port != nil || !knownDomain ? "http" : "https"
        return webURL(scheme + "://" + text).map(Input.navigate) ?? .invalid
    }

    private static func webURL(_ text: String) -> URL? {
        guard !text.contains("\\"), let url = BrowserAddress.resolve(text),
              let rawHost = url.host, url.port.map({ (0...65_535).contains($0) }) ?? true else { return nil }
        let host = normalizedHost(rawHost)
        if isIPv4(host) || isIPv6(host) { return url }
        guard !host.contains(":"), host.utf8.count <= 253,
              !host.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        return url
    }

    private static func normalizedHost(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    private static func isIPv4(_ host: String) -> Bool {
        var address = in_addr()
        return host.withCString { inet_pton(AF_INET, $0, &address) } == 1
    }

    private static func isIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }
}
