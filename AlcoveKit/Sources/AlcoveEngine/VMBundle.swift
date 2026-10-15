import Foundation
import CryptoKit

/// A VM on disk: `<name>.alcovevm/` holding `config.json`, disk images, the
/// UEFI variable store and a scratch `run/` directory used while running.
public struct VMBundle: Sendable, Equatable {
    public static let pathExtension = "alcovevm"

    public enum BundleError: Error, Equatable, Sendable {
        case alreadyExists(String)
        case notABundle(String)
        case qemuImgFailed(String)
        case missingFirmware
    }

    public let url: URL
    public var configURL: URL { url.appendingPathComponent("config.json") }
    public var efiVarsURL: URL { url.appendingPathComponent("efi-vars.fd") }
    public var runURL: URL { url.appendingPathComponent("run") }
    public var suspendStateURL: URL { url.appendingPathComponent("suspend.state") }
    /// The configuration the engine ran with when it was suspended; a resume must
    /// launch exactly that machine, whatever `config.json` says by then.
    public var suspendConfigURL: URL { url.appendingPathComponent("suspend.config.json") }
    /// Unix socket paths are limited to 104 bytes on macOS, so sockets live in a
    /// short per-VM directory under /tmp keyed by a hash of the bundle path.
    public var socketDirectory: String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        let short = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "/tmp/alcove-\(getuid())/\(short)"
    }
    public var displaySocketPath: String { socketDirectory + "/display.sock" }
    public var qmpSocketPath: String { socketDirectory + "/qmp.sock" }
    public var swtpmSocketPath: String { socketDirectory + "/swtpm.sock" }
    public var tpmStateURL: URL { url.appendingPathComponent("tpm") }
    public var serialLogURL: URL { runURL.appendingPathComponent("serial.log") }
    public var qemuLogURL: URL { runURL.appendingPathComponent("qemu.log") }
    /// Written by QEMU (`-pidfile`) and write-locked for as long as it lives.
    public var pidFileURL: URL { runURL.appendingPathComponent("qemu.pid") }

    public init(url: URL) { self.url = url }

    public func diskURL(_ disk: VMConfig.Disk) -> URL { url.appendingPathComponent(disk.fileName) }

    /// Load `config.json`. Fields added after the bundle was written (the guest
    /// agent token, port and key) are synthesized by the decoder and written
    /// back at once; a migrated config is returned as `save` wrote it.
    public func loadConfig() throws -> VMConfig {
        let data = try Data(contentsOf: configURL)
        let config = try VMConfig.decode(data)
        if VMConfig.needsMigration(data) {
            return (try? save(config)) ?? config
        }
        return config
    }

    /// Held by `save` from reading the stored config to writing the merged one, and by
    /// `advanceDiskEpoch` from reading the stored config to saving it; one lock for every bundle in the process.
    private static let configLock = NSRecursiveLock()

    /// Validates `config` and writes it to `config.json` with the stored config's disk identity
    /// preserved (`preservingStoredDiskIdentity`) and the stored `agentKey` kept when `config.json` holds one.
    /// Returns the configuration that was written.
    /// Reading the stored config and writing run under `configLock`.
    @discardableResult
    public func save(_ config: VMConfig) throws -> VMConfig {
        try config.validate()
        VMBundle.configLock.lock()
        defer { VMBundle.configLock.unlock() }
        var written = preservingStoredDiskIdentity(config)
        if let key = storedAgentKey() { written.agentKey = key }
        try written.encoded().write(to: configURL, options: .atomic)
        return written
    }

    /// `config` with the disk identity fields of the stored `config.json` preserved
    /// (`VMConfig.preservingDiskIdentity`); `config` itself when no stored config can be read.
    func preservingStoredDiskIdentity(_ config: VMConfig) -> VMConfig {
        storedConfig().map { config.preservingDiskIdentity(from: $0) } ?? config
    }

    /// The `agentKey` string stored in `config.json`, or nil when the file or the field is missing.
    func storedAgentKey() -> String? {
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["agentKey"] as? String
    }

    /// Whether a suspended state exists to resume from.
    public var isSuspended: Bool { FileManager.default.fileExists(atPath: suspendStateURL.path) }

    /// The configuration saved next to `suspend.state`, or nil when absent or unreadable.
    public func loadSuspendedConfig() -> VMConfig? {
        guard let data = try? Data(contentsOf: suspendConfigURL) else { return nil }
        return try? VMConfig.decode(data)
    }

    /// Forget a suspended session so the next start boots from scratch.
    public func discardSuspendState(fileManager fm: FileManager = .default) throws {
        for u in [suspendStateURL, suspendConfigURL] where fm.fileExists(atPath: u.path) {
            try fm.removeItem(at: u)
        }
    }

    /// Create a new bundle: directory, config, disk images (qcow2) and the UEFI
    /// variable store (copied from the engine's template, else zero-filled).
    public static func create(_ config: VMConfig, in directory: URL, engine: EngineLocator.Engine,
                              fileManager fm: FileManager = .default) throws -> VMBundle {
        try config.validate()
        let url = directory.appendingPathComponent(config.name).appendingPathExtension(pathExtension)
        guard !fm.fileExists(atPath: url.path) else { throw BundleError.alreadyExists(url.path) }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let bundle = VMBundle(url: url)
        do {
            try fm.createDirectory(at: bundle.runURL, withIntermediateDirectories: true)
            try bundle.save(config)
            for disk in config.disks {
                try bundle.createDisk(disk, engine: engine)
            }
            try bundle.resetFirmwareVars(engine: engine)
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return bundle
    }

    /// `qemu-img create -f qcow2 <file> <size>G`
    public func createDisk(_ disk: VMConfig.Disk, engine: EngineLocator.Engine) throws {
        try VMBundle.qemuImg(["create", "-q", "-f", "qcow2", diskURL(disk).path, "\(disk.sizeGiB)G"], engine: engine)
    }

    /// `qemu-img create -f qcow2 -F qcow2 -b <backing> <overlay>`
    public static func createOverlay(at overlay: URL, backing: URL, engine: EngineLocator.Engine) throws {
        try qemuImg(["create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", backing.path, overlay.path], engine: engine)
    }

    /// Runs `qemu-img` with `arguments`; a non-zero exit throws `qemuImgFailed` with its error output.
    private static func qemuImg(_ arguments: [String], engine: EngineLocator.Engine) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: engine.qemuImg)
        p.arguments = arguments
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw BundleError.qemuImgFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// (Re)create the UEFI variable store from the engine template (64 MiB, zero-filled fallback).
    public func resetFirmwareVars(engine: EngineLocator.Engine, fileManager fm: FileManager = .default) throws {
        if fm.fileExists(atPath: efiVarsURL.path) { try fm.removeItem(at: efiVarsURL) }
        if let template = engine.firmwareVarsTemplate {
            try fm.copyItem(atPath: template, toPath: efiVarsURL.path)
        } else {
            try Data(count: 64 * 1024 * 1024).write(to: efiVarsURL)
        }
    }

    /// Empty the scratch directory (shared framebuffer files, logs) and the
    /// socket directory (stale sockets), creating both.
    public func prepareRunDirectory(fileManager fm: FileManager = .default) throws {
        if fm.fileExists(atPath: runURL.path) { try fm.removeItem(at: runURL) }
        try fm.createDirectory(at: runURL, withIntermediateDirectories: true)
        if fm.fileExists(atPath: socketDirectory) { try fm.removeItem(atPath: socketDirectory) }
        try fm.createDirectory(atPath: socketDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Bundles found directly inside `directory`, which may be or pass through a symbolic link. Each bundle's URL is
    /// `directory` as given plus the bundle's name; a bundle that is itself a symbolic link keeps its own name.
    public static func list(in directory: URL, fileManager fm: FileManager = .default) -> [VMBundle] {
        let names = (try? fm.contentsOfDirectory(atPath: directory.resolvingSymlinksInPath().path)) ?? []
        return names.map { directory.appendingPathComponent($0) }
            .filter { $0.pathExtension == pathExtension && fm.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(VMBundle.init(url:))
    }
}

// MARK: - linked clones and sessions that discard changes

extension VMBundle {
    public enum CloneError: Error, Equatable, Sendable, CustomStringConvertible {
        case sourceRunning(String)
        case sourceSuspended(String)
        case sourceIsClone(String, template: String)
        case sourceHasTPM
        case invalidName(String)
        case nameExists(String)
        case notAClone(String)
        case cloneRunning(String)
        case overlayFailed(String)
        case noFreeAgentPort(String)

        public var description: String {
            switch self {
            case .noFreeAgentPort(let directory):
                return "every guest-tools port from 17000 to 17999 is used by a VM in \(directory); "
                    + "delete a VM there or move it to another folder, then clone again"
            case .overlayFailed(let m):
                return "qemu-img could not create the clone's disk (\(m)); check the template's disk images and the free space, then clone again"
            case .sourceRunning(let n): return "'\(n)' is running; stop it before cloning it"
            case .sourceSuspended(let n): return "'\(n)' has a suspended session; resume and shut it down, or discard the suspended state, before cloning it"
            case .sourceIsClone(let n, let template): return "'\(n)' is a clone of '\(template)'; clone '\(template)' instead"
            case .sourceHasTPM: return "cannot clone a VM with a TPM"
            case .invalidName(let n): return "'\(n)' cannot be used as a VM name; choose a non-empty name without '/', ':' or ','"
            case .nameExists(let n): return "a VM named '\(n)' already exists; choose another name"
            case .notAClone(let n): return "'\(n)' is not a clone; delete it in the Alcove app"
            case .cloneRunning(let n): return "'\(n)' is running; stop it before deleting it"
            }
        }
    }

    /// JSON array of the absolute paths of the bundles cloned from this one.
    public var clonesURL: URL { url.appendingPathComponent("clones.json") }
    /// The name in `config.json`; the directory name when the config cannot be read.
    public var configName: String { storedConfig()?.name ?? url.deletingPathExtension().lastPathComponent }
    /// `config.json` as stored, without writing migrated fields back.
    func storedConfig() -> VMConfig? { try? VMConfig.decode(Data(contentsOf: configURL)) }
    /// Whether an engine process holds this bundle's pidfile lock.
    public var isRunning: Bool { VMController.pidfileLockHolder(pidFileURL.path) != nil }
    /// The host of the engine that holds this bundle's pidfile lock when `VMController.otherHost(ofEngine:)`
    /// names one; nil otherwise.
    public var otherEngineHost: (name: String, pid: pid_t)? {
        VMController.pidfileLockHolder(pidFileURL.path).flatMap(VMController.otherHost(ofEngine:))
    }
    /// The disk image a session that discards changes writes to in place of `diskURL(disk)`.
    public func ephemeralDiskURL(_ disk: VMConfig.Disk) -> URL { runURL.appendingPathComponent("ephemeral-\(disk.id).qcow2") }
    /// The UEFI variable store a session that discards changes writes to in place of `efiVarsURL`.
    public var ephemeralEFIVarsURL: URL { runURL.appendingPathComponent("ephemeral-efi-vars.fd") }

    /// The bundles whose config names this bundle's config name as `cloneOf`: those listed in
    /// clones.json plus those in this bundle's parent directory, once each by standardized path.
    /// A bundle listed in clones.json whose config.json exists but cannot be decoded also counts.
    /// clones.json is rewritten to that set; an undecodable file counts as an empty list.
    public func liveClones(fileManager fm: FileManager = .default) -> [URL] {
        let name = configName, own = url.standardizedFileURL.path
        let listed = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: clonesURL))) ?? []
        let siblings = VMBundle.list(in: url.deletingLastPathComponent(), fileManager: fm).map(\.url)
        var live: [String] = []
        for (index, candidate) in (listed.map({ URL(fileURLWithPath: $0) }) + siblings).enumerated() {
            let path = candidate.standardizedFileURL.path
            guard path != own, !live.contains(path) else { continue }
            let bundle = VMBundle(url: candidate)
            if let config = bundle.storedConfig() {
                guard config.cloneOf == name else { continue }
            } else {
                guard index < listed.count, fm.fileExists(atPath: bundle.configURL.path) else { continue }
            }
            live.append(path)
        }
        if live != listed || (live.isEmpty && fm.fileExists(atPath: clonesURL.path)) { try? writeClones(live, fileManager: fm) }
        return live.map { URL(fileURLWithPath: $0) }
    }

    /// The bundle in `directory` whose config is named `name`.
    public static func named(_ name: String, in directory: URL, fileManager fm: FileManager = .default) -> VMBundle? {
        list(in: directory, fileManager: fm).first { $0.storedConfig()?.name == name }
    }

    /// Writes `paths` to clones.json; an empty list removes the file.
    private func writeClones(_ paths: [String], fileManager fm: FileManager) throws {
        guard !paths.isEmpty else {
            if fm.fileExists(atPath: clonesURL.path) { try fm.removeItem(at: clonesURL) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(paths).write(to: clonesURL, options: .atomic)
    }

    /// New bundle next to this one, named `newName` without surrounding whitespace, whose disks are
    /// qcow2 overlays backed by this bundle's disks, with a copy of the UEFI variables, a fresh token,
    /// `agentKey` and MAC, an agent port no bundle in the directory uses, no CD-ROMs, USB passthrough or static
    /// forwards, and `cloneOf` set. The clone is added to `clones.json`.
    /// The overlays reference the template's disk files by absolute path.
    /// A template without a `diskEpoch` is saved with `diskEpoch` 0 and, when it has none, a new UUID
    /// string as `diskID`, before anything of the clone is created.
    /// The clone records the template's `diskEpoch` as `templateEpoch`, its `diskID` as
    /// `templateDiskID` and this bundle's standardized path as `templatePath`.
    public func cloneLinked(named newName: String, engine: EngineLocator.Engine, fileManager fm: FileManager = .default) throws -> VMBundle {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = url.deletingLastPathComponent()
        var source = try loadConfig()
        if let template = source.cloneOf { throw CloneError.sourceIsClone(source.name, template: template) }
        guard !source.tpm else { throw CloneError.sourceHasTPM }
        guard !isRunning else { throw CloneError.sourceRunning(source.name) }
        guard !isSuspended else { throw CloneError.sourceSuspended(source.name) }
        let epoch = source.diskEpoch ?? 0
        let diskID = source.diskEpoch == nil ? (source.diskID ?? UUID().uuidString.lowercased()) : source.diskID

        let takenPorts = Set(VMBundle.list(in: directory, fileManager: fm).compactMap { $0.storedConfig() }.flatMap(\.hostTCPPorts)
                             + source.hostTCPPorts)
        guard !VMConfig.agentPorts.allSatisfy(takenPorts.contains) else { throw CloneError.noFreeAgentPort(directory.path) }
        var token = UUID().uuidString.lowercased(), attempts = 0
        while takenPorts.contains(VMConfig.agentPort(for: token)), attempts < VMBundle.tokenAttempts {
            token = UUID().uuidString.lowercased()
            attempts += 1
        }
        guard !takenPorts.contains(VMConfig.agentPort(for: token)) else { throw CloneError.noFreeAgentPort(directory.path) }
        var network = VMConfig.Network.user(portForwards: [])
        if case .none = source.network { network = .none }
        let config = VMConfig(name: newName, guestOS: source.guestOS, cpuCount: source.cpuCount, memoryMiB: source.memoryMiB,
                              disks: source.disks, network: network, display: source.display,
                              sharedFolders: source.sharedFolders, agentToken: token, agentKey: VMConfig.randomAgentKey(), cloneOf: source.name,
                              templateEpoch: epoch, templatePath: url.standardizedFileURL.path, templateDiskID: diskID)
        do {
            try config.validate()
        } catch VMConfig.ValidationError.emptyName, VMConfig.ValidationError.invalidName {
            throw CloneError.invalidName(newName)
        }
        let clone = VMBundle(url: directory.appendingPathComponent(newName).appendingPathExtension(VMBundle.pathExtension))
        guard !fm.fileExists(atPath: clone.url.path), VMBundle.named(newName, in: directory, fileManager: fm) == nil else {
            throw CloneError.nameExists(newName)
        }
        if source.diskEpoch == nil {
            source.diskEpoch = epoch
            source.diskID = diskID
            try save(source)
        }

        do {
            try fm.createDirectory(at: clone.runURL, withIntermediateDirectories: true)
            try clone.save(config)
            for disk in source.disks {
                try VMBundle.createOverlay(at: clone.diskURL(disk), backing: diskURL(disk), engine: engine)
            }
            try fm.copyItem(at: efiVarsURL, to: clone.efiVarsURL)
            try writeClones(liveClones(fileManager: fm).map(\.path), fileManager: fm)
        } catch {
            try? fm.removeItem(at: clone.url)
            _ = liveClones(fileManager: fm)
            if case BundleError.qemuImgFailed(let message) = error { throw CloneError.overlayFailed(message) }
            throw error
        }
        return clone
    }

    /// Tokens tried by `cloneLinked` to find an agent port no bundle in the directory uses.
    private static let tokenAttempts = 100_000

    /// Removes this clone's bundle directory, its socket directory and its entry in the template's `clones.json`.
    /// The template is the bundle at the clone's `templatePath` when its config is named `cloneOf`, otherwise
    /// the bundle named `cloneOf` in this bundle's directory.
    public func deleteClone(fileManager fm: FileManager = .default) throws {
        let config = try loadConfig()
        guard let template = config.cloneOf else { throw CloneError.notAClone(config.name) }
        guard !isRunning else { throw CloneError.cloneRunning(config.name) }
        try fm.removeItem(at: url)
        try? fm.removeItem(atPath: socketDirectory)
        let recorded = config.templatePath.map { VMBundle(url: URL(fileURLWithPath: $0)) }
        let templateBundle = recorded.flatMap { $0.storedConfig()?.name == template ? $0 : nil }
            ?? VMBundle.named(template, in: url.deletingLastPathComponent(), fileManager: fm)
        _ = templateBundle?.liveClones(fileManager: fm)
    }

    /// The sentence that refuses to start a VM configured as `config`; nil when `config` has no
    /// `templateEpoch`, or when the `config.json` of the bundle at its `templatePath` stores a
    /// `diskID` equal to its `templateDiskID` and a `diskEpoch` equal to its `templateEpoch`.
    public static func templateMismatch(for config: VMConfig) -> String? {
        guard let epoch = config.templateEpoch else { return nil }
        guard let path = config.templatePath, let template = VMBundle(url: URL(fileURLWithPath: path)).storedConfig() else {
            return "the template of '\(config.name)' was not found at \(config.templatePath ?? "an unrecorded path"); "
                + "the clone cannot run without it"
        }
        guard template.diskID == config.templateDiskID else {
            return "the VM at \(path) is not the template '\(config.name)' was cloned from; the clone cannot run"
        }
        guard template.diskEpoch == epoch else {
            return "the template '\(template.name)' was started after '\(config.name)' was cloned from it, "
                + "so the clone's disk no longer matches; delete the clone and clone again"
        }
        return nil
    }

    /// Saves `config.json` as stored with `diskEpoch` raised by one and returns the new value.
    /// Returns nil and writes nothing when the stored config has no `diskEpoch` or cannot be read.
    /// Reading, raising and saving run under `configLock`.
    public func advanceDiskEpoch() throws -> Int? {
        VMBundle.configLock.lock()
        defer { VMBundle.configLock.unlock() }
        guard var stored = storedConfig(), let epoch = stored.diskEpoch else { return nil }
        stored.diskEpoch = epoch + 1
        try save(stored)
        return epoch + 1
    }

    /// Removes the overlays and the UEFI variable copy of a session that discards changes.
    public func removeEphemeralFiles(fileManager fm: FileManager = .default) {
        for name in (try? fm.contentsOfDirectory(atPath: runURL.path)) ?? [] where name.hasPrefix("ephemeral-") {
            try? fm.removeItem(at: runURL.appendingPathComponent(name))
        }
    }
}
