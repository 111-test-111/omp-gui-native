import Foundation

struct GitHubUser: Codable, Equatable, Sendable {
    let id: Int
    let login: String
    let name: String?
    let avatarURL: URL?

    private enum CodingKeys: String, CodingKey {
        case id, login, name
        case avatarURL = "avatar_url"
    }
}

struct GitHubRepository: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let fullName: String
    let ownerLogin: String
    let description: String?
    let isPrivate: Bool
    let isFork: Bool
    let defaultBranch: String?
    let htmlURL: URL
    let pushedAt: Date?

    private struct Owner: Codable {
        let login: String
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, owner, description
        case fullName = "full_name"
        case isPrivate = "private"
        case isFork = "fork"
        case defaultBranch = "default_branch"
        case htmlURL = "html_url"
        case pushedAt = "pushed_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        fullName = try values.decode(String.self, forKey: .fullName)
        ownerLogin = try values.decode(Owner.self, forKey: .owner).login
        description = try values.decodeIfPresent(String.self, forKey: .description)
        isPrivate = try values.decode(Bool.self, forKey: .isPrivate)
        isFork = try values.decode(Bool.self, forKey: .isFork)
        defaultBranch = try values.decodeIfPresent(String.self, forKey: .defaultBranch)
        htmlURL = try values.decode(URL.self, forKey: .htmlURL)
        pushedAt = try values.decodeIfPresent(Date.self, forKey: .pushedAt)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(fullName, forKey: .fullName)
        try values.encode(Owner(login: ownerLogin), forKey: .owner)
        try values.encodeIfPresent(description, forKey: .description)
        try values.encode(isPrivate, forKey: .isPrivate)
        try values.encode(isFork, forKey: .isFork)
        try values.encodeIfPresent(defaultBranch, forKey: .defaultBranch)
        try values.encode(htmlURL, forKey: .htmlURL)
        try values.encodeIfPresent(pushedAt, forKey: .pushedAt)
    }
}

struct GitHubDeviceCode: Equatable, Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresIn: Int
    let interval: Int
}

enum GitHubTokenSource: String, Codable, Sendable {
    case tivano, githubCLI
}

enum GitHubRepoReference {
    static func fullName(from text: String) -> String? {
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var allowsExtraPath = false
        if path.hasPrefix("git@github.com:") {
            path = String(path.dropFirst("git@github.com:".count))
        } else if path.hasPrefix("https://") {
            guard let url = URLComponents(string: path), url.host == "github.com",
                  url.user == nil, url.password == nil, url.port == nil else { return nil }
            path = String(url.path.dropFirst())
            allowsExtraPath = true
        } else if path.hasPrefix("github.com/") {
            path = String(path.dropFirst("github.com/".count))
            allowsExtraPath = true
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, allowsExtraPath || parts.count == 2 else { return nil }
        let owner = String(parts[0])
        var repo = String(parts[1])
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !owner.isEmpty, !repo.isEmpty,
              owner.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              repo.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return "\(owner)/\(repo)"
    }
}

enum GitHubError: LocalizedError, Equatable {
    case unauthorized, denied, expired, notFound
    case http(Int, String)
    case invalidResponse
    case cloneFailed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: AppText.localized("GitHub did not accept the sign-in.")
        case .denied: AppText.localized("The sign-in was cancelled on GitHub.")
        case .expired: AppText.localized("The code expired. Try again.")
        case .notFound: AppText.localized("That repository was not found, or your account cannot see it.")
        case let .http(code, message): String(format: AppText.localized("GitHub answered %lld: %@"), code, message)
        case .invalidResponse: AppText.localized("GitHub sent an answer Tivano could not read.")
        case let .cloneFailed(message): message
        }
    }
}
