import Foundation
import AlcoveControl
import AlcoveEngine

/// Exposes the app's VM sessions through the control protocol
/// (docs/control-protocol.md) so `alcove-mcp` and scripts can drive VMs the
/// user is watching. Started at launch when no other server owns the socket.
@MainActor
final class AppControlServer {
    static let shared = AppControlServer()

    private var server: ControlServer?
    private let registry = AppVMRegistry()
    /// Why the server is not running (nil when it is).
    private(set) var issue: String?

    private init() {}

    var isRunning: Bool { server != nil }

    func start() {
        guard server == nil else { return }
        let path = ControlServer.defaultSocketPath
        if ControlServer.isAlive(at: path) {
            issue = "another control server (alcovectl serve) owns \(path); automation talks to it instead"
            return
        }
        let s = ControlServer(handler: ControlHandler(registry: registry, hostKind: "app"), socketPath: path)
        do {
            try s.start()
            server = s
            issue = nil
        } catch {
            issue = "control server failed to start: \(error)"
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }
}

/// `VMRegistry` over `AppModel.shared.sessions`; targets are cached per session
/// so the guest-agent connection survives across requests.
actor AppVMRegistry: VMRegistry {
    private var targets: [String: ControllerTarget] = [:]

    func names() async -> [String] {
        await MainActor.run { AppModel.shared.sessions.map(\.name) }
    }

    func target(named name: String) async -> VMTarget? {
        let found: (id: String, controller: VMController)? = await MainActor.run {
            guard let s = AppModel.shared.sessions.first(where: { $0.name == name }) else { return nil }
            return (s.id, s.controller)
        }
        guard let found else { return nil }
        if let t = targets[found.id] { return t }
        let t = ControllerTarget(name: name, controller: found.controller)
        targets[found.id] = t
        return t
    }
}
