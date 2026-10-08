import Foundation

/// The launchable form, with `{key}` placeholders replaced by the user's values (or the
/// field's default). OAuth servers resolve to their route on the app's proxy.
/// Kept out of Core because it needs the proxy.
extension MCPCatalogEntry {
    func resolve(values: [String: String]) -> MCPResolvedServer {
        func fill(_ text: String) -> String { self.fill(text, values: values) }
        var server = MCPResolvedServer(id: id, name: name)
        switch transport {
        case .stdio(let command, let args):
            server.command = command
            server.args = args.map(fill)
            // An optional field left empty drops its variable rather than passing "".
            server.env = env.mapValues(fill).filter { !$0.value.isEmpty }
        case .http(let url, let headers):
            server.url = fill(url)
            server.headers = headers.mapValues(fill).filter { !$0.value.isEmpty }
        case .oauth(let url):
            server.url = MCPProxy.url(for: id)
            server.oauthUpstream = fill(url)
        }
        return server
    }
}
