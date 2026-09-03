import Foundation

/// Finds the QEMU engine (binary, qemu-img, firmware) and swtpm.
public struct EngineLocator: Sendable, Equatable {
    public struct Engine: Sendable, Equatable {
        public var qemuSystem: String
        public var qemuImg: String
        /// Directory containing `edk2-aarch64-code.fd` and `edk2-arm-vars.fd`.
        public var firmwareDir: String
        public var swtpm: String?

        public var firmwareCode: String { firmwareDir + "/edk2-aarch64-code.fd" }
        /// The variable-store template; nil when the engine does not ship one.
        public var firmwareVarsTemplate: String? {
            let p = firmwareDir + "/edk2-arm-vars.fd"
            return FileManager.default.fileExists(atPath: p) ? p : nil
        }
    }

    public enum LocateError: Error, Equatable, Sendable {
        /// Every root that was tried, each with the reason it was rejected.
        case notFound(searched: [String])
    }

    /// Candidate engine roots, in priority order. Each root must contain
    /// `qemu-system-aarch64` and `qemu-img` (either directly or under `bin/`)
    /// and the firmware (directly, under `pc-bios/`, or under `share/qemu/`).
    public var roots: [String]

    public init(roots: [String]) { self.roots = roots }

    /// Default search order: `$ALCOVE_QEMU_DIR`, the app bundle's `Resources/qemu`,
    /// the development build tree next to this package, engines on `$PATH`
    /// (`<prefix>/bin` entries map to `<prefix>`), then Homebrew. A stock QEMU
    /// found anywhere here is rejected by `locate()` because it lacks the
    /// `alcove` display backend.
    public static func standard(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> EngineLocator {
        var roots: [String] = []
        if let env = environment["ALCOVE_QEMU_DIR"] { roots.append(env) }
        if let res = bundle.resourcePath { roots.append(res + "/qemu") }
        roots.append(developmentBuildRoot)
        for dir in (environment["PATH"] ?? "").split(separator: ":").map(String.init) where dir.hasPrefix("/") {
            let root = dir.hasSuffix("/bin") ? String(dir.dropLast(4)) : dir
            if !root.isEmpty { roots.append(root) }
        }
        roots.append("/opt/homebrew")
        var seen = Set<String>()
        return EngineLocator(roots: roots.filter { seen.insert($0).inserted })
    }

    /// `<repo>/build/qemu-build`, derived from this source file's location.
    public static var developmentBuildRoot: String {
        // .../AlcoveKit/Sources/AlcoveEngine/EngineLocator.swift -> repo root
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("build/qemu-build").path
    }

    /// The first root holding the binaries, the firmware and the patched engine
    /// (its `qemu-system-aarch64` must offer the `alcove` display backend, which
    /// every VM needs; see `hasAlcoveDisplay`).
    public func locate(fileManager fm: FileManager = .default) throws -> Engine {
        var searched: [String] = []
        for root in roots {
            let binDirs = [root, root + "/bin"]
            guard let bin = binDirs.first(where: { fm.isExecutableFile(atPath: $0 + "/qemu-system-aarch64") }),
                  fm.isExecutableFile(atPath: bin + "/qemu-img") else {
                searched.append(root)
                continue
            }
            let fwDirs = [root + "/pc-bios", root + "/share/qemu", root]
            guard let fw = fwDirs.first(where: { fm.fileExists(atPath: $0 + "/edk2-aarch64-code.fd") }) else {
                searched.append("\(root) (no edk2-aarch64-code.fd)")
                continue
            }
            let qemu = bin + "/qemu-system-aarch64"
            guard Self.hasAlcoveDisplay(qemuSystem: qemu) else {
                searched.append("\(root) (qemu-system-aarch64 has no alcove display backend; not the patched engine)")
                continue
            }
            let swtpmCandidates = [bin + "/swtpm", "/opt/homebrew/bin/swtpm", "/usr/local/bin/swtpm"]
            return Engine(qemuSystem: qemu, qemuImg: bin + "/qemu-img", firmwareDir: fw,
                          swtpm: swtpmCandidates.first { fm.isExecutableFile(atPath: $0) })
        }
        throw LocateError.notFound(searched: searched)
    }

    /// Whether `qemuSystem` is the patched engine: `-display help` (system/vl.c
    /// `qemu_display_help`) must list `alcove`, which only exists with
    /// qemu-patches/0001-ui-add-alcove-display-backend.patch applied.
    public static func hasAlcoveDisplay(qemuSystem: String) -> Bool {
        guard let out = runCapturingOutput(qemuSystem, ["-display", "help"], timeout: 10) else { return false }
        // qemu_display_help() prints the header, then one backend name per line
        var inList = false
        for rawLine in out.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Available display backend types:") { inList = true; continue }
            if inList {
                if line.isEmpty { break }
                if line == "alcove" { return true }
            }
        }
        return false
    }

    /// stdout+stderr of a short-lived helper invocation; nil when it cannot be
    /// launched or does not exit within `timeout` seconds.
    private static func runCapturingOutput(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        // The help text is far below the pipe buffer, so reading after exit cannot deadlock.
        while p.isRunning && Date() < deadline { usleep(5_000) }
        if p.isRunning { p.terminate(); return nil }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
