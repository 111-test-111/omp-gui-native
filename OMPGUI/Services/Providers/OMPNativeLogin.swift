import Foundation

/// Credentials, OAuth listeners and persistence stay in OMP's public login RPC.
@MainActor
@Observable
final class OMPNativeLogin {
    private let rpc = OMPRPC()
    private let openURL: (URL) -> Bool
    private(set) var links: [OMPLoginLink] = []
    private(set) var input: QuestionRequest?
    private(set) var browserOpenFailed = false
    private(set) var completed = false
    private(set) var isRunning = false
    var error: String?
    private var timer: Task<Void, Never>?

    init(openURL: @escaping (URL) -> Bool) { self.openURL = openURL }

    func start(provider: OMPLoginProvider, registry: ProviderRegistry) async {
        guard !isRunning else { return }
        guard provider.supportsBrowserLogin else {
            error = AppText.localized("This provider does not support browser sign-in. Configure its API key or use OMP's terminal.")
            return
        }
        guard let executable = registry.executable(for: .omp) else {
            error = ProviderError.notInstalled(.omp).localizedDescription
            return
        }
        isRunning = true
        error = nil
        rpc.onFrame = { [weak self] frame in self?.receive(frame) }
        do {
            try rpc.start(executable: executable, arguments: ["--mode", "rpc", "--no-session", "--no-ui", "--no-title"],
                directory: FileManager.default.temporaryDirectory, environment: registry.environment(for: .omp))
            _ = try await rpc.request("login", fields: ["providerId": .string(provider.id)], timeout: .seconds(600))
            guard isRunning else { return }
            completed = true
            input = nil
            timer?.cancel()
            await rpc.stopAndWait(timeout: 5)
            isRunning = false
        } catch {
            if isRunning { self.error = error.localizedDescription }
            isRunning = false
            input = nil
            timer?.cancel()
            await rpc.stopAndWait(timeout: 5)
        }
    }

    private func receive(_ frame: JSONValue) {
        guard isRunning, frame["type"]?.string == "extension_ui_request" else { return }
        switch frame["method"]?.string {
        case "open_url":
            if let link = OMPLoginLink(frame) {
                let newDestination = links.last?.destination != link.destination
                links = [link]
                if newDestination { openLoginPage() }
            }
        case "input":
            input = OMPExtensionDialog.request(frame)
            timer?.cancel()
            if let request = input, let deadline = request.deadline {
                timer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                    guard !Task.isCancelled, let self, input?.id == request.id else { return }
                    rpc.send(["type": "extension_ui_response", "id": .string(request.id), "cancelled": true, "timedOut": true])
                    input = nil
                }
            }
        case "cancel":
            if input?.id == frame["targetId"]?.string { input = nil; timer?.cancel() }
        default: break
        }
    }

    func openLoginPage() {
        guard isRunning, let link = links.last else { return }
        browserOpenFailed = !openURL(link.destination)
    }

    func answer(_ text: String) {
        guard let input else { return }
        rpc.send(["type": "extension_ui_response", "id": .string(input.id), "value": .string(text)]) { [weak self] accepted in
            guard accepted, self?.input?.id == input.id else { return }
            self?.input = nil
            self?.timer?.cancel()
        }
    }

    func stop() {
        isRunning = false
        input = nil
        links.removeAll()
        timer?.cancel()
        rpc.stop()
    }
}
