import Foundation
import AlcoveDisplayProtocol
import AlcoveQMP

/// Lifecycle of one VM: launches the engine, owns the display connection and
/// QMP client, and exposes state changes. One controller per bundle.
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
    }

    public nonisolated let bundle: VMBundle
    public nonisolated let engine: EngineLocator.Engine
    public private(set) var config: VMConfig
    public private(set) var state: State = .stopped { didSet { if state != oldValue { stateContinuation.yield(state) } } }
    /// State changes, starting with the current state on subscription of a fresh stream is not
    /// provided; read `state` first, then observe.
    public nonisolated let states: AsyncStream<State>
    private let stateContinuation: AsyncStream<State>.Continuation

    /// Live display connection while the VM is active.
    public private(set) var display: DisplayConnection?
    /// Live QMP client while the VM is active.
    public private(set) var qmp: QMPClient?

    private var qemu: ChildProcess?
    private var swtpm: ChildProcess?
    private var eventTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var expectingExit = false
    private var generation = 0

    public init(bundle: VMBundle, config: VMConfig, engine: EngineLocator.Engine) {
        self.bundle = bundle
        self.config = config
        self.engine = engine
        var c: AsyncStream<State>.Continuation!
        states = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        stateContinuation = c
    }

    /// Replace the configuration (persisted by the caller); applies on next start.
    public func update(config: VMConfig) throws {
        try config.validate()
        self.config = config
    }

    // MARK: - start / stop

    /// Launch the engine and wait until the guest is running (or resumed from disk).
    public func start() async throws {
        guard !state.isActive else { throw ControllerError.alreadyRunning }
        state = .starting
        generation += 1
        let gen = generation
        do {
            try config.validate()
            try bundle.prepareRunDirectory()
            if config.tpm, let swtpmPath = engine.swtpm {
                try FileManager.default.createDirectory(at: bundle.tpmStateURL, withIntermediateDirectories: true)
                let t = ChildProcess(executable: swtpmPath, arguments: [
                    "socket", "--tpm2", "--tpmstate", "dir=\(bundle.tpmStateURL.path)",
                    "--ctrl", "type=unixio,path=\(bundle.swtpmSocketPath)",
                ], logURL: bundle.runURL.appendingPathComponent("swtpm.log"))
                try t.start()
                swtpm = t
                try await waitForFile(bundle.swtpmSocketPath, process: t, timeout: .seconds(10))
            }
            let display = try DisplayConnection(socketPath: bundle.displaySocketPath)
            self.display = display
            let resuming = bundle.isSuspended
            let options = QEMUCommandBuilder.Options(incomingStatePath: resuming ? bundle.suspendStateURL.path : nil)
            let args = QEMUCommandBuilder(engine: engine).arguments(for: config, bundle: bundle, options: options)
            let q = ChildProcess(executable: engine.qemuSystem, arguments: args, logURL: bundle.qemuLogURL)
            try q.start()
            qemu = q
            expectingExit = false
            exitTask = Task { [weak self] in
                let status = await q.waitForExit()
                await self?.engineExited(status: status, generation: gen)
            }
            try await waitForFile(bundle.qmpSocketPath, process: q, timeout: .seconds(20))
            let client = QMPClient()
            try await client.connect(path: bundle.qmpSocketPath)
            qmp = client
            eventTask = Task { [weak self] in
                for await event in client.events {
                    await self?.handle(event: event, generation: gen)
                }
            }
            // wait for the run state to settle (incoming migration takes a while)
            let deadline = ContinuousClock.now + .seconds(120)
            while ContinuousClock.now < deadline {
                let s = try await client.queryStatus()
                if s.running { break }
                if s.state == "paused" || s.state == "shutdown" { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            if resuming {
                try? FileManager.default.removeItem(at: bundle.suspendStateURL)
            }
            let s = try await client.queryStatus()
            state = s.running ? .running : .paused
        } catch {
            let tail = qemu?.logTail() ?? ""
            await teardown()
            let message = tail.isEmpty ? "\(error)" : "\(error)\n\(tail)"
            state = .failed(message)
            throw ControllerError.engineDidNotStart(message)
        }
    }

    /// ACPI/PSCI power-button shutdown; falls back to `quit` after `gracePeriod`.
    public func shutdown(force: Bool = false, gracePeriod: Duration = .seconds(60)) async throws {
        guard state.isActive, let q = qemu else { throw ControllerError.notRunning }
        state = .stopping
        expectingExit = true
        if !force, let qmp {
            try? await qmp.systemPowerdown()
            if await q.waitForExit(timeout: gracePeriod) != nil { return }
        }
        if let qmp { try? await qmp.quit() }
        if await q.waitForExit(timeout: .seconds(10)) == nil {
            q.kill()
            _ = await q.waitForExit()
        }
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
    public func suspendToDisk() async throws {
        guard state == .running || state == .paused, let qmp, let q = qemu else { throw ControllerError.notRunning }
        state = .suspending
        expectingExit = true
        try? FileManager.default.removeItem(at: bundle.suspendStateURL)
        try await qmp.stop()
        try await qmp.migrate(uri: "file:\(bundle.suspendStateURL.path)")
        try? await qmp.quit()
        if await q.waitForExit(timeout: .seconds(15)) == nil {
            q.kill()
            _ = await q.waitForExit()
        }
    }

    // MARK: - snapshots (qcow2 internal snapshots on every disk, vmstate on the first)

    public func snapshots() async throws -> [SnapshotInfo] {
        guard let disk = config.disks.first else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: engine.qemuImg)
        p.arguments = ["info", "-U", "--output=json", bundle.diskURL(disk).path]
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

    private func checkSnapshotName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 128, !name.contains(where: { $0.isNewline }) else {
            throw ControllerError.invalidSnapshotName(name)
        }
    }

    public func createSnapshot(named name: String) async throws {
        try checkSnapshotName(name)
        guard state == .running || state == .paused, let qmp, let vmstate = config.disks.first?.id else { throw ControllerError.notRunning }
        try await qmp.snapshotSave(tag: name, vmstate: vmstate, devices: config.disks.map(\.id))
    }

    public func restoreSnapshot(named name: String) async throws {
        try checkSnapshotName(name)
        guard state == .running || state == .paused, let qmp, let vmstate = config.disks.first?.id else { throw ControllerError.notRunning }
        let wasRunning = state == .running
        try await qmp.stop()
        state = .paused
        try await qmp.snapshotLoad(tag: name, vmstate: vmstate, devices: config.disks.map(\.id))
        display?.send(.refresh(con: 0))
        if wasRunning {
            try await qmp.cont()
            state = .running
        }
    }

    public func deleteSnapshot(named name: String) async throws {
        try checkSnapshotName(name)
        guard state == .running || state == .paused, let qmp else { throw ControllerError.notRunning }
        try await qmp.snapshotDelete(tag: name, devices: config.disks.map(\.id))
    }

    // MARK: - devices

    /// Attach a host USB device now (`usb-host` hot-plug). Returns the device id.
    @discardableResult
    public func attachUSB(_ selector: VMConfig.USBSelector) async throws -> String {
        guard state.isActive, let qmp else { throw ControllerError.notRunning }
        let id = "usbhot-\(String(format: "%04x-%04x", selector.vendorID, selector.productID))"
        try await qmp.attachUSBHost(id: id, vendorID: selector.vendorID, productID: selector.productID, bus: QEMUCommandBuilder.usbBus)
        return id
    }

    public func detachUSB(id: String) async throws {
        guard state.isActive, let qmp else { throw ControllerError.notRunning }
        try await qmp.deviceDel(id: id)
    }

    public func screenshot(to url: URL) async throws {
        guard state.isActive, let qmp else { throw ControllerError.notRunning }
        try await qmp.screendump(filename: url.path)
    }

    // MARK: - internals

    private func waitForFile(_ path: String, process: ChildProcess, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: path) { return }
            if !process.isRunning {
                throw ControllerError.engineDidNotStart("process exited before creating \(path)\n\(process.logTail())")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ControllerError.qmpUnavailable("timed out waiting for \(path)")
    }

    private func handle(event: QMPClient.Event, generation gen: Int) {
        guard gen == generation else { return }
        switch event.name {
        case "STOP": if state == .running { state = .paused }
        case "RESUME": if state == .paused { state = .running }
        case "SHUTDOWN": if state != .suspending { expectingExit = true; state = .stopping }
        default: break
        }
    }

    private func engineExited(status: Int32, generation gen: Int) async {
        guard gen == generation else { return }
        let tail = qemu?.logTail() ?? ""
        let wasExpected = expectingExit
        await teardown()
        if wasExpected || status == 0 {
            state = .stopped
        } else {
            state = .failed("QEMU exited with status \(status)\n\(tail)")
        }
    }

    private func teardown() async {
        eventTask?.cancel(); eventTask = nil
        await qmp?.disconnect(); qmp = nil
        display?.close(); display = nil
        if let q = qemu, q.isRunning { q.kill() }
        qemu = nil
        if let t = swtpm { t.terminate(); swtpm = nil }
    }
}
