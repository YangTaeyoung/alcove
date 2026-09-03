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
        case notFound(searched: [String])
    }

    /// Candidate engine roots, in priority order. Each root must contain
    /// `qemu-system-aarch64` and `qemu-img` (either directly or under `bin/`)
    /// and the firmware (directly, under `pc-bios/`, or under `share/qemu/`).
    public var roots: [String]

    public init(roots: [String]) { self.roots = roots }

    /// Default search order: `$ALCOVE_QEMU_DIR`, the app bundle's `Resources/qemu`,
    /// the development build tree next to this package, then Homebrew.
    public static func standard(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> EngineLocator {
        var roots: [String] = []
        if let env = environment["ALCOVE_QEMU_DIR"] { roots.append(env) }
        if let res = bundle.resourcePath { roots.append(res + "/qemu") }
        roots.append(developmentBuildRoot)
        roots.append("/opt/homebrew")
        return EngineLocator(roots: roots)
    }

    /// `<repo>/build/qemu-build`, derived from this source file's location.
    public static var developmentBuildRoot: String {
        // .../AlcoveKit/Sources/AlcoveEngine/EngineLocator.swift -> repo root
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repo.appendingPathComponent("build/qemu-build").path
    }

    public func locate(fileManager fm: FileManager = .default) throws -> Engine {
        for root in roots {
            let binDirs = [root, root + "/bin"]
            guard let bin = binDirs.first(where: { fm.isExecutableFile(atPath: $0 + "/qemu-system-aarch64") }),
                  fm.isExecutableFile(atPath: bin + "/qemu-img") else { continue }
            let fwDirs = [root + "/pc-bios", root + "/share/qemu", root]
            guard let fw = fwDirs.first(where: { fm.fileExists(atPath: $0 + "/edk2-aarch64-code.fd") }) else { continue }
            let swtpmCandidates = [bin + "/swtpm", "/opt/homebrew/bin/swtpm", "/usr/local/bin/swtpm"]
            return Engine(qemuSystem: bin + "/qemu-system-aarch64", qemuImg: bin + "/qemu-img", firmwareDir: fw,
                          swtpm: swtpmCandidates.first { fm.isExecutableFile(atPath: $0) })
        }
        throw LocateError.notFound(searched: roots)
    }
}
