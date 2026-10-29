import Foundation

enum WebLinkDestination: String, CaseIterable, Identifiable, Sendable {
    case embeddedBrowser
    case systemBrowser

    var id: String { rawValue }
    var title: String {
        switch self {
        case .embeddedBrowser: "Built-in browser"
        case .systemBrowser: "System default browser"
        }
    }
}

/// Stored navigation only. Cookies belong to CEF's selected edition-wide profile; CDP
/// targets and native handles are deliberately never restored from disk.
struct BrowserPageRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var url = "about:blank"
    var title = ""
}

struct BrowserWorkspaceRecord: Codable, Sendable {
    var pages: [BrowserPageRecord] = []
    var selectedID: UUID?
}

/// Native OMP open options. Omission retains OMP's default dialog policy;
/// `manual` is not an accepted value in the native open schema.
enum BrowserAutomationAttachment {
    static func openOptions(pageID: UUID, targetID: String, endpoint: URL, downloads: String) -> JSONValue {
        .object(["name": .string("omp-gui-" + pageID.uuidString + "-" + targetID),
            "app": .object(["cdp_url": .string(endpoint.absoluteString),
                            "target": .string("omp-gui-target:" + targetID)]),
            "downloads": .string(downloads)])
    }
}

enum BrowserSearchEngine: String, CaseIterable, Identifiable, Sendable {
    case google
    case bing
    case duckDuckGo
    case baidu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: "Google"
        case .bing: "Bing"
        case .duckDuckGo: "DuckDuckGo"
        case .baidu: "Baidu"
        }
    }

    func searchURL(for input: String) -> URL? {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 16_384 else { return nil }
        let endpoint: (host: String, path: String, parameter: String)
        switch self {
        case .google: endpoint = ("www.google.com", "/search", "q")
        case .bing: endpoint = ("www.bing.com", "/search", "q")
        case .duckDuckGo: endpoint = ("duckduckgo.com", "/", "q")
        case .baidu: endpoint = ("www.baidu.com", "/s", "wd")
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpoint.host
        components.path = endpoint.path
        components.queryItems = [URLQueryItem(name: endpoint.parameter, value: query)]
        // Form-style query decoding treats a literal '+' as a space. Preserve
        // terms such as C++ while URLComponents escapes the other delimiters.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { return nil }
        return BrowserAddress.resolve(url.absoluteString)
    }
}

enum BrowserAddress {
    static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 16_384, !text.contains(where: { $0.isNewline }) else { return nil }
        if text == "about:blank" { return URL(string: text) }
        let candidate: String
        if text.contains("://") { candidate = text }
        else if text == "localhost" || text.hasPrefix("localhost:") || text.hasPrefix("localhost/")
                    || text.hasPrefix("127.") || text.hasPrefix("[::1]") {
            candidate = "http://" + text
        } else {
            guard !text.contains(" "), !text.contains(":"), text.contains(".") else { return nil }
            candidate = "https://" + text
        }
        guard let url = URL(string: candidate), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func allowsPageNavigation(_ url: URL?) -> Bool {
        guard let url else { return false }
        // Internal frame documents are permitted; address input and tool opens
        // still accept only web URLs and the empty page.
        return ["http", "https", "about", "blob", "data"].contains(url.scheme?.lowercased() ?? "")
    }

    static func restoredURL(_ text: String) -> String { resolve(text)?.absoluteString ?? "about:blank" }

    static func isBootstrapURL(_ url: URL) -> Bool {
        url.absoluteString.lowercased().hasPrefix("about:blank#omp-gui-")
    }

    static func isBlankPage(_ text: String) -> Bool {
        guard let url = URL(string: text) else { return false }
        return text.lowercased() == "about:blank" || isBootstrapURL(url)
    }
}

enum WorkspaceBrowserError: LocalizedError {
    case invalidAddress, unavailable, closed, limit, connection, incompatibleRuntime

    var errorDescription: String? {
        switch self {
        case .invalidAddress: BrowserLocalization.localized("Enter an HTTP or HTTPS address, or localhost with a port.")
        case .unavailable: BrowserLocalization.localized("The embedded browser could not start. Check the browser runtime in this app bundle.")
        case .closed: BrowserLocalization.localized("This browser tab has closed. List the current tabs before continuing.")
        case .limit: BrowserLocalization.localized("Close a browser tab before opening another. Each conversation supports 16 tabs and the app supports 64 live tabs.")
        case .connection: BrowserLocalization.localized("OMP could not identify this browser page. Reload the tab to reconnect.")
        case .incompatibleRuntime: BrowserLocalization.localized("Embedded browser automation requires the supported OMP SDK. Ordinary browsing is still available.")
        }
    }
}
