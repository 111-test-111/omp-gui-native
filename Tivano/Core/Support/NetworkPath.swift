import Network

/// Whether the Mac can reach the network at all, asked once.
enum NetworkPath {
    /// The system's current path, read from a monitor that is cancelled as soon as it has
    /// answered, so nothing keeps watching. A satisfied path is an interface with a route,
    /// not proof that any one host answers.
    static func isUsable() async -> Bool {
        for await path in NWPathMonitor() { return path.status == .satisfied }
        return false
    }
}
