import SwiftUI

enum ConfiguredProviderProjection {
    struct Provider: Identifiable {
        let id: String
        let name: String
        let login: OMPLoginProvider?
        let nativeIDs: Set<String>
    }

    /// OMP's available catalogue includes configured API keys and keyless endpoints.
    /// Successful usage can also identify an account with no available chat model.
    static func providers(logins: [OMPLoginProvider], models: [ModelOption], reports: [OMPProviderUsage.Report]) -> [Provider] {
        func accountID(_ id: String) -> String { logins.first { $0.id == id }?.accountProviderID ?? id }
        let groups = Dictionary(grouping: logins, by: \.accountProviderID)
        let ids = Set(logins.filter(\.authenticated).map(\.accountProviderID))
            .union(models.map(\.provider).filter { !$0.isEmpty }.map(accountID))
            .union(reports.map(\.provider).map(accountID))
        return ids.map { id in
            let group = groups[id] ?? []
            let canonical = group.first { $0.id == id }
            var login = group.first { $0.id == id && $0.supportsBrowserLogin }
                ?? group.first { $0.supportsBrowserLogin } ?? canonical ?? group.first
            // OMP declares these routes as sharing one credential source. Keep the
            // selected route's native login/logout identity and aggregate presence only.
            login?.authenticated = group.contains(where: \.authenticated)
            return Provider(id: id, name: NativeProviderPresentation.displayName(for: id, nativeName: canonical?.name ?? login?.name), login: login,
                            nativeIDs: Set(group.map(\.id)).union([id]))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct ConfiguredProviderRow<Actions: View>: View {
    let provider: ConfiguredProviderProjection.Provider
    let reports: [OMPProviderUsage.Report]
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ChromeRow(title: provider.name,
                      detail: nil,
                      leading: AnyView(NativeProviderIcon(providerID: provider.id, name: provider.name))) { actions }
            if reports.contains(where: NativeProviderUsageSummary.hasKeyValues) {
                NativeProviderUsageSummary(reports: reports)
                    .padding(.leading, 52).padding(.trailing, 16).padding(.bottom, 12)
            }
        }
    }
}
