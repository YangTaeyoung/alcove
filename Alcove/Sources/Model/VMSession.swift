import Foundation
import Observation
import AlcoveAgent
import AlcoveDisplayProtocol
import AlcoveEngine

/// The UI-facing state of one virtual machine.
///
/// Wraps a `VMController` actor: mirrors its state stream and display
/// connection onto the main actor so SwiftUI can observe them, and converts
/// thrown errors into `lastError` so views can present them.
@MainActor @Observable
final class VMSession: Identifiable {
    /// The standardized bundle path. Stable for the life of the bundle; a
    /// rename produces a new session.
    let id: String
    let bundle: VMBundle
    /// The configuration as last saved to `config.json`.
    private(set) var config: VMConfig
    /// Mirror of `controller.state`.
    private(set) var state: VMController.State = .stopped
    /// The most recent error to show the user; views clear it after presenting.
    var lastError: String?
    let controller: VMController
    /// The feed over `controller.display` while the VM is active; nil when
    /// stopped. Created once per run, so the connection's single-consumer
    /// message stream is iterated exactly once however many times the VM
    /// window is closed and reopened.
    private(set) var display: DisplayFeed?
    /// USB devices hot-plugged in this run, keyed by `USBSelector.id`, with the QEMU device id.
    private(set) var attachedUSB: [String: String] = [:]
    /// Invoked on the main actor after every state change (Dock badge, etc.).
    @ObservationIgnored var onStateChange: (@MainActor (VMSession) -> Void)?

    /// Bumped whenever this session changes the suspend image itself
    /// (`discardSuspendState()`), so views reading `isSuspended` — which is a
    /// file-system check the observation machinery cannot see — refresh.
    private var suspendStateVersion = 0

    /// True while the guest tools (alcove-agent) answer on the forwarded port.
    private(set) var toolsConnected = false
    /// The sentence of the guest tools' `refused` line from the latest connection attempt they refused; nil once an
    /// attempt connects or the tools are disconnected.
    private(set) var toolsRefusal: String?

    /// The last size the window asked the guest to adopt, re-applied when the
    /// guest tools connect: at boot the request goes out before the tools are
    /// up, and a Windows driver picks its own largest mode from the EDID hint.
    private(set) var lastRequestedResolution: (width: Int, height: Int)?
    @ObservationIgnored private var agent: AgentClient?
    @ObservationIgnored private var agentTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var displayTask: Task<Void, Never>?

    init(bundle: VMBundle, config: VMConfig, controller: VMController) {
        self.id = VMSession.identifier(for: bundle)
        self.bundle = bundle
        self.config = config
        self.controller = controller
        observeStates()
    }

    /// The session id a bundle at this location would have.
    static func identifier(for bundle: VMBundle) -> String {
        bundle.url.standardizedFileURL.path
    }

    /// Stop observing the controller. Call before dropping the session
    /// (delete, rename); the tasks otherwise wait on the controller forever.
    func invalidate() {
        stateTask?.cancel(); stateTask = nil
        displayTask?.cancel(); displayTask = nil
        agentTask?.cancel(); agentTask = nil
        let client = agent
        agent = nil
        toolsConnected = false
        toolsRefusal = nil
        Task { await client?.disconnect() }
        onStateChange = nil
    }

    // MARK: - guest tools

    /// Connect to the guest agent in the background while the VM runs, so the
    /// window can show whether the tools are present and drive the guest's
    /// display mode (viogpudo ignores QEMU's resize hint; the agent does not).
    /// Each connection is reported to the control server, which cleans up
    /// what an earlier HTTP capture left in the guest.
    private func connectTools() {
        guard agentTask == nil else { return }
        let port = config.agentHostPort, token = config.agentToken, key = config.agentKey
        agentTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.state.isActive else { return }
                let client = AgentClient()
                do {
                    try await client.connect(port: port, expectedToken: token, agentKey: key, timeout: .seconds(5))
                    self.agent = client
                    self.toolsConnected = true
                    self.toolsRefusal = nil
                    AppControlServer.shared.guestToolsConnected(vm: self.name)
                    if let size = self.lastRequestedResolution {
                        await client.setResolution(width: size.width, height: size.height)
                    }
                    for await event in client.events where !Task.isCancelled {
                        if case .disconnected = event { break }
                    }
                    self.agent = nil
                    self.toolsConnected = false
                } catch {
                    if let refusal = (error as? AgentClient.AgentError)?.refusal { self.toolsRefusal = refusal }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    private func disconnectTools() {
        agentTask?.cancel(); agentTask = nil
        let client = agent
        agent = nil
        toolsConnected = false
        toolsRefusal = nil
        Task { await client?.disconnect() }
    }

    /// Ask the guest to adopt this display mode.
    ///
    /// The QEMU hint is always sent: for virtio-gpu it updates the EDID the
    /// guest sees, which is what puts the mode in the driver's list. Windows
    /// drivers (viogpudo) do not act on it, so when the guest tools are
    /// connected the mode is then applied with them, once the new EDID has
    /// had a moment to reach the guest.
    func requestGuestResolution(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        lastRequestedResolution = (width, height)
        display?.connection.send(.ui(con: 0, w: width, h: height))
        guard let agent else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            await agent.setResolution(width: width, height: height)
        }
    }

    // MARK: - derived state

    var name: String { config.name }
    /// A suspend-to-disk image exists; the next start resumes it.
    var isSuspended: Bool {
        _ = suspendStateVersion   // registers the dependency for observers
        return bundle.isSuspended
    }
    /// The saved session can be thrown away (`discardSuspendState()`).
    var canDiscardSuspendState: Bool { isSuspended && !state.isActive }
    var canStart: Bool { !state.isActive }
    var canPause: Bool { state == .running }
    var canResume: Bool { state == .paused }
    /// A reset needs a live QMP connection, which exists once the start finished.
    var canReset: Bool { state == .running || state == .paused }
    /// Snapshot create/restore/delete need a live QMP connection.
    var canModifySnapshots: Bool { state == .running || state == .paused }
    var canSuspend: Bool { state == .running || state == .paused }

    // MARK: - lifecycle

    func start() async {
        await perform { try await $0.start() }
        if let connection = await controller.display { adoptDisplay(connection) }
    }

    func pause() async { await perform { try await $0.pause() } }

    func resume() async { await perform { try await $0.resume() } }

    /// ACPI power button (`force: false`) or immediate `quit` (`force: true`).
    func shutdown(force: Bool) async { await perform { try await $0.shutdown(force: force) } }

    func reset() async { await perform { try await $0.reset() } }

    /// Save the guest to `suspend.state` and stop the engine.
    func suspend() async { await perform { try await $0.suspendToDisk() } }

    /// Delete the saved session so the next start boots from scratch (the way
    /// out after a resume keeps failing). Refused while the engine is active.
    func discardSuspendState() async {
        await perform { try await $0.discardSuspendState() }
        suspendStateVersion += 1
    }

    // MARK: - snapshots

    /// Snapshots on the first disk. Works while stopped (reads the qcow2 directly).
    func snapshots() async -> [VMController.SnapshotInfo] {
        do { return try await controller.snapshots() } catch { report(error); return [] }
    }

    /// Each snapshot change that worked is reported to the control server, which keeps its record of HTTP captures
    /// in step with the VM's snapshots.
    func createSnapshot(_ name: String) async {
        guard await perform({ try await $0.createSnapshot(named: name) }) else { return }
        await AppControlServer.shared.snapshotCreated(vm: config.name, snapshot: name)
    }

    func restoreSnapshot(_ name: String) async {
        guard await perform({ try await $0.restoreSnapshot(named: name) }) else { return }
        await AppControlServer.shared.snapshotRestored(vm: config.name, snapshot: name)
    }

    func deleteSnapshot(_ name: String) async {
        guard await perform({ try await $0.deleteSnapshot(named: name) }) else { return }
        await AppControlServer.shared.snapshotDeleted(vm: config.name, snapshot: name)
    }

    // MARK: - devices

    func attachUSB(_ selector: VMConfig.USBSelector) async {
        do {
            let deviceID = try await controller.attachUSB(selector)
            attachedUSB[selector.id] = deviceID
        } catch {
            report(error)
        }
    }

    /// `id` is the QEMU device id returned by attach (see `attachedUSB`).
    func detachUSB(id: String) async {
        do {
            try await controller.detachUSB(id: id)
            attachedUSB = attachedUSB.filter { $0.value != id }
        } catch {
            report(error)
        }
    }

    /// Ask QEMU to write the current frame as PNG. Returns false (and sets `lastError`) on failure.
    @discardableResult
    func screenshot(to url: URL) async -> Bool {
        do { try await controller.screenshot(to: url); return true } catch { report(error); return false }
    }

    // MARK: - configuration

    /// Validate and persist a new configuration; the engine picks it up on the next start.
    func saveConfig(_ newConfig: VMConfig) throws {
        try bundle.save(newConfig)
        config = newConfig
        AppControlServer.shared.updateSessions(AppModel.shared.sessions)
        Task { [controller] in try? await controller.update(config: newConfig) }
    }

    // MARK: - internals

    /// Runs `operation` on the controller; false when it threw, after recording the error in `lastError`.
    @discardableResult
    private func perform(_ operation: (VMController) async throws -> Void) async -> Bool {
        do {
            try await operation(controller)
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func report(_ error: Error) {
        let text = ErrorText.describe(error)
        if lastError != text { lastError = text }
    }

    private func observeStates() {
        stateTask = Task { [weak self, controller] in
            for await next in controller.states {
                guard let self else { return }
                self.apply(state: next)
            }
        }
    }

    private func apply(state next: VMController.State) {
        state = next
        switch next {
        case .starting:
            mirrorDisplay()
        case .stopped:
            displayTask?.cancel(); displayTask = nil
            display = nil
            attachedUSB = [:]
            lastRequestedResolution = nil
            disconnectTools()
            // A resume consumed (or a suspend produced) the image.
            suspendStateVersion += 1
        case .failed(let message):
            displayTask?.cancel(); displayTask = nil
            display = nil
            attachedUSB = [:]
            disconnectTools()
            suspendStateVersion += 1
            let text = ErrorText.humanize(message)
            if lastError != text { lastError = text }
        case .running:
            connectTools()
        case .paused, .suspending, .stopping:
            break
        }
        onStateChange?(self)
    }

    /// The controller creates its `DisplayConnection` early in `start()`; pick
    /// it up as soon as it exists so the window shows firmware output.
    private func mirrorDisplay() {
        displayTask?.cancel()
        displayTask = Task { [weak self, controller] in
            for _ in 0..<600 {
                if Task.isCancelled { return }
                if let connection = await controller.display {
                    // The poll may resume after `.stopped`/`.failed` cancelled
                    // this task and the controller closed the connection: never
                    // hand a dead connection to the window then.
                    guard let self, !Task.isCancelled else { return }
                    self.adoptDisplay(connection)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Wrap `connection` in a feed unless the VM is no longer active or the
    /// feed for this very connection already exists.
    private func adoptDisplay(_ connection: DisplayConnection) {
        guard state.isActive else { return }
        if let display, display.connection === connection { return }
        display = DisplayFeed(connection: connection)
    }
}

extension VMController.State {
    /// Short user-facing label.
    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .paused: "Paused"
        case .suspending: "Suspending…"
        case .stopping: "Shutting Down…"
        case .failed: "Failed"
        }
    }

    /// The VM is between two stable states; controls should wait.
    var isTransitional: Bool {
        switch self {
        case .starting, .suspending, .stopping: true
        default: false
        }
    }
}

extension VMConfig.GuestOS {
    var title: String {
        switch self {
        case .windows: "Windows 11 ARM"
        case .linux: "Linux (arm64)"
        case .other: "Other"
        }
    }

    /// SF Symbol used in the library and VM window.
    var symbolName: String {
        switch self {
        case .windows: "pc"
        case .linux: "terminal"
        case .other: "cpu"
        }
    }
}
