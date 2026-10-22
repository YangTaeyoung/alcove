import AppKit
import Foundation
import Observation
import AlcoveEngine

/// Process-wide application state: the located engine, the VM directory and
/// the `VMSession` for every bundle in it. Main-actor singleton.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    enum AppError: Error {
        case engineUnavailable(String)
        case vmIsActive(String)
        case vmRunsInAnotherHost(String, host: String)
        case vmHeldByEarlierEngine(String)
        case nameAlreadyUsed(String)
        case templateHasClones(String, clones: [String])
    }

    /// Directory holding `*.alcovevm` bundles (`$ALCOVE_VM_DIR` or Application Support).
    let vmDirectory: URL
    /// The engine, when found.
    private(set) var engine: EngineLocator.Engine?
    /// Why no engine is available (nil when `engine` is set).
    private(set) var engineIssue: String?
    /// One session per loadable bundle, sorted by name. Empty while the engine is missing.
    private(set) var sessions: [VMSession] = [] {
        didSet { AppControlServer.shared.updateSessions(sessions) }
    }
    /// Bundles that exist on disk but could not be loaded, as "name: reason".
    private(set) var loadFailures: [String] = []
    /// Number of bundles on disk that cannot be shown because the engine is missing.
    private(set) var bundlesAwaitingEngine = 0
    /// An error the library window should present.
    var pendingError: String?
    /// Set by File > New Virtual Machine…; the library window presents the sheet.
    var newVMRequested = false
    /// Host USB devices for the passthrough menus; watching starts on first use.
    let usbDevices = USBDeviceList()

    @ObservationIgnored private var directoryWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var reloadScheduled = false

    private init() {
        vmDirectory = AppModel.resolveVMDirectory()
        locateEngine()
        reload()
        watchDirectory()
    }

    // MARK: - engine

    /// Search again (after the user built the engine or set `ALCOVE_QEMU_DIR`).
    func locateEngine() {
        let locator = EngineLocator.standard()
        do {
            engine = try locator.locate()
            engineIssue = nil
        } catch {
            engine = nil
            engineIssue = ErrorText.describe(error)
        }
    }

    /// `$ALCOVE_VM_DIR` when set, else `~/Library/Application Support/Alcove/VMs`.
    static func resolveVMDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["ALCOVE_VM_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Alcove/VMs", isDirectory: true)
    }

    // MARK: - sessions

    func session(id: String) -> VMSession? {
        sessions.first { $0.id == id }
    }

    var activeSessions: [VMSession] { sessions.filter { $0.state.isActive } }

    /// Re-scan the VM directory. Existing sessions are kept (they may be
    /// running); new bundles get sessions; vanished, inactive bundles are dropped.
    func reload() {
        ensureDirectory()
        let bundles = VMBundle.list(in: vmDirectory)
        guard let engine else {
            bundlesAwaitingEngine = bundles.count
            for s in sessions where !s.state.isActive { s.invalidate() }
            sessions = sessions.filter { $0.state.isActive }
            return
        }
        bundlesAwaitingEngine = 0
        var next: [VMSession] = []
        var failures: [String] = []
        for bundle in bundles {
            let id = VMSession.identifier(for: bundle)
            if let existing = sessions.first(where: { $0.id == id }) {
                next.append(existing)
                continue
            }
            do {
                let config = try bundle.loadConfig()
                next.append(makeSession(bundle: bundle, config: config, engine: engine))
            } catch {
                failures.append("\(bundle.url.lastPathComponent): \(ErrorText.describe(error))")
            }
        }
        for s in sessions where !next.contains(where: { $0.id == s.id }) {
            if s.state.isActive { next.append(s) } else { s.invalidate() }
        }
        sessions = sorted(next)
        loadFailures = failures
        refreshDockBadge()
    }

    /// Create the bundle (disk images are made by `qemu-img`, off the main actor)
    /// and return its session.
    func createVM(_ config: VMConfig) async throws -> VMSession {
        guard let engine else { throw AppError.engineUnavailable(engineIssue ?? "") }
        try config.validate()
        ensureDirectory()
        let directory = vmDirectory
        let bundle = try await Task.detached(priority: .userInitiated) {
            try VMBundle.create(config, in: directory, engine: engine)
        }.value
        // The directory watcher fires as soon as the bundle directory appears;
        // if its debounced reload ran while qemu-img was still working it has
        // already built a session for this bundle. Never register a second one.
        let id = VMSession.identifier(for: bundle)
        if let existing = sessions.first(where: { $0.id == id }) { return existing }
        let session = makeSession(bundle: bundle, config: config, engine: engine)
        sessions = sorted(sessions + [session])
        return session
    }

    /// Remove the bundle (to the Trash when possible) and its session. The VM must be stopped (`refuseRunning`)
    /// and must not be the template of a clone; a clone leaves its template's clone list.
    func deleteVM(_ session: VMSession) throws {
        try refuseRunning(session)
        try refuseTemplate(session)
        let fm = FileManager.default
        do {
            try fm.trashItem(at: session.bundle.url, resultingItemURL: nil)
        } catch {
            try fm.removeItem(at: session.bundle.url)
        }
        try? fm.removeItem(atPath: session.bundle.socketDirectory)
        refreshCloneList(ofTemplate: session.config.cloneOf)
        AppControlServer.shared.vmDeleted(vm: session.name, path: session.id)
        session.invalidate()
        sessions.removeAll { $0.id == session.id }
        refreshDockBadge()
    }

    /// Move the bundle to `<newConfig.name>.alcovevm`, save `newConfig` into it
    /// and replace the session. The VM must be stopped (`refuseRunning`) and must not be the template
    /// of a clone; a renamed clone is re-listed by its template. Returns the new session.
    func rename(_ session: VMSession, to newConfig: VMConfig) throws -> VMSession {
        guard let engine else { throw AppError.engineUnavailable(engineIssue ?? "") }
        try refuseRunning(session)
        try refuseTemplate(session)
        var config = newConfig
        config.name = newConfig.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try config.validate()
        let fm = FileManager.default
        let destination = vmDirectory.appendingPathComponent(config.name).appendingPathExtension(VMBundle.pathExtension)
        guard !fm.fileExists(atPath: destination.path) else { throw AppError.nameAlreadyUsed(config.name) }
        try fm.moveItem(at: session.bundle.url, to: destination)
        let bundle = VMBundle(url: destination)
        do {
            try bundle.save(config)
        } catch {
            try? fm.moveItem(at: destination, to: session.bundle.url)
            throw error
        }
        try? fm.removeItem(atPath: session.bundle.socketDirectory)
        refreshCloneList(ofTemplate: config.cloneOf)
        session.invalidate()
        let replacement = makeSession(bundle: bundle, config: config, engine: engine)
        AppControlServer.shared.vmRenamed(from: session.name, oldPath: session.id, to: replacement.name, newPath: replacement.id)
        sessions = sorted(sessions.filter { $0.id != session.id } + [replacement])
        return replacement
    }

    /// File > New Virtual Machine…. Ignored while the engine is missing: the
    /// library already shows how to build it, and `createVM` would only fail
    /// after the user filled in the whole form.
    func requestNewVM() {
        guard engine != nil else { return }
        newVMRequested = true
    }

    // MARK: - bulk actions (quit)

    /// Suspend every active VM to disk; VMs that cannot be suspended are force-stopped.
    func suspendAll() async {
        await withTaskGroup(of: Void.self) { group in
            for session in activeSessions {
                group.addTask {
                    await session.suspend()
                    if await session.state.isActive { await session.shutdown(force: true) }
                }
            }
        }
    }

    /// Power-button shutdown for every active VM (the controller falls back to
    /// `quit` after its grace period); anything still alive is force-stopped.
    func shutdownAll() async {
        await withTaskGroup(of: Void.self) { group in
            for session in activeSessions {
                group.addTask {
                    await session.shutdown(force: false)
                    if await session.state.isActive { await session.shutdown(force: true) }
                }
            }
        }
    }

    /// Dock badge = number of active VMs.
    func refreshDockBadge() {
        let count = activeSessions.count
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    // MARK: - internals

    /// Throws when the session is active or an engine holds its bundle's pidfile lock; names the other host
    /// when that engine runs under one (`VMBundle.otherEngineHost`), and otherwise says that an engine of an
    /// earlier session holds the bundle.
    private func refuseRunning(_ session: VMSession) throws {
        guard !session.state.isActive else { throw AppError.vmIsActive(session.name) }
        guard session.bundle.isRunning else { return }
        if let host = session.bundle.otherEngineHost {
            throw AppError.vmRunsInAnotherHost(session.name, host: "\(host.name) pid \(host.pid)")
        }
        throw AppError.vmHeldByEarlierEngine(session.name)
    }

    /// Throws when clones are backed by this session's disks.
    private func refuseTemplate(_ session: VMSession) throws {
        let clones = session.bundle.liveClones().map { VMBundle(url: $0).configName }
        guard clones.isEmpty else { throw AppError.templateHasClones(session.name, clones: clones) }
    }

    /// Has the template called `name` rebuild its `clones.json` from the bundles on disk.
    private func refreshCloneList(ofTemplate name: String?) {
        guard let name else { return }
        _ = VMBundle.named(name, in: vmDirectory)?.liveClones()
    }

    private func makeSession(bundle: VMBundle, config: VMConfig, engine: EngineLocator.Engine) -> VMSession {
        let controller = VMController(bundle: bundle, config: config, engine: engine)
        let session = VMSession(bundle: bundle, config: config, controller: controller)
        session.onStateChange = { [weak self] _ in self?.refreshDockBadge() }
        return session
    }

    private func sorted(_ list: [VMSession]) -> [VMSession] {
        list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func ensureDirectory() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: vmDirectory.path) else { return }
        do {
            try fm.createDirectory(at: vmDirectory, withIntermediateDirectories: true)
        } catch {
            pendingError = "Could not create the VM directory at \(vmDirectory.path).\n\(ErrorText.describe(error))"
        }
    }

    /// Reload when bundles are added or removed behind the app's back.
    private func watchDirectory() {
        let fd = open(vmDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        directoryWatcher = source
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            reloadScheduled = false
            reload()
        }
    }
}
