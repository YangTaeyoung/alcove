import Foundation
import AlcoveDisplayProtocol
import AlcoveQMP

/// Lifecycle of one VM: launches the engine, owns the display connection and
/// QMP client, and exposes state changes. One controller per bundle.
///
/// Concurrency: an operation that spans an `await` captures `generation` first
/// and re-checks it afterwards. `shutdown()` bumps the generation, so a start or
/// suspend interrupted by a stop unwinds without touching state it no longer
/// owns, and a late exit notification from a superseded engine is ignored.
public actor VMController {
    public enum State: Sendable, Equatable {
        case stopped
        case starting
        case running
        case paused
        case suspending
        case stopping
        case failed(String)

        public var isActive: Bool {
            switch self { case .stopped, .failed: return false; default: return true }
        }
    }

    public enum ControllerError: Error, Equatable, Sendable {
        case notRunning
        case alreadyRunning
        case engineDidNotStart(String)
        case qmpUnavailable(String)
        case invalidSnapshotName(String)
        case snapshotListFailed(String)
    }

    public struct SnapshotInfo: Sendable, Equatable, Identifiable {
        public var id: String { name }
        public let name: String
        public let vmStateSize: Int
        public let date: Date

        public init(name: String, vmStateSize: Int, date: Date) {
            self.name = name; self.vmStateSize = vmStateSize; self.date = date
        }
    }

    /// The id of the guest's user-mode network backend.
    public static let netdevID = "net0"

    /// Counts the engine processes launched by this controller.
    public private(set) var engineInstance = 0

    public nonisolated let bundle: VMBundle
    public nonisolated let engine: EngineLocator.Engine
    /// The configuration for the next cold start; see `update(config:)`.
    public private(set) var config: VMConfig
    /// The configuration the engine was launched with, while it runs. QMP-driven
    /// operations (snapshots, media changes) address this machine, not `config`,
    /// which may already hold edits for the next start.
    public private(set) var runningConfig: VMConfig?
    /// True while the engine runs on overlays that are removed when it stops (`start(discardChanges: true)`).
    public private(set) var isEphemeral = false
    public private(set) var state: State = .stopped { didSet { if state != oldValue { stateContinuation.yield(state) } } }
    /// State changes, starting with the current state on subscription of a fresh stream is not
    /// provided; read `state` first, then observe.
    public nonisolated let states: AsyncStream<State>
    private let stateContinuation: AsyncStream<State>.Continuation

    /// Live display connection while the VM is active.
    public private(set) var display: DisplayConnection?
    /// When set, each display connection created by `start` has its message stream consumed
    /// for as long as the connection lives (hosts without an app that reads it).
    public private(set) var drainsDisplayMessages = false
    public func setDrainsDisplayMessages(_ on: Bool) { drainsDisplayMessages = on }
    /// The drain of the live display connection; nil when the connection has none or no engine runs.
    private(set) var displayDrain: Task<Void, Never>?

    /// Consumes and discards the messages of `connection` until its stream ends.
    @discardableResult
    static func drain(_ connection: DisplayConnection) -> Task<Void, Never> {
        Task.detached { for await _ in connection.messages {} }
    }

    /// Live QMP client while the VM is active.
    public private(set) var qmp: QMPClient?

    private var qemu: ChildProcess?
    private var swtpm: ChildProcess?
    private var eventTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var expectingExit = false
    private var generation = 0
    private var usbHotplugSerial = 0
    /// The snapshot save, delete, or stop, load and resume of a restore that is running.
    private var snapshotJob: Task<Void, Error>?

    /// Upper bound for loading a suspend-to-disk state (RAM-sized, so slow disks take a while).
    public static let resumeTimeout: Duration = .seconds(600)
    /// Time limit of the `quit` command that `shutdown` and `suspendToDisk` send.
    static let quitTimeout: Duration = .seconds(10)

    /// `tpm-tis-device` aborts under HVF in this engine build: its 0x5000-byte MMIO
    /// region is not 16 KiB aligned and `hv_vm_unmap` fails with HV_BAD_ARGUMENT
    /// (accel/hvf/hvf-all.c:123; reproduced with build/qemu-build). Refusing up
    /// front beats a crashed engine and an opaque log tail.
    private static let tpmSupported = false
    static let savedSessionKeptHint = "The saved session was kept; discard it (discardSuspendState) to boot the VM from scratch."
    public static let tpmUnavailableReason =
        "TPM is not available in this engine build: tpm-tis-device aborts under HVF (HV_BAD_ARGUMENT). Turn the TPM off in the VM settings."

    public init(bundle: VMBundle, config: VMConfig, engine: EngineLocator.Engine) {
        self.bundle = bundle
        self.config = config
        self.engine = engine
        var c: AsyncStream<State>.Continuation!
        states = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        stateContinuation = c
    }

    /// Replace the configuration (persisted by the caller). It applies on the next
    /// cold start: a running engine keeps `runningConfig`, and a suspended session
    /// resumes with the configuration saved next to its state
    /// (`VMBundle.suspendConfigURL`), because an `-incoming` stream only loads
    /// into the machine that produced it.
    /// The disk identity fields of the current `config` and of the stored `config.json` are
    /// preserved in the new one (`VMConfig.preservingDiskIdentity`), as `VMBundle.save` does.
    public func update(config: VMConfig) throws {
        try config.validate()
        self.config = bundle.preservingStoredDiskIdentity(config.preservingDiskIdentity(from: self.config))
    }

    // MARK: - start / stop

    /// Launch the engine and wait until the guest is running (or resumed from disk).
    public func start() async throws {
        try await start(bootFromCDROM: false, discardChanges: false)
    }

    /// `bootFromCDROM` asks the firmware to try the CD-ROMs first. Ignored when
    /// resuming a suspended session, which must relaunch exactly as it was saved.
    public func start(bootFromCDROM: Bool) async throws {
        try await start(bootFromCDROM: bootFromCDROM, discardChanges: false)
    }

    /// `discardChanges` runs the session on qcow2 overlays of the disks and a copy of the
    /// UEFI variables in `run/`; `teardown()` removes them. A template with clones and a
    /// suspended bundle asked to discard changes are refused before anything is launched.
    /// A VM with a `templateEpoch` is refused, on a cold start and on a resume from a suspended
    /// session, unless `VMBundle.templateMismatch` is nil for the configuration it launches with.
    /// A cold start that keeps its changes raises the stored `diskEpoch` of a VM that has one
    /// (`VMBundle.advanceDiskEpoch`) and carries the new value in `config` and `runningConfig`;
    /// when that cannot be saved the start is refused.
    /// A VM whose `config.json` is missing or does not decode is refused, whatever kind of start is asked for.
    /// A VM whose engine runs under another live host is refused (`engineOfAnotherHost()`), and so is a VM whose
    /// `agentKey` gives no public key for the SMBIOS string `alcove-hostkey`.
    public func start(bootFromCDROM: Bool = false, discardChanges: Bool) async throws {
        guard !state.isActive else { throw ControllerError.alreadyRunning }
        guard bundle.storedConfig() != nil else {
            throw ControllerError.engineDidNotStart(
                "the configuration of '\(config.name)' at \(bundle.configURL.path) cannot be read; restore or repair config.json before starting")
        }
        let clones = bundle.liveClones().map { VMBundle(url: $0).configName }
        guard clones.isEmpty else {
            throw ControllerError.engineDidNotStart(
                "'\(config.name)' is a template with clones (\(clones.joined(separator: ", "))); delete the clones first or start a clone")
        }
        let resuming = bundle.isSuspended
        guard !(resuming && discardChanges) else {
            throw ControllerError.engineDidNotStart(
                "'\(config.name)' has a suspended session; resume it or discard the suspended state before starting a session that discards changes")
        }
        if let mismatch = VMBundle.templateMismatch(for: resuming ? (bundle.loadSuspendedConfig() ?? config) : config) {
            throw ControllerError.engineDidNotStart(mismatch)
        }
        if let refusal = engineOfAnotherHost() { throw ControllerError.engineDidNotStart(refusal) }
        guard config.agentPublicKey != nil else {
            throw ControllerError.engineDidNotStart(
                "the agentKey in \(bundle.configURL.path) is not 64 hexadecimal digits, so the guest tools could not check the host; "
                + "restore config.json from a backup")
        }
        if !discardChanges, !resuming {
            do {
                if let epoch = try bundle.advanceDiskEpoch() { config.diskEpoch = epoch }
            } catch {
                throw ControllerError.engineDidNotStart(
                    "'\(config.name)' has been cloned, so each start is recorded in \(bundle.configURL.path), and that file could not be saved; "
                    + "make the bundle folder writable and start it again\n\(error.localizedDescription)")
            }
        }
        generation += 1
        let gen = generation
        state = .starting
        var engineLaunched = false
        do {
            try config.validate()
            let launch = resuming ? (bundle.loadSuspendedConfig() ?? config) : config
            if launch.tpm {
                guard Self.tpmSupported else { throw ControllerError.engineDidNotStart(Self.tpmUnavailableReason) }
                guard engine.swtpm != nil else {
                    throw ControllerError.engineDidNotStart("TPM is enabled but swtpm was not found (next to the engine, /opt/homebrew/bin or /usr/local/bin).")
                }
            }
            try await stopOrphanedEngine()
            try checkCurrent(gen)
            try bundle.prepareRunDirectory()
            if launch.tpm, let swtpmPath = engine.swtpm {
                try FileManager.default.createDirectory(at: bundle.tpmStateURL, withIntermediateDirectories: true)
                // `lock`: never share the state directory with a stale instance;
                // `terminate`: exit when QEMU, the control-channel client, goes away.
                let t = ChildProcess(executable: swtpmPath, arguments: [
                    "socket", "--tpm2", "--tpmstate", "dir=\(bundle.tpmStateURL.path),lock",
                    "--ctrl", "type=unixio,path=\(bundle.swtpmSocketPath),terminate",
                ], logURL: bundle.runURL.appendingPathComponent("swtpm.log"))
                try t.start()
                swtpm = t
                try await waitForFile(bundle.swtpmSocketPath, process: t, timeout: .seconds(10), generation: gen)
            }
            let display = try DisplayConnection(socketPath: bundle.displaySocketPath)
            self.display = display
            if drainsDisplayMessages { displayDrain = VMController.drain(display) }
            var options = QEMUCommandBuilder.Options(incomingStatePath: resuming ? bundle.suspendStateURL.path : nil,
                                                     bootFromCDROM: resuming ? false : bootFromCDROM)
            if discardChanges {
                isEphemeral = true
                for disk in launch.disks {
                    try VMBundle.createOverlay(at: bundle.ephemeralDiskURL(disk), backing: bundle.diskURL(disk), engine: engine)
                    options.diskPathOverrides[disk.id] = bundle.ephemeralDiskURL(disk).path
                }
                try FileManager.default.copyItem(at: bundle.efiVarsURL, to: bundle.ephemeralEFIVarsURL)
                options.efiVarsPath = bundle.ephemeralEFIVarsURL.path
            }
            let args = QEMUCommandBuilder(engine: engine).arguments(for: launch, bundle: bundle, options: options)
            let q = ChildProcess(executable: engine.qemuSystem, arguments: args, logURL: bundle.qemuLogURL)
            try q.start()
            qemu = q
            engineInstance += 1
            runningConfig = launch
            engineLaunched = true
            expectingExit = false
            exitTask = Task { [weak self] in
                let status = await q.waitForExit()
                await self?.engineExited(status: status, generation: gen)
            }
            try await waitForFile(bundle.qmpSocketPath, process: q, timeout: .seconds(20), generation: gen)
            let client = QMPClient()
            do {
                try await client.connect(path: bundle.qmpSocketPath)
                try checkCurrent(gen)
            } catch {
                await client.disconnect()
                throw error
            }
            qmp = client
            eventTask = Task { [weak self] in
                for await event in client.events {
                    await self?.handle(event: event, generation: gen)
                }
            }
            if resuming {
                try await waitForIncomingMigration(client, generation: gen)
                // the stream is loaded; the saved session has served its purpose
                try? bundle.discardSuspendState()
                // the saved run state is "paused" (we stop before migrating); resume it
                if try await !client.queryStatus().running { try await client.cont() }
            } else {
                try await waitForRunStateToSettle(client, generation: gen)
            }
            let s = try await client.queryStatus()
            try checkCurrent(gen)
            state = s.running ? .running : .paused
        } catch {
            // stop-during-start: shutdown() owns the state and the engine now
            guard gen == generation else { throw ControllerError.notRunning }
            // from here on a late exit notification from this engine is ignored
            generation += 1
            if case .failed(let early) = state {
                // the engine already died and engineExited() recorded its log: one report
                await teardown()
                throw ControllerError.engineDidNotStart(early)
            }
            var message = "\(error)"
            if case .engineDidNotStart(let reason)? = error as? ControllerError { message = reason }
            // give a dying engine a moment to flush its error output
            var status: Int32?
            if let q = qemu { status = await q.waitForExit(timeout: .seconds(2)) }
            let tail = qemu?.logTail() ?? ""
            if let status { message += "\nengine exited with status \(status)" }
            if !tail.isEmpty { message += "\n\(tail)" }
            if resuming, engineLaunched, bundle.isSuspended { message += "\n" + Self.savedSessionKeptHint }
            await teardown()
            state = .failed(message)
            throw ControllerError.engineDidNotStart(message)
        }
    }

    /// ACPI/PSCI power-button shutdown; falls back to `quit` after `gracePeriod`.
    /// A guest the engine reports as not running is resumed before the power button is
    /// pressed; the status query, the resume and the button press share the grace period
    /// as their time limit.
    /// While starting (including a resume still loading its state) it aborts the
    /// start; while suspending only `force` is accepted and drops the partial state.
    public func shutdown(force: Bool = false, gracePeriod: Duration = .seconds(60)) async throws {
        guard state.isActive else { throw ControllerError.notRunning }
        let gen = generation
        switch state {
        case .starting:
            generation += 1   // start() unwinds at its next checkpoint without touching the state
            state = .stopping
            await teardown()
            state = .stopped
            return
        case .suspending:
            guard force else { throw ControllerError.notRunning }
            generation += 1   // suspendToDisk() rethrows without touching the state
            state = .stopping
            await teardown()
            try? bundle.discardSuspendState()
            state = .stopped
            return
        default:
            break
        }
        guard let q = qemu else { throw ControllerError.notRunning }
        let wasPaused = state == .paused
        state = .stopping
        expectingExit = true
        if !force, let qmp {
            let deadline = ContinuousClock.now + gracePeriod
            func remaining() -> Duration { max(.zero, deadline - ContinuousClock.now) }
            // stopped vCPUs cannot act on the power button
            let running = (try? await qmp.queryStatus(timeout: remaining()))?.running ?? !wasPaused
            if !running { try? await qmp.cont(timeout: remaining()) }
            try? await qmp.systemPowerdown(timeout: remaining())
            if await q.waitForExit(timeout: remaining()) != nil { await finalizeExpectedExit(generation: gen); return }
        }
        if let qmp { try? await qmp.quit(timeout: Self.quitTimeout) }
        if await q.waitForExit(timeout: .seconds(10)) == nil {
            q.kill()
            _ = await q.waitForExit()
        }
        await finalizeExpectedExit(generation: gen)
    }

    public func pause() async throws {
        guard state == .running, let qmp else { throw ControllerError.notRunning }
        try await qmp.stop()
        state = .paused
    }

    public func resume() async throws {
        guard state == .paused, let qmp else { throw ControllerError.notRunning }
        try await qmp.cont()
        state = .running
    }

    public func reset() async throws {
        guard state.isActive, let qmp else { throw ControllerError.notRunning }
        try await qmp.systemReset()
    }

    /// Save all state to disk and stop the engine; the next `start()` resumes it.
    /// On failure (disk full, migration error, timeout) nothing is kept and the
    /// guest is left as it was.
    public func suspendToDisk() async throws {
        guard state == .running || state == .paused, let qmp, let q = qemu, let launched = runningConfig else {
            throw ControllerError.notRunning
        }
        guard !isEphemeral else {
            throw ControllerError.engineDidNotStart("this session discards changes and cannot be suspended; stop it instead")
        }
        let gen = generation
        let previous = state
        state = .suspending
        expectingExit = true
        try? bundle.discardSuspendState()
        do {
            try launched.encoded().write(to: bundle.suspendConfigURL, options: .atomic)
            try await qmp.stop()
            try await qmp.migrate(uri: "file:\(bundle.suspendStateURL.path)")
        } catch {
            guard gen == generation else { throw error }   // a forced shutdown took over
            try? bundle.discardSuspendState()
            expectingExit = false
            if previous == .running { try? await qmp.cont() }
            let s = try? await qmp.queryStatus()
            state = (s?.running ?? (previous == .running)) ? .running : .paused
            throw error
        }
        try? await qmp.quit(timeout: Self.quitTimeout)
        if await q.waitForExit(timeout: .seconds(15)) == nil {
            q.kill()
            _ = await q.waitForExit()
        }
        await finalizeExpectedExit(generation: gen)
    }

    /// Forget a suspended session so the next `start()` boots from scratch (the
    /// way out after a resume failed). Refused while the engine is active.
    public func discardSuspendState() throws {
        guard !state.isActive else { throw ControllerError.alreadyRunning }
        try bundle.discardSuspendState()
    }

    // MARK: - linked clones

    /// Creates a linked clone of this VM's bundle (`VMBundle.cloneLinked`); refused while the engine is active.
    public func cloneLinked(named newName: String) throws -> VMBundle {
        guard !state.isActive else { throw VMBundle.CloneError.sourceRunning(config.name) }
        return try bundle.cloneLinked(named: newName, engine: engine)
    }

    /// Deletes this VM's bundle when it is a clone (`VMBundle.deleteClone`); refused while the engine is active.
    public func deleteClone() throws {
        guard !state.isActive else { throw VMBundle.CloneError.cloneRunning(config.name) }
        try bundle.deleteClone()
    }

    // MARK: - snapshots (qcow2 internal snapshots on every disk, vmstate on the first)

    public func snapshots() async throws -> [SnapshotInfo] {
        guard let disk = (runningConfig ?? config).disks.first else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: engine.qemuImg)
        p.arguments = ["info", "-U", "--output=json", (isEphemeral ? bundle.ephemeralDiskURL(disk) : bundle.diskURL(disk)).path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ControllerError.snapshotListFailed(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        let json = try JSON.parse(data)
        return (json["snapshots"]?.arrayValue ?? []).compactMap { s in
            guard let name = s["name"]?.stringValue else { return nil }
            return SnapshotInfo(name: name, vmStateSize: s["vm-state-size"]?.intValue ?? 0,
                                date: Date(timeIntervalSince1970: TimeInterval(s["date-sec"]?.intValue ?? 0)))
        }
    }

    /// Whether `name` can name a snapshot: 1 to 128 characters without a line break.
    public static func isValidSnapshotName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && !name.contains(where: { $0.isNewline })
    }

    private func checkSnapshotName(_ name: String) throws {
        guard Self.isValidSnapshotName(name) else { throw ControllerError.invalidSnapshotName(name) }
    }

    /// Saves a snapshot of the running or paused guest; waits for a snapshot save, delete or restore that runs to end
    /// first. The save runs to its end in a task of its own, also when the caller is cancelled.
    public func createSnapshot(named name: String) async throws {
        try checkSnapshotName(name)
        await waitForSnapshotJob()
        guard state == .running || state == .paused, let qmp, let disks = runningConfig?.disks, let vmstate = disks.first?.id else {
            throw ControllerError.notRunning
        }
        try await runSnapshotJob { try await qmp.snapshotSave(tag: name, vmstate: vmstate, devices: disks.map(\.id)) }
    }

    /// Runs `body` as the snapshot job in a task of its own and returns its outcome.
    private func runSnapshotJob(_ body: @escaping @Sendable () async throws -> Void) async throws {
        let job = Task {
            defer { self.snapshotJob = nil }
            try await body()
        }
        snapshotJob = job
        try await job.value
    }

    /// Load a snapshot; a guest that runs when the load task begins is stopped
    /// for the load and resumed afterwards, also when the load fails. Once the
    /// guest is touched, the stop, load and resume run to their end in a task
    /// of their own, also when the caller is cancelled. A restore asked for
    /// while another restore, a save or a delete runs waits for it to end
    /// first. When a stop or a
    /// suspend takes over the VM before or during the load, the restore leaves
    /// the state and the guest to it and throws `notRunning`.
    public func restoreSnapshot(named name: String) async throws {
        try checkSnapshotName(name)
        await waitForSnapshotJob()
        guard state == .running || state == .paused, let qmp, let disks = runningConfig?.disks, let vmstate = disks.first?.id else {
            throw ControllerError.notRunning
        }
        try Task.checkCancellation()
        let gen = generation
        try await runSnapshotJob { try await self.loadSnapshot(name, qmp: qmp, vmstate: vmstate, devices: disks.map(\.id), generation: gen) }
    }

    /// Returns once no snapshot job is in flight.
    private func waitForSnapshotJob() async {
        while let inFlight = snapshotJob { _ = await inFlight.result }
    }

    private func loadSnapshot(_ name: String, qmp: QMPClient, vmstate: String, devices: [String], generation gen: Int) async throws {
        try checkRestoreOwnsState(gen)
        let wasRunning = state == .running
        try await qmp.stop()
        try checkRestoreOwnsState(gen)
        state = .paused
        do {
            try await qmp.snapshotLoad(tag: name, vmstate: vmstate, devices: devices)
        } catch {
            if wasRunning, restoreOwnsState(gen), (try? await qmp.cont()) != nil, restoreOwnsState(gen) { state = .running }
            throw error
        }
        try checkRestoreOwnsState(gen)
        display?.send(.refresh(con: 0))
        if wasRunning {
            try await qmp.cont()
            try checkRestoreOwnsState(gen)
            state = .running
        }
    }

    /// Whether the engine of generation `gen` still runs and no stop or suspend has taken over the state.
    private func restoreOwnsState(_ gen: Int) -> Bool {
        gen == generation && (state == .running || state == .paused)
    }

    private func checkRestoreOwnsState(_ gen: Int) throws {
        guard restoreOwnsState(gen) else { throw ControllerError.notRunning }
    }

    /// Deletes a snapshot of the running or paused guest; waits for a snapshot save, delete or restore that runs to end
    /// first. The delete runs to its end in a task of its own, also when the caller is cancelled.
    public func deleteSnapshot(named name: String) async throws {
        try checkSnapshotName(name)
        await waitForSnapshotJob()
        guard state == .running || state == .paused, let qmp, let disks = runningConfig?.disks else { throw ControllerError.notRunning }
        try await runSnapshotJob { try await qmp.snapshotDelete(tag: name, devices: disks.map(\.id)) }
    }

    // MARK: - monitor and network

    /// Runs one human-monitor line and returns its text output.
    public func monitorCommand(_ line: String) async throws -> String {
        guard state.isActive, let qmp else { throw ControllerError.notRunning }
        return try await qmp.humanMonitorCommand(line)
    }

    /// Brings the guest's network link up or down.
    public func setNetworkLink(up: Bool) async throws {
        guard state.isActive, let qmp else { throw ControllerError.notRunning }
        try await qmp.setLink(name: Self.netdevID, up: up)
    }

    // MARK: - devices

    /// Attach a host USB device now (`usb-host` hot-plug). Returns the device id,
    /// unique per attachment so identical devices (or a re-attach) never clash.
    @discardableResult
    public func attachUSB(_ selector: VMConfig.USBSelector) async throws -> String {
        guard state.isActive, let qmp else { throw ControllerError.notRunning }
        usbHotplugSerial += 1
        let id = "usbhot-\(String(format: "%04x-%04x", selector.vendorID, selector.productID))-\(usbHotplugSerial)"
        try await qmp.attachUSBHost(id: id, vendorID: selector.vendorID, productID: selector.productID, bus: QEMUCommandBuilder.usbBus)
        return id
    }

    public func detachUSB(id: String) async throws {
        guard state.isActive, let qmp else { throw ControllerError.notRunning }
        try await qmp.deviceDel(id: id)
    }

    /// Insert `isoPath` into the running VM's CD-ROM `cdromID` (eject when nil).
    /// A tray the guest has locked is forced open. `config` and `runningConfig`
    /// record the change so the next start and a later suspend match.
    public func changeMedium(cdromID: String, isoPath: String?) async throws {
        guard state.isActive, let qmp else { throw ControllerError.notRunning }
        let device = QEMUCommandBuilder.cdromDeviceID(cdromID)
        if let isoPath {
            do {
                try await qmp.changeMedium(deviceID: device, filename: isoPath, format: "raw")
            } catch let error as QMPClient.QMPError where Self.isLockedTray(error) {
                try await qmp.eject(deviceID: device, force: true)
                try await qmp.changeMedium(deviceID: device, filename: isoPath, format: "raw")
            }
        } else {
            do {
                try await qmp.eject(deviceID: device)
            } catch let error as QMPClient.QMPError where Self.isLockedTray(error) {
                try await qmp.eject(deviceID: device, force: true)
            }
        }
        if let i = config.cdroms.firstIndex(where: { $0.id == cdromID }) { config.cdroms[i].path = isoPath }
        if let i = runningConfig?.cdroms.firstIndex(where: { $0.id == cdromID }) { runningConfig?.cdroms[i].path = isoPath }
    }

    public func screenshot(to url: URL) async throws {
        guard state.isActive, let qmp else { throw ControllerError.notRunning }
        try await qmp.screendump(filename: url.path)
    }

    // MARK: - internals

    /// block/qapi-system.c `do_open_tray`: "Device '%s' is locked and force was not specified".
    private static func isLockedTray(_ error: QMPClient.QMPError) -> Bool {
        if case .command(_, _, let desc) = error { return desc.contains("is locked") }
        return false
    }

    private func checkCurrent(_ gen: Int) throws {
        guard gen == generation else { throw CancellationError() }
    }

    private func waitForFile(_ path: String, process: ChildProcess, timeout: Duration, generation gen: Int) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try checkCurrent(gen)
            if FileManager.default.fileExists(atPath: path) { return }
            if !process.isRunning {
                throw ControllerError.engineDidNotStart("process exited before creating \(path)\n\(process.logTail())")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ControllerError.qmpUnavailable("timed out waiting for \(path)")
    }

    /// A cold boot runs as soon as the machine is built; wait through `prelaunch` (bounded).
    private func waitForRunStateToSettle(_ client: QMPClient, generation gen: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            let s = try await client.queryStatus()
            try checkCurrent(gen)
            if s.running || s.state == "paused" || s.state == "shutdown" { return }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Wait until the `-incoming` load has finished, i.e. the run state left
    /// `inmigrate` (a failed load exits the engine instead, which surfaces as a
    /// disconnected QMP client).
    private func waitForIncomingMigration(_ client: QMPClient, generation gen: Int) async throws {
        let deadline = ContinuousClock.now + Self.resumeTimeout
        while true {
            let s = try await client.queryStatus()
            try checkCurrent(gen)
            if s.state != "inmigrate" { return }
            guard ContinuousClock.now < deadline else {
                throw ControllerError.engineDidNotStart("resuming the saved session did not finish within \(Self.resumeTimeout)")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func handle(event: QMPClient.Event, generation gen: Int) {
        guard gen == generation else { return }
        switch event.name {
        case "STOP": if state == .running { state = .paused }
        case "RESUME": if state == .paused { state = .running }
        case "SHUTDOWN": if state == .running || state == .paused || state == .stopping { expectingExit = true; state = .stopping }
        default: break
        }
    }

    /// The engine exited because we asked it to: tear down now and ignore the
    /// late exit notification. A no-op when a newer generation (a start issued
    /// by a `states` observer, say) already owns the controller.
    private func finalizeExpectedExit(generation gen: Int) async {
        guard gen == generation else { return }
        generation += 1
        await teardown()
        state = .stopped
    }

    private func engineExited(status: Int32, generation gen: Int) async {
        guard gen == generation else { return }
        let tail = qemu?.logTail() ?? ""
        let wasExpected = expectingExit
        let resumeDied = state == .starting && bundle.isSuspended
        await teardown()
        if wasExpected || status == 0 {
            state = .stopped
        } else {
            var message = "QEMU exited with status \(status)\n\(tail)"
            if resumeDied { message += "\n" + Self.savedSessionKeptHint }
            state = .failed(message)
        }
    }

    private func teardown() async {
        eventTask?.cancel(); eventTask = nil
        await qmp?.disconnect(); qmp = nil
        display?.close(); display = nil
        displayDrain?.cancel(); displayDrain = nil
        if let q = qemu, q.isRunning { q.kill() }
        qemu = nil
        runningConfig = nil
        if isEphemeral {
            isEphemeral = false
            bundle.removeEphemeralFiles()
        }
        if let t = swtpm {
            swtpm = nil
            t.terminate()
            // its state-directory lock must be free before the next start
            if await t.waitForExit(timeout: .seconds(3)) == nil { t.kill() }
        }
    }

    // MARK: orphaned engines

    /// The refusal for an engine that holds this VM's pidfile lock while its parent, a process other than
    /// launchd (pid 1) and this one, is alive; nil when no engine holds the lock or the engine is an orphan
    /// or this process's own.
    func engineOfAnotherHost() -> String? {
        Self.pidfileLockHolder(bundle.pidFileURL.path).flatMap(anotherHostRefusal(holder:))
    }

    /// The refusal for the pidfile lock holder `pid` when `otherHost(ofEngine:)` names its host; nil otherwise.
    private func anotherHostRefusal(holder pid: pid_t) -> String? {
        guard let host = Self.otherHost(ofEngine: pid) else { return nil }
        return "'\(config.name)' is running in another Alcove host (\(host.name) pid \(host.pid)); "
            + "stop the VM there or quit that host, then start it here"
    }

    /// The name and pid of the parent of the engine process `pid` when that parent is alive and is neither
    /// launchd (pid 1) nor this process; nil otherwise.
    public nonisolated static func otherHost(ofEngine pid: pid_t) -> (name: String, pid: pid_t)? {
        guard let parent = parentPID(of: pid), parent != 1, parent != getpid() else { return nil }
        return (processName(parent), parent)
    }

    /// An engine from a previous app instance (crash, force-quit) may still own
    /// this VM's disks. QEMU holds a write lock on its pidfile while alive, so
    /// the lock holder is the live process, never a reused pid. An engine whose
    /// parent is launchd or this process is stopped (SIGTERM, then SIGKILL)
    /// before touching the run directory; swtpm follows on its own
    /// (`--ctrl ...,terminate`). An engine of another live host is refused
    /// (`anotherHostRefusal(holder:)`). Signals go only to the holder pid that was checked; a different
    /// holder that appears while waiting is checked the same way and, unless refused, stopped in turn.
    private func stopOrphanedEngine() async throws {
        let path = bundle.pidFileURL.path
        var holder = Self.pidfileLockHolder(path)
        var pid: pid_t = 0
        var deadline = ContinuousClock.now
        var killed = false
        while let current = holder {
            if current != pid {
                if let refusal = anotherHostRefusal(holder: current) { throw ControllerError.engineDidNotStart(refusal) }
                pid = current
                Darwin.kill(pid, SIGTERM)
                deadline = ContinuousClock.now + .seconds(10)
                killed = false
            } else if ContinuousClock.now >= deadline {
                guard !killed else {
                    throw ControllerError.engineDidNotStart("an engine from a previous session (pid \(pid)) still owns this VM and could not be stopped")
                }
                Darwin.kill(pid, SIGKILL)
                killed = true
                deadline = ContinuousClock.now + .seconds(5)
            }
            try await Task.sleep(for: .milliseconds(100))
            holder = Self.pidfileLockHolder(path)
        }
    }

    /// The pid holding a write lock on `path` (F_GETLK), or nil when unlocked or absent.
    nonisolated static func pidfileLockHolder(_ path: String) -> pid_t? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        guard fcntl(fd, F_GETLK, &lock) == 0, lock.l_type != Int16(F_UNLCK) else { return nil }
        return lock.l_pid
    }

    /// The parent pid of `pid` (`sysctl` `KERN_PROC_PID`), or nil when no such process exists.
    nonisolated static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// The name of the process `pid` (`proc_name`), or "a process" when it cannot be read.
    nonisolated static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "a process" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return bytes.isEmpty ? "a process" : String(decoding: bytes, as: UTF8.self)
    }
}
