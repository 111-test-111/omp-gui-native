import AppKit
import Observation

/// Decoded icons are short-lived and edition-local. Chromium owns persistent
/// network caching; no favicon URLs or pixels are added to saved tab records.
@MainActor
final class BrowserFaviconCache {
    typealias Completion = @MainActor (NSImage?) -> Void
    typealias Fetch = @MainActor (URL, Bool, @escaping Completion) -> Void

    struct Key: Hashable {
        let profileID: UUID
        let url: URL
        let isDark: Bool
    }

    private struct Entry {
        let image: NSImage?
        let expires: Date
        var access: UInt64
    }
    private struct Pending {
        let id: UUID
        var completions: [UUID: Completion]
        let timeout: Task<Void, Never>
    }

    static let shared = BrowserFaviconCache()
    private let capacity: Int
    private let now: () -> Date
    private var access: UInt64 = 0
    private var entries: [Key: Entry] = [:]
    private var pending: [Key: Pending] = [:]

    init(capacity: Int = 128, now: @escaping () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.now = now
    }

    func load(_ key: Key, consumerID: UUID = UUID(), bypassCache: Bool = false, fetch: Fetch, completion: @escaping Completion) {
        access &+= 1
        if !bypassCache, var entry = entries[key], entry.expires > now() {
            entry.access = access; entries[key] = entry
            completion(entry.image); return
        }
        entries.removeValue(forKey: key)
        if let request = pending[key], request.completions[consumerID] == nil, request.completions.count >= 64 {
            completion(nil); return
        }
        if !bypassCache, pending[key] != nil {
            pending[key]?.completions[consumerID] = completion; return
        }
        // Bound pending work separately from decoded cache size. Repeated
        // notifications from one page replace that page's obsolete listener.
        guard pending[key] != nil || pending.count < 64 else { completion(nil); return }
        let previous = pending.removeValue(forKey: key)
        previous?.timeout.cancel()
        let id = UUID()
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.finish(key, id: id, image: nil)
        }
        var completions = previous?.completions ?? [:]
        completions[consumerID] = completion
        pending[key] = Pending(id: id, completions: completions, timeout: timeout)
        fetch(key.url, bypassCache) { [weak self] image in self?.finish(key, id: id, image: image) }
    }

    private func finish(_ key: Key, id: UUID, image: NSImage?) {
        guard let request = pending[key], request.id == id else { return }
        pending.removeValue(forKey: key)
        request.timeout.cancel()
        if entries.count >= capacity, let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key {
            entries.removeValue(forKey: oldest)
        }
        access &+= 1
        entries[key] = Entry(image: image, expires: now().addingTimeInterval(image == nil ? 30 : 300), access: access)
        for completion in request.completions.values { completion(image) }
    }
}

/// A document generation fences every completion, including changes of
/// appearance, redirects, reloads, dynamic icons and closing a native page.
@MainActor @Observable
final class BrowserFaviconState {
    private(set) var image: NSImage?
    @ObservationIgnored var onImageLoaded: ((URL, NSImage) -> Void)?
    @ObservationIgnored private let profileID: UUID
    @ObservationIgnored private let cache: BrowserFaviconCache
    @ObservationIgnored private let fetch: BrowserFaviconCache.Fetch
    @ObservationIgnored private let consumerID = UUID()
    @ObservationIgnored private var document: URL?
    @ObservationIgnored private var candidates: [URL] = []
    @ObservationIgnored private var isDark = false
    @ObservationIgnored private var hasLoadedDocument = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var bypassCache = false
    @ObservationIgnored private var refreshed: Set<URL> = []

    init(profileID: UUID, cache: BrowserFaviconCache = .shared, fetch: @escaping BrowserFaviconCache.Fetch) {
        self.profileID = profileID; self.cache = cache; self.fetch = fetch
    }

    func navigate(to value: String) {
        let url = Self.documentURL(for: value)
        guard url != document else { return }
        reset()
        if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { document = url }
    }

    static func documentURL(for value: String) -> URL? {
        var components = URLComponents(string: value)
        components?.fragment = nil
        return components?.url
    }

    func receive(_ urls: [URL]) {
        guard document != nil else { return }
        var unique: Set<URL> = []
        var candidates: [URL] = []
        for url in urls where Self.allows(url) && unique.insert(url).inserted {
            candidates.append(url)
            if candidates.count == 8 { break }
        }
        if candidates != self.candidates { image = nil }
        self.candidates = candidates
        hasLoadedDocument = true
        update()
    }

    func startedLoading() { revision &+= 1; image = nil; hasLoadedDocument = false }

    func finishedLoading() { hasLoadedDocument = true; if image == nil { update() } }

    func reload() {
        revision &+= 1
        bypassCache = true; refreshed.removeAll()
        image = nil; hasLoadedDocument = false
    }

    func setDarkAppearance(_ value: Bool) {
        guard isDark != value else { return }
        isDark = value; image = nil
        update()
    }

    func reset() {
        revision &+= 1
        document = nil; candidates = []; image = nil
        hasLoadedDocument = false
        bypassCache = false; refreshed.removeAll()
    }

    private func update() {
        revision &+= 1
        guard let document, hasLoadedDocument else { return }
        var urls = candidates
        if let origin = URLComponents(url: document, resolvingAgainstBaseURL: false) {
            var fallback = origin
            fallback.path = "/favicon.ico"; fallback.query = nil; fallback.fragment = nil
            if let url = fallback.url, !urls.contains(url) { urls.append(url) }
        }
        load(urls[...], revision: revision)
    }

    private func load(_ urls: ArraySlice<URL>, revision expected: UInt64) {
        guard revision == expected else { return }
        guard let url = urls.first else { bypassCache = false; refreshed.removeAll(); return }
        let bypass = bypassCache && refreshed.insert(url).inserted
        cache.load(.init(profileID: profileID, url: url, isDark: isDark), consumerID: consumerID, bypassCache: bypass, fetch: fetch) { [weak self] image in
            guard let self, revision == expected else { return }
            if let image {
                self.image = image; bypassCache = false; refreshed.removeAll()
                if let document { onImageLoaded?(document, image) }
            }
            else { load(urls.dropFirst(), revision: expected) }
        }
    }

    private static func allows(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "data" { return url.absoluteString.utf8.count <= 65_536 && url.absoluteString.lowercased().hasPrefix("data:image/") }
        return ["http", "https"].contains(scheme) && url.host != nil && url.user == nil && url.password == nil
            && url.absoluteString.utf8.count <= 8_192
    }
}
