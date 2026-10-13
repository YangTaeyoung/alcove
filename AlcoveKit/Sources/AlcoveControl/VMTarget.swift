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
    /// Whether a connection to the guest agent is being made and no attempt has failed since an agent was last
    /// connected or the VM last stopped.
    func isConnectingAgent() async -> Bool
    /// The guest events with a sequence number above `seq`, oldest first, the sequence
    /// number of the newest event and that of the oldest one still kept. The events
    /// outlive the agent connection.
    func events(since seq: Int) async -> (events: [GuestEvent], next: Int, first: Int)
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

/// The one agent connection of a VM: connects on demand, replaces a connection that ended, and makes the adopted
/// connection the source of the VM's guest events.
actor AgentLink {
    private let isRunning: @Sendable () async -> Bool
    private let endpoint: @Sendable () async -> (port: Int, token: String?)
    private let events: EventBuffer
    private let retryDelay: Duration
    private var client: AgentClient?
    /// Counts the times the client was dropped; a connection begun under an older count is not adopted.
    private var generation = 0
    /// Feeds the events of `client` into `events`.
    private var feed: Task<Void, Never>?
    /// The connection attempt started by a zero-timeout `agent` call.
    private var warmUp: Task<Void, Never>?
    /// How many such attempts were started.
    private(set) var warmUpCount = 0
    /// The `ui.ping` sent after the latest adoption of a client with the `ui` capability.
    private(set) var helperStart: Task<Void, Never>?
    /// Connection attempts in flight.
    private var attempts = 0
    /// Whether the latest attempt that ended failed; false once a client was adopted or dropped.
    private var lastAttemptFailed = false

    /// Whether a connection is being made and no attempt has failed since a client was last adopted or dropped.
    var isConnecting: Bool { (attempts > 0 || warmUp != nil) && !lastAttemptFailed }

    /// `isRunning` says whether the VM runs; `endpoint` gives the forwarded agent port and the token the agent must present.
    init(events: EventBuffer, retryDelay: Duration = .seconds(1), isRunning: @escaping @Sendable () async -> Bool,
         endpoint: @escaping @Sendable () async -> (port: Int, token: String?)) {
        self.events = events
        self.retryDelay = retryDelay
        self.isRunning = isRunning
        self.endpoint = endpoint
    }

    /// The connected agent client; nil when the VM is not running or the agent is not reachable within `timeout`.
    /// A zero `timeout` returns the client only when it is already connected and starts one connection attempt in the background.
    func agent(timeout: Duration) async -> AgentClient? {
        guard await isRunning() else {
            await drop()
            return nil
        }
        if let current = await connected() { return current }
        guard timeout > .zero else {
            startWarmUp()
            return nil
        }
        let deadline = ContinuousClock.now + timeout
        repeat {
            let begun = generation
            attempts += 1
            let target = await endpoint()
            let candidate = AgentClient()
            do {
                try await candidate.connect(port: target.port, expectedToken: target.token, timeout: .seconds(5))
                attempts -= 1
            } catch {
                attempts -= 1
                if begun == generation { lastAttemptFailed = true }
                try? await Task.sleep(for: retryDelay)
                continue
            }
            let hasUI = await candidate.hello?.capabilities.contains("ui") ?? false
            if let current = await connected() {
                await candidate.disconnect()
                return current
            }
            guard begun == generation else {
                await candidate.disconnect()
                continue
            }
            adopt(candidate, startsHelper: hasUI)
            return candidate
        } while ContinuousClock.now < deadline
        return nil
    }

    /// Forgets the client and ends its event feed, then disconnects it.
    func drop() async {
        let dropped = client
        client = nil
        generation += 1
        lastAttemptFailed = false
        feed?.cancel()
        feed = nil
        await dropped?.disconnect()
    }

    /// The cached client when it is connected. A cached client found disconnected is forgotten, unless another
    /// caller replaced it while it was asked.
    private func connected() async -> AgentClient? {
        while let cached = client {
            if await cached.isConnected { return cached }
            guard client === cached else { continue }
            client = nil
            feed?.cancel()
            feed = nil
        }
        return nil
    }

    /// Makes `candidate` the cached client and the one source of guest events. With `startsHelper` it gets one `ui.ping`
    /// that nobody waits for, which starts the agent's UI helper.
    private func adopt(_ candidate: AgentClient, startsHelper: Bool) {
        feed?.cancel()
        feed = events.follow(candidate)
        client = candidate
        lastAttemptFailed = false
        helperStart = startsHelper ? Task { _ = try? await candidate.call("ui.ping", [:], timeout: UITiming.callTimeout) } : nil
    }

    private func startWarmUp() {
        guard warmUp == nil else { return }
        warmUpCount += 1
        warmUp = Task {
            _ = await self.agent(timeout: .milliseconds(1))
            self.warmUp = nil
        }
    }
}

/// Adapts a `VMController` (plus a lazily connected agent) to `VMTarget`.
public actor ControllerTarget: VMTarget {
    public nonisolated let name: String
    public let controller: VMController
    private let frameSource = FrameSource()
    private let guestEvents = EventBuffer()
    private let link: AgentLink

    public init(name: String, controller: VMController) {
        self.name = name
        self.controller = controller
        link = AgentLink(events: guestEvents, isRunning: {
            let state = await controller.state
            return state == .running || state == .paused
        }, endpoint: {
            let config = await controller.config
            return (config.agentHostPort, config.agentToken)
        })
    }

    public func guestOS() async -> VMConfig.GuestOS { await controller.config.guestOS }
    public func state() async -> VMController.State { await controller.state }
    public func isSuspended() async -> Bool { controller.bundle.isSuspended }
    public func start() async throws { try await controller.start() }
    public func start(discardChanges: Bool) async throws { try await controller.start(discardChanges: discardChanges) }
    public func isEphemeral() async -> Bool { await controller.isEphemeral }
    public func cloneOf() async -> String? { await controller.config.cloneOf }
    public func stop(force: Bool) async throws {
        await link.drop()
        try await controller.shutdown(force: force)
    }
    public func events(since seq: Int) async -> (events: [GuestEvent], next: Int, first: Int) { await guestEvents.since(seq) }
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
        await link.drop()
        do { try await controller.restoreSnapshot(named: name) } catch { await link.drop(); throw error }
        await link.drop()
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

    public func agent(timeout: Duration) async -> AgentClient? { await link.agent(timeout: timeout) }
    public func isConnectingAgent() async -> Bool { await link.isConnecting }
}
