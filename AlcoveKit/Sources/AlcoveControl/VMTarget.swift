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
    /// Same as `start(discardChanges: false)`.
    func start() async throws
    /// Starts the VM; with `discardChanges` the session's disk and firmware writes are dropped when it stops.
    func start(discardChanges: Bool) async throws
    /// Whether the running session discards its changes when it stops.
    func isEphemeral() async -> Bool
    /// The template this VM was cloned from; nil when it is not a clone.
    func cloneOf() async -> String?
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
    /// or the agent is not reachable within `timeout`. A zero `timeout` returns
    /// the agent only when it is already connected.
    func agent(timeout: Duration) async -> AgentClient?
    /// The guest events with a sequence number above `seq`, oldest first, and the
    /// sequence number of the newest event. The events outlive the agent connection.
    func events(since seq: Int) async -> (events: [GuestEvent], next: Int)
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

/// A registry that can also create linked clones and delete them.
public protocol VMProvisioning: Sendable {
    /// Creates the linked clone `newName` of the stopped VM `name`.
    func cloneVM(named name: String, as newName: String) async throws
    /// Deletes the stopped clone `name`.
    func deleteVM(named name: String) async throws
}

/// Adapts a `VMController` (plus a lazily connected agent) to `VMTarget`.
public actor ControllerTarget: VMTarget {
    public nonisolated let name: String
    public let controller: VMController
    private var agentClient: AgentClient?
    /// Counts the times the agent client was dropped; a connection begun under an older count is not adopted.
    private var agentGeneration = 0
    private let frameSource = FrameSource()
    private let guestEvents = EventBuffer()
    /// Feeds the events of `agentClient` into `guestEvents`.
    private var eventFeed: Task<Void, Never>?
    /// The connection attempt started by a zero-timeout `agent` call.
    private var warmUp: Task<Void, Never>?

    public init(name: String, controller: VMController) {
        self.name = name
        self.controller = controller
    }

    public func guestOS() async -> VMConfig.GuestOS { await controller.config.guestOS }
    public func state() async -> VMController.State { await controller.state }
    public func isSuspended() async -> Bool { controller.bundle.isSuspended }
    public func start() async throws { try await controller.start() }
    public func start(discardChanges: Bool) async throws { try await controller.start(discardChanges: discardChanges) }
    public func isEphemeral() async -> Bool { await controller.isEphemeral }
    public func cloneOf() async -> String? { await controller.config.cloneOf }
    public func stop(force: Bool) async throws {
        await dropAgentClient()
        try await controller.shutdown(force: force)
    }
    public func events(since seq: Int) async -> (events: [GuestEvent], next: Int) { await guestEvents.since(seq) }
    public func pause() async throws { try await controller.pause() }
    public func resume() async throws { try await controller.resume() }

    public func frame() async throws -> Frame {
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

    /// Forgets the cached agent client and ends its event feed synchronously, then disconnects it.
    private func dropAgentClient() async {
        let client = agentClient
        agentClient = nil
        agentGeneration += 1
        eventFeed?.cancel()
        eventFeed = nil
        await client?.disconnect()
    }

    /// Makes `client` the cached agent client and the one source of guest events.
    private func adopt(_ client: AgentClient) {
        eventFeed?.cancel()
        eventFeed = guestEvents.follow(client)
        agentClient = client
    }

    /// Starts one connection attempt that nobody waits for, unless one is running.
    private func startWarmUp() {
        guard warmUp == nil else { return }
        warmUp = Task {
            _ = await self.agent(timeout: .milliseconds(1))
            self.warmUp = nil
        }
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
            await dropAgentClient()
            return nil
        }
        if let a = agentClient, await a.isConnected { return a }
        guard timeout > .zero else {
            startWarmUp()
            return nil
        }
        let config = await controller.config
        let deadline = ContinuousClock.now + timeout
        repeat {
            let generation = agentGeneration
            let client = AgentClient()
            do {
                try await client.connect(port: config.agentHostPort, expectedToken: config.agentToken, timeout: .seconds(5))
                if let current = agentClient, await current.isConnected {
                    await client.disconnect()
                    return current
                }
                guard generation == agentGeneration else {
                    await client.disconnect()
                    continue
                }
                adopt(client)
                return client
            } catch {
                try? await Task.sleep(for: .seconds(1))
            }
        } while ContinuousClock.now < deadline
        return nil
    }
}
