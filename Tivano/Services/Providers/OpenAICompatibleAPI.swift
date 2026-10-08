import Foundation

/// Bearer auth, key validation and the models list, read the same way by DeepSeek, Meta and Z.ai.
enum OpenAICompatibleAPI {
    static func bearerRequest(url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// A key counts as valid when the models endpoint accepts it.
    static func validate(modelsURL: URL, key: String) async -> Bool {
        let key = key.trimmed
        guard !key.isEmpty else { return false }
        let request = bearerRequest(url: modelsURL, key: key)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    static func listModels(modelsURL: URL, key: String, option: (String) -> ModelOption?) async throws -> [ModelOption] {
        let key = key.trimmed
        guard !key.isEmpty else { return [] }
        let request = bearerRequest(url: modelsURL, key: key)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = JSONValue.parse(data) else { return [] }
        let ids = (json["data"]?.array ?? []).compactMap { $0["id"]?.string }
        guard !ids.isEmpty else { return [] }
        return ids.compactMap(option).sorted { lhs, rhs in
            (lhs.isDefault ? 0 : 1, lhs.id) < (rhs.isDefault ? 0 : 1, rhs.id)
        }
    }
}
