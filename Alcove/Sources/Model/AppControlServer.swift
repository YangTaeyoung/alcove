import Foundation
import Observation
import AlcoveControl
import AlcoveEngine

/// Exposes the app's VM sessions through the control protocol
/// (docs/control-protocol.md) so `alcove-mcp` and scripts can drive VMs the
/// user is watching. Started at launch (`AppDelegate`) when no other server
/// owns the socket; stopped on quit so the socket file is removed.
///
/// Hosting the server while the app runs is what keeps automation from
/// spawning a headless `alcovectl serve` for the same bundles — a second
/// owner of a running VM's bundle would stop the app's engine as an orphan.
@MainActor @Observable
final class AppControlServer {
    static let shared = AppControlServer()

    @ObservationIgnored private var server: ControlServer?
    @ObservationIgnored private let registry = AppVMRegistry()
    /// Why the server is not running (nil when it is). Informational when
    /// another server owns the socket; see `startFailure` for real failures.
    private(set) var issue: String?
    /// The error when the server could not be started at all (bind/listen
    /// failed); nil when it runs or when it merely deferred to another server.
    private(set) var startFailure: String?

    private init() {}

    var isRunning: Bool { server != nil }

    func start() {
        guard server == nil else { return }
        let path = ControlServer.defaultSocketPath
        if ControlServer.isAlive(at: path) {
            issue = "Another control server (alcovectl serve) owns \(path); automation talks to it, not to this app, until it exits."
            startFailure = nil
            return
        }
        let s = ControlServer(handler: ControlHandler(registry: registry, hostKind: "app"), socketPath: path)
        do {
            try s.start(loadingRecognizers: true)
            server = s
            issue = nil
            startFailure = nil
        } catch {
            let message = "The automation control socket at \(path) could not be started: \(error)"
            issue = message
            startFailure = message
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }
}

/// `VMRegistry` over `AppModel.shared.sessions`; targets are cached per session
/// so the guest-agent connection survives across requests.
///
/// A session id is the bundle path, which outlives the session object: delete
/// + create under the same name, or a rename A→B→A, yields a new `VMSession`
/// and `VMController` with the id of the old one. Cached targets are therefore
/// validated against the live controller before use and pruned to the ids the
/// app currently shows, so automation never drives a controller whose bundle
/// is in the Trash or whose observers were discarded.
actor AppVMRegistry: VMRegistry {
    private var targets: [String: ControllerTarget] = [:]

    func names() async -> [String] {
        let live: [(id: String, name: String)] = await MainActor.run {
            AppModel.shared.sessions.map { ($0.id, $0.name) }
        }
        prune(keeping: Set(live.map(\.id)))
        return live.map(\.name)
    }

    func target(named name: String) async -> VMTarget? {
        let snapshot: (found: (id: String, controller: VMController)?, liveIDs: Set<String>) = await MainActor.run {
            let sessions = AppModel.shared.sessions
            let match = sessions.first { $0.name == name }
            return (match.map { ($0.id, $0.controller) }, Set(sessions.map(\.id)))
        }
        prune(keeping: snapshot.liveIDs)
        guard let found = snapshot.found else { return nil }
        if let cached = targets[found.id], await cached.controller === found.controller {
            return cached
        }
        let t = ControllerTarget(name: name, controller: found.controller)
        targets[found.id] = t
        return t
    }

    /// Drop targets for sessions the app no longer has.
    private func prune(keeping liveIDs: Set<String>) {
        targets = targets.filter { liveIDs.contains($0.key) }
    }
}

/// Clones and deletes bundles through the session's controller, then has `AppModel` re-scan the VM directory.
extension AppVMRegistry: VMProvisioning {
    func cloneVM(named name: String, as newName: String) async throws {
        _ = try await controller(named: name).cloneLinked(named: newName)
        await MainActor.run { AppModel.shared.reload() }
    }

    func deleteVM(named name: String) async throws {
        try await controller(named: name).deleteClone()
        await MainActor.run { AppModel.shared.reload() }
    }

    /// The controller of the session called `name`.
    private func controller(named name: String) async throws -> VMController {
        let found = await MainActor.run { AppModel.shared.sessions.first { $0.name == name }?.controller }
        guard let found else { throw ControlHandler.ControlError.noSuchVM(name) }
        return found
    }
}
