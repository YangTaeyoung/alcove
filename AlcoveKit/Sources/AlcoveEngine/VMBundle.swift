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

    public init(url: URL) { self.url = url }

    public func diskURL(_ disk: VMConfig.Disk) -> URL { url.appendingPathComponent(disk.fileName) }

    public func loadConfig() throws -> VMConfig {
        try VMConfig.decode(try Data(contentsOf: configURL))
    }

    public func save(_ config: VMConfig) throws {
        try config.validate()
        try config.encoded().write(to: configURL, options: .atomic)
    }

    /// Whether a suspended state exists to resume from.
    public var isSuspended: Bool { FileManager.default.fileExists(atPath: suspendStateURL.path) }

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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: engine.qemuImg)
        p.arguments = ["create", "-q", "-f", "qcow2", diskURL(disk).path, "\(disk.sizeGiB)G"]
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

    /// Bundles found directly inside `directory`.
    public static func list(in directory: URL, fileManager fm: FileManager = .default) -> [VMBundle] {
        let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == pathExtension && fm.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(VMBundle.init(url:))
    }
}
