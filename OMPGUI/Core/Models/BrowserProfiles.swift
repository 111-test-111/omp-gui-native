import Foundation

struct BrowserProfileRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    var chromeSourceProfile: String? = nil

    static let defaultProfile = BrowserProfileRecord(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, name: "")
    var isDefault: Bool { id == Self.defaultProfile.id }
    // A separate namespace leaves old conversation profiles intact and unused.
    var storageName: String { "Shared-" + id.uuidString }
}

/// The saved selection is for the next launch. The running profile is frozen
/// before settings can change, even if Chromium has not been started yet.
struct BrowserProfileConfiguration: Codable, Equatable, Sendable {
    static let preferenceKey = "browserProfiles"
    private(set) var profiles: [BrowserProfileRecord] = [.defaultProfile]
    private(set) var selectedID = BrowserProfileRecord.defaultProfile.id
    private(set) var pendingDeletionIDs: [UUID] = []

    private enum CodingKeys: String, CodingKey { case profiles, selectedID, pendingDeletionIDs }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try values.decode([BrowserProfileRecord].self, forKey: .profiles)
        selectedID = try values.decode(UUID.self, forKey: .selectedID)
        pendingDeletionIDs = try values.decodeIfPresent([UUID].self, forKey: .pendingDeletionIDs) ?? []
    }

    var selected: BrowserProfileRecord {
        profiles.first { $0.id == selectedID } ?? .defaultProfile
    }

    static let activeProfile = load().selected

    static func load() -> Self {
        let defaults = CaptureRun.defaults ?? .standard
        guard let data = defaults.data(forKey: preferenceKey), data.count <= 65_536,
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        var result = Self()
        var ids: Set<UUID> = [BrowserProfileRecord.defaultProfile.id]
        for id in saved.pendingDeletionIDs.prefix(1_024) where ids.insert(id).inserted {
            result.pendingDeletionIDs.append(id)
        }
        for profile in saved.profiles where !profile.isDefault {
            let name = normalizedName(profile.name)
            guard !name.isEmpty, ids.insert(profile.id).inserted else { continue }
            result.profiles.append(BrowserProfileRecord(id: profile.id, name: name, chromeSourceProfile: profile.chromeSourceProfile))
        }
        result.select(saved.selectedID)
        return result
    }

    mutating func select(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    /// Retire the identity now; its disk directory is removed on a later launch,
    /// after this process's frozen active profile can no longer be using it.
    @discardableResult mutating func remove(_ id: UUID) -> BrowserProfileRecord? {
        guard id != BrowserProfileRecord.defaultProfile.id,
              let record = profiles.first(where: { $0.id == id }), pendingDeletionIDs.count < 1_024 else { return nil }
        var updated = self
        updated.profiles.removeAll { $0.id == id }
        if updated.selectedID == id { updated.selectedID = BrowserProfileRecord.defaultProfile.id }
        if !updated.pendingDeletionIDs.contains(id) { updated.pendingDeletionIDs.append(id) }
        guard let data = try? JSONEncoder().encode(updated), data.count <= 65_536 else { return nil }
        self = updated
        return record
    }

    mutating func acknowledgeDeletions(_ ids: Set<UUID>) {
        pendingDeletionIDs.removeAll { ids.contains($0) }
    }

    @discardableResult mutating func add(named input: String) -> BrowserProfileRecord? {
        let name = Self.normalizedName(input)
        guard !name.isEmpty, !containsName(name) else { return nil }
        let profile = BrowserProfileRecord(id: UUID(), name: name)
        profiles.append(profile)
        selectedID = profile.id
        return profile
    }

    func containsName(_ input: String) -> Bool {
        let name = Self.normalizedName(input)
        return profiles.contains { profile in
            let title = profile.isDefault ? AppText.localized("Default profile") : profile.name
            return title.caseInsensitiveCompare(name) == .orderedSame
                || (profile.isDefault && "Default profile".caseInsensitiveCompare(name) == .orderedSame)
        }
    }

    func chromeImportName(sourceName: String) -> String {
        let base = String(sourceName.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        var name = base + " [Chrome]"
        var index = 2
        while containsName(name) {
            name = base + " (\(index)) [Chrome]"; index += 1
        }
        return name
    }

    mutating func addChromeImport(id: UUID, sourceName: String) throws -> BrowserProfileRecord {
        guard !profiles.contains(where: { $0.id == id }), !pendingDeletionIDs.contains(id) else { throw BrowserCookieImportError.invalidDatabase }
        let record = BrowserProfileRecord(id: id, name: chromeImportName(sourceName: sourceName), chromeSourceProfile: sourceName)
        var updated = self
        updated.profiles.append(record); updated.selectedID = id
        guard let data = try? JSONEncoder().encode(updated), data.count <= 65_536 else { throw BrowserCookieImportError.profileLimit }
        self = updated
        return record
    }

    private static func normalizedName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }
}
