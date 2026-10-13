import Foundation
import AlcoveEngine
import AlcoveAgent
import AlcoveQMP

/// `vm.deploy`: copies a host file or directory into a guest folder, optionally runs an installer and launches a program.
/// Built on the agent's `proc.*`, `fs.*`, `exec.run` and `app.launch` operations.
extension ControlHandler {
    static let defaultDeployWaitSeconds = 20.0
    static let installTimeoutMilliseconds = 900_000
    /// The installer exit code that means success with a restart pending.
    static let installRestartCode = 3010
    static let defaultGuestRoot = "C:\\alcove-apps"

    private struct InstallPlan {
        let msi: Bool
        let file: String
        let args: [JSON]
    }

    private struct LaunchPlan {
        let exe: String
        var fields: [String: JSON]
    }

    func deploy(_ params: JSON) async throws -> JSON {
        let op = "vm.deploy"
        let path = try string(params, "path")
        var requestedDir: String?
        if let value = params["guestDir"], value != .null {
            guard let text = value.stringValue, !ControlHandler.trimmingSeparators(text).isEmpty else { throw ControlError.missing("guestDir") }
            requestedDir = text
        }
        let killRunning = try optional(params, "killRunning", .boolean)?.boolValue ?? true
        let waitMs = try waitWindowMilliseconds(params, default: ControlHandler.defaultDeployWaitSeconds)
        let install = try installPlan(params["install"])
        let launching = try launchPlan(params["launch"])

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ControlError.failed("'\(path)' does not exist on the host; check the path")
        }
        let source = URL(fileURLWithPath: path)
        let t = try await running(params)
        let guestDir: String
        if let requestedDir {
            guestDir = ControlHandler.trimmingSeparators(requestedDir)
        } else {
            let base = (isDirectory.boolValue ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent)
                .precomposedStringWithCanonicalMapping
            let fallback = ControlHandler.defaultGuestRoot + "\\" + base
            guard await t.guestOS() == .windows else {
                throw ControlError.failed("pass guestDir; the default \(fallback) only fits Windows guests")
            }
            guestDir = fallback
        }
        let agent = try await tools(t)

        var out: [String: JSON] = ["guestDir": .string(guestDir)]
        do {
            if killRunning { try await stopProcesses(under: guestDir, agent) }
            if isDirectory.boolValue {
                let r = try await agent.syncDirectory(source, toGuestPath: guestDir, deleteExtras: true)
                out["sent"] = .array(r.sent.map(JSON.string)); out["skipped"] = .int(Int64(r.skipped)); out["bytes"] = .int(Int64(r.bytes))
            } else {
                let name = source.lastPathComponent.precomposedStringWithCanonicalMapping
                let r = try await agent.pushFile(source, toGuestPath: ControlHandler.guestPath(name, in: guestDir), overwrite: true)
                out["sent"] = [.string(name)]; out["skipped"] = 0; out["bytes"] = .int(Int64(r.bytes))
            }
            if let install { out["installCode"] = .int(Int64(try await runInstaller(install, in: guestDir, agent))) }
            if let launching {
                var request = launching.fields
                request["path"] = .string(ControlHandler.guestPath(launching.exe, in: guestDir))
                if request["cwd"] == nil { request["cwd"] = .string(guestDir) }
                let started = try await launch(agent, request, waitMs: waitMs)
                if let pid = started["pid"] { out["pid"] = pid }
                if let window = started["window"] { out["window"] = window }
            }
        } catch {
            throw agentFailure(error, vm: t.name, op: op)
        }
        return .object(out)
    }

    // MARK: - parameters

    private nonisolated func installPlan(_ value: JSON?) throws -> InstallPlan? {
        guard let value, value != .null else { return nil }
        guard let kind = value["kind"]?.stringValue, kind == "msi" || kind == "exe", let file = value["file"]?.stringValue, !file.isEmpty else {
            throw ControlError.failed("install needs kind 'msi' or 'exe' and a string 'file'")
        }
        var args: [JSON] = []
        if let list = value["args"], list != .null {
            guard let items = list.arrayValue, items.allSatisfy(isString) else { throw ControlError.failed("install.args must be an array of strings") }
            args = items
        }
        return InstallPlan(msi: kind == "msi", file: file, args: args)
    }

    private nonisolated func launchPlan(_ value: JSON?) throws -> LaunchPlan? {
        guard let value, value != .null else { return nil }
        guard let exe = value["exe"]?.stringValue, !exe.isEmpty else { throw ControlError.failed("launch needs a string 'exe'") }
        var fields: [String: JSON] = [:]
        if let args = value["args"], args != .null {
            guard let items = args.arrayValue, items.allSatisfy(isString) else { throw ControlError.failed("launch.args must be an array of strings") }
            fields["args"] = args
        }
        if let env = value["env"], env != .null {
            guard let entries = env.objectValue, entries.values.allSatisfy(isString) else { throw ControlError.failed("launch.env must be an object of strings") }
            fields["env"] = env
        }
        if let cwd = value["cwd"], cwd != .null {
            guard cwd.stringValue != nil else { throw ControlError.failed("launch.cwd must be a string") }
            fields["cwd"] = cwd
        }
        return LaunchPlan(exe: exe, fields: fields)
    }

    // MARK: - guest paths

    /// Whether `path` is written the Windows way: with a backslash or a drive letter.
    static func isWindowsPath(_ path: String) -> Bool {
        if path.contains("\\") { return true }
        let scalars = Array(path.unicodeScalars.prefix(2))
        return scalars.count == 2 && scalars[1] == ":" && scalars[0].isASCII && scalars[0].properties.isAlphabetic
    }

    /// `path` without separators at its end; a root such as `/` or `C:\` stays as it is.
    static func trimmingSeparators(_ path: String) -> String {
        var out = path
        while out.count > 1, let last = out.last, last == "\\" || last == "/", !out.dropLast().hasSuffix(":") { out.removeLast() }
        return out
    }

    /// `path` when it is absolute in the guest, otherwise `path` below `directory` with the directory's separator.
    static func guestPath(_ path: String, in directory: String) -> String {
        if path.hasPrefix("/") || path.hasPrefix("\\") || (isWindowsPath(path) && path.unicodeScalars.dropFirst().first == ":") { return path }
        let separator = isWindowsPath(directory) ? "\\" : "/"
        let tail = separator == "\\" ? path.replacingOccurrences(of: "/", with: "\\") : path
        return directory.hasSuffix(separator) ? directory + tail : directory + separator + tail
    }

    /// Whether the executable at `path` lies below `directory`; Windows paths compare without regard to case or the kind of separator.
    static func isPath(_ path: String, under directory: String) -> Bool {
        guard !path.isEmpty else { return false }
        guard isWindowsPath(directory) else {
            return path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
        }
        func fold(_ s: String) -> String { s.replacingOccurrences(of: "/", with: "\\").precomposedStringWithCanonicalMapping.lowercased() }
        let root = fold(directory)
        return fold(path).hasPrefix(root.hasSuffix("\\") ? root : root + "\\")
    }

    // MARK: - steps

    /// The processes whose executable lies below `directory`.
    private func processes(under directory: String, _ agent: AgentClient) async throws -> [JSON] {
        let list = try await agent.call("proc.list")["procs"]?.arrayValue ?? []
        return list.filter { ControlHandler.isPath($0["path"]?.stringValue ?? "", under: directory) }
    }

    /// Kills the process trees running from `directory` and waits until none is left; fails when one survives `processExitTimeout`.
    private func stopProcesses(under directory: String, _ agent: AgentClient) async throws {
        var running = try await processes(under: directory, agent)
        guard !running.isEmpty else { return }
        for process in running {
            guard let pid = process["pid"] else { continue }
            do { _ = try await agent.call("proc.kill", ["pid": pid, "tree": true]) } catch AgentClient.AgentError.remote { continue }
        }
        let deadline = ContinuousClock.now + UITiming.processExitTimeout
        while true {
            running = try await processes(under: directory, agent)
            guard let survivor = running.first else { return }
            if ContinuousClock.now >= deadline {
                let name = survivor["name"]?.stringValue ?? "a process"
                let pid = survivor["pid"]?.intValue.map { " (pid \($0))" } ?? ""
                throw ControlError.failed("\(name)\(pid) under '\(directory)' is still running after vm.deploy tried to stop it; "
                                          + "stop it with vm.process.kill or pass another guestDir")
            }
            try await Task.sleep(for: UITiming.processPoll)
        }
    }

    /// Runs the installer without a shell and returns its exit code; a code other than 0 and `installRestartCode`, or a timeout, fails.
    private func runInstaller(_ plan: InstallPlan, in guestDir: String, _ agent: AgentClient) async throws -> Int {
        let file = ControlHandler.guestPath(plan.file, in: guestDir)
        let argv: [JSON] = plan.msi ? ["msiexec.exe", "/i", .string(file), "/qn", "/norestart"] + plan.args : [.string(file)] + plan.args
        let seconds = ControlHandler.installTimeoutMilliseconds / 1000
        let r = try await agent.call("exec.run", ["argv": .array(argv), "cwd": .string(guestDir),
                                                  "timeout_ms": .int(Int64(ControlHandler.installTimeoutMilliseconds))],
                                     timeout: .seconds(seconds + 15))
        if r["timed_out"]?.boolValue == true {
            throw ControlError.failed("installer '\(file)' did not finish within \(seconds) s and was stopped; run it with vm.exec.start to see where it waits")
        }
        let code = r["code"]?.intValue ?? -1
        guard code == 0 || code == ControlHandler.installRestartCode else {
            let err = (r["stderr"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let said = err.isEmpty ? (r["stdout"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : err
            throw ControlError.failed("installer '\(file)' exited with code \(code)\(said.isEmpty ? "" : ": \(said)"); "
                                      + "fix the installer or its arguments and call vm.deploy again")
        }
        return code
    }
}
