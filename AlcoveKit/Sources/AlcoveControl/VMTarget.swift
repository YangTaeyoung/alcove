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
    /// The current guest frame as BGRA pixels.
    func frame() async throws -> Frame
    /// Send a display-protocol message (input) to the engine; false when no display.
    @discardableResult func sendDisplay(_ message: ToQEMU) async -> Bool
    /// The guest agent, connecting on demand; nil when the VM is not running
    /// or the agent is not reachable within `timeout`.
    func agent(timeout: Duration) async -> AgentClient?
    func snapshots() async throws -> [VMController.SnapshotInfo]
    func createSnapshot(named name: String) async throws
    func restoreSnapshot(named name: String) async throws
    func deleteSnapshot(named name: String) async throws
    /// Runs one human-monitor line and returns its text output.
    func monitorCommand(_ line: String) async throws -> String
    func setNetworkLink(up: Bool) async throws
    /// The TCP port forwards of the VM's user-network configuration.
    func staticForwards() async -> [VMConfig.PortForward]
    /// Identifies the engine process currently (or last) launched for the VM.
    func engineInstance() async -> Int
    /// The host port forwarded to the guest agent.
    func agentHostPort() async -> Int
}

/// Why a frame could not be produced.
enum FrameError: Error, CustomStringConvertible {
    case undecodable
    var description: String { "the screendump image could not be decoded" }
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
    private let frameSource = FrameSource()
    /// When true, the target consumes the display message stream of every connection it sees.
    public private(set) var drainsDisplay = false
    private weak var drainedConnection: DisplayConnection?

    public init(name: String, controller: VMController) {
        self.name = name
        self.controller = controller
    }

    public func guestOS() async -> VMConfig.GuestOS { await controller.config.guestOS }
    public func state() async -> VMController.State {
        await drainDisplayIfNeeded()
        return await controller.state
    }
    public func isSuspended() async -> Bool { controller.bundle.isSuspended }
    public func start() async throws {
        try await controller.start()
        await drainDisplayIfNeeded()
    }
    public func stop(force: Bool) async throws {
        await agentClient?.disconnect(); agentClient = nil
        try await controller.shutdown(force: force)
    }
    public func pause() async throws { try await controller.pause() }
    public func resume() async throws { try await controller.resume() }

    /// Makes the target consume display messages (for hosts without an app that reads them).
    public func enableDisplayDrain() async {
        drainsDisplay = true
        await drainDisplayIfNeeded()
    }

    /// Starts consuming the current display connection's messages once per connection.
    private func drainDisplayIfNeeded() async {
        guard drainsDisplay, let display = await controller.display, display !== drainedConnection else { return }
        drainedConnection = display
        Task.detached { for await _ in display.messages {} }
    }

    public func frame() async throws -> Frame {
        await drainDisplayIfNeeded()
        if ProcessInfo.processInfo.environment["ALCOVE_FRAME_SOURCE"] != "screendump",
           let frame = frameSource.frame(for: await controller.display?.currentSurface) {
            return frame
        }
        guard let frame = Frame(png: try await screenshotPNG()) else { throw FrameError.undecodable }
        return frame
    }

    public func screenshotPNG() async throws -> Data {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("alcove-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await controller.screenshot(to: tmp)
        return try Data(contentsOf: tmp)
    }

    public func sendDisplay(_ message: ToQEMU) async -> Bool {
        await drainDisplayIfNeeded()
        guard let display = await controller.display else { return false }
        display.send(message)
        return true
    }

    public func snapshots() async throws -> [VMController.SnapshotInfo] { try await controller.snapshots() }
    public func createSnapshot(named name: String) async throws { try await controller.createSnapshot(named: name) }
    public func restoreSnapshot(named name: String) async throws {
        await dropAgentClient()
        do { try await controller.restoreSnapshot(named: name) } catch { await dropAgentClient(); throw error }
        await dropAgentClient()
    }

    /// Forgets the cached agent client synchronously, then disconnects it.
    private func dropAgentClient() async {
        let client = agentClient
        agentClient = nil
        await client?.disconnect()
    }
    public func engineInstance() async -> Int { await controller.engineInstance }
    public func agentHostPort() async -> Int { await controller.config.agentHostPort }
    public func deleteSnapshot(named name: String) async throws { try await controller.deleteSnapshot(named: name) }
    public func monitorCommand(_ line: String) async throws -> String { try await controller.monitorCommand(line) }
    public func setNetworkLink(up: Bool) async throws { try await controller.setNetworkLink(up: up) }
    public func staticForwards() async -> [VMConfig.PortForward] {
        guard case .user(let forwards) = await controller.config.network else { return [] }
        return forwards.filter { $0.proto == .tcp }
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
