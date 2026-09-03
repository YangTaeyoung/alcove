import Foundation
import AlcoveEngine
import AlcoveAgent
import AlcoveDisplayProtocol

/// What the control server needs from a VM. `VMController` is adapted through
/// `ControllerTarget`; tests use a fake.
public protocol VMTarget: Sendable {
    var name: String { get }
    func guestOS() async -> VMConfig.GuestOS
    func state() async -> VMController.State
    func isSuspended() async -> Bool
    func start() async throws
    func stop(force: Bool) async throws
    func pause() async throws
    func resume() async throws
    /// PNG of the current guest frame.
    func screenshotPNG() async throws -> Data
    /// Send a display-protocol message (input) to the engine; false when no display.
    @discardableResult func sendDisplay(_ message: ToQEMU) async -> Bool
    /// The guest agent, connecting on demand; nil when the VM is not running
    /// or the agent is not reachable within `timeout`.
    func agent(timeout: Duration) async -> AgentClient?
}

/// Provides the VMs by name.
public protocol VMRegistry: Sendable {
    func names() async -> [String]
    func target(named name: String) async -> VMTarget?
}

/// Adapts a `VMController` (plus a lazily connected agent) to `VMTarget`.
public actor ControllerTarget: VMTarget {
    public nonisolated let name: String
    public let controller: VMController
    private var agentClient: AgentClient?
    private var agentGeneration = 0

    public init(name: String, controller: VMController) {
        self.name = name
        self.controller = controller
    }

    public func guestOS() async -> VMConfig.GuestOS { await controller.config.guestOS }
    public func state() async -> VMController.State { await controller.state }
    public func isSuspended() async -> Bool { controller.bundle.isSuspended }
    public func start() async throws { try await controller.start() }
    public func stop(force: Bool) async throws {
        await agentClient?.disconnect(); agentClient = nil
        try await controller.shutdown(force: force)
    }
    public func pause() async throws { try await controller.pause() }
    public func resume() async throws { try await controller.resume() }

    public func screenshotPNG() async throws -> Data {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("alcove-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await controller.screenshot(to: tmp)
        return try Data(contentsOf: tmp)
    }

    public func sendDisplay(_ message: ToQEMU) async -> Bool {
        guard let display = await controller.display else { return false }
        display.send(message)
        return true
    }

    public func agent(timeout: Duration) async -> AgentClient? {
        let st = await controller.state
        guard st == .running || st == .paused else {
            await agentClient?.disconnect(); agentClient = nil
            return nil
        }
        if let a = agentClient, await a.isConnected { return a }
        agentClient = nil
        let config = await controller.config
        let deadline = ContinuousClock.now + timeout
        repeat {
            let client = AgentClient()
            do {
                try await client.connect(port: config.agentHostPort, expectedToken: config.agentToken, timeout: .seconds(5))
                agentClient = client
                return client
            } catch {
                try? await Task.sleep(for: .seconds(1))
            }
        } while ContinuousClock.now < deadline
        return nil
    }
}
