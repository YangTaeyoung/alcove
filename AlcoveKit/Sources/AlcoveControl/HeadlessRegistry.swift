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

    public func target(named name: String) async -> VMTarget? {
        if let t = targets[name] { return t }
        guard let bundle = VMBundle.list(in: directory).first(where: { (try? $0.loadConfig())?.name == name }),
              let config = try? bundle.loadConfig() else { return nil }
        let t = ControllerTarget(name: name, controller: VMController(bundle: bundle, config: config, engine: engine))
        await t.enableDisplayDrain()
        targets[name] = t
        return t
    }

    /// Gracefully stop every running VM (used on shutdown).
    public func stopAll() async {
        for (_, t) in targets where await t.state().isActive {
            try? await t.stop(force: false)
        }
    }
}
