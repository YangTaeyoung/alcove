import Foundation
import AlcoveEngine

/// A registry that owns VM controllers itself (no app): used by `alcovectl serve`.
public actor HeadlessRegistry: VMRegistry {
    public let directory: URL
    public let engine: EngineLocator.Engine
    private var targets: [String: ControllerTarget] = [:]

    public init(directory: URL, engine: EngineLocator.Engine) {
        self.directory = directory
        self.engine = engine
    }

    public func names() async -> [String] {
        VMBundle.list(in: directory).compactMap { (try? $0.loadConfig())?.name }
    }

    public func target(named name: String) async -> VMTarget? { await controllerTarget(named: name) }

    /// The target registered for `name`, returned once its controller drains display messages.
    private func controllerTarget(named name: String) async -> ControllerTarget? {
        guard let t = registeredTarget(named: name) else { return nil }
        await t.controller.setDrainsDisplayMessages(true)
        return t
    }

    /// The one target per name: the first call for a name creates its controller and registers it
    /// without suspending.
    private func registeredTarget(named name: String) -> ControllerTarget? {
        if let t = targets[name] { return t }
        guard let bundle = bundle(named: name), let config = try? bundle.loadConfig() else { return nil }
        let t = ControllerTarget(name: name, controller: VMController(bundle: bundle, config: config, engine: engine))
        targets[name] = t
        return t
    }

    /// Gracefully stop every running VM (used on shutdown).
    public func stopAll() async {
        for (_, t) in targets where await t.state().isActive {
            try? await t.stop(force: false)
        }
    }

    private func bundle(named name: String) -> VMBundle? {
        VMBundle.list(in: directory).first { (try? $0.loadConfig())?.name == name }
    }
}

extension HeadlessRegistry: VMProvisioning {
    public func cloneVM(named name: String, as newName: String) async throws {
        guard let t = await controllerTarget(named: name) else { throw ControlHandler.ControlError.noSuchVM(name) }
        _ = try await t.controller.cloneLinked(named: newName)
    }

    public func deleteVM(named name: String) async throws {
        guard let t = await controllerTarget(named: name) else { throw ControlHandler.ControlError.noSuchVM(name) }
        try await t.controller.deleteClone()
        targets[name] = nil
    }
}
